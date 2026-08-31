defmodule Mix.Tasks.Lemon.Sim.Leaderboard do
  @moduledoc """
  Print and rewrite a LemonSim suite leaderboard.

      mix lemon.sim.leaderboard /tmp/vb-suite
      mix lemon.sim.leaderboard /tmp/vb-suite --recompute
  """

  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @switches [
    recompute: :boolean,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.shell().error("Invalid options: #{inspect(invalid)}")
        exit({:shutdown, 1})

      argv == [] ->
        Mix.shell().error("Usage: mix lemon.sim.leaderboard SUITE_DIR [--recompute]")
        exit({:shutdown, 1})

      true ->
        Common.ensure_runtime_and_core_started()
        [suite_dir | _] = argv

        case LemonSim.Bench.Suite.write_leaderboard(suite_dir, recompute: opts[:recompute]) do
          {:ok, leaderboard} ->
            Mix.shell().info(leaderboard)

          {:error, reason} ->
            Mix.shell().error("Leaderboard failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end
    end
  end
end
