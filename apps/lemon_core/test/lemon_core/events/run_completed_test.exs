defmodule LemonCore.Events.RunCompletedTest do
  use ExUnit.Case, async: true

  alias LemonCore.Events.{Completion, RunCompleted}

  describe "failure/2" do
    test "is a failed completion with an empty answer" do
      assert %RunCompleted{
               completed: %Completion{ok: false, error: :engine_lost, answer: "", meta: %{}},
               duration_ms: nil
             } = RunCompleted.failure(:engine_lost)
    end

    test "records what the publisher knows about the run" do
      payload =
        RunCompleted.failure(%{type: :run_start_failed, reason: :timeout},
          duration_ms: 0,
          engine: "lemon",
          run_id: "run_1",
          session_key: "agent:test:main",
          meta: %{synthetic: true, failure_stage: :run_start}
        )

      assert payload.duration_ms == 0

      assert %Completion{
               ok: false,
               engine: "lemon",
               run_id: "run_1",
               session_key: "agent:test:main",
               meta: %{synthetic: true, failure_stage: :run_start}
             } = payload.completed
    end
  end
end
