defmodule CodingAgent.Tools.Task.Swarm do
  @moduledoc """
  Runs a validated task DAG through the native task lifecycle. The coordinator
  owns no model slot; launched children (including queued children) consume the
  swarm's concurrency allowance until their TaskStore records are terminal.
  """

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.{Control, Execution, Params, Result}
  alias CodingAgent.Tools.Task.Swarm.Graph
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @poll_ms 20

  def execute(tool_call_id, params, signal, on_update, cwd, opts) do
    # The coordinator root is not a persona launch, so a spawns allowlist applies to nodes only.
    root_opts = Keyword.delete(opts, :task_allowed_agents)

    with {:ok, graph} <- Graph.prepare(params, cwd, opts),
         {:ok, root} <- Params.validate_run_params(root_params(params, graph), cwd, root_opts),
         :ok <- Params.check_budget_and_policy(root, opts),
         :ok <- check_nodes(graph.nodes, opts) do
      root_opts =
        opts
        |> Keyword.put(:orchestration_worker, true)
        |> Keyword.put(:run_override, fn update, root_signal, context ->
          run(graph, root_signal, update, cwd, opts, context)
        end)

      Execution.run(tool_call_id, root, signal, on_update, cwd, root_opts)
    end
  end

  defp root_params(params, graph) do
    names = Enum.map_join(graph.nodes, ", ", & &1.name)

    params
    |> Map.drop([
      "tasks",
      "concurrency",
      "output_schema",
      "schema_mode",
      "agent",
      "worktree",
      "tool_policy",
      "context"
    ])
    |> Map.put("prompt", "Coordinate the native task dependency graph: " <> names)
    |> Map.put_new("description", "Swarm: " <> names)
    |> Map.put_new("async", true)
  end

  defp check_nodes(nodes, opts) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case Params.check_budget_and_policy(node.validated, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp run(graph, signal, on_update, cwd, original_opts, context) do
    child_opts =
      original_opts
      |> Keyword.delete(:orchestration_worker)
      |> Keyword.put(:task_owner_pid, self())
      |> Keyword.put(:parent_run_id, context.run_id)
      |> Keyword.put(:root_action_id, context.root_action_id)
      |> Keyword.put(:surface, context.surface)

    state = %{pending: graph.nodes, active: %{}, completed: %{}}

    try do
      emit_progress(graph.nodes, state, on_update)
      completed = schedule(graph, state, signal, on_update, cwd, child_opts)
      Graph.report(graph.nodes, completed)
    after
      # Covers normal cancellation and unexpected scheduler failure. Control's
      # independent owner monitor also covers an untrappable coordinator death.
      Control.cancel_owned()
    end
  end

  defp schedule(graph, previous, signal, update, cwd, opts) do
    state = previous |> collect() |> block_dependents()

    state =
      if AbortSignal.aborted?(signal) do
        Control.cancel_owned()
        cancel_remaining(state)
      else
        launch_ready(state, graph.concurrency, signal, update, cwd, opts)
      end

    if state != previous, do: emit_progress(graph.nodes, state, update)

    if state.pending == [] and map_size(state.active) == 0 do
      state.completed
    else
      Process.sleep(@poll_ms)
      schedule(graph, state, signal, update, cwd, opts)
    end
  end

  defp collect(state) do
    Enum.reduce(state.active, state, fn {name, identity}, acc ->
      case TaskStore.get_status(identity.task_id) do
        {:ok, status} when status in [:queued, :running] ->
          put_in(acc.active[name].status, Atom.to_string(status))

        _ ->
          collect_terminal(acc, name, identity)
      end
    end)
  end

  defp collect_terminal(state, name, identity) do
    case TaskStore.get_record(identity.task_id) do
      {:ok, record} ->
        if record[:status] not in [:completed, :error, :cancelled],
          do: Control.cancel_owned(identity.task_id)

        complete(state, name, Map.merge(identity, terminal_row(record)))

      {:error, :not_found} ->
        Control.cancel_owned(identity.task_id)

        complete(
          state,
          name,
          Map.merge(identity, %{status: "error", error: "Task record missing"})
        )
    end
  end

  defp complete(state, name, row) do
    %{
      state
      | active: Map.delete(state.active, name),
        completed: Map.put(state.completed, name, row)
    }
  end

  defp terminal_row(%{status: :completed, result: result}) do
    details = if match?(%AgentToolResult{}, result), do: result.details || %{}, else: %{}
    failed? = match?(%AgentToolResult{is_error: true}, result)

    row = %{
      status: if(failed?, do: "error", else: "completed"),
      output: visible_output(result)
    }

    row = if failed?, do: Map.put(row, :error, "Task returned an error result"), else: row

    if Map.has_key?(details, :structured_output),
      do: Map.put(row, :structured_output, details.structured_output),
      else: row
  end

  defp terminal_row(record) do
    status = if record[:status] == :cancelled, do: "cancelled", else: "error"
    %{status: status, error: visible_error(record[:error] || "Task ended without a result")}
  end

  defp visible_output(%AgentToolResult{} = result), do: Result.visible_output_text(result)
  defp visible_output(result) when is_binary(result), do: Result.visible_output_text(result)
  defp visible_output(%{answer: answer}) when is_binary(answer), do: answer
  defp visible_output(%{"answer" => answer}) when is_binary(answer), do: answer
  defp visible_output(_), do: ""

  defp visible_error(error) when is_binary(error), do: error
  defp visible_error(error) when is_atom(error), do: Atom.to_string(error)
  defp visible_error(_), do: "Native task execution failed"

  defp block_dependents(state) do
    {blocked, pending} =
      Enum.split_with(state.pending, fn node ->
        Enum.any?(node.depends_on, fn name ->
          case state.completed[name] do
            nil -> false
            %{status: "completed"} -> false
            _ -> true
          end
        end)
      end)

    if blocked == [] do
      state
    else
      completed =
        Enum.reduce(blocked, state.completed, fn node, acc ->
          Map.put(acc, node.name, %{
            status: "blocked",
            error: "A dependency did not complete successfully"
          })
        end)

      block_dependents(%{state | pending: pending, completed: completed})
    end
  end

  defp launch_ready(state, cap, signal, update, cwd, opts) do
    Enum.reduce(state.pending, state, fn node, acc ->
      ready? = Enum.all?(node.depends_on, &match?(%{status: "completed"}, acc.completed[&1]))

      if ready? and map_size(acc.active) < cap and not AbortSignal.aborted?(signal) and
           budget_slot_available?(opts) do
        validated =
          node
          |> Graph.with_dependencies(acc.completed)
          |> Map.merge(%{async: true, auto_followup: false})

        outcome =
          with :ok <- Params.check_budget_and_policy(validated, opts) do
            Execution.run(nil, validated, signal, update, cwd, opts)
          end

        acc = %{acc | pending: Enum.reject(acc.pending, &(&1.name == node.name))}

        case outcome do
          %AgentToolResult{details: %{task_id: task_id, run_id: run_id}}
          when is_binary(task_id) and is_binary(run_id) ->
            put_in(acc.active[node.name], %{
              task_id: task_id,
              run_id: run_id,
              status: "queued"
            })

          {:error, reason} ->
            put_in(acc.completed[node.name], %{status: "error", error: visible_error(reason)})

          _ ->
            put_in(acc.completed[node.name], %{
              status: "error",
              error: "Native task admission returned no identity"
            })
        end
      else
        acc
      end
    end)
  end

  defp budget_slot_available?(opts) do
    case CodingAgent.BudgetTracker.get_budget(Keyword.fetch!(opts, :parent_run_id)) do
      %{max_children: limit, active_children: active} when is_integer(limit) and limit > 0 ->
        active < limit

      _ ->
        true
    end
  end

  defp cancel_remaining(state) do
    completed =
      Enum.reduce(state.active, state.completed, fn {name, identity}, acc ->
        row = Map.merge(identity, %{status: "cancelled", error: "Swarm aborted"})

        Map.put(acc, name, row)
      end)

    state = block_dependents(%{state | active: %{}, completed: completed})

    completed =
      Enum.reduce(state.pending, state.completed, fn node, acc ->
        Map.put(acc, node.name, %{status: "cancelled", error: "Swarm aborted before launch"})
      end)

    %{state | pending: [], completed: completed}
  end

  defp emit_progress(_nodes, _state, nil), do: :ok

  defp emit_progress(nodes, state, update) do
    rows =
      Enum.map(nodes, fn node ->
        row = state.completed[node.name] || state.active[node.name] || %{status: "pending"}

        row
        |> Map.take([:status, :task_id, :run_id])
        |> Map.merge(%{name: node.name, depends_on: node.depends_on})
      end)

    update.(%AgentToolResult{
      content: [
        %TextContent{
          text:
            "Swarm: #{map_size(state.completed)}/#{length(nodes)} terminal, " <>
              "#{map_size(state.active)} active, #{length(state.pending)} pending"
        }
      ],
      details: %{
        status: "running",
        swarm: %{tasks: rows, counts: Enum.frequencies_by(rows, & &1.status)}
      }
    })
  end
end
