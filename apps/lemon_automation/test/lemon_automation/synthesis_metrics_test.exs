defmodule LemonAutomation.SynthesisMetricsTest do
  # async: false — the metric rows live in the shared LemonCore.Store table.
  use ExUnit.Case, async: false

  alias LemonAutomation.SynthesisMetrics
  alias LemonCore.Store

  @table :synthesis_metrics

  setup do
    SynthesisMetrics.clear()
    on_exit(fn -> SynthesisMetrics.clear() end)
    {:ok, agent_id: "synmet-agent-#{System.unique_integer([:positive])}"}
  end

  defp run_result(opts) do
    %{
      generated: Keyword.get(opts, :generated, []),
      skipped: Keyword.get(opts, :skipped, []),
      total_candidates: Keyword.get(opts, :total_candidates, 0),
      latest_doc_ms: Keyword.get(opts, :latest_doc_ms)
    }
  end

  defp seed_row(attrs) do
    ts_ms = Keyword.fetch!(attrs, :ts_ms)
    id = "synmet_#{ts_ms}_#{System.unique_integer([:positive])}"

    row = %{
      id: id,
      ts_ms: ts_ms,
      agent_id: Keyword.get(attrs, :agent_id, "seed"),
      total_candidates: Keyword.get(attrs, :total_candidates, 0),
      generated: Keyword.get(attrs, :generated, 0),
      blocked_by_audit: Keyword.get(attrs, :blocked_by_audit, 0),
      skipped_other: Keyword.get(attrs, :skipped_other, 0),
      latest_doc_ms: Keyword.get(attrs, :latest_doc_ms),
      gate: Keyword.get(attrs, :gate, "fail")
    }

    Store.put(@table, id, row)
    row
  end

  describe "record_run/2" do
    test "maps a pipeline result onto a stored row", %{agent_id: agent_id} do
      result =
        run_result(
          generated: ["synth-a", "synth-b"],
          skipped: [{"blocked-one", :blocked_by_audit}, {"other-one", :already_exists}],
          total_candidates: 4,
          latest_doc_ms: 1_700_000_000_000
        )

      row = SynthesisMetrics.record_run(agent_id, result)

      assert row.agent_id == agent_id
      assert row.total_candidates == 4
      assert row.generated == 2
      assert row.blocked_by_audit == 1
      assert row.skipped_other == 1
      assert row.latest_doc_ms == 1_700_000_000_000
      assert row.gate in ["pass", "fail"]
      assert String.starts_with?(row.id, "synmet_")

      assert [stored] = SynthesisMetrics.list()
      assert stored.id == row.id
      assert stored.generated == 2
      assert stored.blocked_by_audit == 1
      assert stored.gate == row.gate
    end

    test "a string-keyed row round-trips through list/1" do
      ts_ms = LemonCore.Clock.now_ms()
      id = "synmet_#{ts_ms}_#{System.unique_integer([:positive])}"

      Store.put(@table, id, %{
        "id" => id,
        "ts_ms" => ts_ms,
        "agent_id" => "string-keys",
        "total_candidates" => 9,
        "generated" => 5,
        "blocked_by_audit" => 2,
        "skipped_other" => 2,
        "latest_doc_ms" => 42,
        "gate" => "fail"
      })

      assert [row] = SynthesisMetrics.list()
      assert row.agent_id == "string-keys"
      assert row.total_candidates == 9
      assert row.generated == 5
      assert row.blocked_by_audit == 2
      assert row.latest_doc_ms == 42
    end

    test "list/1 is newest-first and honours :limit" do
      seed_row(ts_ms: 1_000)
      seed_row(ts_ms: 3_000)
      seed_row(ts_ms: 2_000)

      assert [a, b, c] = SynthesisMetrics.list()
      assert [a.ts_ms, b.ts_ms, c.ts_ms] == [3_000, 2_000, 1_000]

      assert [only] = SynthesisMetrics.list(limit: 1)
      assert only.ts_ms == 3_000
    end
  end

  describe "aggregate/0" do
    test "sums rows and counts audit-blocked drafts as generated-then-blocked" do
      seed_row(ts_ms: 1_000, total_candidates: 10, generated: 6, blocked_by_audit: 1)
      seed_row(ts_ms: 2_000, total_candidates: 5, generated: 3, blocked_by_audit: 0)

      assert SynthesisMetrics.aggregate() == %{
               total_candidates: 15,
               # kept (6+3) + blocked (1+0)
               generated: 10,
               blocked_by_audit: 1
             }
    end

    test "empty table aggregates to zeroes" do
      assert SynthesisMetrics.aggregate() == %{
               total_candidates: 0,
               generated: 0,
               blocked_by_audit: 0
             }
    end
  end

  describe "gate_status/0" do
    test "returns :no_data with no recorded rows" do
      assert SynthesisMetrics.gate_status() == :no_data
    end

    test "returns :not_ready with reasons below the thresholds" do
      seed_row(ts_ms: 1_000, total_candidates: 5, generated: 1, blocked_by_audit: 0)

      assert {:not_ready, reasons, computed} = SynthesisMetrics.gate_status()
      assert computed.total_candidates == 5
      assert Enum.any?(reasons, &String.contains?(&1, "candidate_count"))
      assert Enum.any?(reasons, &String.contains?(&1, "generation_rate"))
    end

    test "returns :ready once the aggregate clears the thresholds" do
      # 25 candidates, 20 generated drafts of which 1 was blocked by audit.
      seed_row(ts_ms: 1_000, total_candidates: 25, generated: 19, blocked_by_audit: 1)

      assert {:ready, computed} = SynthesisMetrics.gate_status()
      assert computed.total_candidates == 25
      assert computed.generated == 20
      assert computed.blocked_by_audit == 1
      assert computed.generation_rate == 0.8
      assert computed.false_positive_rate == 0.05
    end
  end

  describe "pruning" do
    test "keeps only the newest 500 rows", %{agent_id: agent_id} do
      for i <- 1..509 do
        seed_row(ts_ms: i, total_candidates: 1, generated: 1)
      end

      assert length(Store.list(@table)) == 509

      # The 510th row triggers the prune down to the cap.
      SynthesisMetrics.record_run(agent_id, run_result(total_candidates: 1, generated: ["k"]))

      assert length(Store.list(@table)) == 500

      rows = SynthesisMetrics.list()
      assert length(rows) == 500
      # The ten oldest seeded rows (ts_ms 1..10) were dropped.
      assert rows |> Enum.map(& &1.ts_ms) |> Enum.min() == 11
    end
  end
end
