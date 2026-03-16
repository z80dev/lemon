defmodule LemonCore.RolloutGates do
  @moduledoc """
  Backward-compatible delegation layer for `LemonCore.RolloutGate`.

  All implementation lives in `LemonCore.RolloutGate`.  This module exists
  solely to preserve the two-argument `evaluate_routing_feedback/2` API
  (taking `store_stats` + `fingerprints`) used by the product smoke tests.

  New callers should use `LemonCore.RolloutGate` directly.
  """

  alias LemonCore.RolloutGate

  @type gate_result :: {:pass, [String.t()]} | {:fail, [String.t()]}

  @doc "Return the routing_feedback promotion gate thresholds (store-based)."
  @spec routing_gates() :: map()
  def routing_gates do
    %{
      min_sample_size: 20,
      min_success_rate: 0.60,
      max_failure_rate: 0.20
    }
  end

  @doc "Return the skill_synthesis_drafts promotion gate thresholds (run-result-based)."
  @spec synthesis_gates() :: map()
  def synthesis_gates do
    %{
      min_candidates_processed: 5,
      max_draft_block_rate: 0.50,
      min_generated_rate: 0.20
    }
  end

  @doc """
  Evaluate whether `routing_feedback` is ready for promotion.

  Delegates to `LemonCore.RolloutGate.evaluate_routing_from_store/2`.
  """
  @spec evaluate_routing_feedback(map(), [map()]) :: gate_result()
  def evaluate_routing_feedback(store_stats, fingerprints) do
    RolloutGate.evaluate_routing_from_store(store_stats, fingerprints)
  end

  @doc """
  Evaluate whether `skill_synthesis_drafts` is ready for promotion.

  Delegates to `LemonCore.RolloutGate.evaluate_synthesis_from_run/1`.
  """
  @spec evaluate_synthesis(map()) :: gate_result()
  def evaluate_synthesis(run_result) do
    RolloutGate.evaluate_synthesis_from_run(run_result)
  end
end
