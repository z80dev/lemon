defmodule LemonSim.Examples.Skirmish do
  @moduledoc """
  Tactical skirmish example built on LemonSim.

  Supports configurable squad sizes (up to 5v5), unit classes (scout, soldier,
  heavy, sniper, medic), and procedurally generated maps with terrain
  (cover, walls, water, high ground).
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers
  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.Skirmish.{
    ActionSpace,
    GameLog,
    MapGenerator,
    UnitClasses,
    Updater,
    Visibility
  }

  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 60
  @default_map_width 8
  @default_map_height 6
  @default_max_rounds 8

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    width = Keyword.get(opts, :map_width, @default_map_width)
    height = Keyword.get(opts, :map_height, @default_map_height)
    map_seed = Keyword.get(opts, :map_seed, :erlang.phash2(:erlang.monotonic_time()))
    rng_seed = Keyword.get(opts, :rng_seed, 5)
    squad = Keyword.get(opts, :squad, UnitClasses.default_squad())
    map_preset = Keyword.get(opts, :map_preset, nil)

    # Generate or use preset map
    map_data =
      if map_preset do
        Map.get(
          MapGenerator.preset_maps(),
          map_preset,
          MapGenerator.generate(width: width, height: height, seed: map_seed)
        )
      else
        MapGenerator.generate(width: width, height: height, seed: map_seed)
      end

    # Build squads
    red_positions = MapGenerator.spawn_positions(map_data, :red, length(squad))
    blue_positions = MapGenerator.spawn_positions(map_data, :blue, length(squad))

    red_units = build_squad(squad, "red", red_positions)
    blue_units = build_squad(squad, "blue", blue_positions)

    all_units = Map.merge(red_units, blue_units)
    turn_order = build_turn_order(squad)

    %{
      map: map_data,
      units: all_units,
      turn_order: turn_order,
      active_actor_id: List.first(turn_order),
      phase: "main",
      round: 1,
      max_rounds: @default_max_rounds,
      rng_seed: rng_seed,
      winner: nil,
      status: "in_progress",
      kill_feed: []
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id = Keyword.get(opts, :sim_id, "skirmish_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal: "Win the skirmish by eliminating all enemy units. Use terrain for advantage."
      },
      plan_history: []
    )
  end

  @spec modules() :: map()
  def modules do
    %{
      action_space: ActionSpace,
      projector: SectionedProjector,
      decider: ToolLoopDecider,
      updater: Updater
    }
  end

  @spec projector_opts() :: keyword()
  def projector_opts do
    [
      section_builders: %{
        world_state: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)

          %{
            id: :world_state,
            title: "Battlefield",
            format: :json,
            content:
              Visibility.view_world(frame.world, actor_id)
              |> Map.put("max_rounds", MapHelpers.get_key(frame.world, :max_rounds))
          }
        end,
        active_unit: fn frame, _tools, _opts ->
          %{
            id: :active_unit,
            title: "Active Unit",
            format: :json,
            content: Visibility.active_unit(frame.world)
          }
        end,
        enemy_summary: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)

          %{
            id: :enemy_summary,
            title: "Enemy Summary",
            format: :json,
            content: Visibility.enemy_units(frame.world, actor_id)
          }
        end,
        friendly_summary: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)

          %{
            id: :friendly_summary,
            title: "Friendly Units",
            format: :json,
            content: Visibility.friendly_units(frame.world, actor_id)
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Combat Log",
            format: :json,
            content: Enum.take(frame.recent_events, -12)
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        COMBAT DOCTRINE:
        - ATTACK is your highest priority. If an enemy is in range, ATTACK.
        - Move TOWARD the nearest enemy every turn. Never stay idle.
        - Focus fire: attack the most wounded enemy to secure kills fast.
        - Scouts: sprint aggressively to flank and reach firing positions.
        - Medics: advance WITH the squad, heal wounded allies, then attack.
        - Snipers: find high ground, then attack every turn from range.
        - DO NOT end your turn with unused AP if enemies are reachable.
        - Bold aggression wins. Passive play loses.
        - After round 8, all units take 1 damage per round from the closing storm. End the fight quickly.
        """
      },
      section_order: [
        :world_state,
        :active_unit,
        :friendly_summary,
        :enemy_summary,
        :recent_events,
        :current_intent,
        :available_actions,
        :decision_contract
      ]
    ]
  end

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    config = Modular.load(project_dir: File.cwd!())
    model = Keyword.get_lazy(overrides, :model, fn -> resolve_configured_model!(config) end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        %{api_key: resolve_provider_api_key!(model.provider, config)}
      end)

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: @default_max_turns,
      persist?: true,
      terminal?: &terminal?/1,
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    state = initial_state(opts)
    log_path = Keyword.get(opts, :log_path)

    # Start game log if requested
    game_log =
      if log_path do
        log = GameLog.start(log_path)
        GameLog.log_init(log, state.world)
        log
      end

    run_opts =
      default_opts(opts)
      |> Keyword.merge(opts)
      |> Keyword.put(:on_after_step, build_after_step_callback(game_log))

    IO.puts("Starting skirmish self-play")
    if log_path, do: IO.puts("Logging to: #{log_path}")

    result =
      case Runner.run_until_terminal(state, modules(), run_opts) do
        {:ok, final_state} ->
          IO.puts("Final state:")
          IO.inspect(final_state.world)

          if game_log do
            step = final_state.version
            GameLog.log_game_over(game_log, step, final_state.world)
          end

          if Keyword.get(run_opts, :persist?, true) do
            _ = Store.put_state(final_state)
          end

          {:ok, final_state}

        {:error, reason} = error ->
          IO.puts("Driver failed:")
          IO.inspect(reason)
          error
      end

    GameLog.stop(game_log)
    result
  end

  defp build_after_step_callback(nil) do
    &print_step/2
  end

  defp build_after_step_callback(game_log) do
    step_counter = :counters.new(1, [:atomics])

    fn _turn, result ->
      :counters.add(step_counter, 1, 1)
      step = :counters.get(step_counter, 1)

      case result do
        %{state: next_state} ->
          GameLog.log_step(game_log, step, next_state.world)
          print_units(next_state)

        _ ->
          :ok
      end
    end
  end

  # -- Squad building --

  defp build_squad(class_list, team, positions) do
    class_list
    |> Enum.with_index(1)
    |> Enum.zip(positions)
    |> Enum.into(%{}, fn {{class_name, idx}, pos} ->
      unit_id = "#{team}_#{idx}"
      {unit_id, UnitClasses.build_unit(unit_id, team, class_name, pos)}
    end)
  end

  defp build_turn_order(squad) do
    count = length(squad)

    # Interleave red and blue turns for fairness
    Enum.flat_map(1..count, fn idx ->
      ["red_#{idx}", "blue_#{idx}"]
    end)
  end

  # -- Callbacks --

  defp terminal?(state), do: MapHelpers.get_key(state.world, :status) == "won"

  defp announce_turn(turn, state) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)
    actor = get_unit(state.world, actor_id)
    class = if actor, do: " (#{get(actor, :class, "?")})", else: ""

    IO.puts(
      "Step #{turn} | round=#{MapHelpers.get_key(state.world, :round)} actor=#{actor_id}#{class}"
    )
  end

  defp print_step(_turn, %{state: next_state}) do
    print_units(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_units(state) do
    units = get(state.world, :units, %{})

    IO.puts("Units:")

    Enum.each(Enum.sort(Map.keys(units)), fn unit_id ->
      unit = Map.get(units, unit_id)
      pos = get(unit, :pos, %{})

      IO.puts(
        "#{unit_id} [#{get(unit, :class, "?")}] team=#{MapHelpers.get_key(unit, :team)} hp=#{MapHelpers.get_key(unit, :hp)} ap=#{MapHelpers.get_key(unit, :ap)} pos=(#{MapHelpers.get_key(pos, :x)},#{MapHelpers.get_key(pos, :y)}) cover=#{get(unit, :cover?, false)} status=#{MapHelpers.get_key(unit, :status)}"
      )
    end)

    IO.puts(
      "status=#{MapHelpers.get_key(state.world, :status)} winner=#{inspect(MapHelpers.get_key(state.world, :winner))}"
    )
  end

  defp get_unit(world, unit_id) when is_binary(unit_id) do
    world
    |> get(:units, %{})
    |> Map.get(unit_id)
  end

  defp get_unit(_world, _unit_id), do: nil

  # -- Config resolution --

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Skirmish example requires a valid default model.
        Configure [defaults].provider + [defaults].model (or [agent].default_*) in Lemon config,
        or pass an explicit model via the mix task.
        """
    end
  end

  defp resolve_model_spec(provider, model_spec) when is_binary(model_spec) do
    trimmed = String.trim(model_spec)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, ":") ->
        case String.split(trimmed, ":", parts: 2) do
          [provider_name, model_id] -> lookup_model(provider_name, model_id)
          _ -> nil
        end

      String.contains?(trimmed, "/") ->
        case String.split(trimmed, "/", parts: 2) do
          [provider_name, model_id] -> lookup_model(provider_name, model_id)
          _ -> lookup_model(provider, trimmed)
        end

      true ->
        lookup_model(provider, trimmed)
    end
  end

  defp resolve_model_spec(_provider, _model_spec), do: nil

  defp lookup_model(nil, model_id), do: Ai.Models.find_by_id(model_id)
  defp lookup_model("", model_id), do: Ai.Models.find_by_id(model_id)

  defp lookup_model(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    normalized = normalize_provider(provider)

    Ai.Models.get_model(normalized, model_id) ||
      Ai.Models.get_model(String.to_atom(String.trim(provider)), model_id)
  end

  defp apply_provider_base_url(%Ai.Types.Model{} = model, config) do
    provider_name = provider_name(model.provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)
    base_url = provider_cfg[:base_url]

    if is_binary(base_url) and base_url != "" and base_url != model.base_url do
      %{model | base_url: base_url}
    else
      model
    end
  end

  defp resolve_provider_api_key!(provider, config) do
    provider_name = provider_name(provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)

    cond do
      provider_name == "openai-codex" ->
        case LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_access_token() do
          token when is_binary(token) and token != "" ->
            token

          _ ->
            raise "skirmish sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "skirmish sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "skirmish sim requires configured credentials for #{provider_name}"
    end
  end

  @provider_aliases %{
    "gemini" => "google_gemini_cli",
    "gemini_cli" => "google_gemini_cli",
    "gemini-cli" => "google_gemini_cli",
    "openai_codex" => "openai-codex"
  }

  defp provider_name(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> canonical_provider_name()

  defp provider_name(provider) when is_binary(provider), do: canonical_provider_name(provider)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_provider(provider_name) do
    provider_name
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> canonical_provider_name()
    |> String.to_atom()
  end

  defp canonical_provider_name(provider_name) do
    normalized =
      provider_name
      |> String.trim()
      |> String.downcase()

    Map.get(@provider_aliases, normalized, normalized)
  end

  defp resolve_secret_api_key(secret_name, secret_value)
       when is_binary(secret_name) and is_binary(secret_value) do
    case LemonAiRuntime.Auth.OAuthSecretResolver.resolve_api_key_from_secret(secret_name, secret_value) do
      {:ok, resolved_api_key} when is_binary(resolved_api_key) and resolved_api_key != "" ->
        resolved_api_key

      :ignore ->
        secret_value

      {:error, _reason} ->
        secret_value
    end
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
