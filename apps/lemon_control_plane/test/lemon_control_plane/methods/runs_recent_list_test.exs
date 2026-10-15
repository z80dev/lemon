defmodule LemonControlPlane.Methods.RunsRecentListTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.RunsRecentList
  alias LemonCore.{IntrospectionStore, Store, UsageLedger, UsageStore}
  alias LemonCore.Store.EtsBackend

  defmodule ListFailureBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    defdelegate init(opts), to: LemonCore.Store.EtsBackend

    @impl true
    defdelegate put(state, table, key, value), to: LemonCore.Store.EtsBackend

    @impl true
    defdelegate put_new(state, table, key, value), to: LemonCore.Store.EtsBackend

    @impl true
    defdelegate get(state, table, key), to: LemonCore.Store.EtsBackend

    @impl true
    defdelegate delete(state, table, key), to: LemonCore.Store.EtsBackend

    @impl true
    def list(_state, :introspection_log),
      do: {:error, {:backend_failure, "api_key=private-backend-credential"}}

    def list(state, table), do: LemonCore.Store.EtsBackend.list(state, table)
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    original = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      {:ok, backend_state} = EtsBackend.init([])
      %{state | backend: EtsBackend, backend_state: backend_state}
    end)

    on_exit(fn ->
      :sys.replace_state(Store, fn current ->
        Enum.each(current.backend_state, fn {_key, table} -> :ets.delete(table) end)
        original
      end)
    end)

    suffix = Integer.to_string(System.unique_integer([:positive]))
    %{session_key: "agent:recent-history:#{suffix}", at_ms: System.system_time(:millisecond)}
  end

  test "atom and router string abort labels remain aborted rather than errors", ctx do
    labels = [
      :aborted,
      :user_requested,
      :interrupted,
      "aborted",
      "user_requested",
      "interrupted",
      "ABORTED",
      "Aborted by operator"
    ]

    ids =
      for {label, index} <- Enum.with_index(labels) do
        event(ctx, :run_completed, %{ok: false, error: label}, offset: index)
      end

    assert {:ok, result} = recent(ctx, %{"status" => "aborted"})
    assert Enum.sort(Enum.map(result["runs"], & &1["runId"])) == Enum.sort(ids)
    assert Enum.all?(result["runs"], &(&1["status"] == "aborted" and &1["ok"] == false))
    assert result["summary"]["abortedCount"] == length(labels)
    assert result["summary"]["errorCount"] == 0
  end

  test "run_failed is crashed and does not inflate error or aborted counts", ctx do
    completed = event(ctx, :run_completed, %{ok: true}, offset: 1)
    error = event(ctx, :run_completed, %{ok: false, error: :provider_error}, offset: 2)
    aborted = event(ctx, :run_completed, %{ok: false, error: "interrupted"}, offset: 3)
    crashed = event(ctx, :run_failed, %{reason: "worker_crashed"}, offset: 4)

    assert {:ok, result} = recent(ctx)

    assert Map.new(result["runs"], &{&1["runId"], &1["status"]}) == %{
             completed => "completed",
             error => "error",
             aborted => "aborted",
             crashed => "crashed"
           }

    assert result["total"] == 4

    assert result["summary"]["statusCounts"] == %{
             "completed" => 1,
             "error" => 1,
             "aborted" => 1,
             "crashed" => 1
           }

    assert result["summary"]["okCount"] == 1
    assert result["summary"]["errorCount"] == 1
    assert result["summary"]["abortedCount"] == 1

    assert {:ok,
            %{"runs" => [%{"runId" => ^crashed, "ok" => false, "error" => "worker_crashed"}]}} =
             recent(ctx, %{"status" => "crashed"})
  end

  test "completed outcome wins over a newer failed event for the same run", ctx do
    id = event(ctx, :run_completed, %{ok: true, duration_ms: 100})
    event(ctx, :run_failed, %{error: :worker_crashed}, run_id: id, offset: 1)

    assert {:ok, result} = recent(ctx)

    assert [%{"runId" => ^id, "status" => "completed", "ok" => true, "error" => nil}] =
             result["runs"]

    assert result["total"] == 1
    assert result["summary"]["statusCounts"] == %{"completed" => 1}
    assert {:ok, %{"runs" => [], "total" => 0}} = recent(ctx, %{"status" => "crashed"})
  end

  test "status filtering finds older matches beyond the response limit", ctx do
    older = event(ctx, :run_completed, %{ok: false, error: "aborted"})

    for offset <- 1..3 do
      event(ctx, :run_completed, %{ok: true}, offset: offset)
    end

    assert {:ok, result} = recent(ctx, %{"status" => "aborted", "limit" => 1})
    assert [%{"runId" => ^older, "status" => "aborted"}] = result["runs"]
    assert result["total"] == 1
    assert result["summary"]["errorCount"] == 0
    assert result["summary"]["abortedCount"] == 1
  end

  test "agent and session filters exclude newer unrelated runs before limiting", ctx do
    older = event(ctx, :run_completed, %{ok: true})
    other = %{ctx | session_key: ctx.session_key <> "-other"}

    for offset <- 1..3 do
      event(other, :run_completed, %{ok: true}, offset: offset, agent_id: "other-agent")
    end

    assert {:ok, %{"runs" => [%{"runId" => ^older}]}} = recent(ctx, %{"limit" => 1})

    assert {:ok, %{"runs" => [%{"runId" => ^older}]}} =
             RunsRecentList.handle(%{"agentId" => "recent-history", "limit" => 1}, %{})
  end

  test "error labels are redacted, byte bounded and valid Unicode without exposing terms", ctx do
    secret = "private-run-history-credential"

    redacted =
      event(ctx, :run_completed, %{
        ok: false,
        error: "failure api_key=#{secret}; " <> String.duplicate("detail ", 100)
      })

    unicode = event(ctx, :run_completed, %{ok: false, error: String.duplicate("界", 100)})

    structured =
      event(ctx, :run_failed, %{
        error: {:worker_crashed, %{credential: secret, path: "/private/run-history"}}
      })

    assert {:ok, result} = recent(ctx)
    errors = Map.new(result["runs"], &{&1["runId"], &1["error"]})
    assert String.starts_with?(errors[redacted], "failure ")
    refute errors[redacted] =~ secret
    assert errors[unicode] == String.duplicate("界", 85)
    assert errors[structured] == "unknown_error"

    for label <- Map.values(errors) do
      assert String.valid?(label)
      assert byte_size(label) <= 256
    end

    refute inspect(result) =~ secret
    refute inspect(result) =~ "/private/run-history"
  end

  test "absent usage is explicit null rather than zero tokens or a free run", ctx do
    id = event(ctx, :run_completed, %{ok: true})
    assert {:ok, %{"runs" => [%{"runId" => ^id} = row]}} = recent(ctx)

    assert Map.take(row, ["tokens", "costUsd", "priceKnown", "model", "provider"]) == %{
             "tokens" => nil,
             "costUsd" => nil,
             "priceKnown" => nil,
             "model" => nil,
             "provider" => nil
           }
  end

  test "usage aggregates actual occurrences for the run without mixing another run", ctx do
    id = event(ctx, :run_completed, %{ok: true, duration_ms: 100})

    occurrences = [
      %{
        at_ms: ctx.at_ms - 90,
        provider: "openai",
        model: "gpt-5",
        usage: %{input: 7, output: 3, total_tokens: 10, cost: 0.125, price_known: true}
      },
      %{
        at_ms: ctx.at_ms - 10,
        provider: "openai",
        model: "gpt-5",
        usage: %{input: 11, output: 5, total_tokens: 16, cost: 0.375, price_known: true}
      }
    ]

    put_occurrences(ctx, id, occurrences)

    put_occurrences(ctx, "unrelated-run", [
      %{
        at_ms: ctx.at_ms - 50,
        provider: "other-provider",
        model: "other-model",
        usage: %{input: 1000, output: 1000, cost: 50.0, price_known: true}
      }
    ])

    assert {:ok, %{"runs" => [%{"runId" => ^id} = row]}} = recent(ctx)
    assert row["tokens"] == %{"input" => 18, "output" => 8, "total" => 26}
    assert row["costUsd"] == 0.5
    assert row["priceKnown"] == true
    assert row["provider"] == "openai"
    assert row["model"] == "gpt-5"
  end

  test "crashed runs use their start event to include usage before the crash", ctx do
    id = event(ctx, :run_started, %{}, offset: -100)
    event(ctx, :run_failed, %{reason: "worker_crashed"}, run_id: id)

    put_occurrences(ctx, id, [
      %{
        at_ms: ctx.at_ms - 50,
        provider: "one",
        model: "first",
        usage: %{input: 2, output: 3, cost: 0.125}
      }
    ])

    assert {:ok, %{"runs" => [row]}} = recent(ctx)
    assert row["status"] == "crashed"
    assert row["startedAtMs"] == ctx.at_ms - 100
    assert row["tokens"] == %{"input" => 2, "output" => 3, "total" => 5}
    assert row["costUsd"] == 0.125
  end

  test "an unknown start never turns a narrower usage window into complete run totals", ctx do
    event(ctx, :run_completed, %{ok: true, duration_ms: 100})
    crashed = event(ctx, :run_failed, %{reason: "worker_crashed"}, offset: 1)

    put_occurrences(ctx, crashed, [
      %{at_ms: ctx.at_ms - 150, provider: "one", model: "first",
        usage: %{input: 7, output: 3, cost: 0.125}},
      %{at_ms: ctx.at_ms - 50, provider: "one", model: "first",
        usage: %{input: 2, output: 3, cost: 0.125}}
    ])

    assert {:ok, %{"runs" => runs}} = recent(ctx)
    row = Enum.find(runs, &(&1["runId"] == crashed))
    assert row["startedAtMs"] == nil
    assert row["tokens"] == nil
    assert row["costUsd"] == nil
    assert row["priceKnown"] == nil
  end

  test "unpriced usage retains tokens without inventing cost or a single model", ctx do
    id = event(ctx, :run_completed, %{ok: true, duration_ms: 100})

    put_occurrences(ctx, id, [
      %{
        at_ms: ctx.at_ms - 50,
        provider: "one",
        model: "first",
        usage: %{input: 2, output: 3, cost: 0.0}
      },
      %{at_ms: ctx.at_ms - 10, provider: "two", model: "second", usage: %{input: 5, output: 7}}
    ])

    assert {:ok, %{"runs" => [row]}} = recent(ctx)
    assert row["tokens"] == %{"input" => 7, "output" => 10, "total" => 17}
    assert row["priceKnown"] == false
    assert row["costUsd"] == nil
    assert row["model"] == nil
    assert row["provider"] == nil
  end

  test "overflowing the bounded usage window never presents partial totals", ctx do
    id = event(ctx, :run_completed, %{ok: true, duration_ms: 100})

    put_occurrences(
      ctx,
      id,
      for _ <- 1..501 do
        %{
          at_ms: ctx.at_ms - 10,
          provider: "one",
          model: "first",
          usage: %{input: 1, output: 1, cost: 0.1}
        }
      end
    )

    assert {:ok, %{"runs" => [row]}} = recent(ctx)
    assert row["tokens"] == nil
    assert row["costUsd"] == nil
    assert row["priceKnown"] == nil
  end

  @tag capture_log: true
  test "backend list failure is unavailable, never a successful empty history", ctx do
    id = event(ctx, :run_completed, %{ok: true})
    :ok = Store.ping()
    :sys.replace_state(Store, &%{&1 | backend: ListFailureBackend})

    try do
      assert {:error, {:internal_error, "Run history is unavailable", nil}} = recent(ctx)
    after
      :sys.replace_state(Store, &%{&1 | backend: EtsBackend})
    end

    assert {:ok, %{"runs" => [%{"runId" => ^id}]}} = recent(ctx)
  end

  defp recent(ctx, params \\ %{}) do
    RunsRecentList.handle(Map.put(params, "sessionKey", ctx.session_key), %{})
  end

  defp event(ctx, type, payload, opts \\ []) do
    id = Keyword.get(opts, :run_id, "run-#{LemonCore.Id.uuid()}")

    assert :ok =
             IntrospectionStore.append(%{
               event_id: "evt-#{LemonCore.Id.uuid()}",
               event_type: type,
               ts_ms: ctx.at_ms + Keyword.get(opts, :offset, 0),
               run_id: id,
               session_key: ctx.session_key,
               agent_id: Keyword.get(opts, :agent_id, "recent-history"),
               engine: "native",
               provenance: :direct,
               payload: payload
             })

    id
  end

  defp put_occurrences(ctx, id, occurrences) do
    summary = %{
      session_key: ctx.session_key,
      meta: %{agent_id: "recent-history"},
      completed: %{usage: %{occurrences: occurrences}}
    }

    for entry <- UsageLedger.entries(id, ctx.session_key, summary) do
      assert :ok = UsageStore.put_occurrence(UsageLedger.occurrence_record(entry))
    end
  end
end
