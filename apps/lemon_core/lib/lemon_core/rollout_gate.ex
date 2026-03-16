defmodule LemonCore.RolloutGate do
  @moduledoc """
  Measurable graduation gates for adaptive features.

  Defines the quantitative thresholds that must be satisfied before a feature
  flag can be promoted from `opt-in` to `default-on`.  The gates are evaluated
  against metrics snapshots — they do not read the database directly.

  ## Covered features

  ### `:routing_feedback` (M7-01)

  History-aware model selection is safe to enable by default when **all** of:

  1. **Sample size ≥ #{@routing_min_samples}** — enough recorded runs to trust
     aggregated statistics.  Below this threshold the store returns
     `{:insufficient_data, _}` and the router falls back to profile defaults.
  2. **Success delta ≥ +#{@routing_min_success_delta}** — the history-preferred
     model improves the observed success rate by at least 5 percentage points
     compared to the session-default model on the same task fingerprint family.
  3. **Retry delta ≤ +#{@routing_max_retry_delta_abs}** — the retry rate has not
     *increased* (or has actively decreased) by more than the tolerance.

  ### `:skill_synthesis_drafts` (M7-02)

  Automated skill draft generation is safe to enable by default when **all** of:

  1. **Candidate count ≥ #{@synthesis_min_candidates}** — enough memory
     documents evaluated to judge pipeline breadth and quality.
  2. **Generation rate ≥ #{@synthesis_min_generation_rate}** — at least 60 % of
     qualified candidates produce a written draft (pipeline is not over-filtering
     or crashing silently).
  3. **False-positive rate ≤ #{@synthesis_max_fp_rate}** — at most 10 % of
     generated drafts are blocked by the audit engine (content safety is working
     correctly and not blocking legitimate skill patterns).

  ## Rollback procedure

  If a feature is promoted to `default-on` and unexpected behaviour is observed:

  1. **Immediate kill-switch**: set the flag to `"off"` in
     `~/.lemon/config.toml` or via environment variable:

         echo 'routing_feedback = "off"' >> ~/.lemon/config.toml
         # or
         export LEMON_FEATURE_ROUTING_FEEDBACK=off

  2. **Restart** the Lemon agent process (or run `mix lemon.setup` to reload
     config in a live system).

  3. **No data migration required** — the routing feedback store and draft store
     are read-only from the feature gate's perspective.  Disabling a feature
     stops new data from being written but does not delete existing records.

  4. **Re-evaluation**: after rollback, investigate the feedback store via
     `LemonCore.RoutingFeedbackReport.list_all/1` or the draft store via
     `mix lemon.skill draft list`.  Re-run `evaluate_routing_feedback/1` or
     `evaluate_synthesis/1` with fresh metrics before re-enabling.

  ## Usage

      metrics = %{
        total_samples: 65,
        success_rate: 0.72,
        baseline_success_rate: 0.62,
        retry_rate: 0.09,
        baseline_retry_rate: 0.13
      }

      case LemonCore.RolloutGate.evaluate_routing_feedback(metrics) do
        {:ready, computed} ->
          IO.puts("Gate passed — promote routing_feedback to default-on")
          IO.inspect(computed)

        {:not_ready, reasons, computed} ->
          IO.puts("Gate blocked:\\n" <> Enum.join(reasons, "\\n"))
          IO.inspect(computed)
      end
  """

  @routing_min_samples 50
  @routing_min_success_delta 0.05
  @routing_max_retry_delta_abs 0.05

  @synthesis_min_candidates 20
  @synthesis_min_generation_rate 0.60
  @synthesis_max_fp_rate 0.10

  # ── Store-based (aggregated) thresholds — used by evaluate_routing_from_store/2
  # and evaluate_synthesis_from_run/1.  These functions accept the raw output of
  # RoutingFeedbackStore / Synthesis.Pipeline rather than pre-computed deltas.
  @store_routing_min_sample_size 20
  @store_routing_min_success_rate 0.60
  @store_routing_max_failure_rate 0.20

  @store_synthesis_min_candidates 5
  @store_synthesis_max_block_rate 0.50
  @store_synthesis_min_gen_rate 0.20

  # ── Types ──────────────────────────────────────────────────────────────────

  @type routing_metrics :: %{
          total_samples: non_neg_integer(),
          success_rate: float(),
          baseline_success_rate: float(),
          retry_rate: float(),
          baseline_retry_rate: float()
        }

  @type synthesis_metrics :: %{
          total_candidates: non_neg_integer(),
          generated: non_neg_integer(),
          blocked_by_audit: non_neg_integer()
        }

  @type computed_routing :: %{
          total_samples: non_neg_integer(),
          success_rate: float(),
          baseline_success_rate: float(),
          success_delta: float(),
          retry_delta: float()
        }

  @type computed_synthesis :: %{
          total_candidates: non_neg_integer(),
          generated: non_neg_integer(),
          blocked_by_audit: non_neg_integer(),
          generation_rate: float(),
          false_positive_rate: float()
        }

  @type gate_result(computed) ::
          {:ready, computed}
          | {:not_ready, [String.t()], computed}

  # ── Threshold accessors ────────────────────────────────────────────────────

  @doc "Minimum recorded runs before `:routing_feedback` can graduate to `default-on`."
  @spec routing_min_samples() :: pos_integer()
  def routing_min_samples, do: @routing_min_samples

  @doc "Minimum success-rate improvement (fractional) for `:routing_feedback` to graduate."
  @spec routing_min_success_delta() :: float()
  def routing_min_success_delta, do: @routing_min_success_delta

  @doc "Maximum allowed retry-rate increase (fractional) for `:routing_feedback` to graduate."
  @spec routing_max_retry_delta_abs() :: float()
  def routing_max_retry_delta_abs, do: @routing_max_retry_delta_abs

  @doc "Minimum candidate documents evaluated before `:skill_synthesis_drafts` can graduate."
  @spec synthesis_min_candidates() :: pos_integer()
  def synthesis_min_candidates, do: @synthesis_min_candidates

  @doc "Minimum fraction of candidates that must produce a written draft."
  @spec synthesis_min_generation_rate() :: float()
  def synthesis_min_generation_rate, do: @synthesis_min_generation_rate

  @doc "Maximum fraction of generated drafts that may be blocked by the audit engine."
  @spec synthesis_max_fp_rate() :: float()
  def synthesis_max_fp_rate, do: @synthesis_max_fp_rate

  # ── Gate evaluation ────────────────────────────────────────────────────────

  @doc """
  Evaluate the rollout gate for the `:routing_feedback` feature.

  Takes a metrics snapshot and checks all three graduation gates.

  ## Parameters

  - `metrics` — map with keys:
    - `:total_samples` — total runs recorded in the feedback store
    - `:success_rate` — observed success rate with history-preferred routing
    - `:baseline_success_rate` — success rate without history-preferred routing
    - `:retry_rate` — observed retry rate with history-preferred routing
    - `:baseline_retry_rate` — retry rate without history-preferred routing

  ## Returns

      {:ready, computed}           # all gates pass — safe to promote
      {:not_ready, reasons, computed}  # one or more gates failed
  """
  @spec evaluate_routing_feedback(routing_metrics()) :: gate_result(computed_routing())
  def evaluate_routing_feedback(%{} = metrics) do
    total = metrics.total_samples
    success_delta = metrics.success_rate - metrics.baseline_success_rate
    retry_delta = metrics.retry_rate - metrics.baseline_retry_rate

    computed = %{
      total_samples: total,
      success_rate: metrics.success_rate,
      baseline_success_rate: metrics.baseline_success_rate,
      success_delta: Float.round(success_delta, 4),
      retry_delta: Float.round(retry_delta, 4)
    }

    reasons =
      []
      |> check(
        total >= @routing_min_samples,
        "sample_size: need ≥#{@routing_min_samples} samples, have #{total}"
      )
      |> check(
        success_delta >= @routing_min_success_delta,
        "success_delta: need ≥+#{@routing_min_success_delta}, " <>
          "have #{Float.round(success_delta, 4)}"
      )
      |> check(
        retry_delta <= @routing_max_retry_delta_abs,
        "retry_delta: must be ≤+#{@routing_max_retry_delta_abs}, " <>
          "have #{Float.round(retry_delta, 4)}"
      )

    result(reasons, computed)
  end

  @doc """
  Evaluate the rollout gate for the `:skill_synthesis_drafts` feature.

  Takes a metrics snapshot and checks all three graduation gates.

  ## Parameters

  - `metrics` — map with keys:
    - `:total_candidates` — candidate documents evaluated by the pipeline
    - `:generated` — drafts successfully written to the draft store
    - `:blocked_by_audit` — generated drafts blocked by the audit engine

  ## Returns

      {:ready, computed}           # all gates pass — safe to promote
      {:not_ready, reasons, computed}  # one or more gates failed
  """
  @spec evaluate_synthesis(synthesis_metrics()) :: gate_result(computed_synthesis())
  def evaluate_synthesis(%{} = metrics) do
    total = metrics.total_candidates
    generated = metrics.generated
    blocked = metrics.blocked_by_audit

    generation_rate = if total > 0, do: generated / total, else: 0.0
    fp_rate = if generated > 0, do: blocked / generated, else: 0.0

    computed = %{
      total_candidates: total,
      generated: generated,
      blocked_by_audit: blocked,
      generation_rate: Float.round(generation_rate, 4),
      false_positive_rate: Float.round(fp_rate, 4)
    }

    reasons =
      []
      |> check(
        total >= @synthesis_min_candidates,
        "candidate_count: need ≥#{@synthesis_min_candidates} candidates, have #{total}"
      )
      |> check(
        generation_rate >= @synthesis_min_generation_rate,
        "generation_rate: need ≥#{@synthesis_min_generation_rate}, " <>
          "have #{Float.round(generation_rate, 4)}"
      )
      |> check(
        fp_rate <= @synthesis_max_fp_rate,
        "false_positive_rate: must be ≤#{@synthesis_max_fp_rate}, " <>
          "have #{Float.round(fp_rate, 4)}"
      )

    result(reasons, computed)
  end

  # ── Store-based evaluation (aggregated input format) ───────────────────────

  @doc """
  Evaluate the `:routing_feedback` gate from raw store data.

  Unlike `evaluate_routing_feedback/1`, this variant accepts the output of
  `RoutingFeedbackStore.store_stats/0` and `RoutingFeedbackStore.list_fingerprints/0`
  directly, using absolute success/failure rate thresholds instead of deltas.

  Returns `{:pass, notes}` or `{:fail, failures}`.
  """
  @spec evaluate_routing_from_store(map(), [map()]) ::
          {:pass, [String.t()]} | {:fail, [String.t()]}
  def evaluate_routing_from_store(store_stats, fingerprints)
      when is_map(store_stats) and is_list(fingerprints) do
    total = Map.get(store_stats, :total_records, 0)
    {agg_total, agg_success, agg_failure} = aggregate_fingerprints(fingerprints)

    failures =
      []
      |> check_store(
        total >= @store_routing_min_sample_size,
        "sample_size: #{total} < #{@store_routing_min_sample_size} (need more recorded runs)"
      )

    failures =
      if agg_total > 0 do
        success_rate = agg_success / agg_total
        failure_rate = agg_failure / agg_total

        failures
        |> check_store(
          success_rate >= @store_routing_min_success_rate,
          "success_rate: #{Float.round(success_rate, 3)} < #{@store_routing_min_success_rate}"
        )
        |> check_store(
          failure_rate <= @store_routing_max_failure_rate,
          "failure_rate: #{Float.round(failure_rate, 3)} > #{@store_routing_max_failure_rate}"
        )
      else
        failures
      end

    case failures do
      [] ->
        {:pass,
         [
           "sample_size: #{total} >= #{@store_routing_min_sample_size}",
           "unique_fingerprints: #{Map.get(store_stats, :unique_fingerprints, 0)}"
         ]}

      _ ->
        {:fail, Enum.reverse(failures)}
    end
  end

  @doc """
  Evaluate the `:skill_synthesis_drafts` gate from a pipeline run result.

  Unlike `evaluate_synthesis/1`, this variant accepts the structured output of
  `LemonSkills.Synthesis.Pipeline.run/3` (with `generated` as a list of keys and
  `skipped` as a list of `{key, reason}` tuples) rather than pre-counted integers.

  Returns `{:pass, notes}` or `{:fail, failures}`.
  """
  @spec evaluate_synthesis_from_run(map()) :: {:pass, [String.t()]} | {:fail, [String.t()]}
  def evaluate_synthesis_from_run(%{total_candidates: total} = run_result)
      when is_integer(total) do
    generated = length(Map.get(run_result, :generated, []))
    skipped = Map.get(run_result, :skipped, [])
    blocked = Enum.count(skipped, fn {_key, reason} -> reason == :blocked_by_audit end)

    gen_rate = if total > 0, do: generated / total, else: 0.0
    block_rate = if total > 0, do: blocked / total, else: 0.0

    failures =
      []
      |> check_store(
        total >= @store_synthesis_min_candidates,
        "candidates_processed: #{total} < #{@store_synthesis_min_candidates}"
      )
      |> check_store(
        block_rate <= @store_synthesis_max_block_rate,
        "draft_block_rate: #{Float.round(block_rate, 3)} > #{@store_synthesis_max_block_rate} (too many candidates blocked by audit)"
      )
      |> check_store(
        gen_rate >= @store_synthesis_min_gen_rate,
        "generated_rate: #{Float.round(gen_rate, 3)} < #{@store_synthesis_min_gen_rate} (too few candidates produce stored drafts)"
      )

    case failures do
      [] ->
        {:pass,
         [
           "total_candidates: #{total}",
           "generated: #{generated}",
           "generated_rate: #{Float.round(gen_rate, 3)}"
         ]}

      _ ->
        {:fail, Enum.reverse(failures)}
    end
  end

  def evaluate_synthesis_from_run(_), do: {:fail, ["invalid_run_result: missing total_candidates"]}

  # ── Private ────────────────────────────────────────────────────────────────

  defp check(reasons, true, _message), do: reasons
  defp check(reasons, false, message), do: reasons ++ [message]

  defp result([], computed), do: {:ready, computed}
  defp result(reasons, computed), do: {:not_ready, reasons, computed}

  # Store-based check uses prepend (reversed at the end) to match RolloutGates behaviour.
  defp check_store(failures, true, _message), do: failures
  defp check_store(failures, false, message), do: [message | failures]

  defp aggregate_fingerprints(fingerprints) do
    Enum.reduce(fingerprints, {0, 0, 0}, fn fp, {total, success, failure} ->
      fp_total = Map.get(fp, :total, 0)
      fp_success = Map.get(fp, :success_count, 0)
      fp_failure = fp_total - fp_success
      {total + fp_total, success + fp_success, failure + fp_failure}
    end)
  end
end
