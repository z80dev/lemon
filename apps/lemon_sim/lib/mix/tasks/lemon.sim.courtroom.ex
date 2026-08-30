defmodule Mix.Tasks.Lemon.Sim.Courtroom do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @shortdoc "Run the LemonSim Courtroom Trial self-play example"

  @moduledoc """
  Runs the LemonSim Courtroom Trial self-play example from the repo root.

      mix lemon.sim.courtroom
      mix lemon.sim.courtroom --no-persist --max-turns 50
      mix lemon.sim.courtroom --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.courtroom --witnesses 2 --jurors 3
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    witnesses: :integer,
    jurors: :integer,
    seed: :integer,
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
          |> Common.maybe_put(:witness_count, opts[:witnesses])
          |> Common.maybe_put(:juror_count, opts[:jurors])
          |> Common.maybe_put(:seed, opts[:seed])

        case LemonSim.Examples.Courtroom.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("courtroom sim failed: #{inspect(reason)}")
        end
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.courtroom [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --witnesses N                Number of witness agents (default: 3)
      --jurors N                   Number of juror agents (default: 3)
      --seed N                     Random seed for case generation
      --help                       Show this help
    """)
  end
end
