defmodule LemonCore.RunPhaseGraphTest do
  use ExUnit.Case, async: true

  alias LemonCore.RunPhaseGraph

  test "accepted transitions to queued_in_session" do
    assert :ok = RunPhaseGraph.transition(:accepted, :queued_in_session)
  end

  test "queued_in_session transitions to waiting_for_slot" do
    assert :ok = RunPhaseGraph.transition(:queued_in_session, :waiting_for_slot)
  end

  test "waiting_for_slot transitions to dispatched_to_gateway" do
    assert :ok = RunPhaseGraph.transition(:waiting_for_slot, :dispatched_to_gateway)
  end

  test "starting_engine transitions to streaming" do
    assert :ok = RunPhaseGraph.transition(:starting_engine, :streaming)
  end

  test "streaming transitions to finalizing" do
    assert :ok = RunPhaseGraph.transition(:streaming, :finalizing)
  end

  test "finalizing transitions to completed" do
    assert :ok = RunPhaseGraph.transition(:finalizing, :completed)
  end

  test "completed cannot transition back to streaming" do
    assert {:error, {:invalid_transition, :completed, :streaming}} =
             RunPhaseGraph.transition(:completed, :streaming)
  end

  test "failed cannot transition to completed" do
    assert {:error, {:invalid_transition, :failed, :completed}} =
             RunPhaseGraph.transition(:failed, :completed)
  end

  test "aborted cannot transition to starting_engine" do
    assert {:error, {:invalid_transition, :aborted, :starting_engine}} =
             RunPhaseGraph.transition(:aborted, :starting_engine)
  end
end
