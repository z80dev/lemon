defmodule LemonSim.Examples.Auction do
  @moduledoc """
  Auction House economics game built on LemonSim.

  A 4-6 player free-for-all where agents bid on rare items, manage budgets,
  and complete secret objectives. Items come in three categories (gems,
  artifacts, scrolls) with set bonuses rewarding collection strategies.

  Players: 4-6 agents, each starting with 100 gold.
  Rounds: 8 rounds, 1-2 items auctioned per round (10 items total).
  Scoring: item base values + set bonuses + remaining gold/10 + secret objective bonuses.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers
  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.Auction.{
    ActionSpace,
    GameLog,
    Items,
    Updater
  }

  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 120
  @default_player_count 4
  @starting_gold 100

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, @default_player_count)
    player_count = max(4, min(6, player_count))
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))

    player_ids = Items.collector_names(player_count)
    schedule = Items.generate_schedule(seed)
    objectives = Items.assign_objectives(player_ids, seed)
    traits = Items.assign_traits(player_ids)
    connections = Items.generate_connections(player_ids)

    players =
      Enum.into(player_ids, %{}, fn pid ->
        {pid,
         %{
           gold: @starting_gold,
           items: [],
           secret_objective: Map.get(objectives, pid, "collect_2_gems"),
           status: "active"
         }}
      end)

    first_item = List.first(schedule)

    %{
      players: players,
      traits: traits,
      connections: connections,
      journals: %{},
      auction_schedule: schedule,
      current_round: 1,
      max_rounds: 8,
      current_item: first_item,
      current_item_index: 0,
      high_bid: 0,
      high_bidder: nil,
      active_bidders: player_ids,
      active_actor_id: List.first(player_ids),
      turn_order: player_ids,
      bid_history: [],
      auction_results: [],
      phase: "bidding",
      status: "in_progress",
      winner: nil,
      scores: %{}
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id = Keyword.get(opts, :sim_id, "auction_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Win the auction house game by collecting valuable items, completing your secret objective, and managing your gold wisely."
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
            title: "Auction House",
            format: :json,
            content: build_player_view(frame.world, actor_id)
          }
        end,
        your_profile: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)

          %{
            id: :your_profile,
            title: "Your Collector Profile",
            format: :json,
            content: build_profile_view(frame.world, actor_id)
          }
        end,
        auction_status: fn frame, _tools, _opts ->
          %{
            id: :auction_status,
            title: "Current Auction",
            format: :json,
            content: build_auction_view(frame.world)
          }
        end,
        opponents: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)

          %{
            id: :opponents,
            title: "Other Collectors",
            format: :json,
            content: build_opponents_view(frame.world, actor_id)
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: Enum.take(frame.recent_events, -12)
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        AUCTION STRATEGY:
        - You MUST use exactly one tool call per turn: either `place_bid` or `pass_auction`.
        - Consider your secret objective when deciding what to bid on.
        - Track how much gold you have left - you need gold for future rounds too.
        - Set bonuses can be very valuable: 3 of a kind or collecting across categories.
        - Watch what other players are collecting to assess competition.
        - Sometimes it's better to let an item go than to overpay.
        - Remaining gold contributes to your score (gold/10).
        - The minimum bid increment is 2 gold above the current high bid.

        PERSONALITY GUIDANCE:
        - Stay in character according to your collector profile and personality traits.
        - Let your traits influence HOW you bid, not just WHETHER you bid.
        - Consider your backstory connections — rivalries may push you to outbid certain collectors, while old partnerships may make you yield.
        """
      },
      section_order: [
        :world_state,
        :your_profile,
        :auction_status,
        :opponents,
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

    IO.puts("Starting Auction House with #{length(get(state.world, :turn_order, []))} players")
    IO.puts("Items scheduled: #{length(get(state.world, :auction_schedule, []))}")
    if log_path, do: IO.puts("Logging to: #{log_path}")

    result =
      case Runner.run_until_terminal(state, modules(), run_opts) do
        {:ok, final_state} ->
          IO.puts("\n=== FINAL RESULTS ===")
          print_final_scores(final_state)

          if game_log do
            step = final_state.version
            GameLog.log_game_over(game_log, step, final_state.world)
          end

          if Keyword.get(run_opts, :persist?, true) do
            _ = Store.put_state(final_state)
          end

          {:ok, final_state}

        {:error, reason} = error ->
          IO.puts("Auction House failed:")
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
          events = Map.get(next_state, :recent_events, [])
          GameLog.log_step(game_log, step, next_state.world, events)
          print_step_internal(next_state)

        _ ->
          :ok
      end
    end
  end

  defp print_step_internal(next_state) do
    phase = get(next_state.world, :phase, "bidding")
    status = get(next_state.world, :status, "in_progress")

    cond do
      status == "game_over" ->
        IO.puts("Game Over!")

      phase == "bidding" ->
        active = get(next_state.world, :active_bidders, [])
        high = get(next_state.world, :high_bid, 0)
        bidder = get(next_state.world, :high_bidder, "none")
        IO.puts("  Bidders remaining: #{length(active)} | High bid: #{high} by #{bidder}")

      true ->
        IO.puts("  Phase: #{phase} | Status: #{status}")
    end
  end

  # -- Projector View Builders --

  defp build_player_view(world, actor_id) do
    player = get_player(world, actor_id)

    if player do
      %{
        "your_id" => actor_id,
        "your_gold" => get(player, :gold, 0),
        "your_items" =>
          Enum.map(get(player, :items, []), fn item ->
            %{
              "name" => get(item, :name, "Unknown"),
              "category" => get(item, :category, "unknown"),
              "base_value" => get(item, :base_value, 0)
            }
          end),
        "your_secret_objective" =>
          Items.objective_description(get(player, :secret_objective, "")),
        "round" => get(world, :current_round, 1),
        "max_rounds" => get(world, :max_rounds, 8),
        "items_remaining" =>
          length(get(world, :auction_schedule, [])) -
            length(get(world, :auction_results, [])) - 1
      }
    else
      %{"status" => get(world, :status, "unknown")}
    end
  end

  defp build_auction_view(world) do
    current_item = get(world, :current_item, %{})

    %{
      "item_name" => get(current_item, :name, "Unknown"),
      "item_category" => get(current_item, :category, "unknown"),
      "item_base_value" => get(current_item, :base_value, 0),
      "high_bid" => get(world, :high_bid, 0),
      "high_bidder" => get(world, :high_bidder, nil),
      "active_bidders" => get(world, :active_bidders, []),
      "bid_count" => length(get(world, :bid_history, []))
    }
  end

  defp build_opponents_view(world, actor_id) do
    players = get(world, :players, %{})
    traits = get(world, :traits, %{})

    players
    |> Enum.reject(fn {pid, _} -> pid == actor_id end)
    |> Enum.map(fn {pid, player} ->
      opponent_traits = Map.get(traits, pid, [])

      %{
        "name" => pid,
        "reputation" => format_trait_labels(opponent_traits),
        "wealth" => Items.wealth_indicator(get(player, :gold, 0)),
        "item_count" => length(get(player, :items, [])),
        "items" =>
          Enum.map(get(player, :items, []), fn item ->
            %{
              "name" => get(item, :name, "Unknown"),
              "category" => get(item, :category, "unknown")
            }
          end)
      }
    end)
  end

  defp build_profile_view(world, actor_id) do
    traits = get(world, :traits, %{})
    connections = get(world, :connections, [])

    player_traits = Map.get(traits, actor_id, [])
    player_connections = Items.connections_for_player(connections, actor_id)

    %{
      "name" => actor_id,
      "traits" => player_traits,
      "trait_descriptions" => Enum.map(player_traits, &Items.trait_description/1),
      "connections" =>
        Enum.map(player_connections, fn conn ->
          %{
            "type" => Map.get(conn, :type, "unknown"),
            "with" =>
              conn
              |> Map.get(:players, [])
              |> Enum.reject(&(&1 == actor_id))
              |> List.first(),
            "description" => Map.get(conn, :description, "")
          }
        end)
    }
  end

  defp format_trait_labels(traits) when is_list(traits) and length(traits) > 0 do
    traits
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(", ")
  end

  defp format_trait_labels(_), do: "Unknown"

  # -- Callbacks --

  defp terminal?(state) do
    status = get(state.world, :status, "in_progress")
    status == "game_over"
  end

  defp announce_turn(turn, state) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)
    round = get(state.world, :current_round, 1)
    current_item = get(state.world, :current_item, %{})
    item_name = get(current_item, :name, "?")
    high_bid = get(state.world, :high_bid, 0)

    IO.puts(
      "Step #{turn} | round=#{round} actor=#{actor_id} item=#{item_name} high_bid=#{high_bid}"
    )
  end

  defp print_step(_turn, %{state: next_state}) do
    phase = get(next_state.world, :phase, "bidding")
    status = get(next_state.world, :status, "in_progress")

    cond do
      status == "game_over" ->
        IO.puts("Game Over!")

      phase == "bidding" ->
        active = get(next_state.world, :active_bidders, [])
        high = get(next_state.world, :high_bid, 0)
        bidder = get(next_state.world, :high_bidder, "none")
        IO.puts("  Bidders remaining: #{length(active)} | High bid: #{high} by #{bidder}")

      true ->
        IO.puts("  Phase: #{phase} | Status: #{status}")
    end
  end

  defp print_step(_turn, _result), do: :ok

  defp print_final_scores(state) do
    scores = get(state.world, :scores, %{})
    players = get(state.world, :players, %{})
    winner = get(state.world, :winner, nil)

    turn_order = get(state.world, :turn_order, [])

    Enum.each(turn_order, fn pid ->
      score = Map.get(scores, pid, %{})
      player = Map.get(players, pid, %{})
      marker = if pid == winner, do: " <<< WINNER", else: ""

      IO.puts(
        "#{pid}: total=#{get(score, :total, 0)} (items=#{get(score, :item_value, 0)} sets=#{get(score, :set_bonus, 0)} gold=#{get(score, :gold_bonus, 0)} objective=#{get(score, :objective_bonus, 0)}) gold_left=#{get(player, :gold, 0)} items=#{length(get(player, :items, []))}#{marker}"
      )
    end)
  end

  # -- Config resolution (shared pattern from other examples) --

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Auction House example requires a valid default model.
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
            raise "auction sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "auction sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "auction sim requires configured credentials for #{provider_name}"
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

  defp get_player(world, player_id) when is_binary(player_id) do
    world
    |> get(:players, %{})
    |> Map.get(player_id)
  end

  defp get_player(_world, _player_id), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
