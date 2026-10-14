defmodule CodingAgent.Session.Lifecycle do
  @moduledoc false
  require Logger

  alias CodingAgent.ExtensionLifecycle
  alias CodingAgent.Extensions
  alias CodingAgent.Session

  alias CodingAgent.Session.{
    BackgroundTasks,
    CompactionLifecycle,
    CompactionManager,
    ModelResolver,
    Notifier,
    OverflowRecovery,
    Persistence,
    PromptComposer,
    ProviderFallback,
    State,
    WasmBridge
  }

  alias CodingAgent.SessionManager
  alias CodingAgent.SettingsManager
  alias CodingAgent.SystemPrompt.Environment, as: SystemPromptEnvironment
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
    context_snapshot = normalize_context_snapshot(Keyword.get(opts, :context_snapshot))
    initial_messages = normalize_initial_messages(Keyword.get(opts, :initial_messages))
    custom_tools = Keyword.get(opts, :tools)
    extra_tools = State.normalize_extra_tools(Keyword.get(opts, :extra_tools, []))
    workspace_dir = Keyword.get(opts, :workspace_dir, CodingAgent.Config.workspace_dir())
    profile_instructions = Keyword.get(opts, :profile_instructions)
    register_session = Keyword.get(opts, :register, false)
    session_registry = Keyword.get(opts, :registry, CodingAgent.SessionRegistry)

    Workspace.ensure_workspace(workspace_dir: workspace_dir)

    session_manager = load_or_create_session(cwd, session_file, session_id, parent_session)
    cwd = session_manager.header.cwd
    restored_context = SessionManager.build_session_context(session_manager)

    session_scope =
      PromptComposer.resolve_session_scope(
        opts,
        parent_session,
        session_manager.header.parent_session
      )

    # Header parentage also describes user forks; it is not proof that this
    # invocation is a delegated worker. Keep bootstrap isolation unchanged.
    task_child =
      Keyword.get(opts, :task_child, Keyword.get(opts, :session_scope) in [:subagent, "subagent"])

    settings_manager = Keyword.get(opts, :settings_manager) || SettingsManager.load(cwd)
    budget_limits = Keyword.get(opts, :budget_limits, settings_manager.budgets)
    {session_manager, budget_usage} = CodingAgent.Session.BudgetLedger.initialize(session_manager)

    run_id = Keyword.get(opts, :run_id)
    session_key = Keyword.get(opts, :session_key, session_manager.header.id)
    agent_id = Keyword.get(opts, :agent_id, "default")

    model =
      ModelResolver.resolve_session_model(
        Keyword.get(opts, :model) || restored_context.model,
        settings_manager
      )

    thinking_level =
      Keyword.get(opts, :thinking_level) ||
        if(
          Enum.any?(
            SessionManager.get_branch(session_manager),
            &(&1.type == :thinking_level_change)
          ),
          do: restored_context.thinking_level,
          else: settings_manager.default_thinking_level
        )

    session_file =
      session_file ||
        SessionManager.session_file_path(cwd, session_manager.header.id)

    session_manager =
      session_manager
      |> SessionManager.append_entry(
        SessionManager.SessionEntry.model_change(model.provider, model.id)
      )
      |> SessionManager.append_entry(
        SessionManager.SessionEntry.thinking_level_change(thinking_level)
      )
      |> SessionManager.persist(session_file)

    tool_policy = Keyword.get(opts, :tool_policy)

    approval_context =
      resolve_approval_context(opts, session_manager.header.id, tool_policy)

    secret_obfuscator =
      CodingAgent.Security.SecretObfuscator.for_session(settings_manager, cwd)

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
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:session_key, session_key)
      |> Keyword.put(:agent_id, agent_id)
      |> Keyword.put(:settings_manager, settings_manager)
      |> Keyword.put(:workspace_dir, workspace_dir)
      |> Keyword.put(:session_scope, session_scope)
      |> Keyword.put(:task_child, task_child)
      |> Keyword.put(:tool_policy, tool_policy)
      |> Keyword.put(:approval_context, approval_context)
      |> Keyword.put(:invocation_context_key, (approval_context || %{})[:invocation_context_key])
      |> Keyword.put(:invocation_mcp_servers, (approval_context || %{})[:invocation_mcp_servers])
      |> Keyword.put(:memory_context_key, (approval_context || %{})[:memory_context_key])
      |> Keyword.put(:memory_context_verified, (approval_context || %{})[:memory_context_verified] == true)
      |> Keyword.put(:shared_memory_grant, (approval_context || %{})[:shared_memory_grant] == true)
      |> Keyword.merge(private_native_opts(approval_context))
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
        approval_context: approval_context,
        secret_obfuscator: secret_obfuscator
      )

    plan_gate = CodingAgent.Session.Planning.new_gate()

    tools =
      CodingAgent.Session.Planning.tools(
        lifecycle.tools,
        session_manager,
        CodingAgent.Session.Planning.runtime_context(
          %{
            plan_gate: plan_gate,
            cwd: cwd,
            session_manager: session_manager,
            run_id: run_id,
            session_key: session_key,
            agent_id: agent_id,
            hooks: lifecycle.hooks,
            secret_obfuscator: secret_obfuscator,
            approval_context: approval_context
          },
          session_pid
        )
      )

    tool_names = Enum.map(tools, & &1.name)

    # Captured once: the date and git snapshot stay fixed for the session so
    # every prompt refresh reproduces the same bytes (prompt-cache stable).
    prompt_environment =
      if is_nil(context_snapshot), do: SystemPromptEnvironment.capture(cwd), else: nil

    # Labelled pieces of the composed prompt, kept for context-usage accounting.
    # A frozen snapshot prompt has no known structure and counts as one block.
    prompt_sections =
      case context_snapshot do
        %{system_prompt: _prompt} ->
          []

        nil ->
          PromptComposer.compose_sections(
            cwd,
            explicit_system_prompt,
            prompt_template,
            workspace_dir,
            session_scope,
            "",
            %{
              run_id: run_id,
              session_key: session_key,
              session_id: session_manager.header.id,
              agent_id: agent_id,
              tool_names: tool_names,
              profile_instructions: profile_instructions,
              invocation_context_key: (approval_context || %{})[:invocation_context_key],
              memory_context_key: (approval_context || %{})[:memory_context_key],
              memory_context_verified: (approval_context || %{})[:memory_context_verified] == true,
              shared_memory_grant: (approval_context || %{})[:shared_memory_grant] == true,
              environment: prompt_environment
            }
          )
      end

    base_system_prompt =
      case context_snapshot do
        %{system_prompt: prompt} -> prompt
        nil -> CodingAgent.SystemPrompt.join_sections(prompt_sections)
      end

    system_prompt =
      CodingAgent.Session.Planning.system_prompt(base_system_prompt, session_manager)

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
        context_guardrail_opts,
        secret_obfuscator
      )

    get_api_key =
      Keyword.get(opts, :get_api_key) || ModelResolver.build_get_api_key(settings_manager)

    stream_options =
      ModelResolver.build_stream_options(
        model,
        settings_manager,
        Keyword.get(opts, :stream_options),
        cwd
      )

    # The persisted session id (SessionManager.header.id) is the session
    # identity for provider failover: it is stable across turns and process
    # restarts of the same session file, unlike run_id (per run) or
    # session_key (caller-overridable). It scopes credential-pool rotation and
    # committed-fallback pins so a session sticks to one provider+credential
    # (provider prompt caches are keyed per provider+credential).
    stream_fn =
      opts
      |> Keyword.get(:stream_fn)
      |> ProviderFallback.maybe_wrap(model, settings_manager, cwd,
        session_id: session_manager.header.id
      )

    agent_registry_key = {session_manager.header.id, :main, 0}
    retry_settings = SettingsManager.get_retry_settings(settings_manager)

    {:ok, agent} =
      LemonAgent.Agent.start_link(
        initial_state: %{
          system_prompt: system_prompt,
          model: model,
          tools: tools,
          thinking_level: thinking_level,
          messages: []
        },
        convert_to_llm: convert_to_llm,
        stream_fn: stream_fn,
        stream_options: stream_options,
        transform_context: transform_context,
        get_api_key: get_api_key,
        session_id: session_manager.header.id,
        budget_limits: budget_limits,
        budget_usage: budget_usage,
        # Coding and assistant turns run until the model stops calling tools
        # (or the user interrupts); `[runtime] max_tool_turns` or an explicit
        # `:max_tool_turns` option installs a cap.
        max_tool_turns: Keyword.get(opts, :max_tool_turns, settings_manager.max_tool_turns),
        max_retries: if(retry_settings.enabled, do: retry_settings.max_retries, else: 0),
        retry_base_delay_ms: retry_settings.base_delay_ms,
        name: LemonAgent.AgentRegistry.via(agent_registry_key)
      )

    LemonAgent.Agent.subscribe(agent, session_pid)

    messages =
      case context_snapshot do
        %{messages: snapshot_messages} ->
          Persistence.prepare_initial_messages(snapshot_messages, session_manager)

        nil ->
          case initial_messages do
            nil -> Persistence.restore_messages_from_session(session_manager)
            messages -> Persistence.prepare_initial_messages(messages, session_manager)
          end
      end

    if messages != [] do
      LemonAgent.Agent.replace_messages(agent, messages)
    end

    state = %Session{
      agent: agent,
      session_manager: session_manager,
      run_id: run_id,
      session_key: session_key,
      agent_id: agent_id,
      settings_manager: settings_manager,
      budget_limits: budget_limits,
      budget_usage: budget_usage,
      cwd: cwd,
      tools: tools,
      model: model,
      thinking_level: thinking_level,
      system_prompt: system_prompt,
      base_system_prompt: base_system_prompt,
      prompt_sections: prompt_sections,
      base_tools: lifecycle.tools,
      prompt_environment: prompt_environment,
      explicit_system_prompt: explicit_system_prompt,
      prompt_template: prompt_template,
      workspace_dir: workspace_dir,
      profile_instructions: profile_instructions,
      mcp_session_id: Keyword.get(opts, :mcp_session_id),
      acp_mcp_session_id: Keyword.get(opts, :acp_mcp_session_id),
      extra_tools: extra_tools,
      # Kept so a reload recomputes disclosure with the same per-session
      # override the session started with -- `reload_extensions/1` rebuilds
      # `tool_opts` from state rather than from the original opts.
      tool_disclosure: Keyword.get(opts, :tool_disclosure),
      tool_catalog: lifecycle.tool_catalog,
      session_scope: session_scope,
      task_child: task_child,
      task_depth: Keyword.get(opts, :task_depth),
      task_allowed_agents: Keyword.get(opts, :task_allowed_agents),
      context_frozen: not is_nil(context_snapshot),
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
      secret_obfuscator: secret_obfuscator,
      extensions: lifecycle.extensions,
      hooks: lifecycle.hooks,
      extension_status_report: lifecycle.extension_status_report,
      wasm_sidecar_pid: wasm_boot.sidecar_pid,
      wasm_tool_names: wasm_boot.wasm_tool_names,
      wasm_status: wasm_boot.wasm_status,
      plan_gate: plan_gate,
      auto_compaction: %CompactionLifecycle.State{},
      overflow_recovery: %OverflowRecovery.State{}
    }

    {:ok, state, lifecycle.extension_status_report}
  end

  defp normalize_context_snapshot(%{messages: messages, system_prompt: system_prompt})
       when is_list(messages) and is_binary(system_prompt) do
    %{messages: messages, system_prompt: system_prompt}
  end

  defp normalize_context_snapshot(_), do: nil

  defp normalize_initial_messages(messages) when is_list(messages), do: messages
  defp normalize_initial_messages(_), do: nil

  @spec reload_extensions(Session.t()) ::
          {:ok, Extensions.extension_status_report() | nil, Session.t()}
  def reload_extensions(state) do
    wasm_reload = WasmBridge.reload_wasm_tools(state)

    tool_opts = [
      model: state.model,
      thinking_level: state.thinking_level,
      parent_session: state.session_manager.header.id,
      session_id: state.session_manager.header.id,
      session_pid: self(),
      run_id: state.run_id,
      session_key: state.session_key,
      agent_id: state.agent_id,
      settings_manager: state.settings_manager,
      workspace_dir: state.workspace_dir,
      mcp_session_id: state.mcp_session_id,
      acp_mcp_session_id: state.acp_mcp_session_id,
      session_scope: state.session_scope,
      task_child: state.task_child,
      task_depth: state.task_depth,
      task_allowed_agents: state.task_allowed_agents,
      tool_policy: state.tool_policy,
      approval_context: state.approval_context,
      invocation_context_key: (state.approval_context || %{})[:invocation_context_key],
      invocation_mcp_servers: (state.approval_context || %{})[:invocation_mcp_servers],
      memory_context_key: (state.approval_context || %{})[:memory_context_key],
      memory_context_verified: (state.approval_context || %{})[:memory_context_verified] == true,
      shared_memory_grant: (state.approval_context || %{})[:shared_memory_grant] == true,
      wasm_tools: wasm_reload.wasm_tools,
      wasm_status: wasm_reload.wasm_status,
      tool_disclosure: state.tool_disclosure
    ]
    |> Keyword.merge(private_native_opts(state.approval_context))

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
        secret_obfuscator: state.secret_obfuscator,
        previous_status_report: state.extension_status_report
      )

    tools =
      CodingAgent.Session.Planning.tools(
        lifecycle.tools,
        state.session_manager,
        state
        |> CodingAgent.Session.Planning.runtime_context(self())
        |> Map.put(:hooks, lifecycle.hooks)
      )

    :ok = LemonAgent.Agent.set_tools(state.agent, tools)
    Notifier.broadcast_event(state, {:extension_status_report, lifecycle.extension_status_report})

    new_state = %{
      state
      | extensions: lifecycle.extensions,
        hooks: lifecycle.hooks,
        tools: tools,
        base_tools: lifecycle.tools,
        tool_catalog: lifecycle.tool_catalog,
        extension_status_report: lifecycle.extension_status_report,
        wasm_sidecar_pid: wasm_reload.sidecar_pid,
        wasm_tool_names: wasm_reload.wasm_tool_names,
        wasm_status: wasm_reload.wasm_status
    }

    {:ok, lifecycle.extension_status_report, new_state}
  end

  @spec reset(Session.t(), non_neg_integer()) ::
          {:ok, Session.t()} | {:error, :busy, Session.t()}
  def reset(state, reset_abort_wait_ms) when is_integer(reset_abort_wait_ms) do
    was_streaming = state.is_streaming
    had_pending_prompt = not is_nil(state.pending_prompt_timer_ref)
    state = State.cancel_pending_prompt(state)

    case wait_for_reset_abort(state, was_streaming, had_pending_prompt, reset_abort_wait_ms) do
      :ok ->
        # Reset may discard queued events after abort. Capture already reported
        # spend from the agent first, and persist it in both old and new files.
        usage = LemonAgent.Agent.get_state(state.agent).budget_usage
        state = CodingAgent.Session.BudgetLedger.update(state, %{session_usage: usage})

        state =
          if was_streaming do
            Notifier.broadcast_event(state, {:canceled, :reset})
            Notifier.complete_event_streams(state, {:canceled, :reset})

            if not had_pending_prompt do
              BackgroundTasks.flush_queued_agent_events()
            end

            %{state | is_streaming: false, event_streams: %{}, steering_queue: :queue.new()}
          else
            state
          end

        state = CompactionManager.cancel_compaction_tasks(state, :session_reset)
        :ok = LemonAgent.Agent.reset(state.agent)

        previous_session_id = state.session_manager.header.id

        new_session_manager =
          SessionManager.new(state.cwd)
          |> SessionManager.append_entry(
            SessionManager.SessionEntry.model_change(state.model.provider, state.model.id)
          )
          |> SessionManager.append_entry(
            SessionManager.SessionEntry.thinking_level_change(state.thinking_level)
          )
          |> CodingAgent.Session.BudgetLedger.append(state.budget_usage)

        new_session_manager =
          SessionManager.persist(
            new_session_manager,
            SessionManager.session_file_path(state.cwd, new_session_manager.header.id)
          )

        Persistence.maybe_unregister_session(
          previous_session_id,
          state.register_session,
          state.session_registry
        )

        Persistence.maybe_register_session(
          new_session_manager,
          state.cwd,
          state.register_session,
          state.session_registry,
          state.session_key
        )

        state =
          State.reset_runtime(state, new_session_manager, System.system_time(:millisecond))
          |> CodingAgent.Session.Planning.refresh()

        {:ok, state}

      {:error, :timeout} ->
        Logger.warning("Timed out waiting for agent abort during reset")
        {:error, :busy, state}
    end
  end

  defp wait_for_reset_abort(_state, false, _had_pending_prompt, _reset_abort_wait_ms), do: :ok
  defp wait_for_reset_abort(_state, true, true, _reset_abort_wait_ms), do: :ok

  defp wait_for_reset_abort(state, true, false, reset_abort_wait_ms) do
    LemonAgent.Agent.abort(state.agent)
    LemonAgent.Agent.wait_for_idle(state.agent, timeout: reset_abort_wait_ms)
  end

  defp load_or_create_session(cwd, nil, session_id, parent_session) do
    SessionManager.new(cwd, id: session_id, parent_session: parent_session)
  end

  defp load_or_create_session(_cwd, session_file, _session_id, _parent_session) do
    case SessionManager.load_from_file(session_file) do
      {:ok, session} ->
        session

      {:error, reason} ->
        raise ArgumentError, "cannot resume session: #{inspect(reason)}"
    end
  end

  defp resolve_approval_context(opts, session_id, tool_policy) do
    approval_context = Keyword.get(opts, :approval_context)
    native_managed? = CodingAgent.Tools.Task.Params.managed_context?(
      Map.merge(Map.new(opts), approval_context || %{}))

    invocation_context_key =
      LemonCore.MapHelpers.get_key(approval_context, :invocation_context_key) ||
        Keyword.get(opts, :invocation_context_key)
    invocation_mcp_servers =
      Keyword.get(
        opts,
        :invocation_mcp_servers,
        (approval_context || %{})[:invocation_mcp_servers]
      )
    memory_context_key =
      Keyword.get(
        opts,
        :memory_context_key,
        LemonCore.MapHelpers.get_key(approval_context, :memory_context_key)
      )

    memory_context_verified =
      Keyword.get(
        opts,
        :memory_context_verified,
        Map.get(
          approval_context || %{},
          :memory_context_verified,
          Map.get(approval_context || %{}, "memory_context_verified")
        )
      ) == true

    shared_memory_grant =
      Keyword.get(
        opts,
        :shared_memory_grant,
        Map.get(
          approval_context || %{},
          :shared_memory_grant,
          Map.get(approval_context || %{}, "shared_memory_grant")
        )
      ) == true

    context = if is_nil(approval_context) &&
         (tool_policy || invocation_context_key || memory_context_key || memory_context_verified ||
            shared_memory_grant || not is_nil(invocation_mcp_servers)) do
      %{
        session_key: Keyword.get(opts, :session_key, session_id),
        session_id: session_id,
        agent_id: Keyword.get(opts, :agent_id, "default"),
        run_id: Keyword.get(opts, :run_id),
        invocation_context_key: invocation_context_key,
        memory_context_key: memory_context_key,
        memory_context_verified: memory_context_verified,
        shared_memory_grant: shared_memory_grant,
        invocation_mcp_servers: invocation_mcp_servers,
        timeout_ms: Keyword.get(opts, :approval_timeout_ms, :infinity)
      }
    else
      approval_context
      |> maybe_put_session_id(session_id)
      |> maybe_put_execution_identity(opts, session_id)
      |> maybe_put_invocation_context_key(invocation_context_key)
      |> maybe_put_invocation_mcp_servers(invocation_mcp_servers)
      |> maybe_put_memory_context(memory_context_key, memory_context_verified, shared_memory_grant)
    end

    private = Map.new(Keyword.take(opts, private_native_fields()))
    if is_map(context),
      do: Map.merge(private, context) |> Map.put(:native_managed_context, native_managed?),
      else: context
  end

  defp private_native_fields do
    [
      :native_lineage_handle, :native_lineage_run_id, :native_source_profile_id,
      :native_source_session_key, :native_followup_submit, :native_source_floor_fun,
      :invocation_proof, :invocation_proof_verified, :native_managed_context
    ]
  end

  defp private_native_opts(context), do: Map.to_list(Map.take(context || %{}, private_native_fields()))

  defp maybe_put_session_id(approval_context, session_id) when is_map(approval_context) do
    Map.put(approval_context, :session_id, approval_context[:session_id] || session_id)
  end

  defp maybe_put_session_id(approval_context, _session_id), do: approval_context

  defp maybe_put_invocation_context_key(context, key) when is_map(context),
    do: Map.put(context, :invocation_context_key, key)

  defp maybe_put_invocation_context_key(context, _key), do: context

  defp maybe_put_invocation_mcp_servers(context, servers) when is_map(context),
    do: Map.put(context, :invocation_mcp_servers, servers)

  defp maybe_put_invocation_mcp_servers(context, _servers), do: context

  defp maybe_put_memory_context(context, key, verified, shared_grant) when is_map(context) do
    context
    |> Map.put(:memory_context_key, key)
    |> Map.put(:memory_context_verified, verified)
    |> Map.put(:shared_memory_grant, shared_grant)
  end

  defp maybe_put_memory_context(context, _key, _verified, _shared_grant), do: context

  defp maybe_put_execution_identity(context, opts, session_id) when is_map(context) do
    context
    |> Map.put(:agent_id, Keyword.get(opts, :agent_id, "default"))
    |> Map.put(:run_id, context[:run_id] || Keyword.get(opts, :run_id))
    |> Map.put(:session_key, context[:session_key] || Keyword.get(opts, :session_key, session_id))
  end

  defp maybe_put_execution_identity(context, _opts, _session_id), do: context
end
