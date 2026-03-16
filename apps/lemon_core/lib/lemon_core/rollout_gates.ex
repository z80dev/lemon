defmodule LemonCore.RolloutGates do
  @moduledoc """
  Measurable promotion gates for adaptive features.

  Before a feature can be promoted from `:opt-in` to `:default-on`, all of its
  configured gates must pass.  Gates are intentionally conservative to avoid
  enabling features on noisy or insufficient data.

  ## Features gated here

  - `routing_feedback` — tracks run outcomes and uses them to break model ties
  - `skill_synthesis_drafts` — auto-generates skill drafts from successful runs

  ## Usage

      # Check if routing feedback data is good enough to enable by default
      store_stats = RoutingFeedbackStore.store_stats()
      fingerprints = RoutingFeedbackStore.list_fingerprints()
      case RolloutGates.evaluate_routing_feedback(store_stats, fingerprints) do
        {:pass, notes} -> IO.puts("Ready to promote: \#{inspect(notes)}")
        {:fail, failures} -> IO.puts("Not ready: \#{inspect(failures)}")
      end

      # Check if synthesis pipeline is producing acceptable quality
      {:ok, result} = Pipeline.run(:agent, agent_id)
      case RolloutGates.evaluate_synthesis(result) do
        {:pass, notes} -> IO.puts("Synthesis quality acceptable")
        {:fail, failures} -> IO.puts("Quality gates failed: \#{inspect(failures)}")
      end

  ## Gate thresholds

  See `routing_gates/0` and `synthesis_gates/0` for the current thresholds.
  Thresholds are conservative by design — raise them carefully.

  ## Rollback procedure

  If a feature is enabled and causes problems:

  1. Set the flag to `"off"` in `~/.lemon/config.toml`:
     ```toml
     [features]
     routing_feedback       = "off"
     skill_synthesis_drafts = "off"
     ```
  2. Restart the runtime (`./bin/lemon-gateway`).
  3. Check `mix lemon.doctor` to confirm the flag change is active.
  4. File an issue describing the problem before re-enabling.
  """

  @routing_gates %{
    # Minimum total recorded samples before any routing decisions are made.
    min_sample_size: 20,
    # Minimum aggregate success rate (success / total) across all fingerprints.
    min_success_rate: 0.60,
    # Maximum aggregate failure rate (failure / total) across all fingerprints.
    max_failure_rate: 0.20
  }

  @synthesis_gates %{
    # Minimum number of candidates the pipeline must have processed.
    min_candidates_processed: 5,
    # Maximum fraction of candidates that are blocked by the audit engine.
    # A high block rate suggests the memory documents contain noisy content.
    max_draft_block_rate: 0.50,
    # Minimum fraction of candidates that produce a stored draft.
    min_generated_rate: 0.20
  }

  @type gate_result :: {:pass, [String.t()]} | {:fail, [String.t()]}

  @doc """
  Return the routing_feedback promotion gate thresholds.
  """
  @spec routing_gates() :: map()
  def routing_gates, do: @routing_gates

  @doc """
  Return the skill_synthesis_drafts promotion gate thresholds.
  """
  @spec synthesis_gates() :: map()
  def synthesis_gates, do: @synthesis_gates

  @doc """
  Evaluate whether `routing_feedback` is ready for promotion to `:default-on`.

  Takes:
  - `store_stats` — output of `RoutingFeedbackStore.store_stats/0`; expected keys:
    `total_records`, `unique_fingerprints`
  - `fingerprints` — list of fingerprint summary maps from
    `RoutingFeedbackStore.list_fingerprints/0`; expected keys per entry:
    `total`, `success_count`

  Returns `{:pass, notes}` or `{:fail, failures}` where each element is a
  human-readable string.
  """
  @spec evaluate_routing_feedback(map(), [map()]) :: gate_result()
  def evaluate_routing_feedback(store_stats, fingerprints)
      when is_map(store_stats) and is_list(fingerprints) do
    failures = []

    # Gate 1: sample size
    total = Map.get(store_stats, :total_records, 0)

    failures =
      if total < @routing_gates.min_sample_size do
        [
          "sample_size: #{total} < #{@routing_gates.min_sample_size} (need more recorded runs)"
          | failures
        ]
      else
        failures
      end

    # Gate 2: aggregate success rate and failure rate
    {agg_total, agg_success, agg_failure} = aggregate_outcomes(fingerprints)

    failures =
      if agg_total > 0 do
        success_rate = agg_success / agg_total
        failure_rate = agg_failure / agg_total

        f = failures

        f =
          if success_rate < @routing_gates.min_success_rate do
            [
              "success_rate: #{Float.round(success_rate, 3)} < #{@routing_gates.min_success_rate}"
              | f
            ]
          else
            f
          end

        if failure_rate > @routing_gates.max_failure_rate do
          [
            "failure_rate: #{Float.round(failure_rate, 3)} > #{@routing_gates.max_failure_rate}"
            | f
          ]
        else
          f
        end
      else
        failures
      end

    case failures do
      [] ->
        {:pass,
         [
           "sample_size: #{total} >= #{@routing_gates.min_sample_size}",
           "unique_fingerprints: #{Map.get(store_stats, :unique_fingerprints, 0)}"
         ]}

      _ ->
        {:fail, Enum.reverse(failures)}
    end
  end

  @doc """
  Evaluate whether `skill_synthesis_drafts` is ready for promotion to `:default-on`.

  Takes a `run_result` map as returned by `LemonSkills.Synthesis.Pipeline.run/3`:

      %{
        generated: [key, ...],
        skipped: [{key, reason}, ...],
        total_candidates: n
      }

  Returns `{:pass, notes}` or `{:fail, failures}`.
  """
  @spec evaluate_synthesis(map()) :: gate_result()
  def evaluate_synthesis(%{total_candidates: total} = result) when is_integer(total) do
    generated = length(Map.get(result, :generated, []))
    skipped = Map.get(result, :skipped, [])
    blocked = Enum.count(skipped, fn {_key, reason} -> reason == :blocked_by_audit end)

    failures = []

    # Gate 1: minimum candidates processed
    failures =
      if total < @synthesis_gates.min_candidates_processed do
        [
          "candidates_processed: #{total} < #{@synthesis_gates.min_candidates_processed}"
          | failures
        ]
      else
        failures
      end

    # Gate 2: audit block rate
    failures =
      if total > 0 do
        block_rate = blocked / total

        if block_rate > @synthesis_gates.max_draft_block_rate do
          [
            "draft_block_rate: #{Float.round(block_rate, 3)} > #{@synthesis_gates.max_draft_block_rate} (too many candidates blocked by audit)"
            | failures
          ]
        else
          failures
        end
      else
        failures
      end

    # Gate 3: generation rate
    failures =
      if total > 0 do
        gen_rate = generated / total

        if gen_rate < @synthesis_gates.min_generated_rate do
          [
            "generated_rate: #{Float.round(gen_rate, 3)} < #{@synthesis_gates.min_generated_rate} (too few candidates produce stored drafts)"
            | failures
          ]
        else
          failures
        end
      else
        failures
      end

    case failures do
      [] ->
        gen_rate = if total > 0, do: Float.round(generated / total, 3), else: 0.0

        {:pass,
         [
           "total_candidates: #{total}",
           "generated: #{generated}",
           "generated_rate: #{gen_rate}"
         ]}

      _ ->
        {:fail, Enum.reverse(failures)}
    end
  end

  def evaluate_synthesis(_), do: {:fail, ["invalid_run_result: missing total_candidates"]}

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp aggregate_outcomes(fingerprints) do
    Enum.reduce(fingerprints, {0, 0, 0}, fn fp, {total, success, failure} ->
      fp_total = Map.get(fp, :total, 0)
      fp_success = Map.get(fp, :success_count, 0)
      # failure count = total - success (includes partial, aborted, unknown)
      # We track :failure separately if available, otherwise infer it
      fp_failure = fp_total - fp_success

      {total + fp_total, success + fp_success, failure + fp_failure}
    end)
  end
end
