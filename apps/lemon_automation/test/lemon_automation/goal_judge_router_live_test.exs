defmodule LemonAutomation.GoalJudgeRouterLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias LemonAutomation.GoalLoop
  alias LemonCore.GoalStore

  test "provider-backed router judge completes a persisted goal" do
    case live_config() do
      {:skip, reason} ->
        IO.puts("[GoalJudgeRouterLiveTest] Skipping: #{reason}")
        assert true

      {:ok, model} ->
        session_key = "goal-live-judge-#{System.unique_integer([:positive])}"

        on_exit(fn -> GoalStore.clear(session_key) end)

        {:ok, _apps} = Application.ensure_all_started(:lemon_router)
        {:ok, _apps} = Application.ensure_all_started(:lemon_gateway)

        assert {:ok, _goal} =
                 GoalStore.set(
                   session_key,
                   "This verification goal is already complete. The judge should return done.",
                   agent_id: "default"
                 )

        assert {:ok, %{run_id: nil, goal: completed, verdict: verdict}} =
                 GoalLoop.run_once(session_key,
                   judge_runner: LemonAutomation.GoalJudge.RouterRunner,
                   judge_run_id: "run_live_model_judge_#{System.unique_integer([:positive])}",
                   judge_wait_timeout_ms: 120_000,
                   judge_model: model
                 )

        assert completed.status == "completed"
        assert verdict.action == :done
        assert verdict.source in ["judge", "judge:#{model}"]

        stored = GoalStore.get(session_key)
        assert stored.meta["goalLoop"]["lastVerdict"]["action"] == "done"
    end
  end

  defp live_config do
    cond do
      System.get_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS") not in [
        "1",
        "true",
        "TRUE",
        "yes",
        "YES"
      ] ->
        {:skip, "set LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 to run provider-backed judge proof"}

      blank?(System.get_env("LEMON_GOAL_JUDGE_MODEL")) ->
        {:skip, "set LEMON_GOAL_JUDGE_MODEL to the provider/model to use for judging"}

      true ->
        {:ok, String.trim(System.fetch_env!("LEMON_GOAL_JUDGE_MODEL"))}
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
