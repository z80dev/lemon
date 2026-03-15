defmodule LemonSim.Examples.Werewolf do
  @moduledoc """
  Werewolf/Mafia social deduction game built on LemonSim.

  A multiplayer game (5-8 players) with hidden roles, day/night phases,
  voting, and deception. Each player is an AI agent with a secret role.

  ## Roles
  - Werewolves (2): Know each other. Kill one villager each night.
  - Seer (1): Investigates one player each night to learn their role.
  - Doctor (1): Protects one player from being killed each night.
  - Villagers (remaining): No special ability.

  ## Win Conditions
  - Villagers win if all werewolves are eliminated.
  - Werewolves win if they equal or outnumber villagers.
  """

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.EventHelpers

  alias LemonSim.GameHelpers.Runner, as: GameRunner

  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.Werewolf.{
    ActionSpace,
    Performance,
    Roles,
    TranscriptLogger,
    Updater
  }

  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.State

  @default_max_turns 200
  @default_player_count 6

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, @default_player_count)
    players = Roles.assign_roles(player_count)

    # Assign personality traits and backstory connections
    player_names = Map.keys(players)
    traits = Roles.assign_traits(player_names)
    backstory_connections = Roles.generate_connections(player_names)

    # Add traits to player maps
    players =
      Enum.into(players, %{}, fn {name, info} ->
        {name, Map.put(info, :traits, Map.get(traits, name, []))}
      end)

    # Start with wolf discussion if there are wolves
    living_wolves = Roles.living_with_role(players, "werewolf")

    {initial_phase, turn_order, first_actor} =
      if length(living_wolves) > 0 do
        {"wolf_discussion", living_wolves, List.first(living_wolves)}
      else
        night_order = Roles.night_turn_order(players)
        {"night", night_order, List.first(night_order)}
      end

    %{
      players: players,
      phase: initial_phase,
      day_number: 1,
      active_actor_id: first_actor,
      turn_order: turn_order,
      night_actions: %{},
      discussion_transcript: [],
      votes: %{},
      vote_history: [],
      elimination_log: [],
      seer_history: [],
      night_history: [],
      discussion_round: 0,
      discussion_round_limit: 0,
      status: "in_progress",
      winner: nil,
      # Day history for past days
      past_transcripts: %{},
      past_votes: %{},
      # Last words
      last_words: [],
      pending_elimination: nil,
      # Wolf chat
      wolf_chat_transcript: [],
      # Runoffs
      runoff_candidates: nil,
      # Personality & backstory
      backstory_connections: backstory_connections,
      # Internal journals
      journals: %{},
      # Evidence tokens
      evidence_tokens: [],
      # Night wandering
      wanderer_results: [],
      # Private meetings
      meeting_requests: %{},
      meeting_pairs: [],
      meeting_transcripts: [],
      current_meeting_index: 0,
      current_meeting_messages: [],
      # Village events
      village_event_history: [],
      current_village_event: nil,
      # Items
      player_items: %{}
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "werewolf_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Play Werewolf strategically based on your assigned role. " <>
            "If you are a werewolf, coordinate kills and deflect suspicion. " <>
            "If you are a villager/seer/doctor, find and eliminate the werewolves."
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
          actor_id = get(world, :active_actor_id)
          players = get(world, :players, %{})
          actor = Map.get(players, actor_id, %{})
          actor_role = get(actor, :role, "unknown")

          %{
            id: :world_state,
            title: "Game State",
            format: :json,
            content: build_player_view(world, actor_id, actor_role)
          }
        end,
        role_info: fn frame, _tools, _opts ->
          world = frame.world
          actor_id = get(world, :active_actor_id)
          players = get(world, :players, %{})
          actor = Map.get(players, actor_id, %{})
          actor_role = get(actor, :role, "unknown")

          %{
            id: :role_info,
            title: "Your Role (SECRET - do not reveal unless strategically advantageous)",
            format: :json,
            content: build_role_info(world, actor_id, actor_role)
          }
        end,
        discussion_log: fn frame, _tools, _opts ->
          transcript = get(frame.world, :discussion_transcript, [])
          elimination_log = get(frame.world, :elimination_log, [])
          last_words = get(frame.world, :last_words, [])
          meeting_transcripts = get(frame.world, :meeting_transcripts, [])

          %{
            id: :discussion_log,
            title: "Discussion & Events",
            format: :json,
            content: %{
              "discussion_transcript" =>
                Enum.map(transcript, fn entry ->
                  base = %{
                    "player" => get(entry, :player),
                    "statement" => get(entry, :statement, "")
                  }

                  if get(entry, :type) == "accusation" do
                    Map.merge(base, %{
                      "type" => "accusation",
                      "target" => get(entry, :target)
                    })
                  else
                    base
                  end
                end),
              "elimination_log" =>
                Enum.map(elimination_log, fn entry ->
                  %{
                    "player" => get(entry, :player),
                    "role" => get(entry, :role),
                    "reason" => get(entry, :reason),
                    "day" => get(entry, :day)
                  }
                end),
              "last_words" =>
                Enum.map(last_words, fn entry ->
                  %{
                    "player" => get(entry, :player),
                    "statement" => get(entry, :statement, "")
                  }
                end),
              "meeting_transcripts" =>
                meeting_transcripts
                |> Enum.filter(fn t -> get(t, :day) == get(frame.world, :day_number) end)
                |> Enum.map(fn t ->
                  %{
                    "pair" => get(t, :pair, []),
                    "messages" =>
                      Enum.map(get(t, :messages, []), fn m ->
                        %{"player" => get(m, :player), "message" => get(m, :message, "")}
                      end)
                  }
                end)
            }
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          actor_id = get(frame.world, :active_actor_id)
          players = get(frame.world, :players, %{})
          actor = Map.get(players, actor_id, %{})
          actor_role = get(actor, :role, "unknown")

          # Filter events to only show what this player should see
          filtered =
            frame.recent_events
            |> Enum.take(-15)
            |> Enum.filter(&event_visible?(&1, actor_id, actor_role))
            |> Enum.map(&sanitize_event(&1, actor_id, actor_role, players))

          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: filtered
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        WEREWOLF GAME RULES:
        - You are one of several players in a Werewolf/Mafia game.
        - Use exactly one tool call per turn.
        - During WOLF DISCUSSION: Werewolves privately discuss who to target before night actions.
        - During NIGHT: Use your role's night action (werewolves kill, seer investigates, doctor protects, villagers sleep or wander).
        - During MEETING SELECTION: Choose a player for a private 1-on-1 meeting.
        - During PRIVATE MEETING: Exchange private messages with your meeting partner.
        - During DAY DISCUSSION: Make a strategic statement or formally accuse another player.
        - During DAY VOTING: Vote to eliminate a suspicious player, or skip if unsure.
        - During RUNOFF DISCUSSION/VOTING: When no majority, top candidates face a runoff vote.
        - During LAST WORDS: An eliminated player gives their final statement before dying.
        - IMPORTANT: Your role is SECRET. Do not carelessly reveal it. Werewolves should pretend to be villagers.
        - PERSONALITY: Play your assigned personality traits. Let them influence how you speak and act.
        - CONNECTIONS: You have backstory relationships with some players. These may create trust or tension.
        - JOURNAL: Use the optional "thought" field in any tool to record private observations. These persist across days.
        - ITEMS: You may find items that provide tactical advantages. Use them wisely.
        - VILLAGE EVENTS: Random events may affect the village. Factor these into your strategy.
        - Think strategically about who might be a werewolf based on behavior and statements.
        - Dead players' roles are revealed, so use that information.
        - Use player names when referring to other players in discussion and tool calls.
        """
      },
      section_order: [
        :world_state,
        :role_info,
        :discussion_log,
        :recent_events,
        :current_intent,
        :available_actions,
        :decision_contract
      ]
    ]
  end

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    overrides = Keyword.put_new(overrides, :provider_min_interval_ms, %{google_gemini_cli: 5_000})

    GameRunner.build_default_opts(projector_opts(), overrides,
      game_name: "werewolf",
      max_turns: @default_max_turns,
      terminal?: &terminal?/1,
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    state = initial_state(opts)

    GameRunner.run(state, modules(), &default_opts/1, opts,
      print_setup: fn s ->
        IO.puts("Starting Werewolf game with #{map_size(get(s.world, :players, %{}))} players")
        print_role_assignments(s.world)
      end,
      print_result: &print_game_result/1
    )
  end

  @doc """
  Runs a Werewolf game with different models assigned to different players.

  ## Options
    * `:model_assignments` - map of player_name => {%Model{}, api_key_string}
    * `:transcript_path` - path to write JSONL transcript
    * All other opts from `run/1`
  """
  @spec run_multi_model(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run_multi_model(opts \\ []) when is_list(opts) do
    model_assignments = Keyword.fetch!(opts, :model_assignments)
    state = initial_state(opts) |> attach_model_assignments(model_assignments)

    GameRunner.run_multi_model(state, modules(), &default_opts/1, opts,
      print_setup: fn s ->
        IO.puts(
          "Starting Werewolf game with #{map_size(get(s.world, :players, %{}))} players (multi-model)"
        )

        print_role_assignments(s.world)
      end,
      print_result: &print_game_result/1,
      announce_turn: &announce_turn/2,
      print_step: &print_step/2,
      transcript_step_meta: &TranscriptLogger.step_meta/1,
      transcript_step_entry: &TranscriptLogger.turn_start_entry/3,
      transcript_result_entry: &TranscriptLogger.turn_result_entry/3,
      transcript_detail: &transcript_detail/1,
      transcript_game_over_extra: fn world ->
        performance = Performance.summarize(world)

        %{
          day: get(world, :day_number),
          elimination_log: get(world, :elimination_log, []),
          discussion_transcript: get(world, :discussion_transcript, []),
          performance: performance
        }
      end
    )
  end

  defp transcript_detail(world) do
    phase = get(world, :phase)

    case phase do
      p when p in ["day_discussion", "runoff_discussion"] ->
        transcript = get(world, :discussion_transcript, [])
        last = List.last(transcript)

        Map.merge(
          %{
            discussion_round: get(world, :discussion_round, 1),
            discussion_round_limit: get(world, :discussion_round_limit, 1)
          },
          if(last,
            do: %{statement: get(last, :statement), speaker: get(last, :player)},
            else: %{}
          )
        )

      p when p in ["day_voting", "runoff_voting"] ->
        %{votes: get(world, :votes, %{})}

      "night" ->
        %{night_actions: get(world, :night_actions, %{})}

      "wolf_discussion" ->
        wolf_chat = get(world, :wolf_chat_transcript, [])
        last = List.last(wolf_chat)

        if last,
          do: %{speaker: get(last, :player), message: get(last, :message)},
          else: %{}

      p when p in ["last_words_vote", "last_words_night"] ->
        pending = get(world, :pending_elimination)
        if pending, do: %{pending_elimination: pending}, else: %{}

      "meeting_selection" ->
        %{meeting_requests: get(world, :meeting_requests, %{})}

      "private_meeting" ->
        %{
          current_pair:
            Enum.at(
              get(world, :meeting_pairs, []),
              get(world, :current_meeting_index, 0),
              []
            ),
          messages: get(world, :current_meeting_messages, [])
        }

      _ ->
        %{}
    end
  end

  # -- View builders for information hiding --

  defp build_player_view(world, actor_id, _actor_role) do
    players = get(world, :players, %{})

    player_summary =
      players
      |> Enum.sort_by(fn {id, _p} -> id end)
      |> Enum.map(fn {id, p} ->
        status = get(p, :status, "alive")

        base = %{"name" => id, "status" => status}

        # Dead players' roles are revealed
        if status == "dead" do
          Map.put(base, "role", get(p, :role, "unknown"))
        else
          base
        end
      end)

    %{
      "phase" => get(world, :phase),
      "day_number" => get(world, :day_number),
      "discussion_round" => get(world, :discussion_round),
      "discussion_round_limit" => get(world, :discussion_round_limit),
      "you" => actor_id,
      "active_player" => get(world, :active_actor_id),
      "players" => player_summary,
      "living_count" => length(Roles.living_players(players))
    }
  end

  defp build_role_info(world, actor_id, actor_role) do
    players = get(world, :players, %{})
    actor = Map.get(players, actor_id, %{})
    traits = get(actor, :traits, [])
    connections = get(world, :backstory_connections, [])
    my_connections = Roles.connections_for_player(connections, actor_id)
    journals = get(world, :journals, %{})
    my_journal = Map.get(journals, actor_id, [])
    player_items_map = get(world, :player_items, %{})
    my_items = Map.get(player_items_map, actor_id, [])

    trait_guidance =
      traits
      |> Enum.map(&Roles.trait_description/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    base = %{
      "your_name" => actor_id,
      "your_role" => actor_role,
      "personality_traits" => traits,
      "trait_guidance" => trait_guidance,
      "connections" =>
        Enum.map(my_connections, fn conn ->
          other =
            conn
            |> Map.get(:players, [])
            |> Enum.find(&(&1 != actor_id))

          %{
            "other_player" => other,
            "type" => Map.get(conn, :type),
            "description" => Map.get(conn, :description)
          }
        end),
      "your_journal" => Enum.take(my_journal, -10),
      "your_items" =>
        Enum.map(my_items, fn item -> Map.get(item, :type) || Map.get(item, "type") end)
    }

    case actor_role do
      "werewolf" ->
        partner_ids = Roles.werewolf_partners(players, actor_id)
        wolf_chat = get(world, :wolf_chat_transcript, [])

        Map.merge(base, %{
          "werewolf_partners" => partner_ids,
          "wolf_chat_transcript" =>
            Enum.map(wolf_chat, fn entry ->
              %{"player" => get(entry, :player), "message" => get(entry, :message, "")}
            end),
          "description" =>
            "You are a WEREWOLF. Your partners are: #{Enum.join(partner_ids, ", ")}. " <>
              "During wolf discussion, coordinate with your pack before night actions. " <>
              "At night, choose a villager to kill. During the day, pretend to be a villager " <>
              "and deflect suspicion away from yourself and your partners."
        })

      "seer" ->
        seer_history = get(world, :seer_history, [])

        Map.merge(base, %{
          "investigation_history" =>
            Enum.map(seer_history, fn entry ->
              %{
                "target" => get(entry, :target),
                "role" => get(entry, :role)
              }
            end),
          "description" =>
            "You are the SEER. Each night you can investigate one player to learn their role. " <>
              "Use your knowledge wisely during discussions, but be careful not to make yourself " <>
              "an obvious target for the werewolves."
        })

      "doctor" ->
        Map.merge(base, %{
          "description" =>
            "You are the DOCTOR. Each night you can protect one player from being killed. " <>
              "Try to predict who the werewolves will target. You can protect yourself."
        })

      "villager" ->
        wanderer_results = get(world, :wanderer_results, [])

        my_sightings =
          wanderer_results
          |> Enum.filter(fn r -> get(r, :wanderer) == actor_id end)
          |> Enum.map(fn r -> %{"day" => get(r, :day), "description" => get(r, :description)} end)

        Map.merge(base, %{
          "night_sightings" => my_sightings,
          "description" =>
            "You are a VILLAGER. You have no special abilities, but your vote counts. " <>
              "At night you can choose to WANDER the village — you might witness something suspicious. " <>
              "Pay attention to the discussion and try to identify suspicious behavior."
        })

      _ ->
        base
    end
  end

  # -- Event visibility filtering --
  # These ensure players only see events they should have access to.

  @secret_night_events ~w(choose_victim investigate_player protect_player sleep night_wander use_item)
  @seer_only_events ~w(investigation_result)

  defp event_visible?(event, _actor_id, _actor_role) when not is_map(event), do: false

  defp event_visible?(event, actor_id, actor_role) do
    kind = event_kind(event)

    cond do
      # Night action events: only the actor who performed them sees them
      kind in @secret_night_events ->
        event_player_id(event) == actor_id

      # Investigation results: seer only
      kind in @seer_only_events ->
        actor_role == "seer"

      # Wolf chat: werewolves only
      kind == "wolf_chat" ->
        actor_role == "werewolf"

      # Action rejections: only the rejected player
      kind == "action_rejected" ->
        event_player_id(event) == actor_id

      # Votes are secret until the public vote_result is announced.
      kind == "cast_vote" ->
        false

      # Wanderer results: only the wanderer
      kind == "wanderer_result" ->
        event_player_id(event) == actor_id

      # Lantern results: only the user
      kind == "lantern_result" ->
        event_player_id(event) == actor_id

      # Item found: only the finder
      kind == "item_found" ->
        event_player_id(event) == actor_id

      # Item used: only the user
      kind == "item_used" ->
        event_player_id(event) == actor_id

      # Last words, accusations, meetings, evidence, village events, anonymous messages are public
      kind in ~w(make_last_words make_accusation request_meeting meeting_message evidence_found village_event anonymous_message) ->
        true

      # Everything else is public (phase_changed, night_resolved, player_eliminated,
      # vote_result, make_statement, game_over)
      true ->
        true
    end
  end

  defp sanitize_event(event, _actor_id, _actor_role, _players) when not is_map(event), do: event

  defp sanitize_event(event, _actor_id, _actor_role, _players) do
    kind = event_kind(event)
    payload = event_payload(event)

    sanitized_payload =
      case kind do
        "make_statement" ->
          %{
            "speaker" => get(payload, :player_id),
            "statement" => get(payload, :statement, "")
          }

        "vote_result" ->
          tally =
            payload
            |> get(:vote_tally, %{})
            |> Enum.sort_by(fn {player_id, _votes} -> player_id end)
            |> Enum.map(fn {player_id, votes} ->
              %{
                "player" => player_id,
                "votes" => votes
              }
            end)

          %{
            "eliminated" => get(payload, :eliminated_id),
            "vote_tally" => tally
          }

        "player_eliminated" ->
          %{
            "player" => get(payload, :player_id),
            "role" => get(payload, :role),
            "reason" => get(payload, :reason, "")
          }

        "night_resolved" ->
          victim_id = get(payload, :victim_id)
          saved? = get(payload, :saved?, false)

          %{
            "victim" => victim_id,
            "saved?" => saved?,
            "summary" =>
              cond do
                is_nil(victim_id) ->
                  "No one died overnight."

                saved? ->
                  "#{victim_id} was attacked but survived."

                true ->
                  "#{victim_id} died overnight."
              end
          }

        "investigation_result" ->
          %{
            "target" => get(payload, :target_id),
            "role" => get(payload, :role)
          }

        "make_last_words" ->
          %{
            "player" => get(payload, :player_id),
            "statement" => get(payload, :statement, "")
          }

        "wolf_chat" ->
          %{
            "player" => get(payload, :player_id),
            "message" => get(payload, :message, "")
          }

        "make_accusation" ->
          %{
            "accuser" => get(payload, :player_id),
            "target" => get(payload, :target_id),
            "reason" => get(payload, :reason, "")
          }

        "request_meeting" ->
          %{"player" => get(payload, :player_id), "target" => get(payload, :target_id)}

        "meeting_message" ->
          %{"player" => get(payload, :player_id), "message" => get(payload, :message, "")}

        "evidence_found" ->
          %{
            "tokens" =>
              get(payload, :tokens, [])
              |> Enum.map(fn t -> %{"type" => get(t, :type), "clue" => get(t, :clue)} end)
          }

        "night_wander" ->
          %{"player" => get(payload, :player_id)}

        "wanderer_result" ->
          %{
            "saw_shadows" => get(payload, :saw_shadows),
            "description" => get(payload, :description, "")
          }

        "village_event" ->
          %{
            "event_type" => get(payload, :event_type),
            "description" => get(payload, :description, "")
          }

        "item_found" ->
          %{
            "item_type" => get(payload, :item_type),
            "description" => get(payload, :description, "")
          }

        "item_used" ->
          %{"player" => get(payload, :player_id), "item_type" => get(payload, :item_type)}

        "lantern_result" ->
          %{
            "description" => get(payload, :description, ""),
            "saw_target" => get(payload, :saw_target)
          }

        "anonymous_message" ->
          %{"message" => get(payload, :message, "")}

        "action_rejected" ->
          %{
            "reason" => get(payload, :reason, "")
          }

        _ ->
          payload
      end

    put_payload(event, sanitized_payload)
  end

  # -- Callbacks --

  defp terminal?(state), do: get(state.world, :status) in ["game_over"]

  defp announce_turn(turn, state) do
    actor_id = get(state.world, :active_actor_id)
    phase = get(state.world, :phase)
    day = get(state.world, :day_number, 1)

    IO.puts("Step #{turn} | day=#{day} phase=#{phase} actor=#{actor_id}")
  end

  defp print_step(_turn, result) when is_map(result) do
    case TranscriptLogger.print_step_summary(result) do
      nil -> :ok
      line -> IO.puts(line)
    end
  end

  defp print_step(_turn, _result), do: :ok

  defp print_role_assignments(world) do
    players = get(world, :players, %{})

    IO.puts("Role assignments (hidden from players):")

    players
    |> Enum.sort_by(fn {id, _p} -> id end)
    |> Enum.each(fn {id, p} ->
      IO.puts("  #{id}: #{get(p, :role)}")
    end)

    IO.puts("")
  end

  defp print_game_result(world) do
    winner = get(world, :winner)
    players = get(world, :players, %{})
    elimination_log = get(world, :elimination_log, [])
    performance = Performance.summarize(world)

    IO.puts("Winner: #{winner}")
    IO.puts("Final player status:")

    players
    |> Enum.sort_by(fn {id, _p} -> id end)
    |> Enum.each(fn {id, p} ->
      IO.puts("  #{id}: #{get(p, :role)} (#{get(p, :status)})")
    end)

    IO.puts("Elimination log:")

    Enum.each(elimination_log, fn entry ->
      IO.puts(
        "  Day #{get(entry, :day)}: #{get(entry, :player)} (#{get(entry, :role)}) - #{get(entry, :reason)}"
      )
    end)

    IO.puts("Performance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {player_id, metrics} -> {get(metrics, :role, ""), player_id} end)
    |> Enum.each(fn {player_id, metrics} ->
      IO.puts(
        "  #{player_id} [#{get(metrics, :role)}#{if get(metrics, :team_won), do: ", team win", else: ""}] " <>
          "votes(wolf=#{get(metrics, :votes_for_werewolf, 0)}, villager=#{get(metrics, :votes_for_villager, 0)}, skip=#{get(metrics, :skip_votes, 0)}) " <>
          "night(kills=#{get(metrics, :successful_kills, 0)}, failed=#{get(metrics, :failed_kills, 0)}, checks=#{get(metrics, :wolf_checks_found, 0)}, saves=#{get(metrics, :doctor_saves, 0)})"
      )
    end)

    IO.puts("Model summary:")

    performance
    |> get(:models, %{})
    |> Enum.sort_by(fn {model, _metrics} -> model || "" end)
    |> Enum.each(fn {model, metrics} ->
      IO.puts(
        "  #{model}: seats=#{get(metrics, :seats, 0)} wins=#{get(metrics, :team_wins, 0)} " <>
          "wolf_votes=#{get(metrics, :votes_for_werewolf, 0)} villager_votes=#{get(metrics, :votes_for_villager, 0)} " <>
          "kills=#{get(metrics, :successful_kills, 0)} checks=#{get(metrics, :wolf_checks_found, 0)} saves=#{get(metrics, :doctor_saves, 0)}"
      )
    end)
  end

  defp attach_model_assignments(state, model_assignments) do
    players =
      state.world
      |> get(:players, %{})
      |> Enum.into(%{}, fn {player_id, info} ->
        {model, _key} = Map.get(model_assignments, player_id, {nil, nil})
        model_name = if model, do: "#{model.provider}/#{model.id}", else: nil
        {player_id, Map.put(info, :model, model_name)}
      end)

    %{state | world: Map.put(state.world, :players, players)}
  end
end
