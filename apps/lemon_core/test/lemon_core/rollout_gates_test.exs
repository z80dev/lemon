defmodule LemonCore.RolloutGateTest do
  use ExUnit.Case, async: true

  alias LemonCore.RolloutGate

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

  describe "evaluate_routing_from_store/2 — passing cases" do
    test "passes with healthy store stats and fingerprints" do
      assert {:pass, notes} =
               RolloutGate.evaluate_routing_from_store(
                 @healthy_store_stats,
                 @healthy_fingerprints
               )

      assert Enum.any?(notes, &String.starts_with?(&1, "sample_size:"))
    end

    test "notes include sample count and unique fingerprints" do
      {:pass, notes} =
        RolloutGate.evaluate_routing_from_store(
          @healthy_store_stats,
          @healthy_fingerprints
        )

      assert Enum.any?(notes, &(&1 =~ "50"))
      assert Enum.any?(notes, &(&1 =~ "unique_fingerprints"))
    end
  end

  describe "evaluate_routing_from_store/2 — failing cases" do
    test "fails when sample size is below threshold" do
      assert {:fail, failures} =
               RolloutGate.evaluate_routing_from_store(
                 @small_store_stats,
                 @small_fingerprints
               )

      assert Enum.any?(failures, &(&1 =~ "sample_size"))
    end

    test "fails when success rate is too low" do
      assert {:fail, failures} =
               RolloutGate.evaluate_routing_from_store(
                 @low_success_store_stats,
                 @low_success_fingerprints
               )

      assert Enum.any?(failures, &(&1 =~ "success_rate"))
    end

    test "fails when failure rate is too high" do
      assert {:fail, failures} =
               RolloutGate.evaluate_routing_from_store(
                 @high_failure_store_stats,
                 @high_failure_fingerprints
               )

      assert Enum.any?(failures, &(&1 =~ ~r/failure_rate|success_rate/))
    end

    test "fails with empty fingerprints and zero sample size" do
      assert {:fail, _} = RolloutGate.evaluate_routing_from_store(%{total_records: 0}, [])
    end
  end

  # ── Synthesis gate tests ──────────────────────────────────────────────────────

  describe "evaluate_synthesis_from_run/1 — passing cases" do
    test "passes with healthy pipeline output" do
      assert {:pass, notes} = RolloutGate.evaluate_synthesis_from_run(@healthy_synthesis)
      assert Enum.any?(notes, &String.starts_with?(&1, "total_candidates:"))
    end

    test "notes include generation rate" do
      {:pass, notes} = RolloutGate.evaluate_synthesis_from_run(@healthy_synthesis)
      assert Enum.any?(notes, &(&1 =~ "generated_rate:"))
    end
  end

  describe "evaluate_synthesis_from_run/1 — failing cases" do
    test "fails when too few candidates processed" do
      assert {:fail, failures} = RolloutGate.evaluate_synthesis_from_run(@thin_synthesis)
      assert Enum.any?(failures, &(&1 =~ "candidates_processed"))
    end

    test "fails when audit block rate is too high" do
      assert {:fail, failures} = RolloutGate.evaluate_synthesis_from_run(@high_block_synthesis)
      assert Enum.any?(failures, &(&1 =~ "draft_block_rate"))
    end

    test "fails when generated rate is too low" do
      assert {:fail, failures} = RolloutGate.evaluate_synthesis_from_run(@low_gen_rate_synthesis)
      assert Enum.any?(failures, &(&1 =~ "generated_rate"))
    end

    test "fails with invalid input (missing total_candidates)" do
      assert {:fail, [msg]} =
               RolloutGate.evaluate_synthesis_from_run(%{generated: [], skipped: []})

      assert msg =~ "invalid_run_result"
    end
  end

  describe "public API" do
    test "does not expose the deprecated plural rollout module" do
      refute Code.ensure_loaded?(LemonCore.RolloutGates)
    end
  end
end
