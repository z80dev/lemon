defmodule LemonCore.RunStoreTerminalDecisionPropertyTest do
  @moduledoc """
  Property proof for the durable terminal decision every run owner writes
  through `LemonCore.RunStore.finalize/3` (epic #68): the first committed
  summary is the run's only terminal decision. Identical retries succeed,
  conflicting decisions fail explicitly, and late run events never change it.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias LemonCore.{RunStore, Store}
  alias LemonCore.Store.EtsBackend

  @store :run_store_terminal_decision_property

  setup do
    start_supervised!(
      Supervisor.child_spec({Store, name: @store, backend: EtsBackend}, id: @store)
    )

    :ok
  end

  property "the first committed terminal decision is immutable under any later operation" do
    check all(operations <- list_of(operation(), min_length: 1, max_length: 25)) do
      run_id = "run-terminal-#{System.unique_integer([:positive])}"

      committed =
        Enum.reduce(operations, nil, fn operation, committed ->
          apply_operation(run_id, operation, committed)
        end)

      :ok = Store.ping(@store)
      record = Store.get(@store, :runs, run_id)

      case committed do
        nil -> assert record == nil or record.summary == nil
        summary -> assert %{summary: ^summary} = record
      end
    end
  end

  defp operation do
    one_of([
      tuple({constant(:finalize), member_of([:completed, :failed, :aborted, :unknown])}),
      tuple({constant(:event), member_of([:delta, :action, :completed])})
    ])
  end

  defp apply_operation(run_id, {:finalize, outcome}, committed) do
    summary = summary(run_id, outcome)
    result = RunStore.finalize(@store, run_id, summary)

    cond do
      is_nil(committed) ->
        assert result == :ok
        summary

      summary == committed ->
        assert result == :ok
        committed

      true ->
        assert result == {:error, {:already_finalized, run_id}}
        committed
    end
  end

  defp apply_operation(run_id, {:event, type}, committed) do
    # Late executor events land through the same serialized Store owner.
    :ok = Store.append_run_event(@store, run_id, %{type: type, ok: type != :completed})
    committed
  end

  defp summary(run_id, outcome) do
    completed =
      case outcome do
        :completed -> %{ok: true, answer: "done"}
        :failed -> %{ok: false, error: :assistant_error}
        :aborted -> %{ok: false, error: :user_requested}
        :unknown -> %{ok: false, error: :outcome_unknown, interrupted: true}
      end

    %{run_id: run_id, completed: Map.put(completed, :run_id, run_id)}
  end
end
