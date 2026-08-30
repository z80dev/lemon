defmodule Mix.Tasks.Lemon.Sim.SupplyChain do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @shortdoc "Run the LemonSim Supply Chain self-play example"

  @moduledoc """
  Runs the LemonSim Supply Chain self-play example from the repo root.

      mix lemon.sim.supply_chain
      mix lemon.sim.supply_chain --no-persist --max-turns 50
      mix lemon.sim.supply_chain --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.supply_chain --max-rounds 10
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    max_rounds: :integer,
    demand_seed: :integer,
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
          |> Common.maybe_put(:max_rounds, opts[:max_rounds])
          |> Common.maybe_put(:demand_seed, opts[:demand_seed])

        case LemonSim.Examples.SupplyChain.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("supply chain sim failed: #{inspect(reason)}")
        end
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.supply_chain [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum driver turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --max-rounds N               Number of rounds to play (default: 20)
      --demand-seed N              Random seed for demand generation (for reproducibility)
      --help                       Show this help
    """)
  end
end
