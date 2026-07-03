defmodule Mix.Tasks.Lemon.Sim.Score do
  @moduledoc """
  Print the scorecard for a LemonSim run artifact bundle.

      mix lemon.sim.score path/to/run
  """

  use Mix.Task
  alias LemonSim.Bench.Artifacts.Verifier

  @impl true
  def run(args) do
    case args do
      [artifact_dir] ->
        with {:ok, verified} <- Verifier.verify_run(artifact_dir),
             scorecard when is_map(scorecard) <- verified.scorecard do
          if Map.get(verified, :legacy) do
            Mix.shell().error(
              "warning: legacy bundle — hash integrity and scorecard recompute checks were SKIPPED"
            )
          end

          Mix.shell().info(Jason.encode!(scorecard, pretty: true))
        else
          nil ->
            Mix.shell().error("Could not read verified scorecard: missing scorecard")
            exit({:shutdown, 1})

          {:error, reason} ->
            Mix.shell().error("Could not read verified scorecard: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error(@moduledoc)
        exit({:shutdown, 1})
    end
  end
end
