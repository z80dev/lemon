defmodule CodingAgent.Tools.Task.Telemetry do
  @moduledoc false

  alias CodingAgent.Tools.Task.Params
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult

  @actions ~w(run swarm poll join wait get message steer cancel)
  @event [:coding_agent, :task, :action]

  def observe(params, opts, signal, fun) do
    labels = labels(params)
    metadata = context(opts)

    try do
      result = fun.()
      outcome = if AbortSignal.aborted?(signal), do: :aborted, else: outcome(result)
      emit(labels, metadata, outcome)
      result
    catch
      kind, reason ->
        emit(labels, metadata, :exception)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def speculative_launch(opts, fun) do
    metadata = context(opts)

    try do
      result = fun.()
      emit([{"speculative_launch", :launch}], metadata, outcome(result))
      result
    catch
      kind, reason ->
        emit([{"speculative_launch", :launch}], metadata, :exception)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp labels(params) do
    action = Params.normalize_action(params["action"])
    action = if action in @actions, do: action, else: "unknown"
    labels = [{action, :dispatch}]

    labels =
      if action == "run" and Map.has_key?(params, "tasks"),
        do: labels ++ [{"batch", :feature}],
        else: labels

    steps? =
      Map.has_key?(params, "steps") or
        (is_list(params["tasks"]) and
           Enum.any?(params["tasks"], &(is_map(&1) and Map.has_key?(&1, "steps"))))

    if action in ["run", "swarm"] and steps?,
      do: labels ++ [{"steps", :feature}],
      else: labels
  end

  defp context(opts) do
    %{
      run_id: Keyword.get(opts, :parent_run_id) || Keyword.get(opts, :run_id),
      model: model_label(Keyword.get(opts, :model)),
      depth: depth(opts)
    }
  end

  defp model_label(%{provider: provider, id: id}) when is_binary(id) and is_atom(provider),
    do: Atom.to_string(provider) <> "/" <> id

  defp model_label(%{provider: provider, id: id}) when is_binary(id) and is_binary(provider),
    do: provider <> "/" <> id

  defp model_label(model) when is_binary(model), do: model
  defp model_label(_), do: nil

  defp depth(opts) do
    case Keyword.get(opts, :task_depth) do
      depth when is_integer(depth) and depth >= 0 -> depth
      _ -> if Keyword.get(opts, :session_scope) == :subagent, do: nil, else: 0
    end
  end

  defp outcome({:error, _}), do: :error
  defp outcome(%AgentToolResult{is_error: true}), do: :error
  defp outcome(_), do: :ok

  defp emit(labels, metadata, outcome) do
    Enum.each(labels, fn {action, kind} ->
      :telemetry.execute(
        @event,
        %{count: 1},
        Map.merge(metadata, %{action: action, kind: kind, outcome: outcome})
      )
    end)
  end
end
