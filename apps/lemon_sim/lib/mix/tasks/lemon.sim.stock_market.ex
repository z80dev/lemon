defmodule Mix.Tasks.Lemon.Sim.StockMarket do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  alias LemonSim.Examples.StockMarket.Artifacts

  @shortdoc "Run the LemonSim Stock Market self-play example"

  @moduledoc """
  Runs the LemonSim Stock Market self-play example from the repo root.

      mix lemon.sim.stock_market
      mix lemon.sim.stock_market --no-persist --max-turns 10
      mix lemon.sim.stock_market --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.stock_market --player-count 4
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    player_count: :integer,
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
          |> Common.maybe_put(:sim_id, opts[:sim_id])

        case LemonSim.Examples.StockMarket.run(run_opts) do
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
            Mix.raise("stock market sim failed: #{inspect(reason)}")
        end
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.stock_market [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --player-count N             Number of players in the stock market sim
      --sim-id ID                  Override generated simulation id
      --artifact-dir DIR           Override benchmark artifact output directory
      --help                       Show this help
    """)
  end
end
