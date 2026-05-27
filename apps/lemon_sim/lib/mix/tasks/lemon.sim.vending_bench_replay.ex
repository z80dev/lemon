defmodule Mix.Tasks.Lemon.Sim.VendingBenchReplay do
  @moduledoc """
  Build a static replay browser from a VendingBench artifact directory.

  ## Usage

      mix lemon.sim.vending_bench_replay ARTIFACT_DIR [--output-dir DIR]
  """

  use Mix.Task

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
        ensure_runtime_started!()
        [artifact_dir | _] = argv

        replay_opts =
          []
          |> maybe_put(:output_dir, opts[:output_dir])

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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_runtime_started! do
    Application.ensure_all_started(:lemon_sim)
    Application.ensure_all_started(:lemon_core)
  end
end
