defmodule LemonCore.UsageRecordsTest do
  use ExUnit.Case, async: false
  alias LemonCore.{Store, UsageLedger, UsageStore}

  setup do
    store = :usage_records_test_store

    start_supervised!(
      {Store,
       name: store,
       backend: LemonCore.Store.EtsBackend,
       backend_opts: [],
       cached_tables: [],
       finalize_run_hooks: []}
    )

    ledger = :usage_records_test_ledger
    start_supervised!({UsageLedger, name: ledger, store: store})
    %{store: store, ledger: ledger}
  end

  defp entry(run, session, at, usage) do
    UsageLedger.entry(run, session, %{
      completed: %{usage: usage, answer: "private answer"},
      completed_at_ms: at,
      meta: %{model: "openai:gpt-5", agent_id: "bot"},
      prompt: "private prompt",
      cwd: "/private/path",
      credentials: "private credentials"
    })
  end

  defp query(store, params), do: UsageStore.records(params, store: store)

  test "speech character metadata and unknown costs survive ledger persistence", ctx do
    for {run, cost, known} <- [{"speech-priced", 0.00016, true}, {"speech-unknown", nil, false}] do
      usage = %{
        run_id: run,
        occurrence: "voice_reply:delivery",
        session_key: "agent:bot:main",
        agent_id: "bot",
        at_ms: 1000,
        provider: "openai",
        model: "configured-tts",
        input: 0,
        output: 0,
        input_characters: 8,
        cost: cost,
        price_known: known
      }

      assert :ok = UsageLedger.record(ctx.ledger, usage)
    end

    stop_supervised!(UsageLedger)
    start_supervised!({UsageLedger, name: ctx.ledger, store: ctx.store})
    assert {:ok, page} = query(ctx.store, %{"fromMs" => 1000, "toMs" => 1001})
    assert length(page.records) == 2
    assert Enum.all?(page.records, &(&1.input_characters == 8))
    assert Enum.any?(page.records, &(&1.cost_usd == 0.00016 and &1.price_known))
    assert Enum.any?(page.records, &(is_nil(&1.cost_usd) and not &1.price_known))
  end

  test "all sessions paginate beyond top twenty with exact half-open cursor boundaries", ctx do
    for i <- 0..26 do
      assert :ok =
               UsageLedger.record(
                 ctx.ledger,
                 entry("r#{i}", "agent:bot:session#{i}", 1000 + i, %{
                   input: 10,
                   output: 2,
                   total_tokens: 12,
                   cost: %{total: 0.1}
                 })
               )
    end

    params = %{"fromMs" => 1000, "toMs" => 1026, "limit" => 7}
    {records, cursors} = pages(ctx.store, params, [], [])
    assert length(records) == 26
    assert length(Enum.uniq(Enum.map(records, & &1.id))) == 26
    assert Enum.map(records, & &1.at_ms) == Enum.to_list(1000..1025)
    assert Enum.any?(records, &(&1.run_id == "r25"))
    refute Enum.any?(records, &(&1.run_id == "r26"))
    refute inspect(records) =~ "private"
    assert [cursor | _] = cursors

    assert {:error, :invalid_usage_cursor} =
             query(
               ctx.store,
               Map.merge(params, %{"cursor" => cursor, "toMs" => 1027})
             )

    assert {:error, :invalid_usage_cursor} =
             query(
               ctx.store,
               Map.merge(params, %{"cursor" => cursor, "sessionKey" => "agent:bot:session1"})
             )

    assert {:ok, %{records: [%{run_id: "r1"}], next_cursor: nil}} =
             query(ctx.store, Map.put(params, "runId", "r1"))
  end

  defp pages(store, params, records, cursors) do
    assert {:ok, page} = query(store, params)
    refute page.incomplete

    case page.next_cursor do
      nil ->
        {records ++ page.records, cursors}

      cursor ->
        pages(store, Map.put(params, "cursor", cursor), records ++ page.records, [
          cursor | cursors
        ])
    end
  end

  test "equal occurrence times use immutable IDs as the pagination tie-breaker", ctx do
    for run <- ["a", "b", "c"] do
      assert :ok =
               UsageLedger.record(
                 ctx.ledger,
                 entry(run, "agent:bot:main", 1500, %{input: 1, output: 1, cost: 0.1})
               )
    end

    {records, _} = pages(ctx.store, %{"fromMs" => 1500, "toMs" => 1501, "limit" => 1}, [], [])
    assert length(records) == 3
    assert Enum.map(records, & &1.id) == Enum.sort(Enum.map(records, & &1.id))
  end

  test "known actual zero differs from unknown and durable dedupe survives ledger restart", ctx do
    known =
      entry("zero", "agent:bot:main", 2000, %{input: 1, output: 0, cost: 0.0, price_known: true})

    unknown = entry("unknown", "agent:bot:main", 2001, %{input: 1, output: 0, cost: 0.0})
    assert :ok = UsageLedger.record(ctx.ledger, known)
    assert :ok = UsageLedger.record(ctx.ledger, unknown)
    stop_supervised!(UsageLedger)
    start_supervised!({UsageLedger, name: ctx.ledger, store: ctx.store})
    assert :ok = UsageLedger.record(ctx.ledger, known)
    assert {:ok, page} = query(ctx.store, %{"fromMs" => 2000, "toMs" => 2002})
    assert page.incomplete

    assert [%{cost_usd: 0.0, price_known: true}, %{cost_usd: nil, price_known: false}] =
             page.records

    assert length(page.records) == 2
    assert UsageStore.get_record(ctx.store, "1970-01-01").requests == %{"openai" => 2}
  end

  test "durable occurrence fences survive a full SQLite Store and ledger restart" do
    directory = Path.join(System.tmp_dir!(), "usage-ledger-#{LemonCore.Id.uuid()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    store = :usage_durable_store
    ledger = :usage_durable_ledger

    store_spec =
      Supervisor.child_spec(
        {Store,
         name: store,
         backend: LemonCore.Store.SqliteBackend,
         backend_opts: [path: Path.join(directory, "usage.sqlite3"), ephemeral_tables: []],
         finalize_run_hooks: []},
        id: store
      )

    ledger_spec = Supervisor.child_spec({UsageLedger, name: ledger, store: store}, id: ledger)
    start_supervised!(store_spec)
    start_supervised!(ledger_spec)
    usage = entry("persisted", "agent:bot:main", 2500, %{input: 1, output: 1, cost: 0.5})
    assert :ok = UsageLedger.record(ledger, usage)
    stop_supervised!(ledger)
    stop_supervised!(store)
    start_supervised!(store_spec)
    start_supervised!(ledger_spec)
    assert :ok = UsageLedger.record(ledger, usage)

    assert {:ok, %{records: [%{run_id: "persisted", cost_usd: 0.5}], incomplete: false}} =
             query(store, %{"fromMs" => 2500, "toMs" => 2501})

    assert UsageStore.get_record(store, "1970-01-01").requests == %{"openai" => 1}
  end

  test "two genuine calls on one run are billed separately and replay once", ctx do
    occurrences =
      Enum.map([3000, 3001], fn at ->
        %{
          at_ms: at,
          provider: "openai",
          model: "gpt-5",
          usage: %{input: 4, output: 1, cost: 0.25, price_known: true}
        }
      end)

    summary = %{
      session_key: "agent:bot:main",
      meta: %{agent_id: "bot"},
      completed: %{usage: %{occurrences: occurrences}}
    }

    for _ <- 1..2, entry <- UsageLedger.entries("two-calls", summary.session_key, summary) do
      assert :ok = UsageLedger.record(ctx.ledger, entry)
    end

    assert {:ok, %{records: records, incomplete: false}} =
             query(
               ctx.store,
               %{"fromMs" => 3000, "toMs" => 3002}
             )

    assert length(records) == 2
    assert Enum.sum(Enum.map(records, & &1.cost_usd)) == 0.5
    assert Enum.all?(records, &(&1.run_id == "two-calls"))
  end

  test "historical missing price or attribution is incomplete, aggregate-only history cannot be assigned",
       ctx do
    summary = %{
      session_key: "legacy-session",
      completed: %{usage: %{input: 3, output: 1}},
      meta: %{}
    }

    assert :ok = Store.finalize_run(ctx.store, "legacy", summary)

    assert {:ok, %{records: [record], incomplete: true}} =
             query(
               ctx.store,
               %{"fromMs" => 4000, "toMs" => 5000, "runId" => "legacy"}
             )

    assert record.cost_usd == nil
    assert record.at_ms == nil
    assert record.agent_id == nil

    assert :ok =
             UsageStore.put_record(ctx.store, "1970-01-01", %{
               requests: %{"unknown" => 1},
               total_cost: 0.0
             })

    assert {:ok, %{records: [], incomplete: true}} =
             query(
               ctx.store,
               %{"fromMs" => 4000, "toMs" => 5000, "runId" => "not-attributable"}
             )
  end

  test "unavailable owner and invalid range fail, never return an empty page", ctx do
    assert {:error, :store_unavailable} =
             query(:usage_records_missing_store, %{"fromMs" => 0, "toMs" => 10})

    assert {:error, :invalid_usage_filters} = query(ctx.store, %{"fromMs" => 10, "toMs" => 10})

    assert {:error, :invalid_usage_filters} =
             query(ctx.store, %{"fromMs" => 0, "toMs" => 10, "limit" => 501})
  end
end
