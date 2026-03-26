defmodule Mix.Tasks.Lemon.Sim.Poker do
  use Mix.Task

  alias LemonCore.Config.Modular
  alias LemonSim.GameHelpers
  alias LemonSim.GameHelpers.Config, as: GameConfig

  @shortdoc "Run the LemonSim poker self-play example"

  @moduledoc """
  Runs the LemonSim poker example from the repo root.

      mix lemon.sim.poker
      mix lemon.sim.poker --player-count 2 --max-hands 1 --seed 7
      mix lemon.sim.poker --model anthropic:claude-sonnet-4-20250514
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    player_count: :integer,
    starting_stack: :integer,
    max_hands: :integer,
    seed: :integer,
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
        ensure_runtime_started!()
        config = Modular.load(project_dir: File.cwd!())

        run_opts =
          []
          |> GameHelpers.maybe_put(:persist?, opts[:persist])
          |> GameHelpers.maybe_put(:driver_max_turns, opts[:max_turns] || opts[:max_driver_turns])
          |> GameHelpers.maybe_put(:player_count, opts[:player_count])
          |> GameHelpers.maybe_put(:starting_stack, opts[:starting_stack])
          |> GameHelpers.maybe_put(:max_hands, opts[:max_hands])
          |> GameHelpers.maybe_put(:seed, opts[:seed])
          |> GameHelpers.maybe_put(:model, resolve_model(opts[:model], config))

        case LemonSim.Examples.Poker.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("poker sim failed: #{inspect(reason)}")
        end
    end
  end

  defp ensure_runtime_started! do
    case Application.ensure_all_started(:lemon_sim) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("failed to start lemon_sim runtime: #{inspect(reason)}")
    end
  end

  defp resolve_model(nil, _config), do: nil
  defp resolve_model("", _config), do: nil

  defp resolve_model(model_spec, config) when is_binary(model_spec) do
    GameConfig.resolve_model_spec(nil, model_spec)
    |> case do
      %Ai.Types.Model{} = model -> GameConfig.apply_provider_base_url(model, config)
      nil -> Mix.raise("unknown model #{inspect(model_spec)}")
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.poker [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum decision steps before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --player-count N             Number of seats to fill (default: 4)
      --starting-stack N           Chips per player (default: 2000)
      --max-hands N                Stop after this many completed hands (default: 12)
      --seed N                     Base seed for deterministic shuffles
      --model PROVIDER:MODEL       Override the configured default model
      --help                       Show this help
    """)
  end
end
