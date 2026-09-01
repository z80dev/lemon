defmodule LemonRouter.SyntheticCompletionTest do
  use ExUnit.Case, async: true

  alias LemonCore.Bus
  alias LemonCore.Events.{Completion, RunCompleted}
  alias LemonRouter.SyntheticCompletion

  test "ends the run on its topic with the public shape, marked synthetic" do
    run_id = "run_synthetic_#{System.unique_integer([:positive])}"
    Bus.subscribe(Bus.run_topic(run_id))

    :ok = SyntheticCompletion.broadcast(run_id, "agent:test:main", :gateway_run_missing)

    assert_receive %LemonCore.Event{type: :run_completed, payload: payload, meta: meta}

    assert %RunCompleted{
             completed: %Completion{ok: false, error: :gateway_run_missing, answer: ""},
             duration_ms: nil
           } = payload

    assert meta.run_id == run_id
    assert meta.session_key == "agent:test:main"
    assert meta.synthetic == true
    refute Map.has_key?(meta, :failure_stage)
  end

  test "names the failure stage when the publisher knows it" do
    run_id = "run_synthetic_#{System.unique_integer([:positive])}"
    Bus.subscribe(Bus.run_topic(run_id))

    :ok =
      SyntheticCompletion.broadcast(run_id, "agent:test:main", :runtime_unavailable,
        duration_ms: 42,
        failure_stage: :runtime_submission,
        engine: "lemon"
      )

    assert_receive %LemonCore.Event{type: :run_completed, payload: payload, meta: meta}
    assert payload.duration_ms == 42
    assert payload.completed.engine == "lemon"
    assert meta.failure_stage == :runtime_submission
  end
end
