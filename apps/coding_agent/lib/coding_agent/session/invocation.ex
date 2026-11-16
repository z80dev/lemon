defmodule CodingAgent.Session.Invocation do
  @moduledoc false

  alias CodingAgent.Session.{Lifecycle, ModelResolver}
  alias CodingAgent.SessionManager

  # A live root keeps its agent, journal handle and captured environment. Only
  # invocation-scoped authority and closures are rebound; never reuse a previous
  # run's approvals, lineage, MCP credentials or trace context.
  def prepare(%CodingAgent.Session{} = state, opts) do
    mode = CodingAgent.Session.PromptComposer.resolve_session_mode(opts)

    persona =
      case Keyword.get(opts, :persona) do
        value when is_boolean(value) -> value
        _ -> mode == :chat
      end

    opts = opts |> Keyword.put(:session_mode, mode) |> Keyword.put(:persona, persona)

    if Path.expand(Keyword.fetch!(opts, :cwd)) != Path.expand(state.cwd) or
         Keyword.get(opts, :workspace_dir, state.workspace_dir) != state.workspace_dir do
      {:error, :live_session_workspace_mismatch}
    else
      with {:ok, opts} <-
             CodingAgent.Session.validate_live_execution_options(opts, state.session_manager),
           {:ok, mcp_id} <- open_mcp(opts, state) do
        %LemonCore.ExecutionContext{} = context = Keyword.fetch!(opts, :execution_context)

        policy =
          opts
          |> Keyword.fetch!(:tool_policy)
          |> CodingAgent.ToolPolicy.with_default_approval_mode(
            Map.get(state.settings_manager.tools, :approval_mode)
          )

        context = %{context | tool_policy: policy}

        approval =
          Lifecycle.resolve_approval_context(opts, state.session_manager.header.id, policy)
          |> Map.put(
            :workspace_read_fenced,
            (state.approval_context || %{})[:workspace_read_fenced]
          )
          |> Map.put(:workspace_scope_root, context.workspace_scope.root)

        opts = Keyword.put(opts, :mcp_session_id, mcp_id)
        opts = Keyword.put_new(opts, :stream_fn, nil)
        {:ok, manager} = SessionManager.append_execution_context(state.session_manager, context)

        opts =
          Keyword.merge(opts,
            session_pid: self(),
            session_id: state.session_manager.header.id,
            parent_session: state.session_manager.header.id,
            session_scope: state.session_scope,
            task_child: state.task_child,
            budget_scope: Map.get(state.budget_limits, :scope),
            settings_manager: state.settings_manager,
            plan_gate: state.plan_gate
          )

        state = %{
          state
          | run_id: Keyword.get(opts, :run_id),
            session_key: Keyword.get(opts, :session_key),
            agent_id: Keyword.get(opts, :agent_id),
            execution_context: context,
            tool_policy: policy,
            approval_context: approval,
            session_manager: manager,
            mcp_session_id: mcp_id,
            acp_mcp_session_id: Keyword.get(opts, :acp_mcp_session_id),
            extra_tools: Keyword.get(opts, :extra_tools, []),
            explicit_system_prompt: Keyword.get(opts, :system_prompt),
            profile_instructions: Keyword.get(opts, :profile_instructions),
            project_memory_capture: Keyword.get(opts, :project_memory_capture, true),
            bot_folder_root: Keyword.get(opts, :bot_folder_root),
            config_cwd: Keyword.get(opts, :config_cwd, state.cwd),
            native_source_profile_id: Keyword.get(opts, :native_source_profile_id),
            tool_opts: opts,
            response_system_prompt: nil,
            terminal_event: nil
        }

        state = update_model(state, opts)
        state = update_thinking(state, opts)

        # Bind caller overrides once, before the loop takes ownership. Merging
        # them back at each provider dispatch would undo switch sanitization.
        stream_options =
          ModelResolver.build_stream_options(
            state.model,
            state.settings_manager,
            Keyword.get(opts, :stream_options),
            state.config_cwd
          )

        :ok = LemonAgent.Agent.set_stream_options(state.agent, stream_options)
        {:ok, Lifecycle.rebind_invocation(state)}
      end
    end
  end

  def open_mcp(opts, state \\ nil) do
    servers = Keyword.get(opts, :invocation_mcp_servers)
    previous = if state, do: Keyword.get(state.tool_opts, :invocation_mcp_servers)

    if state && servers == previous do
      {:ok, state.mcp_session_id}
    else
      result =
        if servers in [nil, []] do
          {:ok, Keyword.get(opts, :mcp_session_id)}
        else
          id = "profile-mcp-#{System.unique_integer([:positive, :monotonic])}"

          case LemonSkills.McpSession.open_http(id, Keyword.fetch!(opts, :cwd), servers, self()) do
            :ok -> {:ok, id}
            {:error, reason} -> {:error, {:profile_mcp, reason}}
          end
        end

      case result do
        {:ok, id} ->
          if state && state.mcp_session_id && state.mcp_session_id != id,
            do: LemonSkills.McpSession.close(state.mcp_session_id)

          {:ok, id}

        error ->
          error
      end
    end
  end

  def stream_fn(state), do: Keyword.get(state.tool_opts, :stream_fn) || (&LemonAi.stream/3)

  defp update_model(%CodingAgent.Session{} = state, opts) do
    requested = Keyword.get(opts, :model)
    explicit = Keyword.get(opts, :model_explicit, not is_nil(requested))

    if requested && explicit do
      model = ModelResolver.resolve_session_model(requested, state.settings_manager)
      :ok = LemonAgent.Agent.set_model(state.agent, model)

      if model.provider != state.model.provider or model.id != state.model.id,
        do: LemonAgent.ModelRuntime.SessionPins.clear(state.session_manager.header.id)

      manager =
        SessionManager.append_entry(
          state.session_manager,
          SessionManager.SessionEntry.model_change(model.provider, model.id, explicit: true)
        )

      %{state | model: model, session_manager: manager}
    else
      state
    end
  end

  defp update_thinking(%CodingAgent.Session{} = state, opts) do
    case Keyword.get(opts, :thinking_level) do
      nil ->
        state

      level ->
        level = LemonAgent.AutoThinking.normalize_level(level)
        :ok = LemonAgent.Agent.set_thinking_level(state.agent, level)

        manager =
          SessionManager.append_entry(
            state.session_manager,
            SessionManager.SessionEntry.thinking_level_change(level)
          )

        %{state | thinking_level: level, session_manager: manager}
    end
  end
end
