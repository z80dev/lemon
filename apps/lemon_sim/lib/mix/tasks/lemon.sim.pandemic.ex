defmodule Mix.Tasks.Lemon.Sim.Pandemic do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  alias LemonSim.Examples.Pandemic.Artifacts

  @shortdoc "Run the LemonSim Pandemic Response cooperative self-play example"

  @moduledoc """
  Runs the LemonSim Pandemic Response cooperative self-play example from the repo root.

      mix lemon.sim.pandemic
      mix lemon.sim.pandemic --no-persist --max-turns 20
      mix lemon.sim.pandemic --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.pandemic --player-count 4
      mix lemon.sim.pandemic --max-rounds 8
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    player_count: :integer,
    max_rounds: :integer,
    sim_id: :string,
    artifact_dir: :string,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        print_help()

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      true ->
        Common.ensure_runtime_started!()

        run_opts =
          []
          |> Common.maybe_put(:persist?, opts[:persist])
          |> Common.maybe_put(:driver_max_turns, opts[:max_turns] || opts[:max_driver_turns])
          |> Common.maybe_put(:model, Common.resolve_model(opts[:model]))
          |> Common.maybe_put(:player_count, opts[:player_count])
          |> Common.maybe_put(:max_rounds, opts[:max_rounds])
          |> Common.maybe_put(:sim_id, opts[:sim_id])

        case LemonSim.Examples.Pandemic.run(run_opts) do
          {:ok, final_state} ->
            artifact_opts =
              run_opts
              |> Common.maybe_put(:artifact_dir, opts[:artifact_dir])

            {:ok, _artifacts} =
              Artifacts.write_run_artifacts(
                final_state,
                final_state.recent_events,
                [],
                artifact_opts
              )

            :ok

          {:error, reason} ->
            Mix.raise("pandemic sim failed: #{inspect(reason)}")
        end
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.pandemic [options]

    Runs a cooperative pandemic response simulation where 4-6 regional governors
    must coordinate to keep deaths below 10% of the total population.

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum sim turns before stopping
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --player-count N             Number of governors (4-6, default: 6)
      --max-rounds N               Number of rounds (default: 12)
      --sim-id ID                  Override generated simulation id
      --artifact-dir DIR           Override benchmark artifact output directory
      --help                       Show this help

    Phases per round:
      1. intelligence     - Governors gather regional data (fog of war)
      2. communication    - Governors share data (may be misleading)
      3. resource_allocation - Governors request from shared pool
      4. local_action     - Governors deploy vaccines/quarantine/hospitals/research
      5. spread           - Disease spreads automatically (hidden parameters)
    """)
  end
end
