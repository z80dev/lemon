defmodule CodingAgent.Session do
  @moduledoc """
  Main orchestrator GenServer that wraps AgentCore.Agent and integrates all CodingAgent components.

  The Session GenServer provides:
  - Session management via SessionManager for persistence
  - Message handling with CodingAgent.Messages conversion
  - Tool creation and management
  - Event broadcasting to subscribers
  - Steering and follow-up message queues
  - Navigation through session tree

  ## Usage

      {:ok, session} = CodingAgent.Session.start_link(
        cwd: "/path/to/project",
        model: my_model,
        system_prompt: "You are a helpful coding assistant."
      )

      # Subscribe to events
      unsub = CodingAgent.Session.subscribe(session)

      # Send a prompt
      :ok = CodingAgent.Session.prompt(session, "Help me write a function")

      receive do
        {:session_event, session_id, event} -> IO.inspect({session_id, event})
      end

      # Unsubscribe when done
      unsub.()
  """

  use GenServer
  require Logger

  # Small deferral so callers can (a) subscribe after `prompt/3` and still see early
  # events, and (b) queue immediate follow-ups/steering before the agent loop reaches
  # its end-of-run checks (avoids a race in very fast mock runs).
  @prompt_defer_ms 10
  @reset_abort_wait_ms 5_000

  alias AgentCore.Types.AgentTool
  alias LemonCore.Introspection
  alias CodingAgent.Extensions
  alias CodingAgent.Session.BackgroundTasks
  alias CodingAgent.Session.CompactionLifecycle
  alias CodingAgent.Session.CompactionManager
  alias CodingAgent.Session.EventHandler
  alias CodingAgent.Session.Lifecycle
  alias CodingAgent.Session.Notifier
  alias CodingAgent.Session.OverflowRecovery
  alias CodingAgent.Session.Persistence
  alias CodingAgent.Session.PromptComposer
  alias CodingAgent.Session.State
  alias CodingAgent.Session.WasmBridge
  alias CodingAgent.Wasm.SidecarSupervisor
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.{Session, SessionEntry}
  alias CodingAgent.UI.Context, as: UIContext
  alias CodingAgent.Messages.CustomMessage

  # ============================================================================
  # State
  # ============================================================================

  defstruct [
    :agent,
    :session_manager,
    :settings_manager,
    :ui_context,
    :cwd,
    :tools,
    :model,
    :thinking_level,
    :system_prompt,
    :explicit_system_prompt,
    :prompt_template,
    :workspace_dir,
    :extra_tools,
    :session_scope,
    :is_streaming,
    :pending_prompt_timer_ref,
    :event_listeners,
    :event_streams,
    :abort_signal,
    :steering_queue,
    :follow_up_queue,
    :turn_index,
    :started_at,
    :session_file,
    :register_session,
    :session_registry,
    :convert_to_llm,
    :transform_context,
    :tool_policy,
    :approval_context,
    :extensions,
    :hooks,
    :extension_status_report,
    :wasm_sidecar_pid,
    :wasm_tool_names,
    :wasm_status,
    :auto_compaction_in_progress,
    :auto_compaction_signature,
    :auto_compaction_task_pid,
    :auto_compaction_task_monitor_ref,
    :auto_compaction_task_timeout_ref,
    :overflow_recovery_in_progress,
    :overflow_recovery_attempted,
    :overflow_recovery_signature,
    :overflow_recovery_task_pid,
    :overflow_recovery_task_monitor_ref,
    :overflow_recovery_task_timeout_ref,
    :overflow_recovery_started_at_ms,
    :overflow_recovery_error_reason,
    :overflow_recovery_partial_state
  ]

  @type session_signature ::
          {String.t(), String.t() | nil, non_neg_integer(), non_neg_integer(), term(), term()}

  @type t :: %__MODULE__{
          agent: pid() | nil,
          session_manager: Session.t(),
          settings_manager: term() | nil,
          ui_context: UIContext.t() | nil,
          cwd: String.t(),
          tools: [AgentTool.t()],
          model: Ai.Types.Model.t(),
          thinking_level: AgentCore.Types.thinking_level(),
          system_prompt: String.t(),
          explicit_system_prompt: String.t() | nil,
          prompt_template: String.t() | nil,
          workspace_dir: String.t(),
          extra_tools: [AgentTool.t()],
          session_scope: :main | :subagent,
          is_streaming: boolean(),
          pending_prompt_timer_ref: reference() | nil,
          event_listeners: [{pid(), reference()}],
          event_streams: %{reference() => %{pid: pid(), stream: pid()}},
          abort_signal: reference() | nil,
          steering_queue: :queue.queue(),
          follow_up_queue: :queue.queue(),
          turn_index: non_neg_integer(),
          session_file: String.t() | nil,
          register_session: boolean(),
          session_registry: atom(),
          convert_to_llm: (list() -> list()),
          transform_context: (list(), reference() | nil ->
                                list() | {:ok, list()} | {:error, term()}),
          tool_policy: map() | nil,
          approval_context: map() | nil,
          extensions: [module()],
          hooks: keyword([function()]),
          extension_status_report: Extensions.extension_status_report() | nil,
          wasm_sidecar_pid: pid() | nil,
          wasm_tool_names: [String.t()],
          wasm_status: map() | nil,
          auto_compaction_in_progress: boolean(),
          auto_compaction_signature: session_signature() | nil,
          auto_compaction_task_pid: pid() | nil,
          auto_compaction_task_monitor_ref: reference() | nil,
          auto_compaction_task_timeout_ref: reference() | nil,
          overflow_recovery_in_progress: boolean(),
          overflow_recovery_attempted: boolean(),
          overflow_recovery_signature: session_signature() | nil,
          overflow_recovery_task_pid: pid() | nil,
          overflow_recovery_task_monitor_ref: reference() | nil,
          overflow_recovery_task_timeout_ref: reference() | nil,
          overflow_recovery_started_at_ms: non_neg_integer() | nil,
          overflow_recovery_error_reason: term() | nil,
          overflow_recovery_partial_state: term() | nil
        }

  @type event_handler_callbacks :: %{
          required(:set_working_message) => (t(), String.t() | nil -> :ok),
          required(:notify) => (t(), String.t(), CodingAgent.UI.notify_type() -> :ok),
          required(:complete_event_streams) => (t(), term() -> :ok),
          required(:maybe_trigger_compaction) => (t() -> t()),
          required(:persist_message) => (t(), term() -> t())
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts a new Session GenServer.

  ## Options (required)

    * `:cwd` - Working directory for the session

  ## Options (optional)

    * `:model` - The AI model to use (`Ai.Types.Model.t()`). If not provided,
      uses `default_model` from SettingsManager.
    * `:system_prompt` - Explicit system prompt text. Takes highest precedence
      in the composed prompt.
    * `:prompt_template` - Name of a prompt template to load via ResourceLoader.
      Templates are searched in `.lemon/prompts/`, `.claude/prompts/`, and
      `~/.lemon/agent/prompts/`.
    * `:workspace_dir` - Workspace directory for bootstrap files (default: `~/.lemon/agent/workspace`)
    * `:tools` - List of `AgentTool` structs (default: read, write, edit, bash)
    * `:extra_tools` - Additional `AgentTool` structs appended to the default toolset
    * `:session_file` - Path to existing session file to load
    * `:session_id` - Explicit session ID for new sessions (ignored when loading from file)
    * `:parent_session` - Parent session ID for fork lineage (ignored when loading from file)
    * `:ui_context` - UI context for dialogs and notifications
    * `:thinking_level` - Extended reasoning level. If not provided, uses
      `default_thinking_level` from SettingsManager.
    * `:register` - When true, register the session under its ID in `CodingAgent.SessionRegistry`
    * `:registry` - Registry module to use when registering (default: `CodingAgent.SessionRegistry`)
    * `:transform_context` - Optional custom context transform `(messages, signal) -> messages`
      composed after built-in guardrails and untrusted-output wrapping
    * `:context_guardrails` - Optional map/list overrides for built-in context guardrails
      (for example `max_tool_result_bytes`, `max_tool_result_images`, `spill_dir`)
    * `:name` - GenServer name for registration

  ## System Prompt Composition

  The final system prompt is composed from multiple sources, joined with newlines.
  Components are included in this order (most specific first):

  1. Explicit `:system_prompt` option (if provided)
  2. Prompt template content loaded via `:prompt_template` (if provided)
  3. Lemon base prompt (workspace bootstrap + skills)
  4. CLAUDE.md/AGENTS.md content from ResourceLoader (auto-loaded from cwd)

  Empty strings are filtered out before joining.
  The composed prompt is refreshed before each user prompt to pick up workspace/memory file edits.

  ## Examples

      # With explicit system prompt only
      {:ok, session} = CodingAgent.Session.start_link(
        cwd: "/home/user/project",
        model: my_model,
        system_prompt: "You are a helpful coding assistant."
      )

      # With prompt template (loads .lemon/prompts/review.md)
      {:ok, session} = CodingAgent.Session.start_link(
        cwd: "/home/user/project",
        model: my_model,
        prompt_template: "review"
      )

      # Auto-loads CLAUDE.md from project and home directories
      {:ok, session} = CodingAgent.Session.start_link(
        cwd: "/home/user/project",
        model: my_model
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Send a user prompt to the session.

  Returns `:ok` if the prompt was accepted, `{:error, :already_streaming}` if
  the session is already processing a prompt.

  ## Options

    * `:images` - List of image content blocks to include
  """
  @spec prompt(GenServer.server(), String.t(), keyword()) :: :ok | {:error, :already_streaming}
  def prompt(session, text, opts \\ []) do
    GenServer.call(session, {:prompt, text, opts})
  end

  @doc """
  Inject a steering message to interrupt the agent mid-run.

  Steering messages are delivered after the current tool execution completes,
  potentially skipping remaining tool calls.
  """
  @spec steer(GenServer.server(), String.t()) :: :ok
  def steer(session, text) do
    GenServer.cast(session, {:steer, text})
  end

  @doc """
  Add a follow-up message to be processed after the agent finishes.

  Follow-up messages are delivered only when the agent has no more tool calls
  and no steering messages.
  """
  @spec follow_up(GenServer.server(), String.t()) :: :ok
  def follow_up(session, text) do
    GenServer.cast(session, {:follow_up, text})
  end

  @doc """
  Add a structured async follow-up message to the session.
  """
  @spec handle_async_followup(GenServer.server(), CustomMessage.t() | String.t() | map()) :: :ok
  def handle_async_followup(session, message_or_attrs) do
    GenServer.call(session, {:handle_async_followup, message_or_attrs})
  end

  @doc """
  Abort the current operation.

  This signals cancellation to any running tool executions and stops the agent loop.
  """
  @spec abort(GenServer.server()) :: :ok
  def abort(session) do
    GenServer.cast(session, :abort)
  end

  @doc """
  Subscribe to session events.

  Events are sent as `{:session_event, session_id, event}`.

  ## Options

    * `:mode` - `:direct` (default, uses send/2) or `:stream` (uses EventStream with backpressure)
    * `:max_queue` - Max queue size for stream mode (default 1000)
    * `:drop_strategy` - How to handle overflow: `:drop_oldest`, `:drop_newest`, or `:error` (default :drop_oldest)

  ## Returns

    * For `:direct` mode: an unsubscribe function `(() -> :ok)`
    * For `:stream` mode: `{:ok, stream_pid}` where `stream_pid` is an `AgentCore.EventStream`

  ## Examples

      # Direct mode (legacy behavior)
      unsub = Session.subscribe(session)
      receive do
        {:session_event, _id, event} -> IO.inspect(event)
      end
      unsub.()

      # Stream mode with backpressure
      {:ok, stream} = Session.subscribe(session, mode: :stream)
      stream
      |> AgentCore.EventStream.events()
      |> Enum.each(fn {:session_event, _id, event} -> IO.inspect(event) end)
  """
  @spec subscribe(GenServer.server(), keyword()) :: (-> :ok) | {:ok, pid()}
  def subscribe(session, opts \\ []) do
    mode = Keyword.get(opts, :mode, :direct)
    GenServer.call(session, {:subscribe, self(), mode, opts})
  end

  @doc """
  Get the current session state.
  """
  @spec get_state(GenServer.server()) :: t()
  def get_state(session) do
    GenServer.call(session, :get_state)
  end

  @doc """
  Get session statistics including message count, token usage, etc.
  """
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(session) do
    GenServer.call(session, :get_stats)
  end

  @doc """
  Perform a lightweight health check for the session.
  """
  @spec health_check(GenServer.server()) :: map()
  def health_check(session) do
    GenServer.call(session, :health_check)
  end

  @doc """
  Return detailed diagnostics for the session.
  """
  @spec diagnostics(GenServer.server()) :: map()
  def diagnostics(session) do
    GenServer.call(session, :diagnostics)
  end

  @doc """
  Get the extension status report from session startup.

  Returns a structured report with loaded extensions, load errors,
  and tool conflicts. This is also published as an event at startup.

  ## Returns

  An `Extensions.extension_status_report()` map.
  """
  @spec get_extension_status_report(GenServer.server()) :: Extensions.extension_status_report()
  def get_extension_status_report(session) do
    GenServer.call(session, :get_extension_status_report)
  end

  @doc """
  Reload extensions without restarting the session.

  This function re-runs extension discovery, refreshes the tool registry,
  and updates the extension status report. Useful when extensions have been
  added, modified, or removed while the session is running.

  The reload process:
  1. Clears the extension module cache (purges loaded extension modules)
  2. Re-discovers and loads extensions from configured paths
  3. Rebuilds the tool list with conflict detection
  4. Updates the extension status report
  5. Broadcasts an `{:extension_status_report, report}` event

  ## Returns

    * `{:ok, report}` - The new extension status report
    * `{:error, :already_streaming}` - If the session is currently streaming

  ## Examples

      {:ok, report} = CodingAgent.Session.reload_extensions(session)
      IO.puts("Loaded \#{report.total_loaded} extensions")
  """
  @spec reload_extensions(GenServer.server()) ::
          {:ok, Extensions.extension_status_report()} | {:error, :already_streaming}
  def reload_extensions(session) do
    GenServer.call(session, :reload_extensions)
  end

  @doc """
  Reset the session, clearing all messages and restarting.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(session) do
    GenServer.call(session, :reset)
  end

  @doc """
  Switch to a different model.
  """
  @spec switch_model(GenServer.server(), Ai.Types.Model.t()) :: :ok
  def switch_model(session, model) do
    GenServer.call(session, {:switch_model, model})
  end

  @doc """
  Set the thinking/reasoning level.

  Valid levels: :off, :minimal, :low, :medium, :high
  """
  @spec set_thinking_level(GenServer.server(), AgentCore.Types.thinking_level()) :: :ok
  def set_thinking_level(session, level) do
    GenServer.call(session, {:set_thinking_level, level})
  end

  @doc """
  Trigger context compaction.

  ## Options

    * `:force` - Force compaction even if not needed
    * `:summary` - Custom summary text (otherwise auto-generated)
  """
  @spec compact(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def compact(session, opts \\ []) do
    GenServer.call(session, {:compact, opts})
  end

  @doc """
  Navigate to a different point in the session tree.

  ## Options

    * `:direction` - `:parent`, `:child`, `:sibling`
    * `:index` - For siblings, which sibling to select
  """
  @spec navigate_tree(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def navigate_tree(session, entry_id, opts \\ []) do
    GenServer.call(session, {:navigate_tree, entry_id, opts})
  end

  @doc """
  Get the current messages in the session.
  """
  @spec get_messages(GenServer.server()) :: [map()]
  def get_messages(session) do
    GenServer.call(session, :get_messages)
  end

  @doc """
  Save the session to disk.
  """
  @spec save(GenServer.server()) :: :ok | {:error, term()}
  def save(session) do
    GenServer.call(session, :save)
  end

  @doc """
  Create a summary for the current branch.

  This is useful when switching branches to preserve context about what
  was explored on the current branch before navigating away.

  ## Options

    * `:custom_instructions` - Additional instructions for the summary

  ## Returns

    * `:ok` - Summary was created and stored
    * `{:error, :empty_branch}` - Branch has no messages to summarize
    * `{:error, reason}` - If summarization fails
  """
  @spec summarize_current_branch(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def summarize_current_branch(session, opts \\ []) do
    GenServer.call(session, {:summarize_branch, opts}, :infinity)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @spec init(keyword()) :: {:ok, t()}
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, state, extension_status_report} = Lifecycle.initialize(opts, self())

    maybe_register_session(
      state.session_manager,
      state.cwd,
      state.register_session,
      state.session_registry
    )

    # Emit introspection event for session start
    Introspection.record(
      :session_started,
      %{
        session_id: state.session_manager.header.id,
        cwd: state.cwd,
        model: state.model && state.model.id,
        session_scope: state.session_scope
      },
      session_key: Keyword.get(opts, :session_key, state.session_manager.header.id),
      agent_id: Keyword.get(opts, :agent_id, "default"),
      engine: "lemon",
      provenance: :direct
    )

    # Schedule the extension status report event to be published after init completes.
    # This allows subscribers to receive the event after they subscribe.
    send(self(), {:publish_extension_status_report, extension_status_report})

    {:ok, state}
  end

  @spec handle_call(term(), GenServer.from(), t()) :: {:reply, term(), t()}
  @impl true
  def handle_call({:prompt, text, opts}, _from, state) do
    if state.is_streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      state = refresh_system_prompt(state)
      user_message = State.build_prompt_message(text, opts)

      # Defer the actual prompt slightly after we reply so callers can subscribe immediately
      # after `Session.prompt/3` and still observe `:agent_start` and other early events.
      #
      # This also gives the session a chance to receive near-immediate `follow_up/2` and
      # `steer/2` messages before the agent loop does its end-of-turn queue checks in
      # very fast (mocked) runs.
      timer_ref = Process.send_after(self(), {:do_prompt, user_message}, @prompt_defer_ms)

      {:reply, :ok, State.begin_prompt(state, timer_ref)}
    end
  end

  def handle_call({:handle_async_followup, message_or_attrs}, _from, state) do
    state = refresh_system_prompt(state)
    message = State.build_async_followup_message(message_or_attrs)
    state = persist_message(state, message)

    if state.is_streaming do
      AgentCore.Agent.follow_up(state.agent, message)
      queue = :queue.in(message, state.follow_up_queue)
      {:reply, :ok, %{state | follow_up_queue: queue}}
    else
      timer_ref = Process.send_after(self(), {:do_prompt, message}, @prompt_defer_ms)
      {:reply, :ok, State.begin_prompt(state, timer_ref)}
    end
  end

  def handle_call({:subscribe, pid, :stream, opts}, _from, state) do
    {:ok, stream, new_state} = Notifier.subscribe_stream(state, pid, opts)
    {:reply, {:ok, stream}, new_state}
  end

  def handle_call({:subscribe, pid, :direct, _opts}, _from, state) do
    {unsubscribe, new_state} = Notifier.subscribe_direct(state, pid, self())
    {:reply, unsubscribe, new_state}
  end

  # Legacy subscribe call for backwards compatibility
  def handle_call({:subscribe, pid}, _from, state) do
    {unsubscribe, new_state} = Notifier.subscribe_direct(state, pid, self())
    {:reply, unsubscribe, new_state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_stats, _from, state) do
    agent_state = AgentCore.Agent.get_state(state.agent)
    messages = agent_state.messages

    stats = %{
      message_count: length(messages),
      turn_count: state.turn_index,
      is_streaming: state.is_streaming,
      session_id: state.session_manager.header.id,
      cwd: state.cwd,
      model: %{
        provider: state.model.provider,
        id: state.model.id
      },
      thinking_level: state.thinking_level
    }

    {:reply, stats, state}
  end

  def handle_call(:health_check, _from, state) do
    diag = State.build_diagnostics(state)

    health = %{
      status: diag.status,
      session_id: diag.session_id,
      uptime_ms: diag.uptime_ms,
      is_streaming: diag.is_streaming,
      agent_alive: diag.agent_alive
    }

    {:reply, health, state}
  end

  def handle_call(:diagnostics, _from, state) do
    {:reply, State.build_diagnostics(state), state}
  end

  def handle_call(:get_extension_status_report, _from, state) do
    {:reply, state.extension_status_report, state}
  end

  def handle_call({:wasm_host_tool_invoke, tool_name, params_json}, _from, state) do
    result =
      case WasmBridge.maybe_handle_reserved_host_target(tool_name, params_json) do
        {:ok, payload} ->
          {:ok, payload}

        {:error, reason} ->
          {:error, reason}

        :not_reserved ->
          case WasmBridge.find_host_tool(state, tool_name) do
            nil ->
              {:error, :tool_not_found}

            tool ->
              params = WasmBridge.decode_wasm_params(params_json)
              call_id = "wasm_host_#{System.unique_integer([:positive, :monotonic])}"

              case tool.execute.(call_id, params, nil, nil) do
                %AgentCore.Types.AgentToolResult{} = tool_result ->
                  {:ok, WasmBridge.encode_wasm_host_output(tool_result)}

                {:ok, %AgentCore.Types.AgentToolResult{} = tool_result} ->
                  {:ok, WasmBridge.encode_wasm_host_output(tool_result)}

                {:error, reason} ->
                  {:error, reason}

                other ->
                  {:error, {:invalid_host_tool_result, other}}
              end
          end
      end

    {:reply, result, state}
  end

  def handle_call(:reload_extensions, _from, state) do
    if state.is_streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      {:ok, extension_status_report, new_state} = Lifecycle.reload_extensions(state)
      {:reply, {:ok, extension_status_report}, new_state}
    end
  end

  def handle_call(:reset, _from, state) do
    new_state = Lifecycle.reset(state, @reset_abort_wait_ms)
    {:reply, :ok, new_state}
  end

  def handle_call({:switch_model, model}, _from, state) do
    :ok = AgentCore.Agent.set_model(state.agent, model)

    # Record model change in session
    entry =
      SessionEntry.model_change(
        model.provider,
        model.id
      )

    session_manager = SessionManager.append_entry(state.session_manager, entry)

    {:reply, :ok, %{state | model: model, session_manager: session_manager}}
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    :ok = AgentCore.Agent.set_thinking_level(state.agent, level)

    # Record thinking level change in session
    entry = SessionEntry.thinking_level_change(level)
    session_manager = SessionManager.append_entry(state.session_manager, entry)

    {:reply, :ok, %{state | thinking_level: level, session_manager: session_manager}}
  end

  def handle_call({:compact, opts}, _from, state) do
    state =
      state
      |> CompactionManager.clear_auto_compaction_state()
      |> CompactionManager.clear_overflow_recovery_state()

    custom_summary = Keyword.get(opts, :summary)
    compaction_opts = CompactionManager.normalize_compaction_opts(state, opts)

    # Show working message before compaction
    Notifier.ui_set_working_message(state, "Compacting context...")

    result = CodingAgent.Compaction.compact(state.session_manager, state.model, compaction_opts)

    case apply_compaction_result(state, result, custom_summary) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:navigate_tree, entry_id, opts}, _from, state) do
    case SessionManager.get_entry(state.session_manager, entry_id) do
      nil ->
        {:reply, {:error, :entry_not_found}, state}

      _entry ->
        # Check if we're navigating away from the current branch
        current_leaf_id = SessionManager.get_leaf_id(state.session_manager)
        current_branch = SessionManager.get_branch(state.session_manager)
        new_branch = SessionManager.get_branch(state.session_manager, entry_id)

        # Determine if this is a branch switch (not just moving within the same branch)
        is_branch_switch =
          BackgroundTasks.branch_switch?(current_branch, new_branch, current_leaf_id, entry_id)

        # Summarize abandoned branch if switching branches and option not disabled
        state =
          if is_branch_switch and Keyword.get(opts, :summarize_abandoned, true) do
            maybe_summarize_abandoned_branch(state, current_branch, current_leaf_id)
          else
            state
          end

        session_manager = SessionManager.set_leaf_id(state.session_manager, entry_id)

        # Rebuild messages from the new position
        messages = restore_messages_from_session(session_manager)
        :ok = AgentCore.Agent.replace_messages(state.agent, messages)

        {:reply, :ok, %{state | session_manager: session_manager}}
    end
  end

  def handle_call(:get_messages, _from, state) do
    agent_state = AgentCore.Agent.get_state(state.agent)
    {:reply, agent_state.messages, state}
  end

  def handle_call(:save, _from, state) do
    case Persistence.save(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, unchanged_state} -> {:reply, {:error, reason}, unchanged_state}
    end
  end

  def handle_call({:summarize_branch, opts}, _from, state) do
    case BackgroundTasks.summarize_branch(state, opts, branch_summary_callbacks()) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, unchanged_state} -> {:reply, {:error, reason}, unchanged_state}
    end
  end

  @spec handle_cast(term(), t()) :: {:noreply, t()}
  @impl true
  def handle_cast({:steer, text}, state) do
    state = refresh_system_prompt(state)

    message = %Ai.Types.UserMessage{
      role: :user,
      content: text,
      timestamp: System.system_time(:millisecond)
    }

    AgentCore.Agent.steer(state.agent, message)
    queue = :queue.in(message, state.steering_queue)

    {:noreply, %{state | steering_queue: queue}}
  end

  def handle_cast({:follow_up, text}, state) do
    state = refresh_system_prompt(state)

    message = %Ai.Types.UserMessage{
      role: :user,
      content: text,
      timestamp: System.system_time(:millisecond)
    }

    AgentCore.Agent.follow_up(state.agent, message)
    queue = :queue.in(message, state.follow_up_queue)

    {:noreply, %{state | follow_up_queue: queue}}
  end

  def handle_cast(:abort, state) do
    had_pending_prompt = not is_nil(state.pending_prompt_timer_ref)
    state = state |> cancel_pending_prompt() |> CompactionManager.clear_overflow_recovery_state()
    AgentCore.Agent.abort(state.agent)

    if had_pending_prompt do
      # If abort lands before deferred prompt dispatch, emit a terminal canceled
      # event so subscribers don't wait for a lifecycle event that never comes.
      Notifier.broadcast_event(state, {:canceled, :assistant_aborted})
      Notifier.complete_event_streams(state, {:canceled, :assistant_aborted})
      {:noreply, %{state | steering_queue: :queue.new(), event_streams: %{}}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, Notifier.unsubscribe_direct(state, pid)}
  end

  @spec handle_info(term(), t()) :: {:noreply, t()}
  @impl true
  def handle_info({:agent_event, {:error, reason, partial_state} = event}, state) do
    case maybe_start_overflow_recovery(state, reason, partial_state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      :no_recovery ->
        # Broadcast to listeners FIRST (before state changes that might clear streams)
        Notifier.broadcast_event(state, event)

        # Process the event and update state
        new_state = handle_agent_event(event, state)
        {:noreply, CompactionManager.clear_overflow_recovery_state_on_terminal(event, new_state)}
    end
  end

  def handle_info({:agent_event, event}, state) do
    # Broadcast to listeners FIRST (before state changes that might clear streams)
    Notifier.broadcast_event(state, event)

    # Process the event and update state
    new_state = handle_agent_event(event, state)

    {:noreply, CompactionManager.clear_overflow_recovery_state_on_terminal(event, new_state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      state.auto_compaction_task_monitor_ref == ref ->
        {:noreply, CompactionManager.handle_auto_compaction_task_down(state)}

      state.overflow_recovery_task_monitor_ref == ref ->
        {:noreply, handle_overflow_recovery_task_down(state)}

      true ->
        {:noreply, Notifier.prune_subscribers(state, pid, ref)}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) when pid == state.agent do
    Logger.warning("Agent process exited: #{inspect(reason)}")

    state =
      state
      |> Map.put(:is_streaming, false)
      |> cancel_pending_prompt()
      |> CompactionManager.clear_overflow_recovery_state()

    {:noreply, state}
  end

  def handle_info({:store_branch_summary, from_id, summary}, state) do
    {:noreply,
     BackgroundTasks.store_branch_summary(state, from_id, summary, branch_summary_callbacks())}
  end

  def handle_info({:publish_extension_status_report, report}, state) do
    # Publish the extension status report event for UI/CLI consumption
    Notifier.broadcast_event(state, {:extension_status_report, report})
    {:noreply, state}
  end

  def handle_info({:auto_compaction_result, signature, result}, state) do
    {:noreply, CompactionLifecycle.handle_result(state, signature, result, session_callbacks())}
  end

  def handle_info({:overflow_recovery_result, signature, result}, state) do
    {:noreply, OverflowRecovery.handle_result(state, signature, result, session_callbacks())}
  end

  def handle_info({:auto_compaction_task_timeout, monitor_ref}, state) do
    case CompactionLifecycle.handle_timeout(state, monitor_ref, session_callbacks()) do
      {:handled, new_state} -> {:noreply, new_state}
      :stale -> {:noreply, state}
    end
  end

  def handle_info({:overflow_recovery_task_timeout, monitor_ref}, state) do
    case OverflowRecovery.handle_timeout(state, monitor_ref, session_callbacks()) do
      {:handled, new_state} -> {:noreply, new_state}
      :stale -> {:noreply, state}
    end
  end

  def handle_info({:do_prompt, %Ai.Types.UserMessage{} = user_message}, state) do
    if state.pending_prompt_timer_ref do
      # Send to agent (user message will be persisted on :message_end event)
      _ = AgentCore.Agent.prompt(state.agent, user_message)
      {:noreply, %{state | pending_prompt_timer_ref: nil}}
    else
      # Prompt was canceled (e.g. via abort/reset) before deferred dispatch.
      {:noreply, state}
    end
  end

  def handle_info({:do_prompt, %CustomMessage{} = message}, state) do
    if state.pending_prompt_timer_ref do
      _ = AgentCore.Agent.prompt(state.agent, message)
      {:noreply, %{state | pending_prompt_timer_ref: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec terminate(term(), t()) :: :ok
  @impl true
  def terminate(_reason, state) do
    # Emit introspection event for session end
    Introspection.record(
      :session_ended,
      %{
        session_id: state.session_manager && state.session_manager.header.id,
        turn_count: state.turn_index
      },
      engine: "lemon",
      provenance: :direct
    )

    # Stop the underlying agent when the session terminates
    if state.agent && Process.alive?(state.agent) do
      GenServer.stop(state.agent, :normal)
    end

    if state.wasm_sidecar_pid && Process.alive?(state.wasm_sidecar_pid) do
      _ = SidecarSupervisor.stop_sidecar(state.wasm_sidecar_pid)
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @spec refresh_system_prompt(t()) :: t()
  defp refresh_system_prompt(state) do
    case PromptComposer.maybe_refresh_system_prompt(
           state.cwd,
           state.explicit_system_prompt,
           state.prompt_template,
           state.workspace_dir,
           state.session_scope,
           state.system_prompt
         ) do
      :unchanged ->
        state

      {:changed, next_prompt} ->
        :ok = AgentCore.Agent.set_system_prompt(state.agent, next_prompt)
        %{state | system_prompt: next_prompt}
    end
  end

  @spec ui_set_working_message(t(), String.t() | nil) :: :ok
  defp ui_set_working_message(state, message), do: Notifier.ui_set_working_message(state, message)

  @spec ui_notify(t(), String.t(), CodingAgent.UI.notify_type()) :: :ok
  defp ui_notify(state, message, type), do: Notifier.ui_notify(state, message, type)

  @spec handle_agent_event(AgentCore.Types.agent_event(), t()) :: t()
  defp handle_agent_event(event, state) do
    EventHandler.handle(event, state, event_handler_callbacks())
  end

  @spec event_handler_callbacks() :: event_handler_callbacks()
  defp event_handler_callbacks do
    %{
      set_working_message: &ui_set_working_message/2,
      notify: &ui_notify/3,
      complete_event_streams: &complete_event_streams/2,
      maybe_trigger_compaction: &maybe_trigger_compaction/1,
      persist_message: &persist_message/2
    }
  end

  @spec broadcast_event(t(), AgentCore.Types.agent_event()) :: :ok
  defp broadcast_event(state, event), do: Notifier.broadcast_event(state, event)

  @spec complete_event_streams(t(), term()) :: :ok
  defp complete_event_streams(state, final_event),
    do: Notifier.complete_event_streams(state, final_event)

  @spec persist_message(t(), term()) :: t()
  defp persist_message(state, message), do: Persistence.persist_message(state, message)

  @spec restore_messages_from_session(Session.t()) :: [map()]
  defp restore_messages_from_session(session),
    do: Persistence.restore_messages_from_session(session)

  defp maybe_register_session(session_manager, cwd, register_session, registry),
    do: Persistence.maybe_register_session(session_manager, cwd, register_session, registry)

  defp cancel_pending_prompt(state), do: State.cancel_pending_prompt(state)

  defp session_callbacks do
    %{
      restore_messages_from_session: &restore_messages_from_session/1,
      broadcast_event: &broadcast_event/2,
      ui_set_working_message: &ui_set_working_message/2,
      ui_notify: &ui_notify/3,
      handle_agent_event: &handle_agent_event/2
    }
  end

  defp branch_summary_callbacks do
    %{
      broadcast_event: &broadcast_event/2,
      ui_set_working_message: &ui_set_working_message/2,
      ui_notify: &ui_notify/3
    }
  end

  # ============================================================================
  # Branch Summarization Helpers
  # ============================================================================

  @doc false
  # Attempts to summarize the abandoned branch asynchronously
  # Returns the state unchanged (summarization happens in background)
  @spec maybe_summarize_abandoned_branch(t(), [SessionEntry.t()], String.t() | nil) :: t()
  defp maybe_summarize_abandoned_branch(state, branch_entries, from_id),
    do: BackgroundTasks.maybe_summarize_abandoned_branch(state, branch_entries, from_id, self())

  @spec handle_overflow_recovery_task_down(t()) :: t()
  defp handle_overflow_recovery_task_down(state),
    do: OverflowRecovery.handle_task_down(state, session_callbacks())

  @spec maybe_start_overflow_recovery(t(), term(), term()) :: {:ok, t()} | :no_recovery
  defp maybe_start_overflow_recovery(state, reason, partial_state),
    do: OverflowRecovery.maybe_start(state, reason, partial_state, self(), session_callbacks())

  @spec apply_compaction_result(t(), {:ok, map()} | {:error, term()}, String.t() | nil) ::
          {:ok, t()} | {:error, term(), t()}
  defp apply_compaction_result(state, result, custom_summary),
    do: CompactionLifecycle.apply_result(state, result, custom_summary, session_callbacks())

  defp maybe_trigger_compaction(%__MODULE__{auto_compaction_in_progress: true} = state), do: state

  @spec maybe_trigger_compaction(t()) :: t()
  defp maybe_trigger_compaction(state),
    do: CompactionLifecycle.maybe_trigger(state, self(), session_callbacks())
end
