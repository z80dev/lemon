defmodule LemonAutomation.GoalContinuation do
  @moduledoc false

  alias LemonCore.GoalStore

  @spec continue_once(binary(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :paused | :completed | :budget_exhausted | term()}
  def continue_once(session_key, opts \\ []) when is_binary(session_key) do
    with {:ok, goal} <- active_goal(session_key),
         :ok <- budget_available?(goal, opts),
         run_id = Keyword.get(opts, :run_id, LemonCore.Id.run_id()),
         params = build_params(goal, run_id, opts),
         {:ok, submitted_run_id} <- submit(params, opts),
         {:ok, updated} <- GoalStore.record_continuation(session_key, submitted_run_id) do
      {:ok, %{run_id: submitted_run_id, goal: updated, params: params}}
    end
  end

  @doc false
  def build_params(goal, run_id, opts \\ []) do
    continuation_count = (goal.continuation_count || 0) + 1
    meta = Keyword.get(opts, :meta, %{})

    params = %{
      origin: :goal,
      session_key: goal.session_key,
      prompt: build_prompt(goal),
      agent_id: goal.agent_id || "default",
      queue_mode: Keyword.get(opts, :queue_mode, :followup),
      meta:
        %{
          goal_id: goal.id,
          goal_continuation: true,
          goal_continuation_count: continuation_count,
          goal_objective_bytes: byte_size(goal.objective || "")
        }
        |> Map.merge(meta),
      run_id: run_id
    }

    if Keyword.has_key?(opts, :model) do
      Map.put(params, :model, Keyword.get(opts, :model))
    else
      params
    end
  end

  defp active_goal(session_key) do
    case GoalStore.get(session_key) do
      %{} = goal when map_size(goal) == 0 -> {:error, :not_found}
      %{status: "paused"} -> {:error, :paused}
      %{status: "completed"} -> {:error, :completed}
      goal -> {:ok, goal}
    end
  end

  defp budget_available?(goal, opts) do
    max = parse_positive_integer(Keyword.get(opts, :max_continuations) || budget_max(goal.budget))

    cond do
      is_nil(max) -> :ok
      (goal.continuation_count || 0) < max -> :ok
      true -> {:error, :budget_exhausted}
    end
  end

  defp budget_max(%{} = budget) do
    budget[:max_continuations] || budget["max_continuations"]
  end

  defp budget_max(_), do: nil

  defp parse_positive_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_positive_integer(_), do: nil

  defp submit(params, opts) do
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)

    try do
      case router_mod.submit(params) do
        {:ok, run_id} when is_binary(run_id) -> {:ok, run_id}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_submit_result, other}}
      end
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp build_prompt(goal) do
    """
    You are continuing an active Lemon goal for this session.

    Goal:
    #{goal.objective}

    Continue the work from the current session state. Use the existing project context and make concrete progress. Stop if the goal is complete, blocked, paused, or needs explicit user input.
    """
  end
end
