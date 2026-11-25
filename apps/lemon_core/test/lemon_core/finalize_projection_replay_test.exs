defmodule LemonCore.FinalizeProjectionReplayTest do
  @moduledoc """
  Finalization projections are derived from the committed terminal decision
  (#77): a failing projection cannot change or hide that decision, and an
  identical finalize retry redelivers every projection without duplicating the
  run-history row it already wrote.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.{RunHistoryStore, RunStore, Store, TerminalOutbox}
  alias LemonCore.Store.EtsBackend

  @moduletag :tmp_dir

  test "a failed projection keeps the committed outcome and an identical retry repairs it once",
       %{tmp_dir: tmp_dir} do
    history = :projection_replay_history

    start_supervised!(
      Supervisor.child_spec({RunHistoryStore, name: history, path: tmp_dir}, id: history)
    )

    deliveries = :ets.new(:projection_replay_deliveries, [:duplicate_bag, :public])
    failures = :counters.new(1, [])

    # Fails its first delivery, like an unavailable projection owner.
    flaky = fn event ->
      if :counters.get(failures, 1) == 0 do
        :counters.add(failures, 1, 1)
        raise "projection owner unavailable"
      end

      :ets.insert(deliveries, {event.run_id, event.summary})
    end

    store = :projection_replay_store

    start_supervised!(
      Supervisor.child_spec(
        {Store,
         name: store,
         backend: EtsBackend,
         finalize_run_hooks: [flaky, {RunHistoryStore, :handle_finalize_run, [history]}]},
        id: store
      )
    )

    session_key = "agent:projection:main"
    run_id = "run-projection-replay"
    committed = %{session_key: session_key, completed: %{ok: true, answer: "done"}}
    conflicting = %{session_key: session_key, completed: %{ok: false, error: :failed}}

    :ok = Store.append_run_event(store, run_id, %{type: :started})

    log = capture_log(fn -> assert :ok = RunStore.finalize(store, run_id, committed) end)
    assert log =~ "projection owner unavailable"

    # The projection failure is isolated from the authoritative decision.
    assert {:ok, %{summary: ^committed}} = Store.fetch_run(store, run_id)
    assert :ets.lookup(deliveries, run_id) == []
    assert {:ok, [{^run_id, %{summary: ^committed}}]} = history_rows(history, session_key)
    assert {:ok, %{projections: :failed}} = TerminalOutbox.pending(store, run_id)

    # Repair is an identical retry: every projection is redelivered, the failed
    # one lands, and the idempotent history row is not duplicated.
    assert :ok = RunStore.finalize(store, run_id, committed)
    assert :ok = TerminalOutbox.repair(store, run_id)
    assert [{^run_id, ^committed}] = :ets.lookup(deliveries, run_id)
    assert {:ok, [{^run_id, %{summary: ^committed}}]} = history_rows(history, session_key)
    assert %{run_count: 1} = Store.get(store, :sessions_index, session_key)

    # A conflicting decision is rejected before any projection sees it.
    assert {:error, {:already_finalized, ^run_id}} =
             RunStore.finalize(store, run_id, conflicting)

    assert [{^run_id, ^committed}] = :ets.lookup(deliveries, run_id)
    assert {:ok, [{^run_id, %{summary: ^committed}}]} = history_rows(history, session_key)
  end

  defp history_rows(history, session_key) do
    _ = :sys.get_state(history)
    RunHistoryStore.fetch(history, session_key, limit: 10)
  end
end
