defmodule Mix.Tasks.Lemon.Sim.Poker do
  use Mix.Task

  alias LemonCore.Config.Modular
  alias LemonSim.Examples.Helpers, as: GameHelpers
  alias LemonSim.Examples.Poker.Artifacts
  alias LemonSim.LLM.GameHelpers.Config, as: GameConfig

  @shortdoc "Run the LemonSim poker self-play example"

  @moduledoc """
  Runs the LemonSim poker example from the repo root.

      mix lemon.sim.poker
      mix lemon.sim.poker --player-count 2 --max-hands 1 --seed 7
      mix lemon.sim.poker --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.poker --player-count 3 --models zai:glm-5,anthropic:claude-sonnet-4-20250514,openai:gpt-4.1

  Multi-model assignments are applied in seat order (player_1..player_N).
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    player_count: :integer,
    starting_stack: :integer,
    max_hands: :integer,
    seed: :integer,
    sim_id: :string,
    artifact_dir: :string,
    model: :string,
    models: :string,
    transcript_path: :string,
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

      opts[:model] && opts[:models] ->
        Mix.raise("pass either --model or --models, not both")

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
          |> GameHelpers.maybe_put(:sim_id, opts[:sim_id])

        result =
          if opts[:models] do
            run_opts
            |> Keyword.put(:model_assignments, build_model_assignments!(opts, config))
            |> GameHelpers.maybe_put(:transcript_path, opts[:transcript_path])
            |> LemonSim.Examples.Poker.run_multi_model()
          else
            run_opts
            |> GameHelpers.maybe_put(:model, resolve_model(opts[:model], config))
            |> LemonSim.Examples.Poker.run()
          end

        case result do
          {:ok, final_state} ->
            artifact_opts =
              run_opts
              |> GameHelpers.maybe_put(:artifact_dir, opts[:artifact_dir])

            {:ok, _artifacts} =
              Artifacts.write_run_artifacts(
                final_state,
                final_state.recent_events,
                [],
                artifact_opts
              )

            :ok

          {:error, reason} ->
            Mix.raise("poker sim failed: #{inspect(reason)}")
        end
    end
  end

  defp build_model_assignments!(opts, config) do
    player_count = opts[:player_count] || 4

    specs =
      opts[:models]
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if length(specs) != player_count do
      Mix.raise(
        "--models expects #{player_count} model specs for #{player_count} seats, got #{length(specs)}"
      )
    end

    1..player_count
    |> Enum.map(&"player_#{&1}")
    |> Enum.zip(specs)
    |> Map.new(fn {player_id, spec} ->
      model = resolve_model(spec, config)
      api_key = GameConfig.resolve_provider_api_key!(model.provider, config, "poker")
      {player_id, {model, api_key}}
    end)
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
      --sim-id ID                  Override generated simulation id
      --artifact-dir DIR           Override benchmark artifact output directory
      --model PROVIDER:MODEL       Override the configured default model
      --models A,B,C               Per-seat models in seat order (player_1..N)
      --transcript-path PATH       JSONL transcript path for multi-model runs
      --help                       Show this help
    """)
  end
end
