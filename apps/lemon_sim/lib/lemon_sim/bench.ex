defmodule LemonSim.Bench do
  @moduledoc """
  Internal namespace for benchmark artifacts, manifests, scorecards, suites,
  and leaderboard exports.

  Bench modules own reusable benchmark mechanics: atomic artifact writing,
  manifest and hash verification, deterministic scorecard behaviours,
  scorecard registry dispatch, shared run-bundle helpers, cross-run suite
  aggregation, and model leaderboard rendering. Domain examples may produce
  benchmark data, but reusable artifact, verification, and leaderboard
  mechanics live here.
  """
end
