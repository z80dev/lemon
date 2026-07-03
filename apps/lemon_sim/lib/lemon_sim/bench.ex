defmodule LemonSim.Bench do
  @moduledoc """
  Internal namespace for benchmark artifacts, manifests, scorecards, and replay checks.

  Bench modules own reusable benchmark mechanics: atomic artifact writing,
  manifest and hash verification, deterministic scorecard behaviours,
  scorecard registry dispatch, and shared run-bundle helpers. Domain examples
  may produce benchmark data, but reusable artifact mechanics live here.
  """
end
