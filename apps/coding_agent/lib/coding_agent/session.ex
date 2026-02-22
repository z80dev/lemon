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
  @default_auto_compaction_task_timeout_ms 120_000
  @default_overflow_recovery_task_timeout_ms 120_000
  @task_supervisor CodingAgent.TaskSupervisor
  @secret_exists_target "__lemon.secret.exists"
  @secret_resolve_target "__lemon.secret.resolve"

  alias AgentCore.Types.AgentTool
  alias CodingAgent.Config
  alias CodingAgent.ExtensionLifecycle
  alias CodingAgent.Extensions
  alias CodingAgent.ResourceLoader
  alias CodingAgent.Security.UntrustedToolBoundary
  alias CodingAgent.Session.EventHandler
  alias CodingAgent.Workspace
  alias CodingAgent.Wasm.Config, as: WasmConfig
  alias CodingAgent.Wasm.SidecarSession
  alias CodingAgent.Wasm.SidecarSupervisor
  alias CodingAgent.Wasm.ToolFactory
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.{Session, SessionEntry}
  alias CodingAgent.UI.Context, as: UIContext

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

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cwd = Keyword.fetch!(opts, :cwd)
    explicit_system_prompt = Keyword.get(opts, :system_prompt)
    prompt_template = Keyword.get(opts, :prompt_template)
    session_file = Keyword.get(opts, :session_file)
    session_id = Keyword.get(opts, :session_id)
    parent_session = Keyword.get(opts, :parent_session)
    ui_context = Keyword.get(opts, :ui_context)
    custom_tools = Keyword.get(opts, :tools)
    extra_tools = normalize_extra_tools(Keyword.get(opts, :extra_tools, []))
    workspace_dir = Keyword.get(opts, :workspace_dir, Config.workspace_dir())
    register_session = Keyword.get(opts, :register, false)
    session_registry = Keyword.get(opts, :registry, CodingAgent.SessionRegistry)

    maybe_register_ui_tracker(ui_context)
    Workspace.ensure_workspace(workspace_dir: workspace_dir)

    # Load or create session
    session_manager =
      case session_file do
        nil ->
          SessionManager.new(cwd, id: session_id, parent_session: parent_session)

        path ->
          case SessionManager.load_from_file(path) do
            {:ok, session} ->
              session

            {:error, _reason} ->
              SessionManager.new(cwd, id: session_id, parent_session: parent_session)
          end
      end

    # Derive scope from session lineage. This ensures that sessions loaded from disk
    # keep their main/subagent scope even when start_link opts omit :parent_session.
    session_scope =
      resolve_session_scope(opts, parent_session, session_manager.header.parent_session)

    # Load settings FIRST so we can use defaults for model and thinking_level
    settings_manager =
      Keyword.get(opts, :settings_manager) || CodingAgent.SettingsManager.load(cwd)

    # Compose system prompt from multiple sources
    system_prompt =
      compose_system_prompt(
        cwd,
        explicit_system_prompt,
        prompt_template,
        workspace_dir,
        session_scope
      )

    # Resolve explicit model overrides (including provider:model strings) or
    # fall back to settings_manager.default_model.
    model = resolve_session_model(Keyword.get(opts, :model), settings_manager)

    # Get thinking_level from opts, or fall back to settings_manager.default_thinking_level
    thinking_level = Keyword.get(opts, :thinking_level) || settings_manager.default_thinking_level

    # Get tool policy and approval context if provided
    tool_policy = Keyword.get(opts, :tool_policy)
    approval_context = Keyword.get(opts, :approval_context)

    # Build approval context if policy requires approval but context not provided
    approval_context =
      if tool_policy && is_nil(approval_context) do
        %{
          session_key: Keyword.get(opts, :session_key, session_manager.header.id),
          agent_id: Keyword.get(opts, :agent_id, "default"),
          # Tool calls should not enforce approval timeouts by default.
          timeout_ms: Keyword.get(opts, :approval_timeout_ms, :infinity)
        }
      else
        approval_context
      end

    # Build tool options for ToolRegistry
    wasm_boot =
      maybe_start_wasm_sidecar(
        cwd,
        settings_manager,
        session_manager.header.id,
        tool_policy,
        approval_context
      )

    tool_opts =
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:thinking_level, thinking_level)
      |> Keyword.put(:parent_session, session_manager.header.id)
      |> Keyword.put(:session_id, session_manager.header.id)
      |> Keyword.put(:session_pid, self())
      |> Keyword.put(:session_key, Keyword.get(opts, :session_key, session_manager.header.id))
      |> Keyword.put(:agent_id, Keyword.get(opts, :agent_id, "default"))
      |> Keyword.put(:settings_manager, settings_manager)
      |> Keyword.put(:workspace_dir, workspace_dir)
      |> Keyword.put(:ui_context, ui_context)
      |> Keyword.put(:tool_policy, tool_policy)
      |> Keyword.put(:approval_context, approval_context)
      |> Keyword.put(:wasm_tools, wasm_boot.wasm_tools)
      |> Keyword.put(:wasm_status, wasm_boot.wasm_status)

    lifecycle =
      ExtensionLifecycle.initialize(
        cwd: cwd,
        settings_manager: settings_manager,
        tool_opts: tool_opts,
        custom_tools: custom_tools,
        extra_tools: extra_tools,
        wasm_tools: wasm_boot.wasm_tools,
        wasm_status: wasm_boot.wasm_status,
        tool_policy: tool_policy,
        approval_context: approval_context
      )

    extensions = lifecycle.extensions
    hooks = lifecycle.hooks
    tools = lifecycle.tools
    extension_status_report = lifecycle.extension_status_report

    # Create the convert_to_llm function
    convert_to_llm = &CodingAgent.Messages.to_llm/1
    transform_context = build_transform_context(Keyword.get(opts, :transform_context))

    # Start the AgentCore.Agent
    get_api_key = Keyword.get(opts, :get_api_key) || build_get_api_key(settings_manager)

    # Register main agent in AgentRegistry with key {session_id, :main, 0}
    agent_registry_key = {session_manager.header.id, :main, 0}

    {:ok, agent} =
      AgentCore.Agent.start_link(
        initial_state: %{
          system_prompt: system_prompt,
          model: model,
          tools: tools,
          thinking_level: thinking_level,
          messages: []
        },
        convert_to_llm: convert_to_llm,
        stream_fn: Keyword.get(opts, :stream_fn),
        stream_options: Keyword.get(opts, :stream_options),
        transform_context: transform_context,
        get_api_key: get_api_key,
        session_id: session_manager.header.id,
        name: AgentCore.AgentRegistry.via(agent_registry_key)
      )

    # Subscribe to agent events
    AgentCore.Agent.subscribe(agent, self())

    # Restore messages from session if loaded from file
    messages = restore_messages_from_session(session_manager)

    if messages != [] do
      AgentCore.Agent.replace_messages(agent, messages)
    end

    state = %__MODULE__{
      agent: agent,
      session_manager: session_manager,
      settings_manager: settings_manager,
      ui_context: ui_context,
      cwd: cwd,
      tools: tools,
      model: model,
      thinking_level: thinking_level,
      system_prompt: system_prompt,
      explicit_system_prompt: explicit_system_prompt,
      prompt_template: prompt_template,
      workspace_dir: workspace_dir,
      extra_tools: extra_tools,
      session_scope: session_scope,
      is_streaming: false,
      pending_prompt_timer_ref: nil,
      event_listeners: [],
      event_streams: %{},
      abort_signal: nil,
      steering_queue: :queue.new(),
      follow_up_queue: :queue.new(),
      turn_index: 0,
      started_at: System.system_time(:millisecond),
      session_file: session_file,
      register_session: register_session,
      session_registry: session_registry,
      convert_to_llm: convert_to_llm,
      transform_context: transform_context,
      tool_policy: tool_policy,
      approval_context: approval_context,
      extensions: extensions,
      hooks: hooks,
      extension_status_report: extension_status_report,
      wasm_sidecar_pid: wasm_boot.sidecar_pid,
      wasm_tool_names: wasm_boot.wasm_tool_names,
      wasm_status: wasm_boot.wasm_status,
      auto_compaction_in_progress: false,
      auto_compaction_signature: nil,
      auto_compaction_task_pid: nil,
      auto_compaction_task_monitor_ref: nil,
      auto_compaction_task_timeout_ref: nil,
      overflow_recovery_in_progress: false,
      overflow_recovery_attempted: false,
      overflow_recovery_signature: nil,
      overflow_recovery_task_pid: nil,
      overflow_recovery_task_monitor_ref: nil,
      overflow_recovery_task_timeout_ref: nil,
      overflow_recovery_started_at_ms: nil,
      overflow_recovery_error_reason: nil,
      overflow_recovery_partial_state: nil
    }

    maybe_register_session(session_manager, cwd, register_session, session_registry)

    # Schedule the extension status report event to be published after init completes.
    # This allows subscribers to receive the event after they subscribe.
    send(self(), {:publish_extension_status_report, extension_status_report})

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, text, opts}, _from, state) do
    if state.is_streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      state = refresh_system_prompt(state)

      # Create user message
      images = Keyword.get(opts, :images, [])

      user_message =
        if images == [] do
          %Ai.Types.UserMessage{
            role: :user,
            content: text,
            timestamp: System.system_time(:millisecond)
          }
        else
          content =
            [%Ai.Types.TextContent{type: :text, text: text}] ++
              Enum.map(images, fn img ->
                %Ai.Types.ImageContent{
                  type: :image,
                  data: img.data,
                  mime_type: img.mime_type
                }
              end)

          %Ai.Types.UserMessage{
            role: :user,
            content: content,
            timestamp: System.system_time(:millisecond)
          }
        end

      # Defer the actual prompt slightly after we reply so callers can subscribe immediately
      # after `Session.prompt/3` and still observe `:agent_start` and other early events.
      #
      # This also gives the session a chance to receive near-immediate `follow_up/2` and
      # `steer/2` messages before the agent loop does its end-of-turn queue checks in
      # very fast (mocked) runs.
      timer_ref = Process.send_after(self(), {:do_prompt, user_message}, @prompt_defer_ms)

      new_state = %{
        state
        | is_streaming: true,
          pending_prompt_timer_ref: timer_ref,
          turn_index: state.turn_index + 1,
          overflow_recovery_in_progress: false,
          overflow_recovery_attempted: false,
          overflow_recovery_signature: nil,
          overflow_recovery_started_at_ms: nil,
          overflow_recovery_error_reason: nil,
          overflow_recovery_partial_state: nil
      }

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:subscribe, pid, :stream, opts}, _from, state) do
    max_queue = Keyword.get(opts, :max_queue, 1000)
    drop_strategy = Keyword.get(opts, :drop_strategy, :drop_oldest)
    # Tool calls and long-running sessions should not time out by default.
    timeout = Keyword.get(opts, :timeout, :infinity)

    {:ok, stream} =
      AgentCore.EventStream.start_link(
        max_queue: max_queue,
        drop_strategy: drop_strategy,
        owner: pid,
        timeout: timeout
      )

    mon_ref = Process.monitor(pid)
    event_streams = Map.put(state.event_streams, mon_ref, %{pid: pid, stream: stream})

    {:reply, {:ok, stream}, %{state | event_streams: event_streams}}
  end

  def handle_call({:subscribe, pid, :direct, _opts}, _from, state) do
    monitor_ref = Process.monitor(pid)
    new_listeners = [{pid, monitor_ref} | state.event_listeners]
    session_pid = self()

    unsubscribe = fn ->
      GenServer.cast(session_pid, {:unsubscribe, pid})
    end

    {:reply, unsubscribe, %{state | event_listeners: new_listeners}}
  end

  # Legacy subscribe call for backwards compatibility
  def handle_call({:subscribe, pid}, _from, state) do
    monitor_ref = Process.monitor(pid)
    new_listeners = [{pid, monitor_ref} | state.event_listeners]
    session_pid = self()

    unsubscribe = fn ->
      GenServer.cast(session_pid, {:unsubscribe, pid})
    end

    {:reply, unsubscribe, %{state | event_listeners: new_listeners}}
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
    diag = build_diagnostics(state)

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
    {:reply, build_diagnostics(state), state}
  end

  def handle_call(:get_extension_status_report, _from, state) do
    {:reply, state.extension_status_report, state}
  end

  def handle_call({:wasm_host_tool_invoke, tool_name, params_json}, _from, state) do
    result =
      case maybe_handle_reserved_host_target(tool_name, params_json) do
        {:ok, payload} ->
          {:ok, payload}

        {:error, reason} ->
          {:error, reason}

        :not_reserved ->
          case find_host_tool(state, tool_name) do
            nil ->
              {:error, :tool_not_found}

            tool ->
              params = decode_wasm_params(params_json)
              call_id = "wasm_host_#{System.unique_integer([:positive, :monotonic])}"

              case tool.execute.(call_id, params, nil, nil) do
                %AgentCore.Types.AgentToolResult{} = tool_result ->
                  {:ok, encode_wasm_host_output(tool_result)}

                {:ok, %AgentCore.Types.AgentToolResult{} = tool_result} ->
                  {:ok, encode_wasm_host_output(tool_result)}

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
      # Show working message
      ui_set_working_message(state, "Reloading extensions...")

      wasm_reload = reload_wasm_tools(state)

      # Build tool options
      tool_opts = [
        model: state.model,
        thinking_level: state.thinking_level,
        parent_session: state.session_manager.header.id,
        session_id: state.session_manager.header.id,
        session_pid: self(),
        session_key: state.session_manager.header.id,
        agent_id: "default",
        settings_manager: state.settings_manager,
        workspace_dir: state.workspace_dir,
        ui_context: state.ui_context,
        tool_policy: state.tool_policy,
        approval_context: state.approval_context,
        wasm_tools: wasm_reload.wasm_tools,
        wasm_status: wasm_reload.wasm_status
      ]

      lifecycle =
        ExtensionLifecycle.reload(
          cwd: state.cwd,
          settings_manager: state.settings_manager,
          tool_opts: tool_opts,
          extra_tools: state.extra_tools,
          wasm_tools: wasm_reload.wasm_tools,
          wasm_status: wasm_reload.wasm_status,
          tool_policy: state.tool_policy,
          approval_context: state.approval_context,
          previous_status_report: state.extension_status_report
        )

      extensions = lifecycle.extensions
      hooks = lifecycle.hooks
      tools = lifecycle.tools
      extension_status_report = lifecycle.extension_status_report

      # Update the agent's tools
      :ok = AgentCore.Agent.set_tools(state.agent, tools)

      # Clear working message
      ui_set_working_message(state, nil)

      # Broadcast the new extension status report
      broadcast_event(state, {:extension_status_report, extension_status_report})

      # Notify about the reload
      ui_notify(
        state,
        "Extensions reloaded: #{extension_status_report.total_loaded} loaded",
        :info
      )

      new_state = %{
        state
        | extensions: extensions,
          hooks: hooks,
          tools: tools,
          extension_status_report: extension_status_report,
          wasm_sidecar_pid: wasm_reload.sidecar_pid,
          wasm_tool_names: wasm_reload.wasm_tool_names,
          wasm_status: wasm_reload.wasm_status
      }

      {:reply, {:ok, extension_status_report}, new_state}
    end
  end

  def handle_call(:reset, _from, state) do
    was_streaming = state.is_streaming
    had_pending_prompt = not is_nil(state.pending_prompt_timer_ref)
    state = cancel_pending_prompt(state)

    state =
      if was_streaming do
        # Explicitly publish cancellation semantics for subscribers when reset
        # interrupts an active prompt/run.
        broadcast_event(state, {:canceled, :reset})
        complete_event_streams(state, {:canceled, :reset})

        if not had_pending_prompt do
          AgentCore.Agent.abort(state.agent)

          case AgentCore.Agent.wait_for_idle(state.agent, timeout: @reset_abort_wait_ms) do
            :ok ->
              :ok

            {:error, :timeout} ->
              Logger.warning("Timed out waiting for agent abort during reset")
          end

          # Prevent stale events from the aborted run from mutating the new session.
          flush_queued_agent_events()
        end

        %{state | is_streaming: false, event_streams: %{}, steering_queue: :queue.new()}
      else
        state
      end

    # Reset agent
    :ok = AgentCore.Agent.reset(state.agent)

    # Create new session
    previous_session_id = state.session_manager.header.id
    new_session_manager = SessionManager.new(state.cwd)

    maybe_unregister_session(previous_session_id, state.register_session, state.session_registry)

    maybe_register_session(
      new_session_manager,
      state.cwd,
      state.register_session,
      state.session_registry
    )

    ui_set_working_message(state, nil)

    new_state = %{
      state
      | session_manager: new_session_manager,
        is_streaming: false,
        pending_prompt_timer_ref: nil,
        turn_index: 0,
        started_at: System.system_time(:millisecond),
        session_file: nil,
        steering_queue: :queue.new(),
        follow_up_queue: :queue.new(),
        auto_compaction_in_progress: false,
        auto_compaction_signature: nil,
        overflow_recovery_in_progress: false,
        overflow_recovery_attempted: false,
        overflow_recovery_signature: nil,
        overflow_recovery_started_at_ms: nil,
        overflow_recovery_error_reason: nil,
        overflow_recovery_partial_state: nil
    }

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
    state = state |> clear_auto_compaction_state() |> clear_overflow_recovery_state()
    custom_summary = Keyword.get(opts, :summary)
    compaction_opts = normalize_compaction_opts(state, opts)

    # Show working message before compaction
    ui_set_working_message(state, "Compacting context...")

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
          is_branch_switch?(current_branch, new_branch, current_leaf_id, entry_id)

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
    path =
      state.session_file ||
        Path.join(
          SessionManager.get_session_dir(state.cwd),
          "#{state.session_manager.header.id}.jsonl"
        )

    case SessionManager.save_to_file(path, state.session_manager) do
      :ok ->
        {:reply, :ok, %{state | session_file: path}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:summarize_branch, opts}, _from, state) do
    # Get the current branch entries
    branch_entries = SessionManager.get_branch(state.session_manager)

    # Check if there are any message entries to summarize
    message_entries =
      Enum.filter(branch_entries, fn entry ->
        entry.type == :message and entry.message != nil
      end)

    if Enum.empty?(message_entries) do
      {:reply, {:error, :empty_branch}, state}
    else
      # Show working message before summarization
      ui_set_working_message(state, "Summarizing branch...")

      case CodingAgent.Compaction.generate_branch_summary(branch_entries, state.model, opts) do
        {:ok, summary} ->
          # Get the current leaf_id to use as from_id
          from_id = SessionManager.get_leaf_id(state.session_manager)

          # Create branch summary entry
          entry = SessionEntry.branch_summary(from_id, summary)

          # Append to session manager
          session_manager = SessionManager.append_entry(state.session_manager, entry)

          # Broadcast branch summary event to listeners
          broadcast_event(state, {:branch_summarized, %{from_id: from_id, summary: summary}})

          # Clear working message
          ui_set_working_message(state, nil)

          {:reply, :ok, %{state | session_manager: session_manager}}

        {:error, reason} ->
          ui_set_working_message(state, nil)
          ui_notify(state, "Branch summarization failed: #{inspect(reason)}", :error)
          {:reply, {:error, reason}, state}
      end
    end
  end

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
    state = state |> cancel_pending_prompt() |> clear_overflow_recovery_state()
    AgentCore.Agent.abort(state.agent)

    if had_pending_prompt do
      # If abort lands before deferred prompt dispatch, emit a terminal canceled
      # event so subscribers don't wait for a lifecycle event that never comes.
      broadcast_event(state, {:canceled, :assistant_aborted})
      complete_event_streams(state, {:canceled, :assistant_aborted})
      {:noreply, %{state | steering_queue: :queue.new(), event_streams: %{}}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:unsubscribe, pid}, state) do
    new_listeners =
      Enum.reject(state.event_listeners, fn {listener_pid, monitor_ref} ->
        if listener_pid == pid do
          Process.demonitor(monitor_ref, [:flush])
          true
        else
          false
        end
      end)

    {:noreply, %{state | event_listeners: new_listeners}}
  end

  @impl true
  def handle_info({:agent_event, {:error, reason, partial_state} = event}, state) do
    case maybe_start_overflow_recovery(state, reason, partial_state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      :no_recovery ->
        # Broadcast to listeners FIRST (before state changes that might clear streams)
        broadcast_event(state, event)

        # Process the event and update state
        new_state = handle_agent_event(event, state)
        {:noreply, clear_overflow_recovery_state_on_terminal(event, new_state)}
    end
  end

  def handle_info({:agent_event, event}, state) do
    # Broadcast to listeners FIRST (before state changes that might clear streams)
    broadcast_event(state, event)

    # Process the event and update state
    new_state = handle_agent_event(event, state)

    {:noreply, clear_overflow_recovery_state_on_terminal(event, new_state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      state.auto_compaction_task_monitor_ref == ref ->
        {:noreply, handle_auto_compaction_task_down(state)}

      state.overflow_recovery_task_monitor_ref == ref ->
        {:noreply, handle_overflow_recovery_task_down(state)}

      true ->
        # Remove from direct listeners
        new_listeners =
          Enum.reject(state.event_listeners, fn {listener_pid, monitor_ref} ->
            listener_pid == pid or monitor_ref == ref
          end)

        # Remove from stream subscribers and cancel their streams
        {streams_for_pid, remaining_streams} =
          Enum.split_with(state.event_streams, fn {_mon_ref, %{pid: stream_pid}} ->
            stream_pid == pid
          end)

        Enum.each(streams_for_pid, fn {mon_ref, %{stream: stream}} ->
          AgentCore.EventStream.cancel(stream, :subscriber_down)
          Process.demonitor(mon_ref, [:flush])
        end)

        {:noreply,
         %{state | event_listeners: new_listeners, event_streams: Map.new(remaining_streams)}}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) when pid == state.agent do
    Logger.warning("Agent process exited: #{inspect(reason)}")

    state =
      state
      |> Map.put(:is_streaming, false)
      |> cancel_pending_prompt()
      |> clear_overflow_recovery_state()

    {:noreply, state}
  end

  def handle_info({:store_branch_summary, from_id, summary}, state) do
    # Store the branch summary entry (from async summarization)
    entry = SessionEntry.branch_summary(from_id, summary)
    session_manager = SessionManager.append_entry(state.session_manager, entry)

    # Broadcast branch summary event
    broadcast_event(state, {:branch_summarized, %{from_id: from_id, summary: summary}})

    {:noreply, %{state | session_manager: session_manager}}
  end

  def handle_info({:publish_extension_status_report, report}, state) do
    # Publish the extension status report event for UI/CLI consumption
    broadcast_event(state, {:extension_status_report, report})
    {:noreply, state}
  end

  def handle_info({:auto_compaction_result, signature, result}, state) do
    cond do
      not state.auto_compaction_in_progress ->
        {:noreply, state}

      state.auto_compaction_signature != signature ->
        {:noreply, state}

      signature != session_signature(state) ->
        state = clear_auto_compaction_state(state)

        if not state.is_streaming do
          ui_set_working_message(state, nil)
        end

        {:noreply, state}

      true ->
        state = clear_auto_compaction_state(state)

        case apply_compaction_result(state, result, nil) do
          {:ok, new_state} ->
            {:noreply, new_state}

          {:error, _reason, new_state} ->
            {:noreply, new_state}
        end
    end
  end

  def handle_info({:overflow_recovery_result, signature, result}, state) do
    cond do
      not state.overflow_recovery_in_progress ->
        {:noreply, state}

      state.overflow_recovery_signature != signature ->
        {:noreply, state}

      signature != session_signature(state) ->
        {:noreply, clear_overflow_recovery_task_state(state)}

      true ->
        state = clear_overflow_recovery_task_state(state)

        case apply_compaction_result(state, result, nil) do
          {:ok, compacted_state} ->
            case continue_after_overflow_compaction(compacted_state) do
              {:ok, resumed_state} ->
                emit_overflow_recovery_telemetry(:success, resumed_state, %{
                  duration_ms: overflow_recovery_duration_ms(state)
                })

                {:noreply, resumed_state}

              {:error, reason, failed_state} ->
                ui_notify(
                  failed_state,
                  "Auto-retry failed after compaction: #{inspect(reason)}",
                  :error
                )

                emit_overflow_recovery_telemetry(:failure, failed_state, %{
                  duration_ms: overflow_recovery_duration_ms(state),
                  reason: normalize_overflow_reason(reason)
                })

                {:noreply, finalize_overflow_recovery_failure(failed_state, reason)}
            end

          {:error, reason, failed_state} ->
            ui_notify(
              failed_state,
              "Overflow compaction failed: #{inspect(reason)}",
              :error
            )

            emit_overflow_recovery_telemetry(:failure, failed_state, %{
              duration_ms: overflow_recovery_duration_ms(state),
              reason: normalize_overflow_reason(reason)
            })

            {:noreply, finalize_overflow_recovery_failure(failed_state, reason)}
        end
    end
  end

  def handle_info({:auto_compaction_task_timeout, monitor_ref}, state) do
    if state.auto_compaction_task_monitor_ref == monitor_ref do
      state =
        state
        |> maybe_kill_background_task(state.auto_compaction_task_pid, :auto_compaction_timeout)
        |> clear_auto_compaction_state()

      if not state.is_streaming do
        ui_set_working_message(state, nil)
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:overflow_recovery_task_timeout, monitor_ref}, state) do
    if state.overflow_recovery_task_monitor_ref == monitor_ref do
      failure_reason = :overflow_recovery_timeout

      failed_state =
        state
        |> maybe_kill_background_task(
          state.overflow_recovery_task_pid,
          :overflow_recovery_timeout
        )
        |> clear_overflow_recovery_task_state()

      ui_notify(failed_state, "Overflow compaction timed out", :error)

      emit_overflow_recovery_telemetry(:failure, failed_state, %{
        duration_ms: overflow_recovery_duration_ms(state),
        reason: normalize_overflow_reason(failure_reason)
      })

      {:noreply, finalize_overflow_recovery_failure(failed_state, failure_reason)}
    else
      {:noreply, state}
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

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
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

  defp build_diagnostics(state) do
    {messages, message_count} =
      if state.agent && Process.alive?(state.agent) do
        agent_state = AgentCore.Agent.get_state(state.agent)
        messages = agent_state.messages || []
        {messages, length(messages)}
      else
        {[], 0}
      end

    {tool_call_count, error_count} = count_tool_results(messages)
    error_rate = if tool_call_count == 0, do: 0.0, else: error_count / tool_call_count

    now = System.system_time(:millisecond)
    started_at = state.started_at || now
    last_activity_at = latest_activity_timestamp(messages, started_at)
    uptime_ms = max(now - started_at, 0)

    agent_alive = state.agent && Process.alive?(state.agent)

    %{
      status: determine_health_status(agent_alive, error_rate, state),
      session_id: state.session_manager.header.id,
      uptime_ms: uptime_ms,
      started_at: started_at,
      last_activity_at: last_activity_at,
      is_streaming: state.is_streaming,
      agent_alive: agent_alive,
      message_count: message_count,
      turn_count: state.turn_index,
      tool_call_count: tool_call_count,
      error_count: error_count,
      error_rate: error_rate,
      subscriber_count: length(state.event_listeners),
      stream_subscriber_count: map_size(state.event_streams),
      steering_queue_size: :queue.len(state.steering_queue),
      follow_up_queue_size: :queue.len(state.follow_up_queue),
      model: %{provider: state.model.provider, id: state.model.id},
      cwd: state.cwd,
      thinking_level: state.thinking_level
    }
  end

  defp count_tool_results(messages) do
    results = Enum.filter(messages, &match?(%Ai.Types.ToolResultMessage{}, &1))
    tool_call_count = length(results)
    error_count = Enum.count(results, fn msg -> Map.get(msg, :is_error, false) end)
    {tool_call_count, error_count}
  end

  defp latest_activity_timestamp(messages, fallback) do
    Enum.reduce(messages, fallback, fn msg, acc ->
      ts = Map.get(msg, :timestamp)

      cond do
        is_integer(ts) and ts > acc -> ts
        true -> acc
      end
    end)
  end

  defp determine_health_status(false, _error_rate, _state), do: :unhealthy

  defp determine_health_status(true, error_rate, _state) when error_rate > 0.2, do: :degraded

  defp determine_health_status(true, _error_rate, _state), do: :healthy

  @spec resolve_session_model(term(), CodingAgent.SettingsManager.t()) :: Ai.Types.Model.t()
  defp resolve_session_model(nil, %CodingAgent.SettingsManager{} = settings) do
    resolve_default_model(settings)
  end

  defp resolve_session_model(%Ai.Types.Model{} = model, %CodingAgent.SettingsManager{} = settings) do
    apply_provider_base_url(model, settings)
  end

  defp resolve_session_model(model_spec, %CodingAgent.SettingsManager{} = settings) do
    case resolve_explicit_model(model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, settings)

      _ ->
        raise ArgumentError, "unknown model #{inspect(model_spec)}"
    end
  end

  @spec resolve_explicit_model(term()) :: Ai.Types.Model.t() | nil
  defp resolve_explicit_model(spec) when is_binary(spec) do
    trimmed = String.trim(spec)

    cond do
      trimmed == "" ->
        nil

      true ->
        case String.split(trimmed, ":", parts: 2) do
          [model_id] ->
            lookup_model(nil, non_empty_string(model_id))

          [provider, model_id] ->
            provider = non_empty_string(provider)
            model_id = non_empty_string(model_id)

            if model_id do
              lookup_model(provider, model_id)
            else
              nil
            end

          _ ->
            nil
        end
    end
  end

  defp resolve_explicit_model(spec) when is_map(spec) do
    provider = spec[:provider] || spec["provider"]

    model_id =
      spec[:model_id] || spec["model_id"] || spec[:id] || spec["id"] || spec[:model] ||
        spec["model"]

    lookup_model(non_empty_string(provider), non_empty_string(model_id))
  end

  defp resolve_explicit_model(_), do: nil

  @spec lookup_model(String.t() | nil, String.t() | nil) :: Ai.Types.Model.t() | nil
  defp lookup_model(_provider, nil), do: nil

  defp lookup_model(nil, model_id) when is_binary(model_id) do
    Ai.Models.find_by_id(model_id)
  end

  defp lookup_model(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    case provider_to_atom(provider) do
      nil -> nil
      provider_atom -> Ai.Models.get_model(provider_atom, model_id)
    end
  end

  defp lookup_model(_provider, _model_id), do: nil

  @spec provider_to_atom(String.t()) :: atom() | nil
  defp provider_to_atom(provider) when is_binary(provider) do
    normalized = String.downcase(String.trim(provider))

    Enum.find(Ai.Models.get_providers(), fn known ->
      known_str = Atom.to_string(known)
      known_str == normalized or String.replace(known_str, "_", "-") == normalized
    end)
  end

  defp provider_to_atom(_), do: nil

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_), do: nil

  @spec resolve_default_model(CodingAgent.SettingsManager.t()) :: Ai.Types.Model.t()
  defp resolve_default_model(%CodingAgent.SettingsManager{default_model: nil}) do
    # No default model configured, raise an error
    raise ArgumentError,
          "model is required: either pass :model option or configure default_model in settings"
  end

  defp resolve_default_model(%CodingAgent.SettingsManager{default_model: config} = settings)
       when is_map(config) do
    provider = Map.get(config, :provider)
    model_id = Map.get(config, :model_id)
    base_url = Map.get(config, :base_url)

    model =
      case provider do
        nil ->
          Ai.Models.find_by_id(model_id)

        provider_str when is_binary(provider_str) ->
          provider_atom =
            try do
              String.to_existing_atom(provider_str)
            rescue
              ArgumentError -> String.to_atom(provider_str)
            end

          Ai.Models.get_model(provider_atom, model_id)
      end

    case model do
      nil ->
        raise ArgumentError,
              "unknown model #{inspect(model_id)}" <>
                if(provider, do: " for provider #{inspect(provider)}", else: "")

      model ->
        model =
          if is_binary(base_url) and base_url != "" do
            %{model | base_url: base_url}
          else
            model
          end

        apply_provider_base_url(model, settings)
    end
  end

  defp apply_provider_base_url(model, %CodingAgent.SettingsManager{providers: providers}) do
    provider_key =
      case model.provider do
        p when is_atom(p) -> Atom.to_string(p)
        p when is_binary(p) -> p
        _ -> nil
      end

    provider_cfg = provider_key && Map.get(providers, provider_key)
    base_url = provider_cfg && Map.get(provider_cfg, :base_url)

    if is_binary(base_url) and base_url != "" and base_url != model.base_url do
      %{model | base_url: base_url}
    else
      model
    end
  end

  defp build_transform_context(nil), do: &UntrustedToolBoundary.transform/2

  defp build_transform_context(transform_fn) when is_function(transform_fn, 2) do
    fn messages, signal ->
      with {:ok, wrapped} <-
             normalize_transform_result(UntrustedToolBoundary.transform(messages, signal)),
           {:ok, transformed} <- normalize_transform_result(transform_fn.(wrapped, signal)) do
        {:ok, transformed}
      end
    end
  end

  defp normalize_transform_result({:ok, transformed}) when is_list(transformed),
    do: {:ok, transformed}

  defp normalize_transform_result({:error, reason}), do: {:error, reason}
  defp normalize_transform_result(transformed) when is_list(transformed), do: {:ok, transformed}
  defp normalize_transform_result(_), do: {:error, :invalid_transform_result}

  defp build_get_api_key(%CodingAgent.SettingsManager{providers: providers}) do
    fn provider ->
      provider_name = normalize_provider_key(provider)
      provider_cfg = provider_config(providers, provider_name)

      env_key =
        provider_name
        |> provider_env_vars()
        |> env_first()

      cond do
        is_binary(env_key) and env_key != "" ->
          env_key

        is_binary(plain_api_key = provider_config_value(provider_cfg, :api_key)) and
            plain_api_key != "" ->
          plain_api_key

        is_binary(api_key_secret = provider_config_value(provider_cfg, :api_key_secret)) and
            api_key_secret != "" ->
          resolve_secret_api_key(api_key_secret)

        is_binary(default_secret = provider_default_secret_name(provider_name)) and
            default_secret != "" ->
          resolve_secret_api_key(default_secret)

        true ->
          nil
      end
    end
  end

  defp provider_config(providers, provider_name) when is_binary(provider_name) do
    Map.get(providers, provider_name) ||
      Enum.find_value(providers, fn
        {key, value} when is_atom(key) ->
          if Atom.to_string(key) == provider_name, do: value, else: nil

        _ ->
          nil
      end)
  end

  defp provider_config(_providers, _provider_name), do: nil

  defp provider_config_value(nil, _key), do: nil

  defp provider_config_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))
  end

  defp normalize_provider_key(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp normalize_provider_key(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_provider_key(_), do: nil

  defp provider_env_vars("anthropic"), do: ["ANTHROPIC_API_KEY"]
  defp provider_env_vars("openai"), do: ["OPENAI_API_KEY"]
  defp provider_env_vars("openai-codex"), do: ["OPENAI_CODEX_API_KEY", "CHATGPT_TOKEN"]
  defp provider_env_vars("opencode"), do: ["OPENCODE_API_KEY"]
  defp provider_env_vars("kimi"), do: ["KIMI_API_KEY"]

  defp provider_env_vars("google"),
    do: ["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"]

  defp provider_env_vars(_), do: []

  defp provider_default_secret_name(nil), do: nil

  defp provider_default_secret_name(provider_name) when is_binary(provider_name) do
    sanitized =
      provider_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    if sanitized == "", do: nil, else: "llm_#{sanitized}_api_key"
  end

  defp resolve_secret_api_key(secret_name) when is_binary(secret_name) do
    case LemonCore.Secrets.resolve(secret_name, prefer_env: false, env_fallback: true) do
      {:ok, value, _source} -> value
      _ -> nil
    end
  end

  defp resolve_secret_api_key(_), do: nil

  defp env_first(names) when is_list(names) do
    Enum.find_value(names, fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  # Compose system prompt from multiple sources:
  # 1. Explicit system_prompt option (highest priority)
  # 2. Prompt template content (if prompt_template option provided)
  # 3. Lemon base prompt (skills + workspace context)
  # 4. CLAUDE.md/AGENTS.md content from ResourceLoader
  @spec compose_system_prompt(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t(),
          :main | :subagent
        ) :: String.t()
  defp compose_system_prompt(cwd, explicit_prompt, prompt_template, workspace_dir, session_scope) do
    # Load prompt template if specified
    template_content =
      case prompt_template do
        nil ->
          nil

        name ->
          case ResourceLoader.load_prompt(cwd, name) do
            {:ok, content} -> content
            {:error, :not_found} -> nil
          end
      end

    # Build Lemon base prompt (skills + workspace context)
    base_prompt =
      CodingAgent.SystemPrompt.build(cwd, %{
        workspace_dir: workspace_dir,
        session_scope: session_scope
      })

    # Load instructions (CLAUDE.md, AGENTS.md) from cwd and parent directories
    instructions = ResourceLoader.load_instructions(cwd)

    # Compose in order: explicit > template > base > instructions
    [explicit_prompt, template_content, base_prompt, instructions]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec resolve_session_scope(keyword(), String.t() | nil, String.t() | nil) :: :main | :subagent
  defp resolve_session_scope(opts, parent_session_opt, parent_session_from_file) do
    case Keyword.get(opts, :session_scope) do
      scope when scope in [:main, "main"] ->
        :main

      scope when scope in [:subagent, "subagent"] ->
        :subagent

      _ ->
        parent = first_non_empty_binary([parent_session_opt, parent_session_from_file])

        if is_binary(parent) do
          :subagent
        else
          :main
        end
    end
  end

  defp first_non_empty_binary(list) when is_list(list) do
    Enum.find(list, fn v -> is_binary(v) and String.trim(v) != "" end)
  end

  @spec refresh_system_prompt(t()) :: t()
  defp refresh_system_prompt(state) do
    next_prompt =
      compose_system_prompt(
        state.cwd,
        state.explicit_system_prompt,
        state.prompt_template,
        state.workspace_dir,
        state.session_scope
      )

    if next_prompt == state.system_prompt do
      state
    else
      :ok = AgentCore.Agent.set_system_prompt(state.agent, next_prompt)
      %{state | system_prompt: next_prompt}
    end
  end

  @spec ui_set_working_message(t(), String.t() | nil) :: :ok
  defp ui_set_working_message(state, message) do
    case state.ui_context do
      %UIContext{} = ui -> UIContext.set_working_message(ui, message)
      _ -> :ok
    end
  end

  @spec ui_notify(t(), String.t(), CodingAgent.UI.notify_type()) :: :ok
  defp ui_notify(state, message, type) do
    case state.ui_context do
      %UIContext{} = ui -> UIContext.notify(ui, message, type)
      _ -> :ok
    end
  end

  defp maybe_register_ui_tracker(%UIContext{module: mod, state: tracker})
       when not is_nil(tracker) do
    if function_exported?(mod, :register_tracker, 1) do
      mod.register_tracker(tracker)
    else
      :ok
    end
  end

  defp maybe_register_ui_tracker(_), do: :ok

  defp normalize_extra_tools(tools) when is_list(tools) do
    Enum.filter(tools, &match?(%AgentCore.Types.AgentTool{}, &1))
  end

  defp normalize_extra_tools(_), do: []

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
  defp broadcast_event(state, event) do
    session_event = {:session_event, state.session_manager.header.id, event}

    # Direct subscribers (legacy)
    Enum.each(state.event_listeners, fn {pid, _ref} ->
      send(pid, session_event)
    end)

    # Stream subscribers (with backpressure)
    Enum.each(state.event_streams, fn {_mon_ref, %{stream: stream}} ->
      AgentCore.EventStream.push_async(stream, session_event)
    end)

    :ok
  end

  @spec complete_event_streams(t(), term()) :: :ok
  defp complete_event_streams(state, final_event) do
    # Align EventStream terminal semantics with the terminal lifecycle event.
    Enum.each(state.event_streams, fn {mon_ref, %{stream: stream}} ->
      case final_event do
        {:agent_end, messages} when is_list(messages) ->
          AgentCore.EventStream.complete(stream, messages)

        {:error, reason, partial_state} ->
          AgentCore.EventStream.error(stream, reason, partial_state)

        {:canceled, reason} ->
          AgentCore.EventStream.push_async(stream, {:canceled, reason})
          AgentCore.EventStream.complete(stream, [])

        {:turn_end, %Ai.Types.AssistantMessage{stop_reason: :aborted}, _tool_results} ->
          AgentCore.EventStream.push_async(stream, {:canceled, :assistant_aborted})
          AgentCore.EventStream.complete(stream, [])

        _ ->
          AgentCore.EventStream.complete(stream, [])
      end

      Process.demonitor(mon_ref, [:flush])
    end)

    :ok
  end

  @spec persist_message(t(), term()) :: t()
  defp persist_message(state, message) do
    # Persist ALL messages, not just assistant
    new_session_manager =
      case message do
        %Ai.Types.UserMessage{} ->
          # Persist user messages (including steering/follow-up)
          SessionManager.append_message(state.session_manager, serialize_message(message))

        %Ai.Types.AssistantMessage{} ->
          # Persist assistant messages
          SessionManager.append_message(state.session_manager, serialize_message(message))

        %Ai.Types.ToolResultMessage{} ->
          # Persist tool results
          SessionManager.append_message(state.session_manager, serialize_message(message))

        _ ->
          # Other message types, don't persist
          state.session_manager
      end

    %{state | session_manager: new_session_manager}
  end

  @spec restore_messages_from_session(Session.t()) :: [map()]
  defp restore_messages_from_session(session) do
    context = SessionManager.build_session_context(session)

    context.messages
    |> Enum.map(&deserialize_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_register_session(_session_manager, _cwd, false, _registry), do: :ok

  defp maybe_register_session(session_manager, cwd, true, registry) do
    if Process.whereis(registry) do
      case Registry.register(registry, session_manager.header.id, %{cwd: cwd}) do
        {:ok, _} ->
          :ok

        {:error, {:already_registered, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to register session: #{inspect(reason)}")
      end
    end
  end

  defp maybe_unregister_session(_session_id, false, _registry), do: :ok

  defp maybe_unregister_session(session_id, true, registry) do
    if Process.whereis(registry) do
      Registry.unregister(registry, session_id)
    end

    :ok
  end

  defp cancel_pending_prompt(%__MODULE__{pending_prompt_timer_ref: nil} = state), do: state

  defp cancel_pending_prompt(%__MODULE__{pending_prompt_timer_ref: timer_ref} = state) do
    _ = Process.cancel_timer(timer_ref)
    %{state | pending_prompt_timer_ref: nil, is_streaming: false}
  end

  defp flush_queued_agent_events do
    receive do
      {:agent_event, _event} ->
        flush_queued_agent_events()
    after
      0 ->
        :ok
    end
  end

  @spec serialize_message(map()) :: map()
  defp serialize_message(%Ai.Types.UserMessage{} = msg) do
    %{
      "role" => "user",
      "content" => serialize_content(msg.content),
      "timestamp" => msg.timestamp
    }
  end

  defp serialize_message(%Ai.Types.AssistantMessage{} = msg) do
    %{
      "role" => "assistant",
      "content" => Enum.map(msg.content, &serialize_content_block/1),
      "provider" => msg.provider,
      "model" => msg.model,
      "api" => msg.api,
      "usage" => serialize_usage(msg.usage),
      "stop_reason" => msg.stop_reason && Atom.to_string(msg.stop_reason),
      "timestamp" => msg.timestamp
    }
  end

  defp serialize_message(%Ai.Types.ToolResultMessage{} = msg) do
    %{
      "role" => "tool_result",
      "tool_call_id" => msg.tool_call_id,
      "tool_name" => msg.tool_name,
      "content" => Enum.map(msg.content, &serialize_content_block/1),
      "details" => msg.details,
      "trust" => serialize_trust(msg.trust),
      "is_error" => msg.is_error,
      "timestamp" => msg.timestamp
    }
  end

  defp serialize_message(msg) when is_map(msg) do
    msg
  end

  @spec serialize_content(String.t() | list()) :: String.t() | list()
  defp serialize_content(content) when is_binary(content), do: content

  defp serialize_content(content) when is_list(content) do
    Enum.map(content, &serialize_content_block/1)
  end

  @spec serialize_content_block(map()) :: map()
  defp serialize_content_block(%Ai.Types.TextContent{text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp serialize_content_block(%Ai.Types.ImageContent{data: data, mime_type: mime_type}) do
    %{"type" => "image", "data" => data, "mime_type" => mime_type}
  end

  defp serialize_content_block(%Ai.Types.ThinkingContent{thinking: thinking}) do
    %{"type" => "thinking", "thinking" => thinking}
  end

  defp serialize_content_block(%Ai.Types.ToolCall{id: id, name: name, arguments: arguments}) do
    %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}
  end

  defp serialize_content_block(%{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp serialize_content_block(block) when is_map(block) do
    block
  end

  @spec serialize_usage(map() | nil) :: map() | nil
  defp serialize_usage(nil), do: nil

  defp serialize_usage(%Ai.Types.Usage{} = usage) do
    %{
      "input" => usage.input,
      "output" => usage.output,
      "cache_read" => usage.cache_read,
      "cache_write" => usage.cache_write,
      "total_tokens" => usage.total_tokens
    }
  end

  defp serialize_usage(usage) when is_map(usage), do: usage

  @spec deserialize_message(map()) :: map() | nil
  defp deserialize_message(%{"role" => "user"} = msg) do
    %Ai.Types.UserMessage{
      role: :user,
      content: deserialize_content(msg["content"]),
      timestamp: msg["timestamp"] || 0
    }
  end

  defp deserialize_message(%{"role" => "assistant"} = msg) do
    %Ai.Types.AssistantMessage{
      role: :assistant,
      content: deserialize_content_blocks(msg["content"]),
      provider: msg["provider"] || "",
      model: msg["model"] || "",
      api: msg["api"] || "",
      usage: deserialize_usage(msg["usage"]),
      stop_reason: deserialize_stop_reason(msg["stop_reason"]),
      timestamp: msg["timestamp"] || 0
    }
  end

  defp deserialize_message(%{"role" => "tool_result"} = msg) do
    %Ai.Types.ToolResultMessage{
      role: :tool_result,
      tool_call_id: msg["tool_call_id"] || msg["tool_use_id"] || "",
      tool_name: msg["tool_name"] || "",
      content: deserialize_content_blocks(msg["content"]),
      details: msg["details"],
      trust: deserialize_trust(msg["trust"]),
      is_error: msg["is_error"] || false,
      timestamp: msg["timestamp"] || 0
    }
  end

  defp deserialize_message(%{"role" => "custom"} = msg) do
    %CodingAgent.Messages.CustomMessage{
      role: :custom,
      custom_type: msg["custom_type"] || "",
      content: deserialize_content(msg["content"]),
      display: if(is_nil(msg["display"]), do: true, else: msg["display"]),
      details: msg["details"],
      timestamp: msg["timestamp"] || 0
    }
  end

  defp deserialize_message(%{"role" => "branch_summary"} = msg) do
    %CodingAgent.Messages.BranchSummaryMessage{
      summary: msg["summary"],
      timestamp: msg["timestamp"] || 0
    }
  end

  defp deserialize_message(_msg), do: nil

  @spec deserialize_content(String.t() | list() | nil) :: String.t() | list()
  defp deserialize_content(nil), do: ""
  defp deserialize_content(content) when is_binary(content), do: content
  defp deserialize_content(content) when is_list(content), do: deserialize_content_blocks(content)

  @spec deserialize_content_blocks(list() | nil) :: list()
  defp deserialize_content_blocks(nil), do: []

  defp deserialize_content_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, &deserialize_content_block/1)
  end

  @spec deserialize_content_block(map()) :: map()
  defp deserialize_content_block(%{"type" => "text", "text" => text}) do
    %Ai.Types.TextContent{type: :text, text: text}
  end

  defp deserialize_content_block(%{"type" => "image", "data" => data, "mime_type" => mime_type}) do
    %Ai.Types.ImageContent{type: :image, data: data, mime_type: mime_type}
  end

  defp deserialize_content_block(%{"type" => "thinking", "thinking" => thinking}) do
    %Ai.Types.ThinkingContent{type: :thinking, thinking: thinking}
  end

  defp deserialize_content_block(%{
         "type" => "tool_call",
         "id" => id,
         "name" => name,
         "arguments" => arguments
       }) do
    %Ai.Types.ToolCall{type: :tool_call, id: id, name: name, arguments: arguments}
  end

  defp deserialize_content_block(block), do: block

  @spec deserialize_usage(map() | nil) :: Ai.Types.Usage.t() | nil
  defp deserialize_usage(nil), do: nil

  defp deserialize_usage(usage) when is_map(usage) do
    %Ai.Types.Usage{
      input: usage["input"] || 0,
      output: usage["output"] || 0,
      cache_read: usage["cache_read"] || 0,
      cache_write: usage["cache_write"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      cost: %Ai.Types.Cost{}
    }
  end

  @spec deserialize_stop_reason(String.t() | nil) :: atom() | nil
  defp deserialize_stop_reason(nil), do: nil
  defp deserialize_stop_reason("stop"), do: :stop
  defp deserialize_stop_reason("length"), do: :length
  defp deserialize_stop_reason("tool_use"), do: :tool_use
  defp deserialize_stop_reason("error"), do: :error
  defp deserialize_stop_reason("aborted"), do: :aborted
  defp deserialize_stop_reason(_), do: nil

  defp serialize_trust(:untrusted), do: "untrusted"
  defp serialize_trust(:trusted), do: "trusted"
  defp serialize_trust("untrusted"), do: "untrusted"
  defp serialize_trust("trusted"), do: "trusted"
  defp serialize_trust(_), do: "trusted"

  defp deserialize_trust(:untrusted), do: :untrusted
  defp deserialize_trust("untrusted"), do: :untrusted
  defp deserialize_trust(:trusted), do: :trusted
  defp deserialize_trust("trusted"), do: :trusted
  defp deserialize_trust(_), do: :trusted

  # ============================================================================
  # Branch Summarization Helpers
  # ============================================================================

  @doc false
  # Determines if navigation constitutes a branch switch (abandoning the current branch)
  # A branch switch occurs when:
  # 1. The target entry is not on the current branch path, OR
  # 2. The target entry is an ancestor of the current leaf (going back in history)
  @spec is_branch_switch?([SessionEntry.t()], [SessionEntry.t()], String.t() | nil, String.t()) ::
          boolean()
  defp is_branch_switch?(_current_branch, _new_branch, nil, _target_id), do: false
  defp is_branch_switch?(_current_branch, _new_branch, _current_leaf_id, nil), do: false

  defp is_branch_switch?(current_branch, new_branch, current_leaf_id, target_id) do
    # Get IDs on each branch path
    current_ids = MapSet.new(Enum.map(current_branch, & &1.id))
    new_ids = MapSet.new(Enum.map(new_branch, & &1.id))

    # It's a branch switch if:
    # 1. Target is not on the current path at all (jumping to a different branch), OR
    # 2. Target is an ancestor of current leaf AND current leaf has descendants
    #    (but we can't know about descendants without more info, so simplify to:
    #    target is strictly before current leaf on the current branch)
    cond do
      # Target is current leaf - no switch
      target_id == current_leaf_id ->
        false

      # Target not on current branch - definitely a switch
      not MapSet.member?(current_ids, target_id) ->
        true

      # Target is on current branch but current leaf not on new branch
      # This means we're going back to an ancestor, abandoning the current extension
      not MapSet.member?(new_ids, current_leaf_id) ->
        true

      # Both are on each other's paths - just moving within same linear history
      true ->
        false
    end
  end

  @doc false
  # Attempts to summarize the abandoned branch asynchronously
  # Returns the state unchanged (summarization happens in background)
  @spec maybe_summarize_abandoned_branch(t(), [SessionEntry.t()], String.t() | nil) :: t()
  defp maybe_summarize_abandoned_branch(state, _branch_entries, nil), do: state

  defp maybe_summarize_abandoned_branch(state, branch_entries, from_id) do
    # Check if there are message entries worth summarizing
    message_entries =
      Enum.filter(branch_entries, fn entry ->
        entry.type == :message and entry.message != nil
      end)

    if length(message_entries) >= 2 do
      # Summarize asynchronously to not block navigation
      session_pid = self()
      model = state.model

      _ =
        start_background_task(fn ->
          case CodingAgent.Compaction.generate_branch_summary(branch_entries, model, []) do
            {:ok, summary} ->
              # Send a message back to the session to store the summary
              send(session_pid, {:store_branch_summary, from_id, summary})

            {:error, _reason} ->
              # Silently ignore summarization failures for abandoned branches
              :ok
          end
        end)
    end

    state
  end

  @spec session_signature(t()) :: session_signature()
  defp session_signature(state) do
    {
      state.session_manager.header.id,
      state.session_manager.leaf_id,
      length(state.session_manager.entries),
      state.turn_index,
      state.model.provider,
      state.model.id
    }
  end

  @spec clear_auto_compaction_state(t()) :: t()
  defp clear_auto_compaction_state(state) do
    state = clear_auto_compaction_task_tracking(state)
    %{state | auto_compaction_in_progress: false, auto_compaction_signature: nil}
  end

  @spec clear_overflow_recovery_task_state(t()) :: t()
  defp clear_overflow_recovery_task_state(state) do
    state = clear_overflow_recovery_task_tracking(state)

    %{
      state
      | overflow_recovery_in_progress: false,
        overflow_recovery_signature: nil,
        overflow_recovery_started_at_ms: nil
    }
  end

  @spec clear_overflow_recovery_state(t()) :: t()
  defp clear_overflow_recovery_state(state) do
    %{
      clear_overflow_recovery_task_state(state)
      | overflow_recovery_attempted: false,
        overflow_recovery_error_reason: nil,
        overflow_recovery_partial_state: nil
    }
  end

  @spec clear_auto_compaction_task_tracking(t()) :: t()
  defp clear_auto_compaction_task_tracking(state) do
    maybe_cancel_timer(state.auto_compaction_task_timeout_ref)
    maybe_demonitor(state.auto_compaction_task_monitor_ref)

    %{
      state
      | auto_compaction_task_pid: nil,
        auto_compaction_task_monitor_ref: nil,
        auto_compaction_task_timeout_ref: nil
    }
  end

  @spec clear_overflow_recovery_task_tracking(t()) :: t()
  defp clear_overflow_recovery_task_tracking(state) do
    maybe_cancel_timer(state.overflow_recovery_task_timeout_ref)
    maybe_demonitor(state.overflow_recovery_task_monitor_ref)

    %{
      state
      | overflow_recovery_task_pid: nil,
        overflow_recovery_task_monitor_ref: nil,
        overflow_recovery_task_timeout_ref: nil
    }
  end

  @spec handle_auto_compaction_task_down(t()) :: t()
  defp handle_auto_compaction_task_down(state) do
    state = clear_auto_compaction_task_tracking(state)

    cond do
      not state.auto_compaction_in_progress ->
        state

      true ->
        clear_auto_compaction_state(state)
    end
  end

  @spec handle_overflow_recovery_task_down(t()) :: t()
  defp handle_overflow_recovery_task_down(state) do
    state = clear_overflow_recovery_task_tracking(state)

    cond do
      not state.overflow_recovery_in_progress ->
        state

      true ->
        failure_reason = :overflow_recovery_task_down
        failed_state = clear_overflow_recovery_task_state(state)

        ui_notify(failed_state, "Overflow compaction worker stopped unexpectedly", :error)

        emit_overflow_recovery_telemetry(:failure, failed_state, %{
          duration_ms: overflow_recovery_duration_ms(state),
          reason: normalize_overflow_reason(failure_reason)
        })

        finalize_overflow_recovery_failure(failed_state, failure_reason)
    end
  end

  @spec clear_overflow_recovery_state_on_terminal(AgentCore.Types.agent_event(), t()) :: t()
  defp clear_overflow_recovery_state_on_terminal(event, state) do
    case event do
      {:agent_end, _messages} -> clear_overflow_recovery_state(state)
      {:canceled, _reason} -> clear_overflow_recovery_state(state)
      {:error, _reason, _partial_state} -> clear_overflow_recovery_state(state)
      _ -> state
    end
  end

  @spec maybe_start_overflow_recovery(t(), term(), term()) :: {:ok, t()} | :no_recovery
  defp maybe_start_overflow_recovery(state, reason, partial_state) do
    cond do
      not state.is_streaming ->
        :no_recovery

      state.overflow_recovery_in_progress ->
        :no_recovery

      state.overflow_recovery_attempted ->
        :no_recovery

      not context_length_exceeded_error?(reason) ->
        :no_recovery

      true ->
        signature = session_signature(state)
        session_pid = self()
        session_manager = state.session_manager
        model = state.model
        started_at_ms = System.monotonic_time(:millisecond)
        compaction_opts = overflow_recovery_compaction_opts(state)

        ui_notify(state, "Context window exceeded. Compacting and retrying...", :info)
        ui_set_working_message(state, "Context overflow detected. Compacting and retrying...")

        emit_overflow_recovery_telemetry(:attempt, state, %{
          reason: normalize_overflow_reason(reason)
        })

        case start_tracked_background_task(
               fn ->
                 result =
                   overflow_recovery_compaction_task_result(
                     session_manager,
                     model,
                     compaction_opts
                   )

                 send(session_pid, {:overflow_recovery_result, signature, result})
               end,
               overflow_recovery_task_timeout_ms(),
               :overflow_recovery_task_timeout
             ) do
          {:ok, task_meta} ->
            {:ok,
             %{
               state
               | overflow_recovery_in_progress: true,
                 overflow_recovery_attempted: true,
                 overflow_recovery_signature: signature,
                 overflow_recovery_task_pid: task_meta.pid,
                 overflow_recovery_task_monitor_ref: task_meta.monitor_ref,
                 overflow_recovery_task_timeout_ref: task_meta.timeout_ref,
                 overflow_recovery_started_at_ms: started_at_ms,
                 overflow_recovery_error_reason: reason,
                 overflow_recovery_partial_state: partial_state
             }}

          {:error, task_reason} ->
            Logger.warning(
              "Overflow recovery background task failed to start: #{inspect(task_reason)}"
            )

            :no_recovery
        end
    end
  end

  @spec overflow_recovery_compaction_opts(t()) :: keyword()
  defp overflow_recovery_compaction_opts(state) do
    normalize_compaction_opts(state, force: true)
  end

  @spec overflow_recovery_compaction_task_result(Session.t(), Ai.Types.Model.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp overflow_recovery_compaction_task_result(session_manager, model, opts) do
    try do
      CodingAgent.Compaction.compact(session_manager, model, opts)
    rescue
      exception ->
        {:error, {:exception, exception}}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  @spec continue_after_overflow_compaction(t()) :: {:ok, t()} | {:error, term(), t()}
  defp continue_after_overflow_compaction(state) do
    case AgentCore.Agent.wait_for_idle(state.agent, timeout: 5_000) do
      :ok ->
        ui_set_working_message(state, "Retrying after compaction...")

        case AgentCore.Agent.continue(state.agent) do
          :ok ->
            {:ok,
             %{
               state
               | is_streaming: true,
                 overflow_recovery_error_reason: nil,
                 overflow_recovery_partial_state: nil
             }}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, :timeout} ->
        {:error, :wait_for_idle_timeout, state}
    end
  end

  @spec finalize_overflow_recovery_failure(t(), term()) :: t()
  defp finalize_overflow_recovery_failure(state, fallback_reason) do
    reason = state.overflow_recovery_error_reason || fallback_reason
    event = {:error, reason, state.overflow_recovery_partial_state}

    broadcast_event(state, event)
    state = handle_agent_event(event, state)
    clear_overflow_recovery_state_on_terminal(event, state)
  end

  @spec context_length_exceeded_error?(term()) :: boolean()
  defp context_length_exceeded_error?(reason) do
    text =
      cond do
        is_binary(reason) ->
          reason

        is_atom(reason) ->
          Atom.to_string(reason)

        true ->
          inspect(reason, limit: 200, printable_limit: 8_000)
      end
      |> String.downcase()

    String.contains?(text, "context_length_exceeded") or
      String.contains?(text, "context length exceeded") or
      String.contains?(text, "context window") or
      String.contains?(text, "maximum context length")
  rescue
    _ -> false
  end

  @spec overflow_recovery_duration_ms(t()) :: non_neg_integer() | nil
  defp overflow_recovery_duration_ms(state) do
    case state.overflow_recovery_started_at_ms do
      started when is_integer(started) and started > 0 ->
        max(System.monotonic_time(:millisecond) - started, 0)

      _ ->
        nil
    end
  end

  @spec emit_overflow_recovery_telemetry(:attempt | :success | :failure, t(), map()) :: :ok
  defp emit_overflow_recovery_telemetry(stage, state, extra_meta)
       when stage in [:attempt, :success, :failure] and is_map(extra_meta) do
    metadata =
      %{
        session_id: state.session_manager.header.id,
        provider: state.model.provider,
        model: state.model.id
      }
      |> Map.merge(extra_meta)

    LemonCore.Telemetry.emit(
      [:coding_agent, :session, :overflow_recovery, stage],
      %{count: 1},
      metadata
    )
  rescue
    _ -> :ok
  end

  @spec normalize_overflow_reason(term()) :: String.t()
  defp normalize_overflow_reason(reason) when is_binary(reason), do: reason
  defp normalize_overflow_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_overflow_reason(reason), do: inspect(reason)

  @spec apply_compaction_result(t(), {:ok, map()} | {:error, term()}, String.t() | nil) ::
          {:ok, t()} | {:error, term(), t()}
  defp apply_compaction_result(state, {:ok, result}, custom_summary) do
    # Use custom summary if provided, otherwise use generated one
    summary = custom_summary || result.summary

    # Append compaction entry to session manager
    session_manager =
      SessionManager.append_compaction(
        state.session_manager,
        summary,
        result.first_kept_entry_id,
        result.tokens_before,
        result.details
      )

    # Rebuild messages from the new position and update agent
    messages = restore_messages_from_session(session_manager)
    :ok = AgentCore.Agent.replace_messages(state.agent, messages)

    # Broadcast compaction event to listeners
    compaction_event =
      {:compaction_complete,
       %{
         summary: summary,
         first_kept_entry_id: result.first_kept_entry_id,
         tokens_before: result.tokens_before
       }}

    broadcast_event(state, compaction_event)

    # Clear working message and notify success
    ui_set_working_message(state, nil)
    ui_notify(state, "Context compacted", :info)

    {:ok, %{state | session_manager: session_manager}}
  end

  defp apply_compaction_result(state, {:error, :cannot_compact}, _custom_summary) do
    ui_set_working_message(state, nil)
    {:error, :cannot_compact, state}
  end

  defp apply_compaction_result(state, {:error, reason}, _custom_summary) do
    ui_set_working_message(state, nil)
    ui_notify(state, "Compaction failed: #{inspect(reason)}", :error)
    {:error, reason, state}
  end

  @spec auto_compaction_task_result(Session.t(), Ai.Types.Model.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp auto_compaction_task_result(session_manager, model, opts) do
    try do
      CodingAgent.Compaction.compact(session_manager, model, opts)
    rescue
      exception ->
        {:error, {:exception, exception}}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  defp maybe_trigger_compaction(%__MODULE__{auto_compaction_in_progress: true} = state), do: state

  @spec maybe_trigger_compaction(t()) :: t()
  defp maybe_trigger_compaction(state) do
    # Get context usage from agent state
    agent_state = AgentCore.Agent.get_state(state.agent)
    context_messages = agent_state.messages || []
    context_tokens = CodingAgent.Compaction.estimate_context_tokens(context_messages)
    context_message_count = length(context_messages)

    # Get model's context_window
    context_window = state.model.context_window

    # Get compaction settings from settings_manager (or use defaults)
    compaction_settings = get_compaction_settings(state.settings_manager)
    message_budget = CodingAgent.Compaction.message_budget(state.model, compaction_settings)

    should_compact_by_tokens =
      CodingAgent.Compaction.should_compact?(context_tokens, context_window, compaction_settings)

    should_compact_by_message_limit =
      CodingAgent.Compaction.should_compact_for_message_limit?(
        context_message_count,
        message_budget,
        compaction_settings
      )

    # Check if compaction should be triggered
    if should_compact_by_tokens or should_compact_by_message_limit do
      signature = session_signature(state)
      session_pid = self()
      session_manager = state.session_manager
      model = state.model
      compaction_opts = normalize_compaction_opts(state, [])

      ui_set_working_message(state, "Compacting context...")

      case start_tracked_background_task(
             fn ->
               result = auto_compaction_task_result(session_manager, model, compaction_opts)
               send(session_pid, {:auto_compaction_result, signature, result})
             end,
             auto_compaction_task_timeout_ms(),
             :auto_compaction_task_timeout
           ) do
        {:ok, task_meta} ->
          %{
            state
            | auto_compaction_in_progress: true,
              auto_compaction_signature: signature,
              auto_compaction_task_pid: task_meta.pid,
              auto_compaction_task_monitor_ref: task_meta.monitor_ref,
              auto_compaction_task_timeout_ref: task_meta.timeout_ref
          }

        {:error, reason} ->
          Logger.warning("Auto compaction task failed to start: #{inspect(reason)}")
          ui_set_working_message(state, nil)
          state
      end
    else
      state
    end
  end

  defp maybe_start_wasm_sidecar(cwd, settings_manager, session_id, tool_policy, approval_context) do
    wasm_config = WasmConfig.load(cwd, settings_manager)

    if wasm_config.enabled do
      session_pid = self()

      host_invoke_fun = fn tool_name, params_json ->
        GenServer.call(session_pid, {:wasm_host_tool_invoke, tool_name, params_json}, :infinity)
      end

      sidecar_opts = [
        cwd: cwd,
        session_id: session_id,
        settings_manager: settings_manager,
        wasm_config: wasm_config,
        host_invoke_fun: host_invoke_fun
      ]

      case start_wasm_sidecar_process(sidecar_opts) do
        {:ok, sidecar_pid} ->
          case SidecarSession.discover(sidecar_pid) do
            {:ok, discover} ->
              wasm_tools =
                ToolFactory.build_inventory(sidecar_pid, discover.tools,
                  cwd: cwd,
                  session_id: session_id
                )

              wasm_tool_names = Enum.map(wasm_tools, &elem(&1, 0))

              wasm_status =
                SidecarSession.status(sidecar_pid)
                |> Map.put(:discover_warnings, discover.warnings)
                |> Map.put(:discover_errors, discover.errors)
                |> Map.put(:tool_names, wasm_tool_names)
                |> Map.put(:policy, summarize_wasm_policy(tool_policy, approval_context))

              %{
                sidecar_pid: sidecar_pid,
                wasm_tools: wasm_tools,
                wasm_tool_names: wasm_tool_names,
                wasm_status: wasm_status
              }

            {:error, reason} ->
              _ = SidecarSupervisor.stop_sidecar(sidecar_pid)

              Logger.warning(
                "WASM runtime unavailable for session #{session_id}: #{inspect(reason)}"
              )

              %{
                sidecar_pid: nil,
                wasm_tools: [],
                wasm_tool_names: [],
                wasm_status: wasm_disabled_status(reason)
              }
          end

        {:error, reason} ->
          Logger.warning("WASM runtime unavailable for session #{session_id}: #{inspect(reason)}")

          %{
            sidecar_pid: nil,
            wasm_tools: [],
            wasm_tool_names: [],
            wasm_status: wasm_disabled_status(reason)
          }
      end
    else
      %{
        sidecar_pid: nil,
        wasm_tools: [],
        wasm_tool_names: [],
        wasm_status: wasm_disabled_status(:disabled_in_config)
      }
    end
  end

  defp reload_wasm_tools(state) do
    cond do
      is_pid(state.wasm_sidecar_pid) and Process.alive?(state.wasm_sidecar_pid) ->
        case SidecarSession.discover(state.wasm_sidecar_pid) do
          {:ok, discover} ->
            wasm_tools =
              ToolFactory.build_inventory(state.wasm_sidecar_pid, discover.tools,
                cwd: state.cwd,
                session_id: state.session_manager.header.id
              )

            wasm_tool_names = Enum.map(wasm_tools, &elem(&1, 0))

            wasm_status =
              SidecarSession.status(state.wasm_sidecar_pid)
              |> Map.put(:discover_warnings, discover.warnings)
              |> Map.put(:discover_errors, discover.errors)
              |> Map.put(:tool_names, wasm_tool_names)
              |> Map.put(
                :policy,
                summarize_wasm_policy(state.tool_policy, state.approval_context)
              )

            %{
              sidecar_pid: state.wasm_sidecar_pid,
              wasm_tools: wasm_tools,
              wasm_tool_names: wasm_tool_names,
              wasm_status: wasm_status
            }

          {:error, reason} ->
            Logger.warning("WASM discover failed during reload: #{inspect(reason)}")

            %{
              sidecar_pid: state.wasm_sidecar_pid,
              wasm_tools: [],
              wasm_tool_names: [],
              wasm_status:
                (state.wasm_status || %{})
                |> Map.put(:discover_errors, [to_string(reason)])
                |> Map.put(:tool_names, [])
            }
        end

      true ->
        maybe_start_wasm_sidecar(
          state.cwd,
          state.settings_manager,
          state.session_manager.header.id,
          state.tool_policy,
          state.approval_context
        )
    end
  end

  defp start_wasm_sidecar_process(opts) do
    case SidecarSupervisor.start_sidecar(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp summarize_wasm_policy(nil, _approval_context), do: %{approval_wrapping: false}

  defp summarize_wasm_policy(tool_policy, approval_context) do
    %{
      approval_wrapping: not is_nil(approval_context),
      require_approval:
        Map.get(tool_policy, :require_approval) || Map.get(tool_policy, "require_approval"),
      approvals: Map.get(tool_policy, :approvals) || Map.get(tool_policy, "approvals")
    }
  end

  defp wasm_disabled_status(reason) do
    %{
      enabled: false,
      running: false,
      hello_ok: false,
      runtime_path: nil,
      tool_count: 0,
      tool_names: [],
      discover_warnings: [],
      discover_errors: [inspect(reason)],
      reason: reason
    }
  end

  defp maybe_handle_reserved_host_target(@secret_exists_target, params_json) do
    params = decode_wasm_params(params_json)

    case extract_secret_name(params) do
      {:ok, secret_name} ->
        exists? = LemonCore.Secrets.exists?(secret_name, prefer_env: false, env_fallback: true)
        {:ok, Jason.encode!(%{"exists" => exists?})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_handle_reserved_host_target(@secret_resolve_target, params_json) do
    params = decode_wasm_params(params_json)

    case extract_secret_name(params) do
      {:ok, secret_name} ->
        case LemonCore.Secrets.resolve(secret_name, prefer_env: false, env_fallback: true) do
          {:ok, value, source} ->
            {:ok, Jason.encode!(%{"value" => value, "source" => to_string(source)})}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_handle_reserved_host_target(_tool_name, _params_json), do: :not_reserved

  defp find_host_tool(state, tool_name) when is_binary(tool_name) do
    Enum.find(state.tools, fn tool ->
      tool.name == tool_name and tool.name not in state.wasm_tool_names
    end)
  end

  defp find_host_tool(_state, _tool_name), do: nil

  defp decode_wasm_params(params_json) when is_binary(params_json) do
    case Jason.decode(params_json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_wasm_params(_), do: %{}

  defp extract_secret_name(params) when is_map(params) do
    value = params["name"] || params[:name]

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      {:error, :invalid_secret_name}
    end
  end

  defp extract_secret_name(_), do: {:error, :invalid_secret_name}

  defp encode_wasm_host_output(%AgentCore.Types.AgentToolResult{} = tool_result) do
    payload =
      cond do
        is_map(tool_result.details) and map_size(tool_result.details) > 0 ->
          tool_result.details

        true ->
          %{"text" => extract_text_from_tool_result(tool_result.content)}
      end

    Jason.encode!(payload)
  end

  defp extract_text_from_tool_result(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_text_from_tool_result(_), do: ""

  @spec normalize_compaction_opts(t(), keyword()) :: keyword()
  defp normalize_compaction_opts(state, opts) do
    compaction_settings = get_compaction_settings(state.settings_manager)
    message_budget = CodingAgent.Compaction.message_budget(state.model, compaction_settings)

    opts
    |> maybe_put_keep_recent_tokens(compaction_settings)
    |> maybe_put_keep_recent_messages(message_budget)
  end

  @spec maybe_put_keep_recent_tokens(keyword(), map()) :: keyword()
  defp maybe_put_keep_recent_tokens(opts, compaction_settings) do
    keep_recent_tokens = Map.get(compaction_settings, :keep_recent_tokens)

    cond do
      Keyword.has_key?(opts, :keep_recent_tokens) ->
        opts

      is_integer(keep_recent_tokens) and keep_recent_tokens > 0 ->
        Keyword.put(opts, :keep_recent_tokens, keep_recent_tokens)

      true ->
        opts
    end
  end

  @spec maybe_put_keep_recent_messages(keyword(), CodingAgent.Compaction.message_budget() | nil) ::
          keyword()
  defp maybe_put_keep_recent_messages(opts, nil), do: opts

  defp maybe_put_keep_recent_messages(opts, %{keep_recent_messages: keep_recent_messages}) do
    cond do
      Keyword.has_key?(opts, :keep_recent_messages) ->
        opts

      is_integer(keep_recent_messages) and keep_recent_messages > 0 ->
        Keyword.put(opts, :keep_recent_messages, keep_recent_messages)

      true ->
        opts
    end
  end

  @spec get_compaction_settings(CodingAgent.SettingsManager.t() | nil) :: map()
  defp get_compaction_settings(nil), do: %{}

  defp get_compaction_settings(%CodingAgent.SettingsManager{} = settings) do
    CodingAgent.SettingsManager.get_compaction_settings(settings)
  end

  defp start_background_task(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:noproc, _}} ->
        Task.start(fun)

      {:error, :noproc} ->
        Task.start(fun)

      {:error, reason} ->
        Logger.warning(
          "Failed to start supervised session task: #{inspect(reason)}; falling back to Task.start/1"
        )

        Task.start(fun)
    end
  end

  @spec start_tracked_background_task((-> any()), non_neg_integer(), atom()) ::
          {:ok, %{pid: pid(), monitor_ref: reference(), timeout_ref: reference() | nil}}
          | {:error, term()}
  defp start_tracked_background_task(fun, timeout_ms, timeout_event)
       when is_function(fun, 0) and is_atom(timeout_event) do
    with {:ok, pid} <- start_background_task(fun) do
      monitor_ref = Process.monitor(pid)
      timeout_ref = schedule_background_task_timeout(timeout_event, monitor_ref, timeout_ms)
      {:ok, %{pid: pid, monitor_ref: monitor_ref, timeout_ref: timeout_ref}}
    end
  end

  @spec schedule_background_task_timeout(atom(), reference(), non_neg_integer()) ::
          reference() | nil
  defp schedule_background_task_timeout(timeout_event, monitor_ref, timeout_ms)
       when is_atom(timeout_event) and is_reference(monitor_ref) do
    if is_integer(timeout_ms) and timeout_ms > 0 do
      Process.send_after(self(), {timeout_event, monitor_ref}, timeout_ms)
    else
      nil
    end
  end

  @spec auto_compaction_task_timeout_ms() :: non_neg_integer()
  defp auto_compaction_task_timeout_ms do
    read_session_task_timeout(
      :auto_compaction_task_timeout_ms,
      @default_auto_compaction_task_timeout_ms
    )
  end

  @spec overflow_recovery_task_timeout_ms() :: non_neg_integer()
  defp overflow_recovery_task_timeout_ms do
    read_session_task_timeout(
      :overflow_recovery_task_timeout_ms,
      @default_overflow_recovery_task_timeout_ms
    )
  end

  @spec read_session_task_timeout(atom(), non_neg_integer()) :: non_neg_integer()
  defp read_session_task_timeout(key, default_timeout_ms) do
    case Application.get_env(:coding_agent, __MODULE__, [])
         |> Keyword.get(key, default_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> default_timeout_ms
    end
  end

  @spec maybe_cancel_timer(reference() | nil) :: :ok
  defp maybe_cancel_timer(nil), do: :ok

  defp maybe_cancel_timer(timer_ref) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  rescue
    _ -> :ok
  end

  @spec maybe_demonitor(reference() | nil) :: :ok
  defp maybe_demonitor(nil), do: :ok

  defp maybe_demonitor(monitor_ref) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  rescue
    _ -> :ok
  end

  @spec maybe_kill_background_task(t(), pid() | nil, term()) :: t()
  defp maybe_kill_background_task(state, pid, reason) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, {:shutdown, reason})
    end

    state
  rescue
    _ -> state
  end

  defp maybe_kill_background_task(state, _pid, _reason), do: state
end
