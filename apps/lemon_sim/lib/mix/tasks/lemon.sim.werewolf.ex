defmodule Mix.Tasks.Lemon.Sim.Werewolf do
  use Mix.Task

  alias LemonSim.LLM.GameHelpers.Config, as: SimConfig

  @shortdoc "Run the LemonSim Werewolf social-deduction example"

  @moduledoc """
  Runs the LemonSim Werewolf social-deduction example from the repo root.

      mix lemon.sim.werewolf
      mix lemon.sim.werewolf --no-persist --max-turns 25
      mix lemon.sim.werewolf --player-count 5 --models anthropic:claude-sonnet-4-20250514,openai:gpt-4.1,google_gemini_cli:gemini-2.5-flash,openai-codex:gpt-5.1-codex-mini,kimi:k2p5

  Multi-model assignments are applied in sorted Werewolf seat-name order for the
  seeded run.
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    models: :string,
    player_count: :integer,
    seed: :integer,
    sim_id: :string,
    transcript_path: :string,
    artifact_dir: :string,
    help: :boolean
  ]

  @impl true
  def run(args), do: run(args, [])

  @doc false
  def run(args, deps) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        print_help()

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      opts[:model] && opts[:models] ->
        Mix.raise("pass either --model or --models, not both")

      true ->
        if Keyword.get(deps, :ensure_runtime?, true), do: ensure_runtime_started!()
        run_simulation(opts, deps)
    end
  end

  defp run_simulation(opts, deps) do
    runner = Keyword.get(deps, :runner, &run_werewolf/2)
    config = load_config(deps)

    base_run_opts =
      []
      |> maybe_put(:persist?, opts[:persist])
      |> maybe_put(:driver_max_turns, opts[:max_turns] || opts[:max_driver_turns])
      |> maybe_put(:player_count, opts[:player_count])
      |> maybe_put(:seed, opts[:seed])
      |> maybe_put(:sim_id, opts[:sim_id])

    result =
      if opts[:models] do
        {assignments, effective_seed} = build_model_assignments!(opts, config, deps)
        maybe_seed_random(effective_seed)

        base_run_opts
        |> Keyword.put(:seed, effective_seed)
        |> maybe_put(:model_assignments, assignments)
        |> maybe_put(:transcript_path, transcript_path(opts))
        |> then(&runner.(:multi, &1))
      else
        maybe_seed_random(opts[:seed])

        base_run_opts
        |> maybe_put(:model, resolve_model_override(opts[:model], config, deps))
        |> then(&runner.(:single, &1))
      end

    case result do
      {:ok, _final_state} -> :ok
      {:error, reason} -> Mix.raise("werewolf sim failed: #{inspect(reason)}")
    end
  rescue
    e in RuntimeError -> Mix.raise(Exception.message(e))
  end

  defp build_model_assignments!(opts, config, deps) do
    player_count = opts[:player_count] || 6
    seed = opts[:seed] || System.unique_integer([:positive])
    maybe_seed_random(seed)
    player_ids = werewolf_player_ids(player_count)
    specs = parse_model_list!(opts[:models])

    if length(specs) != length(player_ids) do
      Mix.raise(
        "--models expects #{length(player_ids)} model specs for #{player_count} Werewolf seats, got #{length(specs)}"
      )
    end

    resolver = Keyword.get(deps, :assignment_resolver, &resolve_assignment!/2)

    assignments =
      player_ids
      |> Enum.zip(specs)
      |> Map.new(fn {player_id, spec} -> {player_id, resolver.(spec, config)} end)

    {assignments, seed}
  end

  defp werewolf_player_ids(player_count) do
    LemonSim.Examples.Werewolf.initial_world(player_count: player_count)
    |> Map.fetch!(:players)
    |> Map.keys()
    |> Enum.sort()
  end

  defp parse_model_list!(models) when is_binary(models) do
    models
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp resolve_assignment!(model_spec, config) do
    model = resolve_model!(model_spec, config)
    api_key = SimConfig.resolve_provider_api_key!(model.provider, config, "werewolf")
    {model, api_key}
  end

  defp resolve_model_override(nil, _config, _deps), do: nil
  defp resolve_model_override("", _config, _deps), do: nil

  defp resolve_model_override(model_spec, config, deps) do
    resolver = Keyword.get(deps, :model_resolver, &resolve_model!/2)
    resolver.(model_spec, config)
  end

  defp resolve_model!(model_spec, config) do
    case SimConfig.resolve_model_spec(nil, model_spec) do
      %Ai.Types.Model{} = model -> SimConfig.apply_provider_base_url(model, config)
      nil -> Mix.raise("unknown model #{inspect(model_spec)}")
    end
  end

  defp transcript_path(opts) do
    cond do
      is_binary(opts[:transcript_path]) ->
        opts[:transcript_path]

      is_binary(opts[:artifact_dir]) ->
        sim_id = opts[:sim_id] || "werewolf_#{System.system_time(:second)}"
        Path.join(opts[:artifact_dir], "#{sim_id}.jsonl")

      true ->
        nil
    end
  end

  defp run_werewolf(:single, opts), do: LemonSim.Examples.Werewolf.run(opts)
  defp run_werewolf(:multi, opts), do: LemonSim.Examples.Werewolf.run_multi_model(opts)

  defp load_config(deps) do
    deps
    |> Keyword.get(:config_loader, fn ->
      LemonCore.Config.Modular.load(project_dir: File.cwd!())
    end)
    |> then(& &1.())
  end

  defp maybe_seed_random(nil), do: :ok

  defp maybe_seed_random(seed) when is_integer(seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    :ok
  end

  defp ensure_runtime_started! do
    case Application.ensure_all_started(:lemon_sim) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("failed to start lemon_sim runtime: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.werewolf [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Use one model for all seats
      --models A,B,C               Per-seat models in sorted Werewolf seat order
      --player-count N             Number of players, 5 through 8 (default: 6)
      --seed N                     Seed role and character randomization
      --sim-id ID                  Override generated simulation id
      --transcript-path PATH       JSONL transcript path for multi-model runs
      --artifact-dir DIR           Directory for a generated multi-model transcript
      --help                       Show this help
    """)
  end
end
