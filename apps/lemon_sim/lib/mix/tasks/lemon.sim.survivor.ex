defmodule Mix.Tasks.Lemon.Sim.Survivor do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @shortdoc "Run the LemonSim Survivor self-play example"

  @moduledoc """
  Runs the LemonSim Survivor self-play example from the repo root.

      mix lemon.sim.survivor
      mix lemon.sim.survivor --no-persist --max-turns 10
      mix lemon.sim.survivor --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.survivor --player-count 8
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

        case LemonSim.Examples.Survivor.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("survivor sim failed: #{inspect(reason)}")
        end
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.survivor [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --player-count N             Number of players in the survivor game
      --help                       Show this help
    """)
  end
end
