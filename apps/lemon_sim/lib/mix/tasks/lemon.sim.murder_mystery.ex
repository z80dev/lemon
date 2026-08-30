defmodule Mix.Tasks.Lemon.Sim.MurderMystery do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @shortdoc "Run the LemonSim Murder Mystery self-play example"

  @moduledoc """
  Runs the LemonSim Murder Mystery self-play example from the repo root.

      mix lemon.sim.murder_mystery
      mix lemon.sim.murder_mystery --no-persist --max-turns 50
      mix lemon.sim.murder_mystery --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.murder_mystery --player-count 4
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    player_count: :integer,
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

        case LemonSim.Examples.MurderMystery.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("murder mystery sim failed: #{inspect(reason)}")
        end
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.murder_mystery [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --player-count N             Number of players (3-6, default: 6)
      --help                       Show this help
    """)
  end
end
