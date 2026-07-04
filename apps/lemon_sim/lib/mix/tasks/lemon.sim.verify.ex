defmodule Mix.Tasks.Lemon.Sim.Verify do
  @moduledoc """
  Verify a LemonSim run artifact bundle.

      mix lemon.sim.verify path/to/run
  """

  use Mix.Task

  @impl true
  def run(args) do
    case args do
      [artifact_dir] ->
        ensure_runtime_started!()

        case LemonSim.Bench.Artifacts.Verifier.verify_run(artifact_dir) do
          {:ok, %{legacy: true} = result} ->
            Mix.shell().info(
              "Verified #{get_in(result.manifest, ["sim", "id"])} run (legacy bundle)"
            )

            Mix.shell().info("Status: #{result.scorecard["status"]}")

            Mix.shell().error(
              "warning: legacy bundle has no manifest.json/hashes.json — " <>
                "hash integrity and scorecard recompute checks were SKIPPED"
            )

          {:ok, result} ->
            Mix.shell().info("Verified #{get_in(result.manifest, ["sim", "id"])} run")
            Mix.shell().info("Status: #{result.scorecard["status"]}")

          {:error, reason} ->
            Mix.shell().error("Verification failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error(@moduledoc)
        exit({:shutdown, 1})
    end
  end

  defp ensure_runtime_started! do
    Application.ensure_all_started(:lemon_sim)
  end
end
