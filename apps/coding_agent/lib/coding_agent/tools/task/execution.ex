defmodule CodingAgent.Tools.Task.Execution do
  @moduledoc false

  alias CodingAgent.BudgetEnforcer
  alias CodingAgent.RunGraph
  alias CodingAgent.Session
  alias CodingAgent.TaskProgressBindingStore
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.{Async, Followup, Runner}

  @spec run(
          String.t() | nil,
          map(),
          reference() | nil,
          (term() -> :ok) | nil,
          String.t(),
          keyword()
        ) ::
          term()
  def run(tool_call_id, validated, signal, on_update, cwd, opts) do
    execution = build_execution_context(tool_call_id, validated, cwd, opts)
    run_fun = build_run_fun(execution, signal, on_update, opts)

    if execution.async? do
      :ok =
        Async.run_async(
          execution.task_id,
          execution.run_id,
          run_fun,
          execution.followup_context,
          execution.lifecycle_context
        )

      CodingAgent.Tools.Task.Result.build_async_result(
        execution.task_id,
        execution.description,
        execution.run_id
      )
    else
      Async.run_sync(run_fun)
    end
  end

  defp build_execution_context(tool_call_id, validated, cwd, opts) do
    description = validated.description
    prompt = validated.prompt
    role_id = validated.role_id
    engine = validated.engine
    async? = validated.async
    effective_cwd = validated.cwd || cwd
    parent_session_key = validated.session_key || Keyword.get(opts, :session_key)
    parent_agent_id = validated.agent_id || Keyword.get(opts, :agent_id)
    coordinator = Keyword.get(opts, :coordinator)
    parent_run_id = Keyword.get(opts, :parent_run_id)
    root_action_id = Keyword.get(opts, :root_action_id) || tool_call_id
    surface = Keyword.get(opts, :surface) || default_surface(root_action_id)

    run_id =
      if async? do
        RunGraph.new_run(%{type: :task, description: description, parent: parent_run_id})
      end

    child_scope_id = run_id || "child_scope:" <> generate_child_scope_id()

    task_id =
      if async? do
        TaskStore.new_task(%{
          description: description,
          prompt: prompt,
          run_id: run_id,
          parent_run_id: parent_run_id,
          session_key: parent_session_key,
          agent_id: parent_agent_id,
          engine: validated.engine || "internal",
          role: role_id,
          queue_mode: validated.queue_mode,
          meta: validated.meta
        })
      end

    lifecycle_context = %{
      task_id: task_id,
      run_id: run_id,
      parent_run_id: parent_run_id,
      session_key: parent_session_key,
      agent_id: parent_agent_id,
      root_action_id: root_action_id,
      surface: surface,
      description: description,
      engine: validated.engine || "internal",
      role: role_id,
      queue_mode: validated.queue_mode,
      meta: validated.meta
    }

    maybe_create_progress_binding(task_id, run_id, lifecycle_context)

    if run_id do
      BudgetEnforcer.on_run_start(run_id, opts)
    end

    if run_id && parent_run_id do
      RunGraph.add_child(parent_run_id, run_id)
      BudgetEnforcer.on_subagent_spawn(parent_run_id, run_id, opts)
    end

    followup_context = %{
      auto_followup: validated.auto_followup,
      description: description,
      cwd: cwd,
      parent_session_key: parent_session_key,
      parent_agent_id: parent_agent_id,
      queue_mode: validated.queue_mode,
      meta: validated.meta,
      engine: validated.engine || "internal",
      role: role_id,
      model: validated.model,
      session_pid: Keyword.get(opts, :session_pid),
      session_module: Keyword.get(opts, :session_module, Session),
      run_orchestrator: Keyword.get(opts, :run_orchestrator, Followup.default_run_orchestrator())
    }

    %{
      description: description,
      prompt: prompt,
      role_id: role_id,
      engine: engine,
      async?: async?,
      effective_cwd: effective_cwd,
      coordinator: coordinator,
      run_id: run_id,
      task_id: task_id,
      child_scope_id: child_scope_id,
      lifecycle_context: lifecycle_context,
      followup_context: followup_context,
      validated: validated
    }
  end

  defp build_run_fun(execution, signal, on_update, opts) do
    fn ->
      on_update_safe = Async.wrap_on_update(execution.task_id, execution.lifecycle_context, on_update)
      run_override = Keyword.get(opts, :run_override)

      cond do
        is_function(run_override, 2) ->
          run_override.(on_update_safe, signal)

        execution.engine in ["codex", "claude", "kimi", "opencode", "pi"] ->
          Runner.execute_via_cli_engine(
            execution.engine,
            execution.prompt,
            execution.effective_cwd,
            execution.description,
            execution.role_id,
            execution.validated.model,
            on_update_safe,
            signal
          )

        coordinator_alive?(execution.coordinator) and execution.role_id ->
          Runner.execute_via_coordinator(
            execution.coordinator,
            execution.prompt,
            execution.description,
            execution.role_id
          )

        true ->
          case Runner.maybe_apply_role_prompt(
                 execution.prompt,
                 execution.role_id,
                 execution.effective_cwd
               ) do
            {:error, _} = error ->
              error

            resolved_prompt ->
              Runner.start_session_with_prompt(
                CodingAgent.Tools.Task.Params.build_session_opts(
                  execution.effective_cwd,
                  build_child_session_opts(opts, execution),
                  execution.validated
                ),
                resolved_prompt,
                execution.description,
                signal,
                on_update_safe,
                execution.role_id,
                execution.engine || "internal"
              )
          end
      end
    end
  end

  defp coordinator_alive?(coordinator) when is_pid(coordinator), do: Process.alive?(coordinator)

  defp coordinator_alive?(coordinator) when is_atom(coordinator) do
    case Process.whereis(coordinator) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp coordinator_alive?({:via, _, _} = name) do
    case GenServer.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp coordinator_alive?(_), do: false

  defp build_child_session_opts(opts, execution) do
    opts
    |> Keyword.put(:child_run_id, execution.run_id)
    |> Keyword.put(:child_scope_id, execution.child_scope_id)
    |> Keyword.put(:task_id, execution.task_id)
    |> Keyword.put(:task_description, execution.description)
  end

  defp generate_child_scope_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp maybe_create_progress_binding(task_id, run_id, lifecycle_context) do
    with true <- is_binary(task_id) and task_id != "",
         true <- is_binary(run_id) and run_id != "",
         true <-
           is_binary(lifecycle_context[:parent_run_id]) and
             lifecycle_context[:parent_run_id] != "",
         true <-
           is_binary(lifecycle_context[:session_key]) and lifecycle_context[:session_key] != "",
         true <- is_binary(lifecycle_context[:agent_id]) and lifecycle_context[:agent_id] != "",
         true <-
           is_binary(lifecycle_context[:root_action_id]) and
             lifecycle_context[:root_action_id] != "",
         surface when not is_nil(surface) <- lifecycle_context[:surface] do
      TaskProgressBindingStore.new_binding(%{
        task_id: task_id,
        child_run_id: run_id,
        parent_run_id: lifecycle_context[:parent_run_id],
        parent_session_key: lifecycle_context[:session_key],
        parent_agent_id: lifecycle_context[:agent_id],
        root_action_id: lifecycle_context[:root_action_id],
        surface: surface
      })
    else
      _ -> :ok
    end
  end

  defp default_surface(root_action_id) when is_binary(root_action_id) and root_action_id != "",
    do: {:status_task, root_action_id}

  defp default_surface(_), do: nil
end
