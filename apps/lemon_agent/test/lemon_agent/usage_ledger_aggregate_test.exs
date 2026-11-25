defmodule LemonAgent.UsageLedgerAggregateTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store
  alias LemonAgent.{UsageLedger, UsageStore}
  alias LemonCore.Store.EtsBackend

  # Fails or stalls selected {operation, table} pairs inside a dedicated Store.
  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend

    def set(faults), do: :persistent_term.put({__MODULE__, :faults}, faults)
    def clear, do: :persistent_term.erase({__MODULE__, :faults})

    defp faulted(op, table, fun) do
      case Map.get(:persistent_term.get({__MODULE__, :faults}, %{}), {op, table}) do
        :error ->
          {:error, :boom}

        {:stall, ms} ->
          Process.sleep(ms)
          fun.()

        nil ->
          fun.()
      end
    end

    defdelegate init(opts), to: EtsBackend
    defdelegate sync(state), to: EtsBackend

    def get(s, t, k), do: faulted(:get, t, fn -> EtsBackend.get(s, t, k) end)
    def put(s, t, k, v), do: faulted(:put, t, fn -> EtsBackend.put(s, t, k, v) end)
    def put_new(s, t, k, v), do: faulted(:put_new, t, fn -> EtsBackend.put_new(s, t, k, v) end)
    def delete(s, t, k), do: faulted(:delete, t, fn -> EtsBackend.delete(s, t, k) end)
    def list(s, t), do: faulted(:list, t, fn -> EtsBackend.list(s, t) end)
  end

  @store :usage_ledger_aggregate_store
  @ledger :usage_ledger_aggregate_ledger

  setup do
    on_exit(&FaultBackend.clear/0)

    start_supervised!(
      {Store,
       name: @store,
       backend: FaultBackend,
       backend_opts: [],
       cached_tables: [],
       finalize_run_hooks: []}
    )

    start_supervised!({UsageLedger, name: @ledger, store: @store})
    now = System.system_time(:millisecond)
    today = now |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()
    %{now: now, today: today}
  end

  defp entry(run_id, at_ms, cost \\ 0.25) do
    %{
      run_id: run_id,
      occurrence: 0,
      session_key: "agent:bot:main",
      agent_id: "bot",
      at_ms: at_ms,
      provider: "openai",
      model: "gpt-5",
      input: 10,
      output: 5,
      cost: cost,
      price_known: true
    }
  end

  defp requests(day), do: day |> Map.get(:requests, %{}) |> Map.values() |> Enum.sum()

  test "an occurrence that landed without its daily aggregate is repaired on replay", ctx do
    FaultBackend.set(%{{:put, :usage_records} => :error})
    assert {:error, _} = UsageLedger.record(@ledger, entry("repair-run", ctx.now))

    # The canonical occurrence landed; the projection did not.
    assert {:ok, [_occurrence]} = UsageStore.fetch_occurrences(@store)
    assert {:ok, nil} = Store.fetch(@store, :usage_records, ctx.today)

    FaultBackend.clear()
    assert :ok = UsageLedger.record(@ledger, entry("repair-run", ctx.now))

    assert {:ok, %{} = day} = Store.fetch(@store, :usage_records, ctx.today)
    assert requests(day) == 1
    assert day.total_cost == 0.25

    assert %{total_requests: 1, total_cost: 0.25} = UsageStore.get_summary(@store, :current)

    # A later replay of the same occurrence never counts it twice.
    assert :ok = UsageLedger.record(@ledger, entry("repair-run", ctx.now))
    assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
    assert requests(day) == 1
    assert %{total_requests: 1} = UsageStore.get_summary(@store, :current)
  end

  test "a failed daily-record read never overwrites the stored totals", ctx do
    assert :ok = UsageLedger.record(@ledger, entry("first-run", ctx.now))
    assert :ok = UsageLedger.record(@ledger, entry("second-run", ctx.now))
    assert {:ok, before} = Store.fetch(@store, :usage_records, ctx.today)
    assert requests(before) == 2
    summary_before = UsageStore.get_summary(@store, :current)
    assert summary_before.total_requests == 2

    FaultBackend.set(%{{:get, :usage_records} => :error, {:get, :usage_data} => :error})
    assert {:error, _} = UsageLedger.record(@ledger, entry("third-run", ctx.now))
    FaultBackend.clear()

    assert {:ok, after_failure} = Store.fetch(@store, :usage_records, ctx.today)
    assert requests(after_failure) == 2
    assert after_failure.total_cost == before.total_cost
    assert UsageStore.get_summary(@store, :current).total_requests == 2

    # The failed record is repaired by its replay, not lost.
    assert :ok = UsageLedger.record(@ledger, entry("third-run", ctx.now))
    assert {:ok, repaired} = Store.fetch(@store, :usage_records, ctx.today)
    assert requests(repaired) == 3
    assert UsageStore.get_summary(@store, :current).total_requests == 3
  end

  @tag timeout: 60_000
  test "a timed-out daily-record read never resets the day", ctx do
    assert :ok = UsageLedger.record(@ledger, entry("before-timeout-1", ctx.now))
    assert :ok = UsageLedger.record(@ledger, entry("before-timeout-2", ctx.now))

    FaultBackend.set(%{{:get, :usage_records} => {:stall, 5_500}})

    # The ledger's own Store call times out after five seconds; wait past it.
    assert {:error, _} =
             GenServer.call(@ledger, {:record, entry("during-timeout", ctx.now)}, 20_000)

    FaultBackend.clear()

    assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
    assert requests(day) == 2
  end

  describe "occurrences recorded before projection markers" do
    test "an uncounted legacy occurrence is projected on replay", ctx do
      legacy = entry("legacy-uncounted", ctx.now)
      # The old ledger committed the occurrence, then failed the aggregate write.
      assert :ok = UsageStore.put_occurrence(@store, UsageLedger.occurrence_record(legacy))

      assert :ok = UsageLedger.record(@ledger, legacy)
      assert {:ok, %{} = day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 1
      assert day.total_cost == 0.25
      assert %{total_requests: 1} = UsageStore.get_summary(@store, :current)

      assert :ok = UsageLedger.record(@ledger, legacy)
      assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 1
    end

    test "a counted legacy occurrence is not counted twice", ctx do
      counted = entry("legacy-counted", ctx.now)
      other = entry("legacy-other", ctx.now, 0.5)
      put_legacy_counted(counted, ctx)
      put_legacy_counted(other, ctx)

      assert :ok = UsageLedger.record(@ledger, counted)
      assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 2
      assert day.total_cost == 0.75

      assert :ok = UsageLedger.record(@ledger, other)
      assert :ok = UsageLedger.record(@ledger, counted)
      assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 2
      assert day.total_cost == 0.75
      assert %{total_requests: 2} = UsageStore.get_summary(@store, :current)
    end

    test "a legacy day missing one occurrence is repaired without double counting", ctx do
      counted = entry("legacy-day-counted", ctx.now)
      uncounted = entry("legacy-day-uncounted", ctx.now, 0.5)
      put_legacy_counted(counted, ctx)
      assert :ok = UsageStore.put_occurrence(@store, UsageLedger.occurrence_record(uncounted))

      assert :ok = UsageLedger.record(@ledger, uncounted)
      assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 2
      assert day.total_cost == 0.75

      assert :ok = UsageLedger.record(@ledger, counted)
      assert :ok = UsageLedger.record(@ledger, entry("after-upgrade", ctx.now))
      assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 3
      assert day.total_cost == 1.0
    end

    test "a failed legacy rebuild never double counts on replay", ctx do
      counted = entry("legacy-rebuild-failed", ctx.now)
      put_legacy_counted(counted, ctx)
      put_legacy_counted(entry("legacy-rebuild-other", ctx.now, 0.5), ctx)

      # The marker lands, then the canonical rebuild cannot read the ledger.
      FaultBackend.set(%{{:list, :usage_occurrences} => :error})
      assert {:error, _} = UsageLedger.record(@ledger, counted)
      FaultBackend.clear()

      assert :ok = UsageLedger.record(@ledger, counted)
      assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 2
      assert day.total_cost == 0.75

      assert :ok = UsageLedger.record(@ledger, counted)
      assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 2
    end

    test "a legacy migration interrupted right after the marker insert never double counts",
         ctx do
      counted = entry("legacy-marker-only", ctx.now)
      put_legacy_counted(counted, ctx)

      # The ledger stopped after inserting the bare pending marker.
      record = UsageLedger.occurrence_record(counted)

      assert :ok =
               UsageStore.put_projection_new(@store, record.id, %{
                 state: :pending,
                 date: ctx.today,
                 at_ms: ctx.now
               })

      assert :ok = UsageLedger.record(@ledger, counted)
      assert {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
      assert requests(day) == 1
      assert day.total_cost == 0.25
    end
  end

  # What the pre-marker ledger left behind after a fully successful record.
  defp put_legacy_counted(entry, ctx) do
    :ok = UsageStore.put_occurrence(@store, UsageLedger.occurrence_record(entry))
    {:ok, day} = Store.fetch(@store, :usage_records, ctx.today)
    day = UsageLedger.add_to_record(day || %{date: ctx.today}, entry, ctx.today, entry.at_ms)
    :ok = UsageStore.put_record(@store, ctx.today, day)
  end
end
