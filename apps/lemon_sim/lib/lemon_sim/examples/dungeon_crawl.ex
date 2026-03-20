defmodule LemonSim.Examples.DungeonCrawl do
  @moduledoc """
  Cooperative dungeon crawl example built on LemonSim.

  A party of 2-4 adventurers (Warrior, Rogue, Mage, Cleric) work together
  to clear 5 procedurally generated dungeon rooms. Each room has enemies,
  optional traps, and optional treasure. The final room contains a boss.

  This is a PvE (players vs environment) cooperative game where all players
  share full information and work together to survive.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.DungeonCrawl.{
    ActionSpace,
    DungeonGenerator,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 120

  @character_names %{
    "warrior" => ["Thorin", "Brynn", "Kael", "Helga"],
    "rogue" => ["Shadow", "Wren", "Flick", "Nyx"],
    "mage" => ["Aldric", "Zara", "Ember", "Rune"],
    "cleric" => ["Sera", "Oswin", "Dawn", "Mercy"]
  }

  @traits ~w(reckless cautious glory_seeker protector scholar berserker compassionate tactical)

  @trait_descriptions %{
    "reckless" => "You are RECKLESS — you charge in first, ask questions never. The thrill of combat drives you forward.",
    "cautious" => "You are CAUTIOUS — you check every corner, test every floor tile, and never rush into a room.",
    "glory_seeker" => "You are a GLORY SEEKER — you want the killing blow, the dramatic save, the story worth telling at the tavern.",
    "protector" => "You are a PROTECTOR — your party members' safety comes before everything. You'll take a hit for anyone.",
    "scholar" => "You are a SCHOLAR — you study your enemies, exploit weaknesses, and believe knowledge is the sharpest weapon.",
    "berserker" => "You are a BERSERKER — when blood is drawn, something primal takes over. You attack the strongest enemy first, always.",
    "compassionate" => "You are COMPASSIONATE — you heal before fighting, prioritize the wounded, and believe mercy is strength.",
    "tactical" => "You are TACTICAL — you coordinate attacks, call targets, and think of the party as a single fighting unit."
  }

  @connection_types ~w(sworn_oath tavern_debt old_quest siblings_in_arms rescued mentor_student)

  @connection_templates %{
    "sworn_oath" => " swore a blood oath to protect each other after surviving a near-death encounter.",
    "tavern_debt" => ": the first owes the second a considerable sum from a legendary night of gambling.",
    "old_quest" => " adventured together before and know how the other fights. They can anticipate each other's moves.",
    "siblings_in_arms" => " trained at the same academy and consider each other closer than family.",
    "rescued" => ": the first once saved the second's life in a collapsing dungeon. The debt weighs heavily.",
    "mentor_student" => ": the first taught the second their craft. Pride and protectiveness mix in equal measure."
  }

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    party_size = Keyword.get(opts, :party_size, 4)

    rooms = DungeonGenerator.generate(seed: seed)
    party = build_party(party_size)
    turn_order = build_turn_order(party_size)

    first_room = List.first(rooms) || %{}
    initial_enemies = load_room_enemies(first_room)

    # Assign personality traits to each party member (1-2 traits each)
    class_ids = Map.keys(party)
    traits = assign_traits(class_ids)
    connections = generate_connections(class_ids, party)

    # Enrich party members with traits
    party =
      Enum.into(party, %{}, fn {id, member} ->
        {id, Map.put(member, :traits, Map.get(traits, id, []))}
      end)

    %{
      rooms: rooms,
      current_room: 0,
      party: party,
      enemies: initial_enemies,
      active_actor_id: List.first(turn_order),
      turn_order: turn_order,
      round: 1,
      inventory: [],
      buffs: %{},
      taunt_active: nil,
      attacks_this_turn: [],
      combat_log: [],
      traits: traits,
      connections: connections,
      journals: %{},
      status: "in_progress",
      winner: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "dungeon_crawl_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Clear all 5 dungeon rooms cooperatively. Keep the party alive. " <>
            "Use abilities strategically: Warrior tanks with taunt, Rogue uses backstab after allies attack, " <>
            "Mage uses fireball for AoE, Cleric heals wounded allies. Focus fire on dangerous enemies first."
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
          world = frame.world
          current_room_index = MapHelpers.get_key(world, :current_room) || 0
          rooms = get(world, :rooms, [])
          current_room = Enum.at(rooms, current_room_index, %{})

          %{
            id: :world_state,
            title: "Dungeon Status",
            format: :json,
            content: %{
              "current_room" => current_room_index + 1,
              "total_rooms" => length(rooms),
              "room_name" => get(current_room, :name, "Unknown"),
              "round" => MapHelpers.get_key(world, :round),
              "status" => MapHelpers.get_key(world, :status),
              "rooms_cleared" => Enum.count(rooms, fn r -> get(r, :cleared, false) end),
              "traps" => format_traps(current_room),
              "inventory" => format_inventory(get(world, :inventory, []))
            }
          }
        end,
        party_status: fn frame, _tools, _opts ->
          world = frame.world
          party = get(world, :party, %{})
          buffs = get(world, :buffs, %{})
          active_id = MapHelpers.get_key(world, :active_actor_id)
          traits_map = get(world, :traits, %{})
          connections = get(world, :connections, [])

          party_members =
            Enum.map(get(world, :turn_order, []), fn id ->
              adventurer = Map.get(party, id, %{})
              actor_buffs = Map.get(buffs, id, [])
              actor_traits = Map.get(traits_map, id, [])

              trait_descriptions =
                Enum.map(actor_traits, fn t ->
                  Map.get(@trait_descriptions, t, t)
                end)

              %{
                "id" => id,
                "name" => get(adventurer, :name, id),
                "class" => get(adventurer, :class, "?"),
                "personality" => Enum.join(actor_traits, ", "),
                "personality_detail" => trait_descriptions,
                "hp" => get(adventurer, :hp, 0),
                "max_hp" => get(adventurer, :max_hp, 0),
                "ap" => get(adventurer, :ap, 0),
                "max_ap" => get(adventurer, :max_ap, 0),
                "attack" => get(adventurer, :attack, 0),
                "armor" => get(adventurer, :armor, 0),
                "range" => get(adventurer, :range, 1),
                "status" => if(get(adventurer, :hp, 0) > 0, do: "alive", else: "dead"),
                "active" => id == active_id,
                "buffs" =>
                  Enum.map(actor_buffs, fn b ->
                    "#{get(b, :type, "?")} (#{get(b, :remaining_turns, 0)} turns)"
                  end)
              }
            end)

          %{
            id: :party_status,
            title: "Party Status",
            format: :json,
            content: %{
              "members" => party_members,
              "connections" => connections
            }
          }
        end,
        enemy_status: fn frame, _tools, _opts ->
          enemies = get(frame.world, :enemies, %{})

          %{
            id: :enemy_status,
            title: "Enemies",
            format: :json,
            content:
              enemies
              |> Enum.sort_by(fn {id, _} -> id end)
              |> Enum.map(fn {id, enemy} ->
                %{
                  "id" => id,
                  "type" => get(enemy, :type, "?"),
                  "hp" => get(enemy, :hp, 0),
                  "max_hp" => get(enemy, :max_hp, 0),
                  "attack" => get(enemy, :attack, 0),
                  "status" => get(enemy, :status, "alive")
                }
              end)
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Combat Log",
            format: :json,
            content: Enum.take(frame.recent_events, -15)
          }
        end,
        decision_contract: fn frame, _tools, _opts ->
          world = frame.world
          active_id = MapHelpers.get_key(world, :active_actor_id)
          party = get(world, :party, %{})
          actor = Map.get(party, active_id, %{})
          char_name = get(actor, :name, active_id)
          class = get(actor, :class, "adventurer")
          traits_map = get(world, :traits, %{})
          actor_traits = Map.get(traits_map, active_id, [])
          trait_label = Enum.join(actor_traits, " and ")

          trait_reminder =
            actor_traits
            |> Enum.map(fn t -> Map.get(@trait_descriptions, t, "") end)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join(" ")

          identity_line =
            "You are #{char_name}, a #{class}" <>
              if(trait_label != "", do: " with a #{trait_label} personality", else: "") <>
              ". Stay in character."

          %{
            id: :decision_contract,
            title: "Decision Contract",
            format: :markdown,
            content: """
            #{identity_line}
            #{trait_reminder}

            DUNGEON CRAWL TACTICS:
            - You control the ACTIVE adventurer shown in party status.
            - COOPERATIVE: All party members work together against enemies.
            - Focus fire: concentrate attacks on one enemy to kill it quickly.
            - Warrior: Use TAUNT when allies are low HP to absorb enemy attacks.
            - Rogue: Use BACKSTAB after another ally has attacked the same target this turn for double damage.
            - Mage: Use FIREBALL when facing multiple enemies (costs 2 AP).
            - Cleric: HEAL wounded allies first, then BLESS the highest-damage dealer.
            - Rogue: DISARM TRAPS when entering rooms with active traps.
            - Use items wisely: healing potions on the most wounded, damage scrolls on tough enemies.
            - Do NOT end turn with unused AP if enemies are alive and actions are possible.
            - Each action costs 1 AP (fireball costs 2 AP).
            """
          }
        end
      },
      section_order: [
        :world_state,
        :party_status,
        :enemy_status,
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

    IO.puts("Starting Dungeon Crawl cooperative adventure")

    case Runner.run_until_terminal(state, modules(), run_opts) do
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

  # -- Party building --

  defp build_party(party_size) do
    all_classes = [
      {"warrior",
       %{
         class: "warrior",
         name: Enum.random(Map.get(@character_names, "warrior", ["Thorin"])),
         hp: 20,
         max_hp: 20,
         ap: 2,
         max_ap: 2,
         attack: 4,
         armor: 2,
         range: 1,
         abilities: ["taunt"],
         status: "alive"
       }},
      {"rogue",
       %{
         class: "rogue",
         name: Enum.random(Map.get(@character_names, "rogue", ["Shadow"])),
         hp: 14,
         max_hp: 14,
         ap: 3,
         max_ap: 3,
         attack: 5,
         armor: 0,
         range: 1,
         abilities: ["backstab", "disarm_trap"],
         status: "alive"
       }},
      {"mage",
       %{
         class: "mage",
         name: Enum.random(Map.get(@character_names, "mage", ["Aldric"])),
         hp: 12,
         max_hp: 12,
         ap: 3,
         max_ap: 3,
         attack: 3,
         armor: 0,
         range: 3,
         abilities: ["fireball"],
         status: "alive"
       }},
      {"cleric",
       %{
         class: "cleric",
         name: Enum.random(Map.get(@character_names, "cleric", ["Sera"])),
         hp: 16,
         max_hp: 16,
         ap: 2,
         max_ap: 2,
         attack: 2,
         armor: 0,
         range: 2,
         heal: 4,
         abilities: ["heal", "bless"],
         status: "alive"
       }}
    ]

    all_classes
    |> Enum.take(min(party_size, 4))
    |> Enum.into(%{}, fn {id, stats} -> {id, stats} end)
  end

  defp build_turn_order(party_size) do
    all_order = ["warrior", "rogue", "mage", "cleric"]
    Enum.take(all_order, min(party_size, 4))
  end

  defp assign_traits(class_ids) do
    Enum.into(class_ids, %{}, fn id ->
      count = Enum.random(1..2)
      chosen = @traits |> Enum.shuffle() |> Enum.take(count)
      {id, chosen}
    end)
  end

  defp generate_connections(class_ids, _party) when length(class_ids) < 2, do: []

  defp generate_connections(class_ids, party) do
    pairs =
      for a <- class_ids, b <- class_ids, a < b, do: {a, b}

    # Pick 2-3 connections (or all pairs if fewer)
    count = min(Enum.random(2..3), length(pairs))

    pairs
    |> Enum.shuffle()
    |> Enum.take(count)
    |> Enum.map(fn {a, b} ->
      conn_type = Enum.random(@connection_types)
      template = Map.get(@connection_templates, conn_type, " share a mysterious bond.")

      name_a = get(Map.get(party, a, %{}), :name, a)
      name_b = get(Map.get(party, b, %{}), :name, b)

      %{
        "between" => [a, b],
        "type" => conn_type,
        "description" => "#{name_a} (#{a}) and #{name_b} (#{b})" <> template
      }
    end)
  end

  defp load_room_enemies(room) do
    room
    |> get(:enemies, [])
    |> Enum.into(%{}, fn enemy ->
      {get(enemy, :id, "unknown"), enemy}
    end)
  end

  # -- Projector helpers --

  defp format_traps(room) do
    traps = get(room, :traps, [])

    Enum.map(traps, fn trap ->
      %{
        "type" => get(trap, :type, "unknown"),
        "damage" => get(trap, :damage, 0),
        "target" => get(trap, :target, "single"),
        "disarmed" => get(trap, :disarmed, false)
      }
    end)
  end

  defp format_inventory(inventory) do
    Enum.map(inventory, fn item ->
      %{
        "name" => get(item, :name, "unknown"),
        "effect" => get(item, :effect, "unknown"),
        "value" => get(item, :value, 0)
      }
    end)
  end

  # -- Callbacks --

  defp terminal?(state) do
    MapHelpers.get_key(state.world, :status) in ["won", "lost"]
  end

  defp announce_turn(turn, state) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)
    party = get(state.world, :party, %{})
    actor = Map.get(party, actor_id, %{})
    class = get(actor, :class, "?")
    char_name = get(actor, :name, actor_id)
    room = (MapHelpers.get_key(state.world, :current_room) || 0) + 1

    IO.puts(
      "Step #{turn} | room=#{room} round=#{MapHelpers.get_key(state.world, :round)} actor=#{actor_id}/#{char_name} (#{class})"
    )
  end

  defp print_step(_turn, %{state: next_state}) do
    print_party(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_party(state) do
    party = get(state.world, :party, %{})
    enemies = get(state.world, :enemies, %{})

    IO.puts("Party:")

    Enum.each(get(state.world, :turn_order, []), fn id ->
      adventurer = Map.get(party, id, %{})
      char_name = get(adventurer, :name, id)

      IO.puts(
        "  #{id}/#{char_name} [#{get(adventurer, :class, "?")}] hp=#{get(adventurer, :hp, 0)}/#{get(adventurer, :max_hp, 0)} ap=#{get(adventurer, :ap, 0)}"
      )
    end)

    IO.puts("Enemies:")

    Enum.each(Enum.sort(Map.keys(enemies)), fn id ->
      enemy = Map.get(enemies, id, %{})

      IO.puts(
        "  #{id} [#{get(enemy, :type, "?")}] hp=#{get(enemy, :hp, 0)}/#{get(enemy, :max_hp, 0)} status=#{get(enemy, :status, "?")}"
      )
    end)

    IO.puts(
      "status=#{MapHelpers.get_key(state.world, :status)} room=#{(MapHelpers.get_key(state.world, :current_room) || 0) + 1}/5"
    )
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
        Dungeon Crawl example requires a valid default model.
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
            raise "dungeon crawl sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "dungeon crawl sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "dungeon crawl sim requires configured credentials for #{provider_name}"
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
