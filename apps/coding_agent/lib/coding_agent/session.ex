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
  alias CodingAgent.Config
  alias CodingAgent.Extensions
  alias CodingAgent.ResourceLoader
  alias CodingAgent.Workspace
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.{Session, SessionEntry}
  alias CodingAgent.ToolRegistry
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
    :extensions,
    :hooks,
    :extension_status_report
  ]

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
          extensions: [module()],
          hooks: keyword([function()]),
          extension_status_report: Extensions.extension_status_report() | nil
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

    # Get model from opts, or fall back to settings_manager.default_model
    model = Keyword.get(opts, :model) || resolve_default_model(settings_manager)

    # Get thinking_level from opts, or fall back to settings_manager.default_thinking_level
    thinking_level = Keyword.get(opts, :thinking_level) || settings_manager.default_thinking_level

    # Load extensions from multiple paths (for hooks)
    extension_paths =
      (settings_manager.extension_paths || []) ++
        [
          Config.extensions_dir(),
          Config.project_extensions_dir(cwd)
        ]

    {:ok, extensions, load_errors, _validation_errors} =
      Extensions.load_extensions_with_errors(extension_paths)

    # Get hooks from extensions
    hooks = Extensions.get_hooks(extensions)

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
    tool_opts =
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:thinking_level, thinking_level)
      |> Keyword.put(:parent_session, session_manager.header.id)
      |> Keyword.put(:session_id, session_manager.header.id)
      |> Keyword.put(:settings_manager, settings_manager)
      |> Keyword.put(:workspace_dir, workspace_dir)
      |> Keyword.put(:ui_context, ui_context)
      |> Keyword.put(:extension_paths, extension_paths)
      |> Keyword.put(:tool_policy, tool_policy)
      |> Keyword.put(:approval_context, approval_context)

    # Build tools list via ToolRegistry (handles extension tools + conflict detection + approval wrapping)
    # When custom_tools is provided, extension tools are still added
    tools =
      case custom_tools do
        nil ->
          ToolRegistry.get_tools(cwd, tool_opts)

        custom ->
          # Extension tools are always loaded, even with custom base tools
          extension_tools = Extensions.get_tools(extensions, cwd)
          all_tools = custom ++ extension_tools

          # Apply approval wrapping if policy and context provided
          if tool_policy && approval_context do
            CodingAgent.ToolExecutor.wrap_all_with_approval(
              all_tools,
              tool_policy,
              approval_context
            )
          else
            all_tools
          end
      end

    # Register extension-provided providers (e.g., model providers)
    provider_registration = Extensions.register_extension_providers(extensions)

    # Build extension status report (tool conflicts computed from registry)
    tool_conflict_report = ToolRegistry.tool_conflict_report(cwd, tool_opts)

    extension_status_report =
      Extensions.build_status_report(extensions, load_errors,
        cwd: cwd,
        tool_conflict_report: tool_conflict_report,
        provider_registration: provider_registration
      )

    # Create the convert_to_llm function
    convert_to_llm = &CodingAgent.Messages.to_llm/1

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
      extensions: extensions,
      hooks: hooks,
      extension_status_report: extension_status_report
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
          turn_index: state.turn_index + 1
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

  def handle_call(:reload_extensions, _from, state) do
    if state.is_streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      # Show working message
      ui_set_working_message(state, "Reloading extensions...")

      # Unregister previously registered extension providers
      old_provider_registration =
        case state.extension_status_report do
          %{provider_registration: reg} -> reg
          _ -> nil
        end

      Extensions.unregister_extension_providers(old_provider_registration)

      # Clear extension module cache
      Extensions.clear_extension_cache()

      # Build extension paths (same logic as init)
      extension_paths =
        (state.settings_manager.extension_paths || []) ++
          [
            Config.extensions_dir(),
            Config.project_extensions_dir(state.cwd)
          ]

      # Reload extensions
      {:ok, extensions, load_errors, _validation_errors} =
        Extensions.load_extensions_with_errors(extension_paths)

      # Get hooks from extensions
      hooks = Extensions.get_hooks(extensions)

      # Register extension-provided providers (e.g., model providers)
      provider_registration = Extensions.register_extension_providers(extensions)

      # Build tool options
      tool_opts = [
        model: state.model,
        thinking_level: state.thinking_level,
        parent_session: state.session_manager.header.id,
        session_id: state.session_manager.header.id,
        settings_manager: state.settings_manager,
        workspace_dir: state.workspace_dir,
        ui_context: state.ui_context,
        extension_paths: extension_paths
      ]

      # Rebuild tools via ToolRegistry
      tools = ToolRegistry.get_tools(state.cwd, tool_opts)

      # Build extension status report
      tool_conflict_report = ToolRegistry.tool_conflict_report(state.cwd, tool_opts)

      extension_status_report =
        Extensions.build_status_report(extensions, load_errors,
          cwd: state.cwd,
          tool_conflict_report: tool_conflict_report,
          provider_registration: provider_registration
        )

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
          extension_status_report: extension_status_report
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

    new_state = %{
      state
      | session_manager: new_session_manager,
        is_streaming: false,
        pending_prompt_timer_ref: nil,
        turn_index: 0,
        started_at: System.system_time(:millisecond),
        session_file: nil,
        steering_queue: :queue.new(),
        follow_up_queue: :queue.new()
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
    custom_summary = Keyword.get(opts, :summary)

    # Show working message before compaction
    ui_set_working_message(state, "Compacting context...")

    case CodingAgent.Compaction.compact(state.session_manager, state.model, opts) do
      {:ok, result} ->
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

        {:reply, :ok, %{state | session_manager: session_manager}}

      {:error, :cannot_compact} ->
        ui_set_working_message(state, nil)
        {:reply, {:error, :cannot_compact}, state}

      {:error, reason} ->
        ui_set_working_message(state, nil)
        ui_notify(state, "Compaction failed: #{inspect(reason)}", :error)
        {:reply, {:error, reason}, state}
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
    state = cancel_pending_prompt(state)
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
  def handle_info({:agent_event, event}, state) do
    # Broadcast to listeners FIRST (before state changes that might clear streams)
    broadcast_event(state, event)

    # Process the event and update state
    new_state = handle_agent_event(event, state)

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
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

  def handle_info({:EXIT, pid, reason}, state) when pid == state.agent do
    Logger.warning("Agent process exited: #{inspect(reason)}")
    state = state |> Map.put(:is_streaming, false) |> cancel_pending_prompt()
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

  defp build_get_api_key(%CodingAgent.SettingsManager{providers: providers}) do
    fn provider ->
      provider_cfg =
        case provider do
          p when is_atom(p) -> Map.get(providers, Atom.to_string(p))
          p when is_binary(p) -> Map.get(providers, p)
          _ -> nil
        end

      provider_cfg && Map.get(provider_cfg, :api_key)
    end
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

  @spec handle_agent_event(AgentCore.Types.agent_event(), t()) :: t()
  defp handle_agent_event({:agent_start}, state) do
    # Execute on_agent_start hooks
    Extensions.execute_hooks(state.hooks, :on_agent_start, [])
    state
  end

  defp handle_agent_event({:turn_start}, state) do
    # Execute on_turn_start hooks
    Extensions.execute_hooks(state.hooks, :on_turn_start, [])
    state
  end

  defp handle_agent_event({:turn_end, message, tool_results}, state) do
    # Execute on_turn_end hooks
    Extensions.execute_hooks(state.hooks, :on_turn_end, [message, tool_results])

    # Abort can terminate the underlying stream before {:canceled, reason} is observed.
    # Treat an aborted assistant turn as terminal to keep Session lifecycle consistent.
    case message do
      %Ai.Types.AssistantMessage{stop_reason: :aborted} ->
        ui_set_working_message(state, nil)
        complete_event_streams(state, {:turn_end, message, tool_results})
        %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}

      _ ->
        state
    end
  end

  defp handle_agent_event({:message_start, message}, state) do
    # Execute on_message_start hooks
    Extensions.execute_hooks(state.hooks, :on_message_start, [message])
    state
  end

  defp handle_agent_event({:message_end, message}, state) do
    # Execute on_message_end hooks
    Extensions.execute_hooks(state.hooks, :on_message_end, [message])

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

    new_state = %{state | session_manager: new_session_manager}

    # Some abort paths can terminate after :message_end without emitting
    # :turn_end/:agent_end/:canceled. Treat aborted assistant messages as terminal
    # to avoid leaving the session in a permanently streaming state.
    case message do
      %Ai.Types.AssistantMessage{stop_reason: :aborted} ->
        ui_set_working_message(new_state, nil)
        complete_event_streams(new_state, {:canceled, :assistant_aborted})
        %{new_state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}

      _ ->
        new_state
    end
  end

  defp handle_agent_event({:tool_start, tool_call}, state) do
    # Execute on_tool_execution_start hooks
    Extensions.execute_hooks(state.hooks, :on_tool_execution_start, [
      tool_call.id,
      tool_call.name,
      tool_call.arguments
    ])

    tool_name = tool_call.name
    ui_set_working_message(state, "Running #{tool_name}...")
    state
  end

  defp handle_agent_event({:tool_end, tool_call, result}, state) do
    # Execute on_tool_execution_end hooks
    is_error = Map.get(result, :is_error, false)

    Extensions.execute_hooks(state.hooks, :on_tool_execution_end, [
      tool_call.id,
      tool_call.name,
      result,
      is_error
    ])

    ui_set_working_message(state, nil)
    state
  end

  defp handle_agent_event({:agent_end, messages}, state) do
    # Execute on_agent_end hooks
    Extensions.execute_hooks(state.hooks, :on_agent_end, [messages])

    # Clear working message and steering queue
    ui_set_working_message(state, nil)

    # Complete all event streams with the final event
    complete_event_streams(state, {:agent_end, messages})

    # Check if compaction is needed
    new_state = %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}
    maybe_trigger_compaction(new_state)
  end

  defp handle_agent_event({:error, reason, partial_state}, state) do
    ui_set_working_message(state, nil)
    ui_notify(state, "Agent error: #{inspect(reason)}", :error)

    # Complete all event streams with the error event
    complete_event_streams(state, {:error, reason, partial_state})

    %{state | is_streaming: false, event_streams: %{}}
  end

  defp handle_agent_event({:canceled, reason}, state) do
    # Canceled is a terminal lifecycle event (e.g. abort) and may occur without :agent_end.
    ui_set_working_message(state, nil)

    # Complete all event streams with the canceled event
    complete_event_streams(state, {:canceled, reason})

    %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}
  end

  defp handle_agent_event(_event, state) do
    state
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

      Task.start(fn ->
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

  @spec maybe_trigger_compaction(t()) :: t()
  defp maybe_trigger_compaction(state) do
    # Get context usage from agent state
    agent_state = AgentCore.Agent.get_state(state.agent)
    context_tokens = CodingAgent.Compaction.estimate_context_tokens(agent_state.messages)

    # Get model's context_window
    context_window = state.model.context_window

    # Get compaction settings from settings_manager (or use defaults)
    compaction_settings = get_compaction_settings(state.settings_manager)

    # Check if compaction should be triggered
    if CodingAgent.Compaction.should_compact?(context_tokens, context_window, compaction_settings) do
      # Trigger compaction asynchronously
      session_pid = self()

      Task.start(fn ->
        GenServer.call(session_pid, {:compact, []}, :infinity)
      end)
    end

    state
  end

  @spec get_compaction_settings(CodingAgent.SettingsManager.t() | nil) :: map()
  defp get_compaction_settings(nil), do: %{}

  defp get_compaction_settings(%CodingAgent.SettingsManager{} = settings) do
    CodingAgent.SettingsManager.get_compaction_settings(settings)
  end
end
