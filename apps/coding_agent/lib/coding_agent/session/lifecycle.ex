defmodule CodingAgent.Session.Lifecycle do
  @moduledoc false
  require Logger

  alias CodingAgent.ExtensionLifecycle
  alias CodingAgent.Extensions
  alias CodingAgent.Session

  alias CodingAgent.Session.{
    BackgroundTasks,
    ModelResolver,
    Notifier,
    Persistence,
    PromptComposer,
    State,
    WasmBridge
  }

  alias CodingAgent.SessionManager
  alias CodingAgent.Workspace

  @spec initialize(keyword(), pid()) ::
          {:ok, Session.t(), Extensions.extension_status_report() | nil}
  def initialize(opts, session_pid) when is_list(opts) and is_pid(session_pid) do
    cwd = Keyword.fetch!(opts, :cwd)
    explicit_system_prompt = Keyword.get(opts, :system_prompt)
    prompt_template = Keyword.get(opts, :prompt_template)
    session_file = Keyword.get(opts, :session_file)
    session_id = Keyword.get(opts, :session_id)
    parent_session = Keyword.get(opts, :parent_session)
    ui_context = Keyword.get(opts, :ui_context)
    custom_tools = Keyword.get(opts, :tools)
    extra_tools = State.normalize_extra_tools(Keyword.get(opts, :extra_tools, []))
    workspace_dir = Keyword.get(opts, :workspace_dir, CodingAgent.Config.workspace_dir())
    register_session = Keyword.get(opts, :register, false)
    session_registry = Keyword.get(opts, :registry, CodingAgent.SessionRegistry)

    Notifier.maybe_register_ui_tracker(ui_context)
    Workspace.ensure_workspace(workspace_dir: workspace_dir)

    session_manager = load_or_create_session(cwd, session_file, session_id, parent_session)

    session_scope =
      PromptComposer.resolve_session_scope(
        opts,
        parent_session,
        session_manager.header.parent_session
      )

    settings_manager =
      Keyword.get(opts, :settings_manager) || CodingAgent.SettingsManager.load(cwd)

    system_prompt =
      PromptComposer.compose_system_prompt(
        cwd,
        explicit_system_prompt,
        prompt_template,
        workspace_dir,
        session_scope
      )

    model = ModelResolver.resolve_session_model(Keyword.get(opts, :model), settings_manager)
    thinking_level = Keyword.get(opts, :thinking_level) || settings_manager.default_thinking_level
    tool_policy = Keyword.get(opts, :tool_policy)

    approval_context =
      resolve_approval_context(opts, session_manager.header.id, tool_policy)

    wasm_boot =
      WasmBridge.maybe_start_wasm_sidecar(
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
      |> Keyword.put(:session_pid, session_pid)
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

    convert_to_llm = &CodingAgent.Messages.to_llm/1

    context_guardrail_opts =
      State.build_context_guardrail_opts(
        cwd,
        session_manager.header.id,
        Keyword.get(opts, :context_guardrails)
      )

    transform_context =
      State.build_transform_context(
        Keyword.get(opts, :transform_context),
        context_guardrail_opts
      )

    get_api_key =
      Keyword.get(opts, :get_api_key) || ModelResolver.build_get_api_key(settings_manager)

    stream_options =
      ModelResolver.build_stream_options(
        model,
        settings_manager,
        Keyword.get(opts, :stream_options)
      )

    agent_registry_key = {session_manager.header.id, :main, 0}

    {:ok, agent} =
      AgentCore.Agent.start_link(
        initial_state: %{
          system_prompt: system_prompt,
          model: model,
          tools: lifecycle.tools,
          thinking_level: thinking_level,
          messages: []
        },
        convert_to_llm: convert_to_llm,
        stream_fn: Keyword.get(opts, :stream_fn),
        stream_options: stream_options,
        transform_context: transform_context,
        get_api_key: get_api_key,
        session_id: session_manager.header.id,
        name: AgentCore.AgentRegistry.via(agent_registry_key)
      )

    AgentCore.Agent.subscribe(agent, session_pid)

    messages = Persistence.restore_messages_from_session(session_manager)

    if messages != [] do
      AgentCore.Agent.replace_messages(agent, messages)
    end

    state = %Session{
      agent: agent,
      session_manager: session_manager,
      settings_manager: settings_manager,
      ui_context: ui_context,
      cwd: cwd,
      tools: lifecycle.tools,
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
      extensions: lifecycle.extensions,
      hooks: lifecycle.hooks,
      extension_status_report: lifecycle.extension_status_report,
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

    {:ok, state, lifecycle.extension_status_report}
  end

  @spec reload_extensions(Session.t()) ::
          {:ok, Extensions.extension_status_report() | nil, Session.t()}
  def reload_extensions(state) do
    Notifier.ui_set_working_message(state, "Reloading extensions...")

    wasm_reload = WasmBridge.reload_wasm_tools(state)

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

    :ok = AgentCore.Agent.set_tools(state.agent, lifecycle.tools)
    Notifier.ui_set_working_message(state, nil)
    Notifier.broadcast_event(state, {:extension_status_report, lifecycle.extension_status_report})

    Notifier.ui_notify(
      state,
      "Extensions reloaded: #{lifecycle.extension_status_report.total_loaded} loaded",
      :info
    )

    new_state = %{
      state
      | extensions: lifecycle.extensions,
        hooks: lifecycle.hooks,
        tools: lifecycle.tools,
        extension_status_report: lifecycle.extension_status_report,
        wasm_sidecar_pid: wasm_reload.sidecar_pid,
        wasm_tool_names: wasm_reload.wasm_tool_names,
        wasm_status: wasm_reload.wasm_status
    }

    {:ok, lifecycle.extension_status_report, new_state}
  end

  @spec reset(Session.t(), non_neg_integer()) :: Session.t()
  def reset(state, reset_abort_wait_ms) when is_integer(reset_abort_wait_ms) do
    was_streaming = state.is_streaming
    had_pending_prompt = not is_nil(state.pending_prompt_timer_ref)
    state = State.cancel_pending_prompt(state)

    state =
      if was_streaming do
        Notifier.broadcast_event(state, {:canceled, :reset})
        Notifier.complete_event_streams(state, {:canceled, :reset})

        if not had_pending_prompt do
          AgentCore.Agent.abort(state.agent)

          case AgentCore.Agent.wait_for_idle(state.agent, timeout: reset_abort_wait_ms) do
            :ok -> :ok
            {:error, :timeout} -> Logger.warning("Timed out waiting for agent abort during reset")
          end

          BackgroundTasks.flush_queued_agent_events()
        end

        %{state | is_streaming: false, event_streams: %{}, steering_queue: :queue.new()}
      else
        state
      end

    :ok = AgentCore.Agent.reset(state.agent)

    previous_session_id = state.session_manager.header.id
    new_session_manager = SessionManager.new(state.cwd)

    Persistence.maybe_unregister_session(
      previous_session_id,
      state.register_session,
      state.session_registry
    )

    Persistence.maybe_register_session(
      new_session_manager,
      state.cwd,
      state.register_session,
      state.session_registry
    )

    Notifier.ui_set_working_message(state, nil)
    State.reset_runtime(state, new_session_manager, System.system_time(:millisecond))
  end

  defp load_or_create_session(cwd, nil, session_id, parent_session) do
    SessionManager.new(cwd, id: session_id, parent_session: parent_session)
  end

  defp load_or_create_session(cwd, session_file, session_id, parent_session) do
    case SessionManager.load_from_file(session_file) do
      {:ok, session} -> session
      {:error, _reason} -> SessionManager.new(cwd, id: session_id, parent_session: parent_session)
    end
  end

  defp resolve_approval_context(opts, session_id, tool_policy) do
    approval_context = Keyword.get(opts, :approval_context)

    if tool_policy && is_nil(approval_context) do
      %{
        session_key: Keyword.get(opts, :session_key, session_id),
        agent_id: Keyword.get(opts, :agent_id, "default"),
        timeout_ms: Keyword.get(opts, :approval_timeout_ms, :infinity)
      }
    else
      approval_context
    end
  end
end
