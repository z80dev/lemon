defmodule Mix.Tasks.Lemon.Sim.VendingBenchReplay do
  @moduledoc """
  Build a static replay browser from a VendingBench artifact directory.

  ## Usage

      mix lemon.sim.vending_bench_replay ARTIFACT_DIR [--output-dir DIR]
  """

  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @switches [
    output_dir: :string,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, argv, _invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      argv == [] ->
        Mix.shell().error("missing artifact directory\n\n" <> @moduledoc)
        exit({:shutdown, 1})

      true ->
        Common.ensure_runtime_and_core_started()
        [artifact_dir | _] = argv

        replay_opts =
          []
          |> Common.maybe_put(:output_dir, opts[:output_dir])

        case LemonSim.Examples.VendingBench.Replay.write_browser(artifact_dir, replay_opts) do
          {:ok, paths} ->
            Mix.shell().info("Replay JSON written to #{paths.replay_json}")
            Mix.shell().info("Replay browser written to #{paths.replay_html}")

          {:error, reason} ->
            Mix.shell().error("Replay build failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end
    end
  end
end
