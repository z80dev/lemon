defmodule Mix.Tasks.Lemon.Sim.Skirmish do
  use Mix.Task

  alias Mix.Tasks.Lemon.Sim.Common

  @shortdoc "Run the LemonSim skirmish self-play example"

  @moduledoc """
  Runs the LemonSim skirmish example from the repo root.

      mix lemon.sim.skirmish
      mix lemon.sim.skirmish --no-persist --max-turns 12
      mix lemon.sim.skirmish --model anthropic:claude-sonnet-4-20250514
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    log: :string,
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

        log_path = resolve_log_path(opts[:log])

        run_opts =
          []
          |> Common.maybe_put(:persist?, opts[:persist])
          |> Common.maybe_put(:driver_max_turns, opts[:max_turns] || opts[:max_driver_turns])
          |> Common.maybe_put(:model, Common.resolve_model(opts[:model]))
          |> Common.maybe_put(:log_path, log_path)

        case LemonSim.Examples.Skirmish.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("skirmish sim failed: #{inspect(reason)}")
        end
    end
  end

  defp resolve_log_path(nil), do: nil
  defp resolve_log_path(""), do: nil

  defp resolve_log_path("auto"),
    do:
      LemonSim.Examples.Skirmish.GameLog.default_log_path(
        "skirmish_#{System.system_time(:second)}"
      )

  defp resolve_log_path(path), do: path

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.skirmish [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --help                       Show this help
    """)
  end
end
