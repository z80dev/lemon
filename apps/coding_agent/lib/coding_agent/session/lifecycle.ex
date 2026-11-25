defmodule CodingAgent.Session.Lifecycle do
  @moduledoc false
  require Logger

  alias CodingAgent.ExtensionLifecycle
  alias CodingAgent.Extensions
  alias CodingAgent.ModelProvenance
  alias CodingAgent.Security.SecretObfuscator
  alias CodingAgent.Session

  alias CodingAgent.Session.{
    BackgroundTasks,
    BudgetLedger,
    CompactionLifecycle,
    CompactionManager,
    Notifier,
    OverflowRecovery,
    Persistence,
    PromptComposer,
    PromptJournal,
    State
  }

  alias CodingAgent.Session.BranchState
  alias CodingAgent.Session.Ownership
  alias CodingAgent.Session.Planning
  alias CodingAgent.SessionManager
  alias CodingAgent.SettingsManager
  alias CodingAgent.ToolPolicy
  alias CodingAgent.Tools.Task.InvocationAuthority
  alias CodingAgent.Workspace
  alias CodingAgent.WorkspaceReads
  alias LemonAgent.ModelRuntime.{ModelResolver, ProviderFailover, StreamOptions}

  defp emit_start_stage(stage, started, session_id) do
    :telemetry.execute(
      [:coding_agent, :session, :start_stage],
      %{duration: System.monotonic_time() - started},
      %{stage: stage, session_id: session_id}
    )
  end

  @fence_entry WorkspaceReads.fence_entry_type()

  @spec initialize(keyword(), pid()) ::
          {:ok, Session.t(), Extensions.extension_status_report() | nil}
  def initialize(opts, session_pid) when is_list(opts) and is_pid(session_pid) do
    opts =
      case Session.validate_execution_options(opts) do
        {:ok, opts} ->
          opts

        {:error, reason} ->
          raise ArgumentError, "invalid session execution authority: #{inspect(reason)}"
      end

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
    session_mode = PromptComposer.resolve_session_mode(opts)
    persona = Keyword.get(opts, :persona)
    persona = if is_boolean(persona), do: persona, else: session_mode == :chat
    opts = opts |> Keyword.put(:session_mode, session_mode) |> Keyword.put(:persona, persona)
    register_session = Keyword.get(opts, :register, false)
    session_registry = Keyword.get(opts, :registry, CodingAgent.SessionRegistry)

    # Only a session that reads assistant-home bootstrap seeds it, once per
    # workspace; a read-only home never fails session start.
    if persona and context_snapshot == nil,
      do: Workspace.seed_workspace(workspace_dir: workspace_dir)

    stage_started = System.monotonic_time()

    session_manager =
      Keyword.get_lazy(opts, :loaded_session, fn ->
        load_or_create_session(cwd, session_file, session_id, parent_session, opts[:session_key])
      end)

    session_manager =
      SessionManager.persist(
        session_manager,
        session_file || SessionManager.session_file_path(cwd, session_manager.header.id)
      )

    cwd = session_manager.header.cwd
    emit_start_stage(:journal_load, stage_started, session_manager.header.id)

    session_manager = seed_workspace_read_fence(session_manager, opts)

    {:ok, session_manager} =
      SessionManager.append_execution_context(
        session_manager,
        Keyword.fetch!(opts, :execution_context)
      )

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

    config_cwd = Keyword.get(opts, :config_cwd) || cwd
    settings_manager = Keyword.get(opts, :settings_manager) || SettingsManager.load(config_cwd)
    # A delegated `agent` run can only tighten the configured caps.
    budget_limits =
      opts
      |> Keyword.get(:budget_limits, settings_manager.budgets)
      |> CodingAgent.BudgetEnforcer.apply_delegated_limits(Keyword.get(opts, :delegated_budget))

    {session_manager, budget_usage} = BudgetLedger.initialize(session_manager)

    {:ok, budget_scope} =
      LemonAgent.BudgetScope.start_link(
        limits: budget_limits,
        usage: budget_usage,
        child_usage: BudgetLedger.restore_children(session_manager),
        parent: Keyword.get(opts, :parent_budget_scope),
        id: Keyword.get(opts, :run_id) || session_manager.header.id,
        owner: session_pid
      )

    budget_limits = Map.put(budget_limits || %{}, :scope, budget_scope)
    opts = Keyword.put(opts, :budget_scope, budget_scope)

    run_id = Keyword.get(opts, :run_id)
    session_key = Keyword.get(opts, :session_key, session_manager.header.id)
    agent_id = Keyword.get(opts, :agent_id, "default")

    requested_model = Keyword.get(opts, :model)

    requested_explicit =
      case Keyword.get(opts, :model_explicit) do
        explicit when is_boolean(explicit) -> explicit
        _ -> not is_nil(requested_model)
      end

    model_explicit = requested_explicit or restored_context.model_explicit

    selector =
      if requested_explicit,
        do: requested_model,
        else: restored_context.model || requested_model

    # A router-marked profile or router-default selector is operator
    # configuration: it resolves (roles included) against the operator layer
    # of this session's settings, never a project override.
    operator_selector? =
      Keyword.get(opts, :model_source) == :operator and not is_nil(requested_model) and
        selector == requested_model

    {model, resolved_origin} =
      if operator_selector?,
        do: ModelProvenance.resolve_operator(selector, settings_manager),
        else: {ModelResolver.resolve_session_model(selector, settings_manager), nil}

    # Provenance of the session's own model (from the provenance pair loaded
    # with the settings), inherited by task children so a project-origin
    # choice stays gated after it resolves to a concrete model. Task children
    # receive it from their launch; an explicit caller choice is the
    # operator's; a restored model keeps its journaled origin.
    model_origin =
      cond do
        origin = Keyword.get(opts, :model_origin) -> origin
        resolved_origin -> resolved_origin
        requested_explicit -> :operator
        restored_context.model -> ModelProvenance.restored(restored_context, settings_manager)
        true -> ModelProvenance.origin(requested_model, settings_manager)
      end

    model_routing = unless model_explicit, do: ModelProvenance.prepare_routing(settings_manager)

    thinking_level =
      LemonAgent.AutoThinking.normalize_level(
        Keyword.get(opts, :thinking_level) ||
          if(
            Enum.any?(
              SessionManager.get_branch(session_manager),
              &(&1.type == :thinking_level_change)
            ),
            do: restored_context.thinking_level,
            else: settings_manager.default_thinking_level
          )
      )

    session_file =
      session_file ||
        SessionManager.session_file_path(cwd, session_manager.header.id)

    session_manager =
      session_manager
      |> SessionManager.append_entry(
        SessionManager.SessionEntry.model_change(model.provider, model.id,
          explicit: model_explicit,
          origin: model_origin
        )
      )
      |> SessionManager.append_entry(
        SessionManager.SessionEntry.thinking_level_change(thinking_level)
      )
      |> SessionManager.persist(session_file)

    tool_policy =
      opts
      |> Keyword.fetch!(:tool_policy)
      |> ToolPolicy.with_default_approval_mode(Map.get(settings_manager.tools, :approval_mode))

    execution_context = %{Keyword.fetch!(opts, :execution_context) | tool_policy: tool_policy}

    approval_context =
      resolve_approval_context(opts, session_manager.header.id, tool_policy)
      |> then(fn context ->
        if is_map(context) and session_scope != :main,
          do: Map.delete(context, :channel_identity),
          else: context
      end)
      |> then(fn context ->
        # The folder-read exemption binds the bound workspace scope, and a
        # restored or inherited fence keeps gating web egress for this session
        # even if the policy no longer carries the exemption.
        if is_map(context) do
          context
          |> maybe_put_workspace_scope_root(execution_context)
          |> Map.put(
            :workspace_read_fenced,
            not is_nil(SessionManager.latest_custom_entry(session_manager, @fence_entry))
          )
        else
          context
        end
      end)

    secret_obfuscator = SecretObfuscator.for_session(settings_manager)

    # The plan gate is also a tool option so self-gated tools (`task`) can
    # enforce plan mode at execution time.
    plan_gate = Planning.new_gate()

    tool_opts =
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:model_explicit, model_explicit)
      |> Keyword.put(:model_origin, model_origin)
      |> Keyword.put(:thinking_level, thinking_level)
      |> Keyword.put(:parent_session, session_manager.header.id)
      |> Keyword.put(:session_id, session_manager.header.id)
      |> Keyword.put(:session_pid, session_pid)
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:session_key, session_key)
      |> Keyword.put(:agent_id, agent_id)
      |> Keyword.put(:settings_manager, settings_manager)
      |> Keyword.put(:config_cwd, config_cwd)
      |> Keyword.put(:workspace_dir, workspace_dir)
      |> Keyword.put(:session_scope, session_scope)
      |> Keyword.put(:task_child, task_child)
      |> Keyword.put(:tool_policy, tool_policy)
      |> Keyword.put(:execution_context, execution_context)
      |> Keyword.put(:approval_context, approval_context)
      |> Keyword.put(:invocation_context_key, (approval_context || %{})[:invocation_context_key])
      |> Keyword.put(:invocation_mcp_servers, (approval_context || %{})[:invocation_mcp_servers])
      |> Keyword.put(:channel_identity, (approval_context || %{})[:channel_identity])
      |> Keyword.put(:memory_context_key, (approval_context || %{})[:memory_context_key])
      |> Keyword.put(
        :memory_context_verified,
        (approval_context || %{})[:memory_context_verified] == true
      )
      |> Keyword.put(
        :shared_memory_grant,
        (approval_context || %{})[:shared_memory_grant] == true
      )
      |> Keyword.merge(private_native_opts(approval_context))
      |> Keyword.put(:native_managed_context, InvocationAuthority.named_messaging_managed?(opts))
      |> Keyword.put(:plan_gate, plan_gate)

    # Delegated children and reloads inherit `:extra_tools`; keep only what this
    # session's policy admits (a child still applies its own, narrower floor).
    extra_tools = CodingAgent.ToolRegistry.permitted_tools(extra_tools, tool_opts)
    tool_opts = Keyword.put(tool_opts, :extra_tools, extra_tools)

    stage_started = System.monotonic_time()

    lifecycle =
      ExtensionLifecycle.initialize(
        cwd: cwd,
        config_cwd: config_cwd,
        settings_manager: settings_manager,
        tool_opts: tool_opts,
        custom_tools: custom_tools,
        extra_tools: extra_tools,
        tool_policy: tool_policy,
        approval_context: approval_context,
        secret_obfuscator: secret_obfuscator
      )

    tools =
      Planning.tools(
        lifecycle.tools,
        session_manager,
        Planning.runtime_context(
          %{
            plan_gate: plan_gate,
            model: model,
            settings_manager: settings_manager,
            tool_opts: tool_opts,
            cwd: cwd,
            session_manager: session_manager,
            run_id: run_id,
            session_key: session_key,
            agent_id: agent_id,
            hooks: lifecycle.hooks,
            secret_obfuscator: secret_obfuscator,
            approval_context: approval_context,
            bot_folder_root: Keyword.get(opts, :bot_folder_root),
            config_cwd: config_cwd,
            native_source_profile_id: Keyword.get(opts, :native_source_profile_id)
          },
          session_pid
        )
      )

    tool_names = Enum.map(tools, & &1.name)
    emit_start_stage(:tool_registry, stage_started, session_manager.header.id)

    # Durable orientation survives process retirement between turns. Frozen
    # side queries neither capture nor journal new environment context.
    stage_started = System.monotonic_time()

    {session_manager, prompt_environment} =
      if is_nil(context_snapshot) do
        SessionManager.capture_environment(session_manager, cwd)
      else
        {session_manager, nil}
      end

    emit_start_stage(:environment_capture, stage_started, session_manager.header.id)
    stage_started = System.monotonic_time()

    # Labelled pieces of the composed prompt, kept for context-usage accounting.
    # A frozen snapshot prompt has no known structure and counts as one block.
    prompt_sections =
      case context_snapshot do
        %{system_prompt: _prompt} ->
          []

        nil ->
          PromptComposer.compose_sections(
            config_cwd,
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
              session_mode: session_mode,
              persona: persona,
              invocation_context_key: (approval_context || %{})[:invocation_context_key],
              channel_identity: (approval_context || %{})[:channel_identity],
              memory_context_key: (approval_context || %{})[:memory_context_key],
              memory_context_verified:
                (approval_context || %{})[:memory_context_verified] == true,
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

    prompt_state = PromptJournal.restore(session_manager, base_system_prompt, prompt_sections)
    system_prompt = prompt_state.system_prompt
    base_system_prompt = prompt_state.base_system_prompt
    prompt_sections = prompt_state.prompt_sections

    emit_start_stage(:prompt_composition, stage_started, session_manager.header.id)

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
        secret_obfuscator,
        fn rewind_id ->
          GenServer.call(session_pid, {:context_checkpoint_projection, rewind_id}, :infinity)
        end
      )

    get_api_key =
      Keyword.get(opts, :get_api_key) || ModelResolver.build_get_api_key(settings_manager)

    stream_options =
      ModelResolver.build_stream_options(
        model,
        settings_manager,
        Keyword.get(opts, :stream_options),
        config_cwd
      )

    resolve_stream_options = fn next_model, previous_model, options ->
      options =
        if next_model.provider == previous_model.provider do
          options
        else
          StreamOptions.sanitize_for_provider_switch(options)
        end

      options =
        ModelResolver.build_stream_options(next_model, settings_manager, options, config_cwd)

      provider = next_model.provider

      api_key =
        get_api_key.(provider) ||
          if(is_atom(provider), do: get_api_key.(Atom.to_string(provider))) ||
          options.api_key

      %{options | api_key: api_key}
    end

    strip_recalled_context = Session.recalled_context_stripper()

    # Prepare only closures here. Model/credential resolution and completion
    # happen inside AutoThinking's bounded task when the loop sees a user turn.
    resolve_thinking = fn active_model, message, signal ->
      resolve_classifier = fn ->
        case ModelResolver.resolve_auto_thinking_model(settings_manager) do
          nil ->
            nil

          classifier_model ->
            options =
              ModelResolver.build_stream_options(
                classifier_model,
                settings_manager,
                nil,
                config_cwd
              )

            provider = classifier_model.provider

            api_key =
              get_api_key.(provider) ||
                if(is_atom(provider), do: get_api_key.(Atom.to_string(provider))) ||
                options.api_key

            {classifier_model, %{options | api_key: api_key}}
        end
      end

      LemonAgent.AutoThinking.resolve(
        active_model,
        strip_recalled_context.(message),
        signal,
        resolve_classifier: resolve_classifier,
        complete_fn: Keyword.get(opts, :complete_fn, &LemonAi.complete/3),
        timeout_ms: Keyword.get(opts, :auto_thinking_timeout_ms, 5_000)
      )
    end

    # The persisted session id (SessionManager.header.id) is the session
    # identity for provider failover: it is stable across turns and process
    # restarts of the same session file, unlike run_id (per run) or
    # session_key (caller-overridable). It scopes credential-pool rotation and
    # committed-fallback pins so a session sticks to one provider+credential
    # (provider prompt caches are keyed per provider+credential). The loop
    # runs failover inside its own attempt budget and checks each candidate
    # against the live model-routing cost cap.
    agent_registry_key = {session_manager.header.id, :main, 0}

    provider_failover =
      ProviderFailover.new(settings_manager,
        cwd: config_cwd,
        session_id: session_manager.header.id
      )

    stream_fn = fn candidate, context, options ->
      {base_stream_fn, options} =
        GenServer.call(session_pid, {:invocation_stream, candidate, options}, :infinity)

      base_stream_fn.(candidate, context, options)
    end

    retry_settings = SettingsManager.get_retry_settings(settings_manager)
    # Stream rules are repository data: load them from the trusted config
    # directory, like the prompt, never from a Bot folder execution cwd.
    stream_rules = CodingAgent.Rules.stream_rules(config_cwd)

    {:ok, agent} =
      LemonAgent.Agent.start_link(
        initial_state: %{
          system_prompt: PromptJournal.blocks(prompt_state),
          model: model,
          tools: tools,
          thinking_level: thinking_level,
          messages: []
        },
        convert_to_llm: convert_to_llm,
        stream_fn: stream_fn,
        provider_failover: provider_failover,
        system_prompt_observer: session_pid,
        hibernate_after: Keyword.get(opts, :hibernate_after, 5_000),
        stream_rules: fn ->
          GenServer.call(session_pid, {:available_stream_rules, stream_rules}, :infinity)
        end,
        on_stream_rule: fn rule ->
          GenServer.call(session_pid, {:inject_stream_rule, rule}, :infinity)
        end,
        stream_options: stream_options,
        transform_context: transform_context,
        tool_result_max_bytes: Map.get(context_guardrail_opts, :max_tool_result_bytes),
        get_api_key: get_api_key,
        resolve_stream_options: resolve_stream_options,
        model_routing: model_routing,
        resolve_thinking: resolve_thinking,
        session_id: session_manager.header.id,
        budget_limits: budget_limits,
        budget_usage: budget_usage,
        # Coding and assistant turns run until the model stops calling tools
        # (or the user interrupts); `[runtime] max_tool_turns` or an explicit
        # `:max_tool_turns` option installs a cap.
        max_tool_turns: Keyword.get(opts, :max_tool_turns, settings_manager.max_tool_turns),
        intent_tracing:
          Keyword.get(
            opts,
            :intent_tracing,
            Map.get(settings_manager.tools, :intent_tracing, true)
          ),
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
      model_origin: model_origin,
      thinking_level: thinking_level,
      system_prompt: system_prompt,
      base_system_prompt: base_system_prompt,
      prompt_sections: prompt_sections,
      journaled_prompt: prompt_state.journaled_prompt,
      base_tools: lifecycle.tools,
      prompt_environment: prompt_environment,
      explicit_system_prompt: explicit_system_prompt,
      prompt_template: prompt_template,
      workspace_dir: workspace_dir,
      profile_instructions: profile_instructions,
      mcp_session_id: Keyword.get(opts, :mcp_session_id),
      acp_mcp_session_id: Keyword.get(opts, :acp_mcp_session_id),
      extra_tools: extra_tools,
      # Retain startup tool options without transcript payloads for fresh-ID resets.
      tool_opts:
        Keyword.drop(tool_opts, [:initial_messages, :context_snapshot, :responses_transport]),
      # Kept so a reload recomputes disclosure with the same per-session
      # override the session started with -- `reload_extensions/1` rebuilds
      # `tool_opts` from state rather than from the original opts.
      tool_disclosure: Keyword.get(opts, :tool_disclosure),
      tool_catalog: lifecycle.tool_catalog,
      session_scope: session_scope,
      project_memory_capture: Keyword.get(opts, :project_memory_capture, true),
      task_child: task_child,
      task_depth: Keyword.get(opts, :task_depth),
      task_allowed_agents: Keyword.get(opts, :task_allowed_agents),
      context_frozen: not is_nil(context_snapshot),
      is_streaming: false,
      pending_prompt_timer_ref: nil,
      event_listeners: [],
      event_streams: %{},
      event_log:
        CodingAgent.Session.EventLog.new(
          session_manager.header.id,
          session_key,
          run_id,
          cwd,
          opts
        ),
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
      execution_context: execution_context,
      approval_context: approval_context,
      secret_obfuscator: secret_obfuscator,
      bot_folder_root: Keyword.get(opts, :bot_folder_root),
      config_cwd: config_cwd,
      native_source_profile_id: Keyword.get(opts, :native_source_profile_id),
      extensions: lifecycle.extensions,
      hooks: lifecycle.hooks,
      extension_status_report: lifecycle.extension_status_report,
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
    tool_opts =
      [
        model: state.model,
        model_explicit:
          SessionManager.build_session_context(state.session_manager).model_explicit,
        thinking_level: state.thinking_level,
        # Tools are rebuilt with the model and its origin together, so a
        # rebuilt task tool gates children exactly as the current model requires.
        model_origin: state.model_origin,
        parent_session: state.session_manager.header.id,
        session_id: state.session_manager.header.id,
        session_pid: self(),
        budget_scope: Map.get(state.budget_limits, :scope),
        run_id: state.run_id,
        session_key: state.session_key,
        agent_id: state.agent_id,
        settings_manager: state.settings_manager,
        workspace_dir: state.workspace_dir,
        mcp_session_id: state.mcp_session_id,
        acp_mcp_session_id: state.acp_mcp_session_id,
        session_scope: state.session_scope,
        session_mode: Keyword.get(state.tool_opts, :session_mode, :chat),
        persona: Keyword.get(state.tool_opts, :persona),
        task_child: state.task_child,
        task_depth: state.task_depth,
        task_allowed_agents: state.task_allowed_agents,
        tool_policy: state.tool_policy,
        execution_context: state.execution_context,
        approval_context: state.approval_context,
        invocation_context_key: (state.approval_context || %{})[:invocation_context_key],
        tern_pane: Keyword.get(state.tool_opts, :tern_pane),
        cwd_identity: Keyword.get(state.tool_opts, :cwd_identity),
        confine_mutations_to: Keyword.get(state.tool_opts, :confine_mutations_to),
        operator_state_grant: Keyword.get(state.tool_opts, :operator_state_grant),
        invocation_mcp_servers: (state.approval_context || %{})[:invocation_mcp_servers],
        channel_identity: (state.approval_context || %{})[:channel_identity],
        memory_context_key: (state.approval_context || %{})[:memory_context_key],
        memory_context_verified:
          (state.approval_context || %{})[:memory_context_verified] == true,
        shared_memory_grant: (state.approval_context || %{})[:shared_memory_grant] == true,
        tool_disclosure: state.tool_disclosure,
        bot_folder_root: state.bot_folder_root,
        config_cwd: state.config_cwd,
        native_source_profile_id: state.native_source_profile_id,
        plan_gate: state.plan_gate
      ]
      |> Keyword.merge(private_native_opts(state.approval_context))
      |> Keyword.put(
        :native_managed_context,
        InvocationAuthority.named_messaging_managed?(state.tool_opts)
      )

    lifecycle =
      ExtensionLifecycle.reload(
        cwd: state.cwd,
        config_cwd: state.config_cwd,
        settings_manager: state.settings_manager,
        tool_opts: tool_opts,
        # A hand-assembled toolset stays the same closed set across reloads.
        custom_tools: Keyword.get(state.tool_opts, :tools),
        extra_tools: state.extra_tools,
        tool_policy: state.tool_policy,
        approval_context: state.approval_context,
        secret_obfuscator: state.secret_obfuscator,
        previous_status_report: state.extension_status_report
      )

    tools =
      Planning.tools(
        lifecycle.tools,
        state.session_manager,
        state
        |> Planning.runtime_context(self())
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
        tool_opts: Keyword.merge(state.tool_opts, tool_opts),
        journaled_prompt: nil
    }

    {:ok, lifecycle.extension_status_report, new_state}
  end

  @spec reset(Session.t(), non_neg_integer()) ::
          {:ok, Session.t()} | {:error, :busy, Session.t()}
  def reset(state, reset_abort_wait_ms) when is_integer(reset_abort_wait_ms) do
    was_streaming = state.is_streaming or LemonAgent.Agent.get_state(state.agent).is_streaming
    state = State.cancel_pending_prompt(state)

    case wait_for_reset_abort(state, reset_abort_wait_ms) do
      :ok ->
        # Reset may discard queued events after abort. Capture already reported
        # spend from the agent first, and persist it in both old and new files.
        usage = LemonAgent.Agent.get_state(state.agent).budget_usage
        state = BudgetLedger.update(state, %{session_usage: usage})

        state =
          if was_streaming do
            state = %{state | terminal_event: {:canceled, :reset}}
            Notifier.broadcast_event(state, {:canceled, :reset})
            Notifier.complete_event_streams(state, {:canceled, :reset})

            %{state | is_streaming: false, event_streams: %{}, steering_queue: :queue.new()}
          else
            state
          end

        state = CompactionManager.cancel_compaction_tasks(state, :session_reset)
        state = CodingAgent.Session.ResponsesTransport.reset(state)
        :ok = LemonAgent.Agent.reset(state.agent)
        BackgroundTasks.flush_queued_agent_events()

        previous_session_id = state.session_manager.header.id
        :ok = CodingAgent.Tools.Bash.ShellState.reset(previous_session_id)

        # Preserve automatic selection across reset and resume. The journal reducer
        # also keeps legacy model entries without provenance conservatively pinned.
        model_explicit =
          SessionManager.build_session_context(state.session_manager).model_explicit

        new_session_manager =
          SessionManager.new(state.cwd, session_key: state.tool_opts[:session_key])
          |> SessionManager.append_entry(
            SessionManager.SessionEntry.model_change(state.model.provider, state.model.id,
              explicit: model_explicit,
              origin: state.model_origin
            )
          )
          |> SessionManager.append_entry(
            SessionManager.SessionEntry.thinking_level_change(state.thinking_level)
          )
          |> BudgetLedger.append(state.budget_usage)
          |> BudgetLedger.append_children(BudgetLedger.restore_children(state.session_manager))

        new_path = SessionManager.session_file_path(state.cwd, new_session_manager.header.id)

        new_session_manager =
          Ownership.transfer(state.session_file, new_path, fn ->
            SessionManager.persist(new_session_manager, new_path)
          end)

        :ok = SessionManager.close(state.session_manager)

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
          |> Map.put(:session_file, new_path)
          |> Map.put(:journaled_prompt, nil)
          |> Map.put(:response_system_prompt, nil)
          |> rebuild_tools(previous_session_id)
          |> BranchState.restore()

        {:ok, state}

      {:error, :timeout} ->
        Logger.warning("Timed out waiting for agent abort during reset")
        {:error, :busy, state}
    end
  end

  defp wait_for_reset_abort(state, reset_abort_wait_ms) do
    LemonAgent.Agent.abort(state.agent)
    LemonAgent.Agent.wait_for_idle(state.agent, timeout: reset_abort_wait_ms)
  end

  @doc false
  def rebind_invocation(%Session{} = state) do
    state
    |> rebuild_tools(state.session_manager.header.id)
    |> Planning.refresh()
  end

  # Rebuild closures and hook/approval contexts for the fresh journal identity
  # without reloading extensions. BranchState restores the effective tools.
  defp rebuild_tools(state, previous_session_id) do
    session_id = state.session_manager.header.id

    approval_context =
      rebind_approval_context(state.approval_context, previous_session_id, session_id)

    state = %{state | approval_context: approval_context}

    tool_opts =
      Keyword.merge(state.tool_opts,
        model: state.model,
        model_origin: state.model_origin,
        model_explicit:
          SessionManager.build_session_context(state.session_manager).model_explicit,
        thinking_level: state.thinking_level,
        parent_session: session_id,
        session_id: session_id,
        approval_context: approval_context
      )

    built =
      ExtensionLifecycle.rebuild_tools(
        cwd: state.cwd,
        config_cwd: state.config_cwd,
        settings_manager: state.settings_manager,
        tool_opts: tool_opts,
        extensions: state.extensions,
        hooks: state.hooks,
        custom_tools: Keyword.get(tool_opts, :tools),
        extra_tools: state.extra_tools,
        tool_policy: state.tool_policy,
        approval_context: approval_context,
        secret_obfuscator: state.secret_obfuscator
      )

    %{
      state
      | tool_opts: tool_opts,
        base_tools: built.tools,
        tool_catalog: built.tool_catalog
    }
  end

  defp rebind_approval_context(%{session_id: previous} = context, previous, session_id),
    do: %{context | session_id: session_id}

  defp rebind_approval_context(context, _previous, _session_id), do: context

  defp load_or_create_session(cwd, nil, session_id, parent_session, session_key) do
    SessionManager.new(cwd,
      id: session_id,
      parent_session: parent_session,
      session_key: session_key
    )
  end

  defp load_or_create_session(_cwd, session_file, _session_id, _parent_session, _session_key) do
    case SessionManager.load_from_file(session_file) do
      {:ok, session} ->
        session

      {:error, reason} ->
        raise ArgumentError, "cannot resume session: #{inspect(reason)}"
    end
  end

  # A restored branch keeps the egress fence it earned, and a `task` child
  # spawned after its parent was fenced starts fenced too. The state is always
  # recorded explicitly, so a lost ETS mirror reads as unknown (and therefore
  # fenced) rather than as a session that never fenced.
  defp seed_workspace_read_fence(session_manager, opts) do
    session_id = session_manager.header.id
    persisted? = not is_nil(SessionManager.latest_custom_entry(session_manager, @fence_entry))
    inherited? = Keyword.get(opts, :workspace_read_fenced) == true

    WorkspaceReads.register_session(
      session_id,
      persisted? or inherited?,
      session_manager.header.parent_session
    )

    if inherited? and not persisted? do
      SessionManager.append_entry(
        session_manager,
        SessionManager.SessionEntry.custom(@fence_entry, %{
          "fenced" => true,
          "inherited" => true,
          "timestamp" => System.system_time(:millisecond)
        })
      )
    else
      session_manager
    end
  end

  defp maybe_put_workspace_scope_root(context, %{workspace_scope: %{root: root}})
       when is_binary(root),
       do: Map.put_new(context, :workspace_scope_root, root)

  defp maybe_put_workspace_scope_root(context, _execution_context), do: context

  @doc false
  def resolve_approval_context(opts, session_id, tool_policy) do
    approval_context = Keyword.get(opts, :approval_context)

    channel_identity =
      Keyword.get(opts, :channel_identity, (approval_context || %{})[:channel_identity])

    native_managed? =
      InvocationAuthority.managed_context?(Map.merge(Map.new(opts), approval_context || %{}))

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

    context =
      if is_nil(approval_context) &&
           (tool_policy || invocation_context_key || memory_context_key || memory_context_verified ||
              shared_memory_grant || channel_identity || not is_nil(invocation_mcp_servers)) do
        %{
          session_key: Keyword.get(opts, :session_key, session_id),
          session_id: session_id,
          agent_id: Keyword.get(opts, :agent_id, "default"),
          run_id: Keyword.get(opts, :run_id),
          invocation_context_key: invocation_context_key,
          channel_identity: channel_identity,
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
        |> maybe_put_memory_context(
          memory_context_key,
          memory_context_verified,
          shared_memory_grant
        )
      end

    private = Map.new(Keyword.take(opts, private_native_fields()))

    if is_map(context) do
      Map.merge(private, context)
      |> Map.put(:native_managed_context, native_managed?)
      |> Map.put(:channel_identity, channel_identity)
    else
      context
    end
  end

  defp private_native_fields do
    [
      :native_lineage_handle,
      :native_lineage_run_id,
      :native_source_profile_id,
      :native_source_session_key,
      :native_followup_submit,
      :native_source_floor_fun,
      :invocation_proof,
      :invocation_proof_verified,
      :native_managed_context,
      :bot_folder_root,
      :config_cwd
    ]
  end

  defp private_native_opts(context),
    do: Map.to_list(Map.take(context || %{}, private_native_fields()))

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
