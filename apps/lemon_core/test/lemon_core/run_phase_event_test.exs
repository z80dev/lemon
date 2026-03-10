defmodule LemonCore.RunPhaseEventTest do
  use ExUnit.Case, async: true

  alias LemonCore.RunPhaseEvent

  test "build/1 constructs a canonical phase change payload" do
    event =
      RunPhaseEvent.build(
        run_id: "run-123",
        session_key: "session-123",
        phase: :streaming,
        previous_phase: :starting_engine,
        source: :gateway
      )

    assert event.type == :run_phase_changed
    assert event.run_id == "run-123"
    assert event.session_key == "session-123"
    assert event.phase == :streaming
    assert event.previous_phase == :starting_engine
    assert event.source == :gateway
    assert %DateTime{} = event.at
  end

  test "build/1 rejects invalid phases" do
    assert_raise ArgumentError, ~r/invalid phase/, fn ->
      RunPhaseEvent.build(run_id: "run-123", phase: :not_a_phase, source: :gateway)
    end

    assert_raise ArgumentError, ~r/invalid previous_phase/, fn ->
      RunPhaseEvent.build(
        run_id: "run-123",
        phase: :accepted,
        previous_phase: :not_a_phase,
        source: :gateway
      )
    end
  end
end
