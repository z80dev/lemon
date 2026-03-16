defmodule LemonCore.RoutingFeedbackStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.RoutingFeedbackStore

  # Start a store instance backed by an in-memory (temp dir) database for each test.
  setup do
    dir = System.tmp_dir!() |> Path.join("rfs_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, pid} =
      GenServer.start_link(RoutingFeedbackStore, [path: dir],
        name: :"rfs_#{:erlang.unique_integer([:positive])}"
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    %{pid: pid}
  end

  defp record(pid, key, outcome, duration_ms \\ nil) do
    GenServer.cast(pid, {:record, key, Atom.to_string(outcome), duration_ms})
    # Give the async cast time to be processed
    Process.sleep(20)
  end

  defp aggregate(pid, key) do
    GenServer.call(pid, {:aggregate, key})
  end

  describe "record and aggregate" do
    test "returns :insufficient_data when below threshold", %{pid: pid} do
      record(pid, "fp1", :success)
      record(pid, "fp1", :success)

      assert {:insufficient_data, 2} = aggregate(pid, "fp1")
    end

    test "returns :insufficient_data for unknown fingerprint", %{pid: pid} do
      assert {:insufficient_data, 0} = aggregate(pid, "nonexistent_fp")
    end

    test "returns ok aggregate when threshold is met", %{pid: pid} do
      key = "code|bash|-|-|-"

      # Default min_sample_size is 5; record 5 samples
      record(pid, key, :success, 1000)
      record(pid, key, :success, 2000)
      record(pid, key, :success, 1500)
      record(pid, key, :failure, 500)
      record(pid, key, :failure, 800)

      assert {:ok, agg} = aggregate(pid, key)
      assert agg.fingerprint_key == key
      assert agg.total == 5
      assert agg.outcomes[:success] == 3
      assert agg.outcomes[:failure] == 2
      assert agg.success_rate == 0.6
      assert is_integer(agg.mean_duration_ms)
    end

    test "success_rate is 1.0 when all succeed", %{pid: pid} do
      key = "query|read_file|-|-|-"

      for _ <- 1..5 do
        record(pid, key, :success, 1000)
      end

      assert {:ok, agg} = aggregate(pid, key)
      assert agg.success_rate == 1.0
    end

    test "success_rate is 0.0 when all fail", %{pid: pid} do
      key = "code|bash|-|-|-"

      for _ <- 1..5 do
        record(pid, key, :failure, 500)
      end

      assert {:ok, agg} = aggregate(pid, key)
      assert agg.success_rate == 0.0
    end

    test "mean_duration_ms is nil when no durations recorded", %{pid: pid} do
      key = "chat|-|-|-|-"

      for _ <- 1..5 do
        record(pid, key, :success, nil)
      end

      assert {:ok, agg} = aggregate(pid, key)
      assert is_nil(agg.mean_duration_ms)
    end

    test "handles mixed outcome types including aborted and partial", %{pid: pid} do
      key = "code|bash|/proj|anthropic|opus"

      record(pid, key, :success, 2000)
      record(pid, key, :partial, 1000)
      record(pid, key, :aborted, 100)
      record(pid, key, :failure, 500)
      record(pid, key, :unknown, nil)

      assert {:ok, agg} = aggregate(pid, key)
      assert agg.total == 5
      assert Map.has_key?(agg.outcomes, :success)
      assert Map.has_key?(agg.outcomes, :failure)
    end

    test "fingerprints are isolated from each other", %{pid: pid} do
      key1 = "code|bash|-|-|-"
      key2 = "query|read_file|-|-|-"

      for _ <- 1..5, do: record(pid, key1, :success, 1000)
      for _ <- 1..5, do: record(pid, key2, :failure, 500)

      {:ok, agg1} = aggregate(pid, key1)
      {:ok, agg2} = aggregate(pid, key2)

      assert agg1.success_rate == 1.0
      assert agg2.success_rate == 0.0
    end
  end

  describe "list_fingerprints/0" do
    test "returns empty list when store is empty", %{pid: pid} do
      assert {:ok, []} = GenServer.call(pid, :list_fingerprints)
    end

    test "returns one row per distinct fingerprint", %{pid: pid} do
      record(pid, "code|bash|-|-|-", :success, 1000)
      record(pid, "code|bash|-|-|-", :failure, 500)
      record(pid, "query|read_file|-|-|-", :success, 200)

      assert {:ok, rows} = GenServer.call(pid, :list_fingerprints)
      assert length(rows) == 2

      keys = Enum.map(rows, & &1.fingerprint_key)
      assert "code|bash|-|-|-" in keys
      assert "query|read_file|-|-|-" in keys
    end

    test "includes total, success_count, and last_seen_ms", %{pid: pid} do
      key = "code|bash|-|-|-"
      record(pid, key, :success, 1000)
      record(pid, key, :success, 800)
      record(pid, key, :failure, 400)

      assert {:ok, [row]} = GenServer.call(pid, :list_fingerprints)
      assert row.fingerprint_key == key
      assert row.total == 3
      assert row.success_count == 2
      assert is_integer(row.last_seen_ms)
    end

    test "avg_duration_ms is nil when all durations are nil", %{pid: pid} do
      key = "chat|-|-|-|-"
      record(pid, key, :success, nil)
      record(pid, key, :success, nil)

      assert {:ok, [row]} = GenServer.call(pid, :list_fingerprints)
      assert is_nil(row.avg_duration_ms)
    end

    test "orders results by total descending", %{pid: pid} do
      record(pid, "a|-|-|-|-", :success, nil)
      for _ <- 1..3, do: record(pid, "b|-|-|-|-", :success, nil)

      assert {:ok, [first | _]} = GenServer.call(pid, :list_fingerprints)
      assert first.fingerprint_key == "b|-|-|-|-"
    end
  end

  describe "store_stats/0" do
    test "returns zeros for empty store", %{pid: pid} do
      assert {:ok, stats} = GenServer.call(pid, :store_stats)
      assert stats.total_records == 0
      assert stats.unique_fingerprints == 0
      assert is_nil(stats.oldest_ms)
      assert is_nil(stats.newest_ms)
    end

    test "counts total records and distinct fingerprints", %{pid: pid} do
      record(pid, "code|bash|-|-|-", :success, 1000)
      record(pid, "code|bash|-|-|-", :failure, 500)
      record(pid, "query|read|-|-|-", :success, 200)

      assert {:ok, stats} = GenServer.call(pid, :store_stats)
      assert stats.total_records == 3
      assert stats.unique_fingerprints == 2
      assert is_integer(stats.oldest_ms)
      assert is_integer(stats.newest_ms)
      assert stats.newest_ms >= stats.oldest_ms
    end
  end

  describe "min_sample_size/0" do
    test "returns a positive integer" do
      assert RoutingFeedbackStore.min_sample_size() > 0
    end
  end

  describe "record/3 public API" do
    test "returns :ok immediately (fire-and-forget)" do
      # Should not raise even if store isn't the named process
      result = RoutingFeedbackStore.record("fp_key", :success, 1000)
      assert result == :ok
    end
  end

  describe "best_model_for_context/1" do
    defp best_model(pid, context_key) do
      GenServer.call(pid, {:best_model_for_context, context_key})
    end

    test "returns :insufficient_data when no data exists", %{pid: pid} do
      assert {:insufficient_data, 0} = best_model(pid, "code|-|-")
    end

    test "returns :insufficient_data when below min_sample_size", %{pid: pid} do
      # 4 records < default min_sample_size of 5
      for _ <- 1..4, do: record(pid, "code|-|-|anthropic|claude-sonnet", :success)
      assert {:insufficient_data, 0} = best_model(pid, "code|-|-")
    end

    test "returns best model when threshold is met", %{pid: pid} do
      context = "code|-|/srv/app"

      # claude-sonnet: 5 successes
      for _ <- 1..5, do: record(pid, "#{context}|anthropic|claude-sonnet", :success)

      assert {:ok, "claude-sonnet"} = best_model(pid, context)
    end

    test "picks model with highest success rate when multiple models qualify", %{pid: pid} do
      context = "query|-|-"

      # model-a: 5 successes, 0 failures → 100%
      for _ <- 1..5, do: record(pid, "#{context}|p|model-a", :success)

      # model-b: 5 successes, 5 failures → 50%
      for _ <- 1..5, do: record(pid, "#{context}|p|model-b", :success)
      for _ <- 1..5, do: record(pid, "#{context}|p|model-b", :failure)

      assert {:ok, "model-a"} = best_model(pid, context)
    end

    test "aggregates across providers for the same model name", %{pid: pid} do
      context = "file_ops|-|-"

      # Same model name, two providers — combined: 10 records, 8 successes
      for _ <- 1..5, do: record(pid, "#{context}|provider-a|shared-model", :success)
      for _ <- 1..3, do: record(pid, "#{context}|provider-b|shared-model", :success)
      for _ <- 1..2, do: record(pid, "#{context}|provider-b|shared-model", :failure)

      assert {:ok, "shared-model"} = best_model(pid, context)
    end

    test "does not match fingerprints outside the context prefix", %{pid: pid} do
      # Records for a different context
      for _ <- 1..5, do: record(pid, "chat|-|-|p|gpt-4o", :success)

      # Querying for a different context should return no match
      assert {:insufficient_data, 0} = best_model(pid, "code|-|-")
    end

    test "ignores model '-' (unknown model) even if it has enough records", %{pid: pid} do
      context = "code|-|-"
      for _ <- 1..5, do: record(pid, "#{context}|-|-", :success)

      assert {:insufficient_data, 0} = best_model(pid, context)
    end
  end
end
