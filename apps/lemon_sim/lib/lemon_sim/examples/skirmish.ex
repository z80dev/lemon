defmodule LemonSim.Examples.Skirmish do
  @moduledoc """
  Small tactical skirmish example built on LemonSim.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers
  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.Skirmish.{
    ActionSpace,
    Updater,
    Visibility
  }

  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 24

  @spec initial_world() :: map()
  def initial_world do
    %{
      map: %{
        width: 5,
        height: 5,
        cover: [%{x: 1, y: 1}, %{x: 3, y: 3}]
      },
      units: %{
        "red_1" => %{
          team: "red",
          hp: 8,
          max_hp: 8,
          ap: 2,
          max_ap: 2,
          pos: %{x: 0, y: 0},
          status: "alive",
          cover?: false,
          attack_range: 2,
          attack_damage: 3,
          attack_chance: 100
        },
        "blue_1" => %{
          team: "blue",
          hp: 8,
          max_hp: 8,
          ap: 2,
          max_ap: 2,
          pos: %{x: 2, y: 0},
          status: "alive",
          cover?: false,
          attack_range: 2,
          attack_damage: 3,
          attack_chance: 100
        }
      },
      turn_order: ["red_1", "blue_1"],
      active_actor_id: "red_1",
      phase: "main",
      round: 1,
      rng_seed: 5,
      winner: nil,
      status: "in_progress"
    }
  end

  @spec initial_state() :: State.t()
  def initial_state do
    State.new(
      sim_id: "skirmish_1",
      world: initial_world(),
      intent: %{goal: "Win the skirmish while preserving your unit"},
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
            content: Visibility.view_world(frame.world, actor_id)
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
        - Use exactly one terminal action tool each turn.
        - Attack when you have a clean kill or strong trade.
        - Move only to improve position or preserve health.
        - End the turn if no better action remains.
        """
      },
      section_order: [
        :world_state,
        :active_unit,
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
    run_opts = Keyword.merge(default_opts(opts), opts)

    IO.puts("Starting skirmish self-play")

    case Runner.run_until_terminal(initial_state(), modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("Final state:")
        IO.inspect(final_state.world)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Driver failed:")
        IO.inspect(reason)
        error
    end
  end

  defp terminal?(state), do: MapHelpers.get_key(state.world, :status) == "won"

  defp announce_turn(turn, state) do
    IO.puts(
      "Step #{turn} | round=#{MapHelpers.get_key(state.world, :round)} actor=#{MapHelpers.get_key(state.world, :active_actor_id)}"
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
        "#{unit_id} team=#{MapHelpers.get_key(unit, :team)} hp=#{MapHelpers.get_key(unit, :hp)} ap=#{MapHelpers.get_key(unit, :ap)} pos=(#{MapHelpers.get_key(pos, :x)},#{MapHelpers.get_key(pos, :y)}) cover=#{get(unit, :cover?, false)} status=#{MapHelpers.get_key(unit, :status)}"
      )
    end)

    IO.puts(
      "status=#{MapHelpers.get_key(state.world, :status)} winner=#{inspect(MapHelpers.get_key(state.world, :winner))}"
    )
  end

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
    provider
    |> normalize_provider()
    |> then(&Ai.Models.get_model(&1, model_id))
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
        case Ai.Auth.OpenAICodexOAuth.resolve_access_token() do
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
            value

          {:error, reason} ->
            raise "skirmish sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "skirmish sim requires configured credentials for #{provider_name}"
    end
  end

  defp provider_name(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_name(provider) when is_binary(provider), do: provider

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_provider(provider_name) do
    provider_name
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
