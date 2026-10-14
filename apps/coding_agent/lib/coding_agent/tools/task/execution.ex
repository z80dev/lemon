defmodule CodingAgent.Tools.Task.Execution do
  @moduledoc false

  alias CodingAgent.BudgetEnforcer
  alias CodingAgent.RunGraph
  alias CodingAgent.Session
  alias CodingAgent.TaskProgressBindingStore
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.{Async, Control, Followup, Runner, Worktree}

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
    case build_execution_context(tool_call_id, validated, cwd, opts) do
      {:error, message} ->
        {:error, message}

      {:ok, execution} ->
        child_signal = LemonAgent.AbortSignal.new()
        execution = put_in(execution.lifecycle_context[:signal], child_signal)
        execution = put_in(execution.lifecycle_context[:parent_signal], signal)
        execution = put_in(execution.lifecycle_context[:on_update], on_update)
        run_fun = build_run_fun(execution, child_signal, on_update, opts)

        case Async.run_async(
               execution.task_id,
               execution.run_id,
               run_fun,
               execution.followup_context,
               execution.lifecycle_context
             ) do
          :ok when execution.async? ->
            CodingAgent.Tools.Task.Result.build_async_result(execution.lifecycle_context)

          :ok ->
            await_sync_result(execution, signal)

          {:error, reason} ->
            {:error, async_launch_error_message(reason)}
        end
    end
  end

  defp build_execution_context(tool_call_id, validated, cwd, opts) do
    description = validated.description
    prompt = validated.prompt
    role_id = validated.role_id
    async? = validated.async
    effective_cwd = validated.cwd || cwd
    parent_session_key = validated.session_key || Keyword.get(opts, :session_key)
    parent_agent_id = validated.agent_id || Keyword.get(opts, :agent_id)
    parent_run_id = Keyword.get(opts, :parent_run_id) || Keyword.get(opts, :run_id)
    parent_session_id = Keyword.get(opts, :session_id) || Keyword.get(opts, :parent_session)
    root_action_id = Keyword.get(opts, :root_action_id) || tool_call_id
    surface = Keyword.get(opts, :surface) || default_surface(root_action_id)

    run_id =
      RunGraph.new_run(%{
        type: :task,
        description: description,
        parent: parent_run_id,
        parent_session_id: parent_session_id,
        session_key: parent_session_key
      })

    child_scope_id = run_id

    task_id =
      TaskStore.new_task(%{
        description: description,
        name: validated[:name],
        prompt: prompt,
        run_id: run_id,
        parent_run_id: parent_run_id,
        parent_session_id: parent_session_id,
        session_key: parent_session_key,
        agent_id: parent_agent_id,
        owner: Control.owner(opts),
        orchestration_worker: Keyword.get(opts, :orchestration_worker, false),
        role: role_id,
        queue_mode: validated.queue_mode,
        meta: validated.meta
      })

    lifecycle_context = %{
      task_id: task_id,
      run_id: run_id,
      parent_run_id: parent_run_id,
      parent_session_id: parent_session_id,
      session_key: parent_session_key,
      agent_id: parent_agent_id,
      root_action_id: root_action_id,
      surface: surface,
      description: description,
      name: validated[:name],
      role: role_id,
      queue_mode: validated.resolved_queue_mode,
      meta: validated.meta,
      parent_session_pid: Keyword.get(opts, :session_pid),
      task_owner_pid: Keyword.get(opts, :task_owner_pid),
      orchestration_worker: Keyword.get(opts, :orchestration_worker, false),
      direct_progress: Keyword.get(opts, :session_module, Session) == Session,
      task_supervisor: Keyword.get(opts, :task_supervisor, CodingAgent.TaskSupervisor)
    }

    if run_id do
      BudgetEnforcer.on_run_start(run_id, opts)
    end

    followup_context = %{
      auto_followup: validated.async and validated.auto_followup,
      description: description,
      cwd: cwd,
      parent_session_key: parent_session_key,
      parent_agent_id: parent_agent_id,
      queue_mode: validated.resolved_queue_mode,
      meta: validated.meta,
      role: role_id,
      model: validated.model,
      session_pid: Keyword.get(opts, :session_pid),
      session_module: Keyword.get(opts, :session_module, Session),
      run_orchestrator: Keyword.get(opts, :run_orchestrator, Followup.default_run_orchestrator())
    }

    execution = %{
      description: description,
      prompt: prompt,
      role_id: role_id,
      async?: async?,
      effective_cwd: effective_cwd,
      run_id: run_id,
      task_id: task_id,
      child_scope_id: child_scope_id,
      lifecycle_context: lifecycle_context,
      followup_context: followup_context,
      validated: validated
    }

    case reserve_parent_budget(run_id, parent_run_id, opts) do
      :ok ->
        if run_id && parent_run_id do
          RunGraph.add_child(parent_run_id, run_id)
        end

        maybe_create_progress_binding(task_id, run_id, lifecycle_context)
        {:ok, execution}

      {:error, _kind, _details} = reason ->
        if task_id, do: TaskStore.fail(task_id, reason)
        RunGraph.fail(run_id, reason)
        {:error, budget_reservation_error(reason)}

      {:error, _kind} = reason ->
        if task_id, do: TaskStore.fail(task_id, reason)
        RunGraph.fail(run_id, reason)
        {:error, budget_reservation_error(reason)}
    end
  end

  defp reserve_parent_budget(run_id, parent_run_id, opts)
       when is_binary(run_id) and is_binary(parent_run_id) do
    BudgetEnforcer.on_subagent_spawn(parent_run_id, run_id, opts)
  end

  defp reserve_parent_budget(_run_id, _parent_run_id, _opts), do: :ok

  defp budget_reservation_error({:error, :budget_exceeded, details}) when is_map(details) do
    {_action, message} = BudgetEnforcer.handle_budget_exceeded("unknown", details)
    message
  end

  defp budget_reservation_error(reason),
    do: "Unable to reserve parent task budget: #{inspect(reason)}"

  defp build_run_fun(execution, signal, on_update, opts) do
    fn ->
      on_update_safe =
        Async.wrap_on_update(execution.task_id, execution.lifecycle_context, on_update)

      run_override = Keyword.get(opts, :run_override)

      result =
        cond do
          is_function(run_override, 3) ->
            run_override.(
              on_update_safe,
              signal,
              Map.put(execution.lifecycle_context, :prompt, execution.prompt)
            )

          is_function(run_override, 2) ->
            run_override.(on_update_safe, signal)

          true ->
            with {:ok, workspace} <- prepare_workspace(execution) do
              CodingAgent.TaskStoreServer.update_record(execution.task_id, fn record ->
                Map.put(record, :workspace, workspace)
              end)

              if workspace[:worktree_path] do
                on_update_safe.(%LemonAgent.Types.AgentToolResult{
                  content: [
                    %LemonAi.Types.TextContent{
                      text: "Working in isolated branch #{workspace.branch}"
                    }
                  ],
                  details: Map.put(workspace, :status, "running")
                })
              end

              result =
                Runner.start_session_with_prompt(
                  CodingAgent.Tools.Task.Params.build_session_opts(
                    workspace.cwd,
                    build_child_session_opts(opts, execution),
                    execution.validated
                  ),
                  execution.prompt,
                  execution.description,
                  signal,
                  on_update_safe,
                  execution.role_id,
                  [task_id: execution.task_id] ++
                    output_validator_opts(execution.validated) ++
                    runner_timeout_opts(execution.effective_cwd, opts)
                )

              case result do
                %LemonAgent.Types.AgentToolResult{} = result ->
                  %{
                    result
                    | details:
                        Map.merge(
                          result.details,
                          workspace
                          |> Map.merge(
                            CodingAgent.Tools.Task.Result.lineage_details(
                              execution.lifecycle_context
                            )
                          )
                          |> Map.merge(%{
                            task_id: execution.task_id,
                            run_id: execution.run_id
                          })
                        )
                  }

                error ->
                  error
              end
            end
        end

      validate_output(result, execution.validated)
    end
  end

  defp runner_timeout_opts(cwd, opts) do
    runner_opts = Keyword.take(opts, [:task_session_timeout_ms, :task_session_poll_ms])

    if Keyword.has_key?(runner_opts, :task_session_timeout_ms) do
      runner_opts
    else
      case CodingAgent.Tools.Task.Params.task_settings(cwd, opts).max_runtime_ms do
        ms when ms > 0 -> Keyword.put(runner_opts, :task_session_timeout_ms, ms)
        _ -> runner_opts
      end
    end
  end

  # Lets the runner re-prompt the same child session before it is stopped.
  defp output_validator_opts(%{output_schema: schema}) when not is_nil(schema) do
    [
      validate_output: fn text ->
        case CodingAgent.Tools.Task.StructuredOutput.decode(text, schema) do
          {:ok, _value} -> :ok
          {:error, _reason} = error -> error
        end
      end
    ]
  end

  defp output_validator_opts(_validated), do: []

  defp validate_output(%LemonAgent.Types.AgentToolResult{} = result, validated) do
    case validated[:output_schema] do
      nil ->
        result

      schema ->
        text = CodingAgent.Tools.Task.Result.visible_output_text(result)
        decoded = CodingAgent.Tools.Task.StructuredOutput.decode(text, schema)

        case {decoded, validated[:schema_mode]} do
          {{:ok, output}, _mode} ->
            %{result | details: Map.put(result.details || %{}, :structured_output, output)}

          {{:error, reason}, "permissive"} ->
            %{result | details: Map.put(result.details || %{}, :structured_output_error, reason)}

          {{:error, _reason} = error, _mode} ->
            error
        end
    end
  end

  defp validate_output(error, _validated), do: error

  defp prepare_workspace(%{validated: %{worktree: true}} = execution) do
    Worktree.prepare(execution.effective_cwd, execution.task_id)
  end

  defp prepare_workspace(execution), do: {:ok, %{cwd: execution.effective_cwd}}

  defp await_sync_result(execution, signal) do
    case CodingAgent.Tools.Task.Result.do_join(%{"task_ids" => [execution.task_id]}, signal) do
      %LemonAgent.Types.AgentToolResult{details: %{status: "needs_parent_answer"}} = result ->
        result

      %LemonAgent.Types.AgentToolResult{} ->
        case TaskStore.get(execution.task_id) do
          {:ok, %{status: :completed, result: result}, _} -> result
          {:ok, %{error: reason}, _} -> {:error, reason}
          _ -> {:error, "Task did not complete"}
        end

      error ->
        error
    end
  end

  defp build_child_session_opts(opts, execution) do
    opts
    |> Keyword.put(:child_run_id, execution.run_id)
    |> Keyword.put(:child_scope_id, execution.child_scope_id)
    |> Keyword.put(:task_id, execution.task_id)
    |> Keyword.put(:task_description, execution.description)
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

  defp async_launch_error_message(:task_supervisor_unavailable),
    do: "Background task supervisor is unavailable"

  defp async_launch_error_message(:task_capacity_reached),
    do: "Background task capacity is exhausted"

  defp async_launch_error_message(_reason), do: "Background task could not be started"
end
