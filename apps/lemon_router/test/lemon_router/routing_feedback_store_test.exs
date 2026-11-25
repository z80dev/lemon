defmodule LemonRouter.RoutingFeedbackStoreTest do
  use ExUnit.Case, async: false

  alias LemonRouter.RoutingFeedbackStore

  # Start a per-test store backed by a fresh temp database.
  # These cases exercise explicit calls, so do not also consume process-wide Bus events.
  setup do
    dir = System.tmp_dir!() |> Path.join("rfs_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    pid =
      start_supervised!({RoutingFeedbackStore, path: dir, subscribe?: false, name: nil})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{pid: pid}
  end

  defp record(pid, key, outcome, duration_ms \\ nil) do
    GenServer.cast(pid, {:record, key, Atom.to_string(outcome), duration_ms})
    # Flush the cast: a call from the same process is handled after it
    :sys.get_state(pid)
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

  describe "best_model_for_context/2" do
    defp best_model(pid, context_key, default_model \\ nil) do
      GenServer.call(pid, {:best_model_for_context, context_key, default_model})
    end

    defp record_n(pid, key, outcome, n), do: for(_ <- 1..n, do: record(pid, key, outcome))

    test "keeps the default when no data exists", %{pid: pid} do
      assert :keep_default = best_model(pid, "code|-|-")
    end

    test "keeps the default below min_sample_size", %{pid: pid} do
      # 4 records < default min_sample_size of 5
      record_n(pid, "code|-|-|anthropic|claude-sonnet", :success, 4)
      assert :keep_default = best_model(pid, "code|-|-")
    end

    test "suggests a qualified model when no default is configured", %{pid: pid} do
      context = "code|-|/srv/app"
      record_n(pid, "#{context}|anthropic|claude-sonnet", :success, 5)

      assert {:ok, "claude-sonnet"} = best_model(pid, context)
    end

    test "picks model with highest success rate when multiple models qualify", %{pid: pid} do
      context = "query|-|-"
      record_n(pid, "#{context}|p|model-a", :success, 5)
      record_n(pid, "#{context}|p|model-b", :success, 9)
      record_n(pid, "#{context}|p|model-b", :failure, 1)

      assert {:ok, "model-a"} = best_model(pid, context)
    end

    test "never suggests a model below the success-rate floor", %{pid: pid} do
      context = "query|-|/floor"
      # A model that has since died: plenty of samples, mostly failures.
      record_n(pid, "#{context}|p|dead-model", :success, 5)
      record_n(pid, "#{context}|p|dead-model", :failure, 20)

      assert :keep_default = best_model(pid, context)
      assert :keep_default = best_model(pid, context, "p:other-model")
    end

    test "keeps a default that has no samples in this context", %{pid: pid} do
      context = "code|-|/changed-default"
      record_n(pid, "#{context}|openai|model-a", :success, 5)

      assert :keep_default = best_model(pid, context, "openai:model-b")
    end

    test "keeps a default that is itself the best model", %{pid: pid} do
      context = "code|-|/default-best"
      record_n(pid, "#{context}|openai|model-a", :success, 5)

      for default <- ["model-a", "openai:model-a", "openai/model-a"] do
        assert :keep_default = best_model(pid, context, default)
      end
    end

    test "suggests a model only when the measured default did worse", %{pid: pid} do
      context = "code|-|/default-worse"
      record_n(pid, "#{context}|openai|model-b", :success, 4)
      record_n(pid, "#{context}|openai|model-b", :failure, 1)
      record_n(pid, "#{context}|openai|model-c", :success, 5)

      assert {:ok, "model-c"} = best_model(pid, context, "openai:model-b")

      record_n(pid, "#{context}|openai|model-c", :failure, 1)
      record_n(pid, "#{context}|openai|model-b", :success, 1)
      assert :keep_default = best_model(pid, context, "openai:model-b")
    end

    test "aggregates across providers for the same model name", %{pid: pid} do
      context = "file_ops|-|-"

      # Same model name, two providers — combined: 10 records, 8 successes
      record_n(pid, "#{context}|provider-a|shared-model", :success, 5)
      record_n(pid, "#{context}|provider-b|shared-model", :success, 3)
      record_n(pid, "#{context}|provider-b|shared-model", :failure, 2)

      assert {:ok, "shared-model"} = best_model(pid, context)
    end

    test "does not match fingerprints outside the context prefix", %{pid: pid} do
      record_n(pid, "chat|-|-|p|gpt-4o", :success, 5)
      record_n(pid, "code|-|-x|p|gpt-4o", :success, 5)

      assert :keep_default = best_model(pid, "code|-|-")
    end

    test "ignores model '-' (unknown model) even if it has enough records", %{pid: pid} do
      context = "code|-|-"
      record_n(pid, "#{context}|-|-", :success, 5)
      record_n(pid, "#{context}|p|known", :success, 4)
      record_n(pid, "#{context}|p|known", :failure, 1)

      assert {:ok, "known"} = best_model(pid, context)
    end

    test "LIKE metacharacters in the context key match only literally", %{pid: pid} do
      record_n(pid, "code|-|/project_foo|p|model-a", :success, 5)
      record_n(pid, "code|-|/tmp/doneXnow|p|model-b", :success, 5)

      assert :keep_default = best_model(pid, "code|-|/proj%")
      assert :keep_default = best_model(pid, "code|-|/tmp/done_now")

      context = "code|-|/tmp/100%_done"
      record_n(pid, "#{context}|p|model-pct", :success, 5)
      assert {:ok, "model-pct"} = best_model(pid, context)
    end
  end
end
