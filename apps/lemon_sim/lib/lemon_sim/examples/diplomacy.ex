defmodule LemonSim.Examples.Diplomacy do
  @moduledoc """
  Diplomacy-lite territory control game built on LemonSim.

  A 4-6 player free-for-all with private negotiation, simultaneous secret
  orders, alliance formation, and betrayal.

  Each round has three phases:
  1. **Diplomacy** - Players send private messages (max 2 per round)
  2. **Orders** - Players secretly assign orders to armies (move/hold/support)
  3. **Resolution** - All orders revealed and resolved simultaneously

  Win condition: First to control 7+ territories, or most territories after 10 rounds.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.Diplomacy.{
    ActionSpace,
    MapGraph,
    Performance,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 200
  @default_max_rounds 10

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, 4)
    player_count = max(4, min(6, player_count))

    starting = MapGraph.starting_positions(player_count)
    factions = MapGraph.factions()
    adjacency = MapGraph.adjacency()

    # Build players
    players =
      Enum.into(1..player_count, %{}, fn idx ->
        id = "player_#{idx}"
        faction = Map.get(factions, id, "Faction #{idx}")
        {id, %{faction: faction, status: "alive"}}
      end)

    turn_order = Enum.map(1..player_count, &"player_#{&1}")

    # Build territories
    territories =
      adjacency
      |> Map.keys()
      |> Enum.into(%{}, fn name ->
        # Check if any player starts here
        owner =
          Enum.find_value(starting, fn {player_id, home_territory} ->
            if home_territory == name, do: player_id, else: nil
          end)

        info =
          if owner do
            %{owner: owner, armies: 2}
          else
            %{owner: nil, armies: 0}
          end

        {name, info}
      end)

    %{
      territories: territories,
      adjacency: adjacency,
      players: players,
      phase: "diplomacy",
      round: 1,
      max_rounds: @default_max_rounds,
      active_actor_id: List.first(turn_order),
      turn_order: turn_order,
      private_messages: Enum.into(turn_order, %{}, &{&1, []}),
      message_history: [],
      messages_sent_this_round: %{},
      pending_orders: %{},
      orders_submitted: MapSet.new(),
      order_history: [],
      diplomacy_done: MapSet.new(),
      capture_history: [],
      resolution_log: [],
      status: "in_progress",
      winner: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "diplomacy_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Win the diplomacy game by controlling 7+ territories. " <>
            "Form alliances, negotiate, coordinate attacks, and betray when advantageous. " <>
            "You are the active player shown in world state."
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
            title: "World State",
            format: :json,
            content: visible_world(frame.world, actor_id)
          }
        end,
        your_faction: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          players = get(frame.world, :players, %{})
          player_info = Map.get(players, actor_id, %{})

          territories = get(frame.world, :territories, %{})

          owned =
            territories
            |> Enum.filter(fn {_name, info} -> get(info, :owner, nil) == actor_id end)
            |> Enum.map(fn {name, info} ->
              %{"territory" => name, "armies" => get(info, :armies, 0)}
            end)

          adjacency = get(frame.world, :adjacency, %{})

          neighbors =
            owned
            |> Enum.flat_map(fn t ->
              Map.get(adjacency, t["territory"], [])
            end)
            |> Enum.uniq()
            |> Enum.reject(fn n -> Enum.any?(owned, &(&1["territory"] == n)) end)
            |> Enum.map(fn n ->
              info = Map.get(territories, n, %{})

              %{
                "territory" => n,
                "owner" => get(info, :owner, nil),
                "armies" => get(info, :armies, 0)
              }
            end)

          %{
            id: :your_faction,
            title: "Your Faction (#{actor_id})",
            format: :json,
            content: %{
              "player_id" => actor_id,
              "faction" => get(player_info, :faction, "Unknown"),
              "territories_owned" => owned,
              "territory_count" => length(owned),
              "adjacent_targets" => neighbors,
              "win_threshold" => 7
            }
          }
        end,
        diplomacy_inbox: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          inbox = get(frame.world, :private_messages, %{})
          my_messages = Map.get(inbox, actor_id, [])

          %{
            id: :diplomacy_inbox,
            title: "Your Private Messages",
            format: :json,
            content: my_messages
          }
        end,
        pending_orders_view: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          pending = get(frame.world, :pending_orders, %{})
          my_orders = Map.get(pending, actor_id, %{})

          %{
            id: :pending_orders_view,
            title: "Your Pending Orders",
            format: :json,
            content: my_orders
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: Enum.take(frame.recent_events, -15)
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        DIPLOMACY RULES:
        - In the DIPLOMACY phase: send up to 2 private messages, then end_diplomacy.
        - Messages are private - only the recipient sees them. You may lie, bluff, or be truthful.
        - In the ORDERS phase: issue orders to each army, then submit_orders.
        - Order types: "move" (attack adjacent territory), "hold" (defend), "support" (boost another army's move).
        - All orders resolve simultaneously. Highest strength wins contested territories. Ties bounce.
        - Strength = armies moving in + support from adjacent armies.
        - STRATEGY: Coordinate with allies to concentrate force. Betray when it gives you the win.
        - You MUST call end_diplomacy or submit_orders to finish your turn. Do not stall.
        - First to 7 territories wins. After 10 rounds, most territories wins.
        """
      },
      section_order: [
        :world_state,
        :your_faction,
        :diplomacy_inbox,
        :pending_orders_view,
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

    run_opts =
      default_opts(opts)
      |> Keyword.merge(opts)

    IO.puts("Starting Diplomacy game with #{length(get(state.world, :turn_order, []))} players")
    IO.puts("Map: #{length(Map.keys(get(state.world, :territories, %{})))} territories")

    case Runner.run_until_terminal(state, modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("\nGame Over!")
        print_final_state(final_state)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Game failed:")
        IO.inspect(reason)
        error
    end
  end

  # -- Visibility --

  defp visible_world(world, _actor_id) do
    territories = get(world, :territories, %{})
    adjacency = get(world, :adjacency, %{})
    players = get(world, :players, %{})

    territory_view =
      Enum.into(territories, %{}, fn {name, info} ->
        {name,
         %{
           "owner" => get(info, :owner, nil),
           "armies" => get(info, :armies, 0),
           "adjacent" => Map.get(adjacency, name, [])
         }}
      end)

    player_view =
      Enum.into(players, %{}, fn {id, info} ->
        count =
          territories
          |> Enum.count(fn {_name, t_info} -> get(t_info, :owner, nil) == id end)

        {id,
         %{
           "faction" => get(info, :faction, "Unknown"),
           "territory_count" => count,
           "status" => get(info, :status, "alive")
         }}
      end)

    %{
      "phase" => get(world, :phase, "diplomacy"),
      "round" => get(world, :round, 1),
      "max_rounds" => get(world, :max_rounds, 10),
      "active_player" => MapHelpers.get_key(world, :active_actor_id),
      "territories" => territory_view,
      "players" => player_view
    }
  end

  # -- Callbacks --

  defp terminal?(state) do
    status = MapHelpers.get_key(state.world, :status)
    status == "won"
  end

  defp announce_turn(turn, state) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)
    phase = get(state.world, :phase, "?")
    round = get(state.world, :round, 1)

    IO.puts("Step #{turn} | round=#{round} phase=#{phase} actor=#{actor_id}")
  end

  defp print_step(_turn, %{state: next_state}) do
    print_territory_summary(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_territory_summary(state) do
    territories = get(state.world, :territories, %{})
    players = get(state.world, :players, %{})

    IO.puts("Territory control:")

    players
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn player_id ->
      owned =
        territories
        |> Enum.filter(fn {_name, info} -> get(info, :owner, nil) == player_id end)
        |> Enum.map(fn {name, info} -> "#{name}(#{get(info, :armies, 0)})" end)
        |> Enum.join(", ")

      count =
        territories
        |> Enum.count(fn {_name, info} -> get(info, :owner, nil) == player_id end)

      player_info = Map.get(players, player_id, %{})
      faction = get(player_info, :faction, "?")
      IO.puts("  #{player_id} [#{faction}]: #{count} territories - #{owned}")
    end)

    IO.puts(
      "status=#{get(state.world, :status, "?")} winner=#{inspect(get(state.world, :winner, nil))}"
    )
  end

  defp print_final_state(state) do
    print_territory_summary(state)

    winner = get(state.world, :winner, nil)
    round = get(state.world, :round, 1)
    performance = Performance.summarize(state.world)

    if winner do
      players = get(state.world, :players, %{})
      player_info = Map.get(players, winner, %{})
      faction = get(player_info, :faction, "Unknown")
      IO.puts("\nWinner: #{winner} (#{faction}) after #{round - 1} rounds!")
    end

    IO.puts("\nPerformance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {_player, metrics} ->
      {get(metrics, :final_territories, 0) * -1, get(metrics, :territories_captured, 0) * -1}
    end)
    |> Enum.each(fn {player_id, metrics} ->
      IO.puts(
        "  #{player_id}#{if get(metrics, :won, false), do: " [winner]", else: ""}: " <>
          "messages_sent=#{get(metrics, :messages_sent, 0)} " <>
          "orders_submitted=#{get(metrics, :orders_submitted, 0)} " <>
          "support_orders=#{get(metrics, :support_orders, 0)} " <>
          "territories_captured=#{get(metrics, :territories_captured, 0)} " <>
          "final_territories=#{get(metrics, :final_territories, 0)}"
      )
    end)
  end

  # -- Config resolution --

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Diplomacy example requires a valid default model.
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
        case Ai.Auth.OpenAICodexOAuth.resolve_access_token() do
          token when is_binary(token) and token != "" ->
            token

          _ ->
            raise "diplomacy sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "diplomacy sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "diplomacy sim requires configured credentials for #{provider_name}"
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
    case Ai.Auth.OAuthSecretResolver.resolve_api_key_from_secret(secret_name, secret_value) do
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
