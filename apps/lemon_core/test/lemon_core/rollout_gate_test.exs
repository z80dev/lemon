defmodule LemonCore.RolloutGateTest do
  @moduledoc """
  Eval fixtures for the rollout gate module (M7-03).

  Each describe block is a named fixture — a realistic operational scenario
  with known inputs and an expected gate decision.  All tests are deterministic
  (no GenServer, no file I/O) so they run anywhere without setup.

  ## Fixture catalogue

  ### routing_feedback gates

  | Fixture | Samples | Success Δ | Retry Δ | Expected |
  |---------|---------|-----------|---------|----------|
  | not_enough_samples | 30 | +0.10 | -0.05 | not_ready (sample_size) |
  | insufficient_delta | 60 | +0.02 | -0.02 | not_ready (success_delta) |
  | retry_regression | 60 | +0.10 | +0.08 | not_ready (retry_delta) |
  | multiple_failures | 10 | -0.05 | +0.10 | not_ready (sample_size + success_delta + retry_delta) |
  | borderline | 50 | +0.05 | 0.0 | ready |
  | healthy | 65 | +0.08 | -0.04 | ready |

  ### skill_synthesis_drafts gates

  | Fixture | Candidates | Generated | Blocked | Expected |
  |---------|------------|-----------|---------|----------|
  | no_candidates | 0 | 0 | 0 | not_ready (candidate_count + generation_rate) |
  | too_few_candidates | 15 | 12 | 0 | not_ready (candidate_count) |
  | low_generation_rate | 25 | 10 | 0 | not_ready (generation_rate) |
  | high_fp_rate | 25 | 20 | 4 | not_ready (false_positive_rate) |
  | all_gates_failing | 5 | 2 | 1 | not_ready (all three) |
  | borderline | 20 | 12 | 1 | ready |
  | healthy | 30 | 24 | 2 | ready |
  """
  use ExUnit.Case, async: true

  alias LemonCore.RolloutGate

  # ── Threshold constants ────────────────────────────────────────────────────

  describe "routing_feedback threshold constants" do
    test "routing_min_samples is 50" do
      assert RolloutGate.routing_min_samples() == 50
    end

    test "routing_min_success_delta is 0.05" do
      assert RolloutGate.routing_min_success_delta() == 0.05
    end

    test "routing_max_retry_delta_abs is 0.05" do
      assert RolloutGate.routing_max_retry_delta_abs() == 0.05
    end
  end

  describe "skill_synthesis_drafts threshold constants" do
    test "synthesis_min_candidates is 20" do
      assert RolloutGate.synthesis_min_candidates() == 20
    end

    test "synthesis_min_generation_rate is 0.60" do
      assert RolloutGate.synthesis_min_generation_rate() == 0.60
    end

    test "synthesis_max_fp_rate is 0.10" do
      assert RolloutGate.synthesis_max_fp_rate() == 0.10
    end
  end

  # ── routing_feedback eval fixtures ────────────────────────────────────────

  describe "routing_feedback — fixture: not_enough_samples (30 runs, good delta)" do
    # 30 runs recorded — well below the 50-sample minimum.
    # Success rate is fine (+10pp) but the gate should block on sample size alone.
    @fixture %{
      total_samples: 30,
      success_rate: 0.75,
      baseline_success_rate: 0.65,
      retry_rate: 0.10,
      baseline_retry_rate: 0.15
    }

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
    end

    test "sample_size gate is the only failing reason" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert length(reasons) == 1
      assert Enum.any?(reasons, &String.contains?(&1, "sample_size"))
    end

    test "computed metrics include sample count" do
      {:not_ready, _, metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert metrics.total_samples == 30
    end
  end

  describe "routing_feedback — fixture: insufficient_delta (60 runs, +2pp delta)" do
    # 60 runs — enough samples. But success delta is only +2pp (below +5pp threshold).
    @fixture %{
      total_samples: 60,
      success_rate: 0.62,
      baseline_success_rate: 0.60,
      retry_rate: 0.12,
      baseline_retry_rate: 0.14
    }

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
    end

    test "success_delta gate is the failing reason" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert Enum.any?(reasons, &String.contains?(&1, "success_delta"))
    end

    test "computed success_delta is approximately 0.02" do
      {:not_ready, _, metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert_in_delta metrics.success_delta, 0.02, 0.001
    end
  end

  describe "routing_feedback — fixture: retry_regression (60 runs, +8pp retry increase)" do
    # 60 runs, success rate improved a lot (+15pp), but retry rate jumped by +8pp.
    # The retry_delta gate blocks graduation even though success looks great.
    @fixture %{
      total_samples: 60,
      success_rate: 0.75,
      baseline_success_rate: 0.60,
      retry_rate: 0.20,
      baseline_retry_rate: 0.12
    }

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
    end

    test "retry_delta gate is the failing reason" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert Enum.any?(reasons, &String.contains?(&1, "retry_delta"))
    end

    test "success_delta gate passes despite overall not_ready" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_routing_feedback(@fixture)
      refute Enum.any?(reasons, &String.contains?(&1, "success_delta"))
    end
  end

  describe "routing_feedback — fixture: multiple_failures (10 runs, worse on all)" do
    # Only 10 runs, success rate dropped, retry rate increased — all three gates fail.
    @fixture %{
      total_samples: 10,
      success_rate: 0.55,
      baseline_success_rate: 0.60,
      retry_rate: 0.20,
      baseline_retry_rate: 0.10
    }

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
    end

    test "all three gates fail" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert length(reasons) == 3
      assert Enum.any?(reasons, &String.contains?(&1, "sample_size"))
      assert Enum.any?(reasons, &String.contains?(&1, "success_delta"))
      assert Enum.any?(reasons, &String.contains?(&1, "retry_delta"))
    end
  end

  describe "routing_feedback — fixture: borderline (exactly at thresholds)" do
    # Exactly 50 samples, exactly +0.05 success delta, exactly 0.0 retry change.
    # All gates should pass at the boundary (inclusive thresholds).
    @fixture %{
      total_samples: 50,
      success_rate: 0.65,
      baseline_success_rate: 0.60,
      retry_rate: 0.10,
      baseline_retry_rate: 0.10
    }

    test "gate returns ready at exact threshold values" do
      assert {:ready, _metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
    end

    test "computed success_delta is exactly 0.05" do
      {:ready, metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert_in_delta metrics.success_delta, 0.05, 0.001
    end

    test "computed retry_delta is exactly 0.0" do
      {:ready, metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert_in_delta metrics.retry_delta, 0.0, 0.001
    end
  end

  describe "routing_feedback — fixture: healthy (65 runs, +8pp delta, retry improved)" do
    # 65 runs, success improved 8pp, retry rate dropped 4pp — clearly ready.
    @fixture %{
      total_samples: 65,
      success_rate: 0.68,
      baseline_success_rate: 0.60,
      retry_rate: 0.09,
      baseline_retry_rate: 0.13
    }

    test "gate returns ready" do
      assert {:ready, _metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
    end

    test "computed metrics include all expected keys" do
      {:ready, metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert Map.has_key?(metrics, :total_samples)
      assert Map.has_key?(metrics, :success_rate)
      assert Map.has_key?(metrics, :baseline_success_rate)
      assert Map.has_key?(metrics, :success_delta)
      assert Map.has_key?(metrics, :retry_delta)
    end

    test "success_delta is positive and retry_delta is negative (improvement)" do
      {:ready, metrics} = RolloutGate.evaluate_routing_feedback(@fixture)
      assert metrics.success_delta > 0
      assert metrics.retry_delta < 0
    end
  end

  # ── skill_synthesis_drafts eval fixtures ──────────────────────────────────

  describe "synthesis — fixture: no_candidates (empty pipeline run)" do
    # Zero candidates — pipeline produced nothing.  Two gates fail:
    # candidate_count (0 < 20) and generation_rate (0/0 = 0.0 < 0.60).
    @fixture %{total_candidates: 0, generated: 0, blocked_by_audit: 0}

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_synthesis(@fixture)
    end

    test "candidate_count and generation_rate gates fail" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_synthesis(@fixture)
      assert Enum.any?(reasons, &String.contains?(&1, "candidate_count"))
      assert Enum.any?(reasons, &String.contains?(&1, "generation_rate"))
    end

    test "generation_rate is 0.0 — no divide-by-zero" do
      {:not_ready, _, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert metrics.generation_rate == 0.0
    end

    test "false_positive_rate is 0.0 — no divide-by-zero" do
      {:not_ready, _, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert metrics.false_positive_rate == 0.0
    end
  end

  describe "synthesis — fixture: too_few_candidates (15 candidates, good rate)" do
    # 15 candidates, 12 generated (80% rate), none blocked — only the count gate fails.
    @fixture %{total_candidates: 15, generated: 12, blocked_by_audit: 0}

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_synthesis(@fixture)
    end

    test "candidate_count is the only failing gate" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_synthesis(@fixture)
      assert length(reasons) == 1
      assert Enum.any?(reasons, &String.contains?(&1, "candidate_count"))
    end
  end

  describe "synthesis — fixture: low_generation_rate (25 candidates, 40% drafted)" do
    # 25 candidates, only 10 drafted — 40% is below the 60% threshold.
    @fixture %{total_candidates: 25, generated: 10, blocked_by_audit: 0}

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_synthesis(@fixture)
    end

    test "generation_rate gate is the failing reason" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_synthesis(@fixture)
      assert Enum.any?(reasons, &String.contains?(&1, "generation_rate"))
    end

    test "computed generation_rate is 0.4" do
      {:not_ready, _, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert_in_delta metrics.generation_rate, 0.4, 0.001
    end
  end

  describe "synthesis — fixture: high_fp_rate (25 candidates, 20% audit blocks)" do
    # 25 candidates, 20 drafted, 4 blocked by audit — 20% FP rate exceeds 10% limit.
    @fixture %{total_candidates: 25, generated: 20, blocked_by_audit: 4}

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_synthesis(@fixture)
    end

    test "false_positive_rate gate is the failing reason" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_synthesis(@fixture)
      assert Enum.any?(reasons, &String.contains?(&1, "false_positive_rate"))
    end

    test "candidate_count and generation_rate gates pass" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_synthesis(@fixture)
      refute Enum.any?(reasons, &String.contains?(&1, "candidate_count"))
      refute Enum.any?(reasons, &String.contains?(&1, "generation_rate"))
    end

    test "computed fp_rate is 0.20" do
      {:not_ready, _, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert_in_delta metrics.false_positive_rate, 0.20, 0.001
    end
  end

  describe "synthesis — fixture: all_gates_failing (5 candidates, 40% rate, 50% FP)" do
    # 5 candidates (too few), 2 drafted (40%), 1 blocked (50% FP) — everything fails.
    @fixture %{total_candidates: 5, generated: 2, blocked_by_audit: 1}

    test "gate returns not_ready" do
      assert {:not_ready, _reasons, _metrics} = RolloutGate.evaluate_synthesis(@fixture)
    end

    test "all three gates fail" do
      {:not_ready, reasons, _} = RolloutGate.evaluate_synthesis(@fixture)
      assert length(reasons) == 3
      assert Enum.any?(reasons, &String.contains?(&1, "candidate_count"))
      assert Enum.any?(reasons, &String.contains?(&1, "generation_rate"))
      assert Enum.any?(reasons, &String.contains?(&1, "false_positive_rate"))
    end
  end

  describe "synthesis — fixture: borderline (exactly at thresholds)" do
    # Exactly 20 candidates, 12 drafted (60.0%), 1 blocked (8.3% ≤ 10%) — all gates pass.
    @fixture %{total_candidates: 20, generated: 12, blocked_by_audit: 1}

    test "gate returns ready at exact threshold values" do
      assert {:ready, _metrics} = RolloutGate.evaluate_synthesis(@fixture)
    end

    test "generation_rate is exactly 0.60" do
      {:ready, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert_in_delta metrics.generation_rate, 0.60, 0.001
    end

    test "false_positive_rate is below 0.10" do
      {:ready, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert metrics.false_positive_rate < 0.10
    end
  end

  describe "synthesis — fixture: healthy (30 candidates, 80% drafted, 8% FP)" do
    # 30 candidates, 24 drafted, 2 blocked — generation rate 80%, FP rate 8.3%.
    @fixture %{total_candidates: 30, generated: 24, blocked_by_audit: 2}

    test "gate returns ready" do
      assert {:ready, _metrics} = RolloutGate.evaluate_synthesis(@fixture)
    end

    test "computed metrics include all expected keys" do
      {:ready, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert Map.has_key?(metrics, :total_candidates)
      assert Map.has_key?(metrics, :generated)
      assert Map.has_key?(metrics, :blocked_by_audit)
      assert Map.has_key?(metrics, :generation_rate)
      assert Map.has_key?(metrics, :false_positive_rate)
    end

    test "generation_rate is approximately 0.80" do
      {:ready, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert_in_delta metrics.generation_rate, 0.80, 0.001
    end

    test "false_positive_rate is approximately 0.083" do
      {:ready, metrics} = RolloutGate.evaluate_synthesis(@fixture)
      assert_in_delta metrics.false_positive_rate, 0.0833, 0.001
    end
  end
end
