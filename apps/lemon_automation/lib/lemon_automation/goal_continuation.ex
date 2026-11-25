defmodule LemonAutomation.GoalContinuation do
  @moduledoc """
  Builds and submits one durable-goal continuation.

  One-shot callers submit asynchronously. Autonomous goal loops pass
  `await_completion: true`; that path uses
  `LemonAutomation.RunCompletionWaiter.submit_and_wait/2`, so the completion
  subscription exists before router submission and even synchronous terminal
  events are observed.

  The continuation runs only under the goal's recorded
  `LemonAutomation.GoalAuthority`: its tool policy is confined to the
  recorded policy and its target is re-resolved inside the recorded root.
  A goal without valid authority, or whose target changed, is not submitted.
  """

  alias LemonAutomation.RunCompletionWaiter
  alias LemonAutomation.{GoalAuthority, GoalStore}

  @spec continue_once(binary(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :paused | :completed | :budget_exhausted | term()}
  def continue_once(session_key, opts \\ []) when is_binary(session_key) do
    with {:ok, goal} <- active_goal(session_key),
         :ok <- budget_available?(goal, opts),
         run_id = Keyword.get(opts, :run_id, LemonCore.Id.run_id()),
         {:ok, params} <- build_params(goal, run_id, opts),
         :ok <- LemonAutomation.RunNotifications.bind_goal(goal, params),
         {:ok, submitted_run_id, completion} <- submit(params, opts),
         {:ok, updated} <-
           GoalStore.record_continuation(session_key, submitted_run_id, completion: completion) do
      {:ok, %{run_id: submitted_run_id, goal: updated, params: params, completion: completion}}
    end
  end

  @doc false
  def build_params(goal, run_id, opts \\ []) do
    continuation_count = (goal.continuation_count || 0) + 1
    meta = Keyword.get(opts, :meta, %{})

    with {:ok, scope} <- GoalAuthority.run_scope(goal, %{blocked_tools: ["goal"]}) do
      params = %{
        origin: :goal,
        session_key: goal.session_key,
        prompt: build_prompt(goal),
        agent_id: goal.agent_id || "default",
        queue_mode: Keyword.get(opts, :queue_mode, :followup),
        cwd: scope.cwd,
        tool_policy: scope.tool_policy,
        # The checked directory identity is applied last: caller meta never
        # replaces it. The session runner re-verifies it at start and before
        # every tool call.
        meta:
          %{
            goal_id: goal.id,
            goal_continuation: true,
            goal_continuation_count: continuation_count,
            goal_objective_bytes: byte_size(goal.objective || "")
          }
          |> Map.merge(meta)
          |> Map.put(:cwd_identity, scope.cwd_identity),
        run_id: run_id
      }

      if Keyword.has_key?(opts, :model) do
        {:ok, Map.put(params, :model, Keyword.get(opts, :model))}
      else
        {:ok, params}
      end
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
    if Keyword.get(opts, :await_completion, false) do
      submit_and_wait(params, opts)
    else
      submit_only(params, opts)
    end
  end

  defp submit_and_wait(params, opts) do
    result =
      RunCompletionWaiter.submit_and_wait(params,
        router_mod: Keyword.get(opts, :router_mod, LemonRouter),
        waiter_mod: Keyword.get(opts, :waiter_mod, RunCompletionWaiter),
        bus_mod: Keyword.get(opts, :bus_mod, LemonCore.Bus),
        timeout_ms: Keyword.get(opts, :wait_timeout_ms, 300_000),
        wait_opts: Keyword.get(opts, :wait_opts, []),
        on_submitting: Keyword.get(opts, :on_submitting),
        on_submitted: fn run_id ->
          GoalStore.record_continuation(params.session_key, run_id)

          if callback = Keyword.get(opts, :on_submitted), do: callback.(run_id)
        end,
        on_terminal: Keyword.get(opts, :on_terminal)
      )

    case result do
      {:ok, run_id, output} ->
        {:ok, run_id, {:ok, output}}

      {:error, {:run_failed, run_id, reason}} ->
        {:ok, run_id, {:error, reason}}

      {:error, {:timeout, run_id}} ->
        {:error, {:completion_outcome_unknown, run_id}}

      {:error, {:unexpected_run_id, run_id, _other_id}} ->
        {:error, {:submission_outcome_unknown, run_id}}

      {:error, {:submit_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp submit_only(params, opts) do
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)

    try do
      case router_mod.submit(params) do
        {:ok, run_id} when is_binary(run_id) and run_id != "" and run_id == params.run_id ->
          {:ok, run_id, :not_awaited}

        {:ok, _other_id} ->
          {:error, {:submission_outcome_unknown, params.run_id}}

        {:error, :outcome_unknown} ->
          {:error, {:submission_outcome_unknown, params.run_id}}

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, {:submission_outcome_unknown, params.run_id}}
      end
    rescue
      _error -> {:error, {:submission_outcome_unknown, params.run_id}}
    catch
      :exit, _reason -> {:error, {:submission_outcome_unknown, params.run_id}}
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
