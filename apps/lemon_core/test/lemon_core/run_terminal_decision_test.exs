defmodule LemonCore.RunTerminalDecisionTest do
  @moduledoc """
  One committed terminal decision per run ID (#75).

  `RunStore.finalize/3` commits the first summary for a run. An identical retry
  is idempotent, a different summary is rejected without replacing or leaking
  the committed one, later run events never rewrite it, and finalize-run hooks
  (the projection fan-out) only ever see the committed decision.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias LemonCore.{RunStore, Store}
  alias LemonCore.Store.{EtsBackend, SqliteBackend}

  @moduletag :tmp_dir

  setup do
    deliveries = :ets.new(:terminal_decision_deliveries, [:duplicate_bag, :public])
    hook = fn event -> :ets.insert(deliveries, {event.run_id, event.summary}) end

    spec =
      Supervisor.child_spec(
        {Store, name: :terminal_decision_store, backend: EtsBackend, finalize_run_hooks: [hook]},
        id: :terminal_decision_store
      )

    start_supervised!(spec)
    %{store: :terminal_decision_store, deliveries: deliveries}
  end

  property "the first committed summary is the only terminal decision", %{
    store: store,
    deliveries: deliveries
  } do
    check all(
            operations <-
              list_of(member_of([:retry_a, :retry_b, :retry_c, :event]),
                min_length: 1,
                max_length: 12
              ),
            max_runs: 60
          ) do
      id = System.unique_integer([:positive])
      run_id = "run-decision-#{id}"
      session_key = "agent:decision:#{id}"
      summaries = summaries(session_key)

      results =
        Enum.map(operations, fn
          :event ->
            assert :ok = Store.append_run_event(store, run_id, %{type: :late_event})
            assert :ok = Store.ping(store)
            :event

          choice ->
            {choice, RunStore.finalize(store, run_id, Map.fetch!(summaries, choice))}
        end)

      case for({choice, _result} <- Enum.reject(results, &(&1 == :event)), do: choice) do
        [] ->
          assert %{summary: nil} = Store.get(store, :runs, run_id)
          assert :ets.lookup(deliveries, run_id) == []

        [winner | _] = choices ->
          committed = Map.fetch!(summaries, winner)

          for {choice, result} <- Enum.reject(results, &(&1 == :event)) do
            if choice == winner,
              do: assert(result == :ok),
              else: assert(result == {:error, {:already_finalized, run_id}})
          end

          assert %{summary: ^committed} = Store.get(store, :runs, run_id)
          assert %{run_count: 1} = Store.get(store, :sessions_index, session_key)

          delivered = :ets.lookup(deliveries, run_id)
          assert length(delivered) == Enum.count(choices, &(&1 == winner))
          assert Enum.all?(delivered, fn {_run_id, summary} -> summary == committed end)
      end
    end
  end

  test "concurrent conflicting finalizations commit exactly one decision", %{
    store: store,
    deliveries: deliveries
  } do
    run_id = "run-race-#{System.unique_integer([:positive])}"
    session_key = "agent:race:main"

    results =
      1..24
      |> Enum.map(fn n ->
        summary = %{session_key: session_key, completed: %{ok: rem(n, 2) == 0, answer: "#{n}"}}
        Task.async(fn -> {summary, RunStore.finalize(store, run_id, summary)} end)
      end)
      |> Task.await_many()

    assert [{winner, :ok}] = Enum.filter(results, fn {_summary, result} -> result == :ok end)

    assert Enum.all?(results, fn {summary, result} ->
             summary == winner or result == {:error, {:already_finalized, run_id}}
           end)

    assert %{summary: ^winner} = Store.get(store, :runs, run_id)
    assert %{run_count: 1} = Store.get(store, :sessions_index, session_key)
    assert [{^run_id, ^winner}] = :ets.lookup(deliveries, run_id)
  end

  test "a persisted decision survives a store restart and still rejects conflicts", %{
    tmp_dir: tmp_dir
  } do
    opts = [
      name: :terminal_decision_sqlite,
      backend: SqliteBackend,
      backend_opts: [path: tmp_dir, ephemeral_tables: []]
    ]

    start_supervised!(Supervisor.child_spec({Store, opts}, id: :terminal_decision_sqlite))

    session_key = "agent:restart:main"
    committed = %{session_key: session_key, completed: %{ok: true, answer: "kept"}}
    conflicting = %{session_key: session_key, completed: %{ok: false, error: :outcome_unknown}}

    assert :ok = RunStore.finalize(:terminal_decision_sqlite, "run-restart", committed)
    :ok = stop_supervised!(:terminal_decision_sqlite)

    start_supervised!(Supervisor.child_spec({Store, opts}, id: :terminal_decision_sqlite))

    assert {:ok, %{summary: ^committed}} =
             Store.fetch_run(:terminal_decision_sqlite, "run-restart")

    assert {:error, {:already_finalized, "run-restart"}} =
             RunStore.finalize(:terminal_decision_sqlite, "run-restart", conflicting)

    assert :ok = RunStore.finalize(:terminal_decision_sqlite, "run-restart", committed)

    assert %{run_count: 1} =
             Store.get(:terminal_decision_sqlite, :sessions_index, session_key)
  end

  defp summaries(session_key) do
    %{
      retry_a: %{session_key: session_key, completed: %{ok: true, answer: "a"}},
      retry_b: %{session_key: session_key, completed: %{ok: false, error: :failed}},
      retry_c: %{session_key: session_key, completed: %{ok: false, error: :user_requested}}
    }
  end
end
