defmodule LemonCore.RunPhaseTest do
  use ExUnit.Case, async: true

  alias LemonCore.RunPhase

  test "all/0 returns the expected list in order" do
    assert RunPhase.all() == [
             :accepted,
             :queued_in_session,
             :waiting_for_slot,
             :dispatched_to_gateway,
             :starting_engine,
             :streaming,
             :finalizing,
             :completed,
             :failed,
             :aborted
           ]
  end

  test "terminal?/1 is true for terminal phases" do
    assert RunPhase.terminal?(:completed)
    assert RunPhase.terminal?(:failed)
    assert RunPhase.terminal?(:aborted)
  end

  test "terminal?/1 is false for non-terminal phases" do
    refute RunPhase.terminal?(:accepted)
    refute RunPhase.terminal?(:queued_in_session)
    refute RunPhase.terminal?(:waiting_for_slot)
    refute RunPhase.terminal?(:dispatched_to_gateway)
    refute RunPhase.terminal?(:starting_engine)
    refute RunPhase.terminal?(:streaming)
    refute RunPhase.terminal?(:finalizing)
  end
end
