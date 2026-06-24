defmodule Mix.Tasks.Lemon.Sim.TcgShop do
  @moduledoc """
  Run the TCG Shop simulation.

  ## Usage

      mix lemon.sim.tcg_shop [options]

  ## Options

    * `--max-days` - Maximum number of simulated days (default: 14)
    * `--max-turns` - Maximum decision turns (default: 180)
    * `--seed` - Random seed for deterministic runs
    * `--sim-id` - Explicit simulation id for deterministic artifact names/content
    * `--preset` - Run preset: ci, stress, paper
    * `--offline-strategy` - Deterministic strategy to run without model credentials (`baseline`, `pressure`, or `overextended`)
    * `--artifact-dir` - Directory for offline run artifacts
    * `--deterministic-artifacts` - Pin artifact timestamps and path labels for byte-reproducible bundles
    * `--persist` - Persist final state (default: true)
    * `--help` - Show this help
  """

  use Mix.Task

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_days: :integer,
    seed: :integer,
    sim_id: :string,
    preset: :string,
    offline_strategy: :string,
    artifact_dir: :string,
    deterministic_artifacts: :boolean,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      ensure_runtime_started!()
      run_simulation(opts)
    end
  end

  defp run_simulation(opts) do
    run_opts =
      []
      |> apply_preset(opts[:preset])
      |> maybe_put(:max_days, opts[:max_days])
      |> maybe_put(:seed, opts[:seed])
      |> maybe_put(:sim_id, opts[:sim_id])
      |> maybe_put(:persist?, opts[:persist])
      |> maybe_put(:driver_max_turns, opts[:max_turns])
      |> maybe_put(:artifact_dir, opts[:artifact_dir])
      |> maybe_put(:deterministic_artifacts?, opts[:deterministic_artifacts])

    strategy = opts[:offline_strategy] || "baseline"

    case LemonSim.Examples.TcgShop.run_offline_strategy(strategy, run_opts) do
      {:ok, %{artifacts: artifacts}} ->
        Mix.shell().info("TCG Shop artifacts written to #{Path.dirname(artifacts.final_world)}")
        :ok

      {:error, reason} ->
        Mix.shell().error("Simulation failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp apply_preset(opts, nil), do: opts

  defp apply_preset(opts, "ci") do
    opts
    |> Keyword.put(:max_days, 5)
    |> Keyword.put(:driver_max_turns, 20)
    |> Keyword.put(:persist?, false)
  end

  defp apply_preset(opts, "paper") do
    opts
    |> Keyword.put(:max_days, 90)
    |> Keyword.put(:driver_max_turns, 200)
  end

  defp apply_preset(opts, "stress") do
    opts
    |> Keyword.put(:max_days, 14)
    |> Keyword.put(:driver_max_turns, 80)
    |> Keyword.put(:persist?, false)
  end

  defp apply_preset(_opts, preset) do
    Mix.shell().error("Unknown preset #{preset}. Expected one of: ci, stress, paper")
    exit({:shutdown, 1})
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_runtime_started! do
    Application.ensure_all_started(:lemon_sim)
    Application.ensure_all_started(:lemon_core)
  end
end
