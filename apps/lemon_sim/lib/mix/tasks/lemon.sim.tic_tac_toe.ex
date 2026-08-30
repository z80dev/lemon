defmodule Mix.Tasks.Lemon.Sim.TicTacToe do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @shortdoc "Run the LemonSim Tic Tac Toe self-play example"

  @moduledoc """
  Runs the LemonSim Tic Tac Toe self-play example from the repo root.

      mix lemon.sim.tic_tac_toe
      mix lemon.sim.tic_tac_toe --offline-strategy random --seed 42 --no-persist --max-turns 10
      mix lemon.sim.tic_tac_toe --model anthropic:claude-sonnet-4-20250514
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    seed: :integer,
    sim_id: :string,
    offline_strategy: :string,
    model: :string,
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
          |> Common.maybe_put(:seed, opts[:seed])
          |> Common.maybe_put(:sim_id, opts[:sim_id])

        result =
          if opts[:offline_strategy] do
            LemonSim.Examples.TicTacToe.run_offline_strategy(opts[:offline_strategy], run_opts)
          else
            run_opts
            |> Common.maybe_put(:model, Common.resolve_model(opts[:model]))
            |> LemonSim.Examples.TicTacToe.run()
          end

        case result do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("tic tac toe sim failed: #{inspect(reason)}")
        end
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.tic_tac_toe [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --seed N                     Seed for deterministic offline runs
      --sim-id ID                  Override simulation id
      --offline-strategy NAME      Run without model credentials (`random`)
      --model PROVIDER:MODEL       Override the configured default model
      --help                       Show this help
    """)
  end
end
