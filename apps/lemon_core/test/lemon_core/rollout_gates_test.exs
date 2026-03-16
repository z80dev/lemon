defmodule LemonCore.RolloutGatesTest do
  use ExUnit.Case, async: true

  alias LemonCore.RolloutGates

  # ── Eval fixtures ────────────────────────────────────────────────────────────

  # Routing feedback — scenarios with enough samples and good success rates

  @healthy_store_stats %{total_records: 50, unique_fingerprints: 8}
  @healthy_fingerprints [
    %{total: 15, success_count: 13},
    %{total: 20, success_count: 18},
    %{total: 15, success_count: 12}
  ]

  @small_store_stats %{total_records: 10, unique_fingerprints: 3}
  @small_fingerprints [
    %{total: 6, success_count: 5},
    %{total: 4, success_count: 3}
  ]

  @low_success_store_stats %{total_records: 30, unique_fingerprints: 5}
  @low_success_fingerprints [
    %{total: 10, success_count: 4},
    %{total: 10, success_count: 3},
    %{total: 10, success_count: 4}
  ]

  @high_failure_store_stats %{total_records: 25, unique_fingerprints: 4}
  @high_failure_fingerprints [
    %{total: 10, success_count: 2},
    %{total: 15, success_count: 5}
  ]

  # Synthesis pipeline — run_result fixtures

  @healthy_synthesis %{
    total_candidates: 20,
    generated: Enum.map(1..8, fn i -> "synth-key-#{i}" end),
    skipped:
      Enum.map(9..12, fn i -> {"synth-key-#{i}", :already_exists} end) ++
        [{"synth-key-13", :blocked_by_audit}]
  }

  @thin_synthesis %{
    total_candidates: 3,
    generated: ["synth-key-1"],
    skipped: []
  }

  @high_block_synthesis %{
    total_candidates: 10,
    generated: ["synth-key-1"],
    skipped: Enum.map(2..10, fn i -> {"synth-key-#{i}", :blocked_by_audit} end)
  }

  @low_gen_rate_synthesis %{
    total_candidates: 20,
    generated: ["synth-key-1"],
    skipped: Enum.map(2..20, fn i -> {"synth-key-#{i}", :already_exists} end)
  }

  # ── Routing feedback gate tests ───────────────────────────────────────────────

  describe "evaluate_routing_feedback/2 — passing cases" do
    test "passes with healthy store stats and fingerprints" do
      assert {:pass, notes} = RolloutGates.evaluate_routing_feedback(
        @healthy_store_stats,
        @healthy_fingerprints
      )
      assert Enum.any?(notes, &String.starts_with?(&1, "sample_size:"))
    end

    test "notes include sample count and unique fingerprints" do
      {:pass, notes} = RolloutGates.evaluate_routing_feedback(
        @healthy_store_stats,
        @healthy_fingerprints
      )
      assert Enum.any?(notes, &(&1 =~ "50"))
      assert Enum.any?(notes, &(&1 =~ "unique_fingerprints"))
    end
  end

  describe "evaluate_routing_feedback/2 — failing cases" do
    test "fails when sample size is below threshold" do
      assert {:fail, failures} = RolloutGates.evaluate_routing_feedback(
        @small_store_stats,
        @small_fingerprints
      )
      assert Enum.any?(failures, &(&1 =~ "sample_size"))
    end

    test "fails when success rate is too low" do
      assert {:fail, failures} = RolloutGates.evaluate_routing_feedback(
        @low_success_store_stats,
        @low_success_fingerprints
      )
      assert Enum.any?(failures, &(&1 =~ "success_rate"))
    end

    test "fails when failure rate is too high" do
      assert {:fail, failures} = RolloutGates.evaluate_routing_feedback(
        @high_failure_store_stats,
        @high_failure_fingerprints
      )
      assert Enum.any?(failures, &(&1 =~ ~r/failure_rate|success_rate/))
    end

    test "fails with empty fingerprints and zero sample size" do
      assert {:fail, _} = RolloutGates.evaluate_routing_feedback(%{total_records: 0}, [])
    end
  end

  # ── Synthesis gate tests ──────────────────────────────────────────────────────

  describe "evaluate_synthesis/1 — passing cases" do
    test "passes with healthy pipeline output" do
      assert {:pass, notes} = RolloutGates.evaluate_synthesis(@healthy_synthesis)
      assert Enum.any?(notes, &String.starts_with?(&1, "total_candidates:"))
    end

    test "notes include generation rate" do
      {:pass, notes} = RolloutGates.evaluate_synthesis(@healthy_synthesis)
      assert Enum.any?(notes, &(&1 =~ "generated_rate:"))
    end
  end

  describe "evaluate_synthesis/1 — failing cases" do
    test "fails when too few candidates processed" do
      assert {:fail, failures} = RolloutGates.evaluate_synthesis(@thin_synthesis)
      assert Enum.any?(failures, &(&1 =~ "candidates_processed"))
    end

    test "fails when audit block rate is too high" do
      assert {:fail, failures} = RolloutGates.evaluate_synthesis(@high_block_synthesis)
      assert Enum.any?(failures, &(&1 =~ "draft_block_rate"))
    end

    test "fails when generated rate is too low" do
      assert {:fail, failures} = RolloutGates.evaluate_synthesis(@low_gen_rate_synthesis)
      assert Enum.any?(failures, &(&1 =~ "generated_rate"))
    end

    test "fails with invalid input (missing total_candidates)" do
      assert {:fail, [msg]} = RolloutGates.evaluate_synthesis(%{generated: [], skipped: []})
      assert msg =~ "invalid_run_result"
    end
  end

  # ── Gate threshold accessors ──────────────────────────────────────────────────

  describe "gate accessors" do
    test "routing_gates/0 returns expected keys" do
      gates = RolloutGates.routing_gates()
      assert Map.has_key?(gates, :min_sample_size)
      assert Map.has_key?(gates, :min_success_rate)
      assert Map.has_key?(gates, :max_failure_rate)
    end

    test "synthesis_gates/0 returns expected keys" do
      gates = RolloutGates.synthesis_gates()
      assert Map.has_key?(gates, :min_candidates_processed)
      assert Map.has_key?(gates, :max_draft_block_rate)
      assert Map.has_key?(gates, :min_generated_rate)
    end

    test "min_sample_size is at least 10" do
      assert RolloutGates.routing_gates().min_sample_size >= 10
    end

    test "max_draft_block_rate is between 0 and 1" do
      rate = RolloutGates.synthesis_gates().max_draft_block_rate
      assert rate > 0.0 and rate < 1.0
    end
  end
end
