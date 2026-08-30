defmodule Mix.Tasks.Lemon.Sim.StartupIncubator do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @shortdoc "Run the LemonSim Startup Incubator self-play example"

  @moduledoc """
  Runs the LemonSim Startup Incubator self-play example from the repo root.

      mix lemon.sim.startup_incubator
      mix lemon.sim.startup_incubator --no-persist --max-turns 20
      mix lemon.sim.startup_incubator --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.startup_incubator --founder-count 4 --investor-count 2
      mix lemon.sim.startup_incubator --max-rounds 3
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    founder_count: :integer,
    investor_count: :integer,
    max_rounds: :integer,
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
          |> Common.maybe_put(:founder_count, opts[:founder_count])
          |> Common.maybe_put(:investor_count, opts[:investor_count])
          |> Common.maybe_put(:max_rounds, opts[:max_rounds])

        case LemonSim.Examples.StartupIncubator.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("startup incubator sim failed: #{inspect(reason)}")
        end
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.startup_incubator [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum driver turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --founder-count N            Number of founder agents (default: 4, max: 6)
      --investor-count N           Number of investor agents (default: 2, max: 4)
      --max-rounds N               Number of funding rounds (default: 5)
      --help                       Show this help
    """)
  end
end
