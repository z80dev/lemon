defmodule LemonSim.Examples.SpaceStation do
  @moduledoc """
  Space Station Crisis: an Among Us-style social deduction game built on LemonSim.

  A multiplayer game (5-7 players) set on a failing space station. One player is
  secretly a saboteur trying to destroy the station, while the rest of the crew
  must keep systems running and identify the traitor.

  ## Roles
  - Engineer (1): Can repair 2 systems per turn OR scan a player to see their last action.
  - Captain (1): Can repair OR lock a room (prevent sabotage) OR call an emergency meeting.
  - Crew (2-4): Standard repair ability.
  - Saboteur (1): Appears as Crew. Can sabotage, fake-repair, or vent (become invisible).

  ## Systems
  - O2 (Oxygen): health 100, decay 10/round
  - Power (Reactor): health 100, decay 8/round
  - Hull (Structural): health 100, decay 5/round
  - Comms (Communications): health 100, decay 3/round

  ## Win Conditions
  - Saboteur wins if any system reaches 0 health.
  - Crew wins if they survive 8 rounds.
  """

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.EventHelpers

  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.SpaceStation.{
    ActionSpace,
    Performance,
    Roles,
    Updater
  }

  alias LemonSim.GameHelpers.Runner, as: GameRunner
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.State

  @default_max_turns 300
  @default_player_count 6

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, @default_player_count)
    player_ids = Enum.map(1..player_count, fn i -> "player_#{i}" end)
    players = Roles.assign_roles(player_ids)
    player_names = Enum.map(players, fn {_id, p} -> get(p, :name) end)
    traits = Roles.assign_traits(player_names)
    connections = Roles.generate_connections(player_names)
    action_order = Roles.action_turn_order(players)
    first_actor = List.first(action_order)

    %{
      players: players,
      traits: traits,
      connections: connections,
      journals: %{},
      systems: %{
        "o2" => %{health: 100, decay_rate: 5, name: "Oxygen"},
        "power" => %{health: 100, decay_rate: 4, name: "Reactor Power"},
        "hull" => %{health: 100, decay_rate: 3, name: "Hull Integrity"},
        "comms" => %{health: 100, decay_rate: 2, name: "Communications"},
        "nav" => %{health: 100, decay_rate: 3, name: "Navigation"},
        "medbay" => %{health: 100, decay_rate: 2, name: "Medical Bay"},
        "shields" => %{health: 100, decay_rate: 4, name: "Shield Array"}
      },
      phase: "action",
      round: 1,
      max_rounds: 12,
      active_actor_id: first_actor,
      turn_order: action_order,
      action_log: %{},
      action_history: [],
      location_log: [],
      round_reports: [],
      discussion_transcript: [],
      vote_history: [],
      discussion_round: 0,
      discussion_round_limit: 0,
      votes: %{},
      emergency_meeting_available: true,
      emergency_meeting_called: false,
      captain_lock: nil,
      scan_results: %{},
      elimination_log: [],
      clues: %{},
      active_crisis: nil,
      pending_questions: [],
      accusations: [],
      status: "in_progress",
      winner: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "space_station_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Play Space Station Crisis strategically based on your assigned role. " <>
            "If you are the saboteur, sabotage systems and deflect suspicion. " <>
            "If you are crew/engineer/captain, keep systems alive and find the saboteur."
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
            title: "Station Status",
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
          actor_name = get(actor, :name, actor_id)

          # Personality traits
          traits = get(world, :traits, %{})
          player_traits = Map.get(traits, actor_name, [])

          trait_info =
            Enum.map(player_traits, fn t ->
              %{"trait" => t, "description" => Roles.trait_description(t)}
            end)

          # Backstory connections
          connections = get(world, :connections, [])
          my_connections = Roles.connections_for_player(connections, actor_name)

          connection_info =
            Enum.map(my_connections, fn conn ->
              %{"type" => conn.type, "description" => conn.description}
            end)

          # Journal entries
          journals = get(world, :journals, %{})
          my_journal = Map.get(journals, actor_id, [])

          role_info = build_role_info(world, actor_id, actor_role)

          # Clues this player has received
          clues = get(world, :clues, %{})
          my_clues = Map.get(clues, actor_id, [])

          enriched =
            Map.merge(role_info, %{
              "personality_traits" => trait_info,
              "backstory_connections" => connection_info,
              "journal" => my_journal,
              "clues_found" => my_clues
            })

          %{
            id: :role_info,
            title: "Your Role (SECRET - do not reveal unless strategically advantageous)",
            format: :json,
            content: enriched
          }
        end,
        discussion_log: fn frame, _tools, _opts ->
          transcript = get(frame.world, :discussion_transcript, [])
          elimination_log = get(frame.world, :elimination_log, [])
          players = get(frame.world, :players, %{})

          %{
            id: :discussion_log,
            title: "Discussion & Events",
            format: :json,
            content: %{
              "discussion_transcript" =>
                Enum.map(transcript, fn entry ->
                  player_id = get(entry, :player)
                  entry_type = get(entry, :type, "statement")

                  base = %{
                    "player_id" => player_id,
                    "player_name" => player_name(players, player_id),
                    "type" => entry_type
                  }

                  case entry_type do
                    "question" ->
                      target_id = get(entry, :target)

                      Map.merge(base, %{
                        "directed_at" => player_name(players, target_id),
                        "question" => rewrite_public_text(get(entry, :statement, ""), players)
                      })

                    "accusation" ->
                      target_id = get(entry, :target)

                      Map.merge(base, %{
                        "accused" => player_name(players, target_id),
                        "evidence" => rewrite_public_text(get(entry, :statement, ""), players)
                      })

                    _ ->
                      Map.put(
                        base,
                        "statement",
                        rewrite_public_text(get(entry, :statement, ""), players)
                      )
                  end
                end),
              "elimination_log" =>
                Enum.map(elimination_log, fn entry ->
                  base = %{
                    "player" => player_name(players, get(entry, :player)),
                    "reason" => get(entry, :reason),
                    "round" => get(entry, :round)
                  }

                  # Include revealed role for ejected players
                  role = get(entry, :role)
                  if role, do: Map.put(base, "role", role), else: base
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
            |> Enum.map(&sanitize_event(&1, actor_id, actor_role))

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
        SPACE STATION CRISIS RULES:
        - You are a crew member on a failing space station. One person is secretly a saboteur.
        - Use exactly one tool call per turn.
        - During ACTION phase: Choose to repair a system, or use your special ability if you have one.
        - During DISCUSSION phase: You have THREE tools: make_statement (general), ask_question (direct a question at someone), and accuse (formal accusation with evidence). Use ask_question to probe suspicious players — they'll feel pressure to respond. Use accuse when you've built a case.
        - During VOTING phase: Vote to eject a suspect, or skip if unsure. Majority required.
        - IMPORTANT: Your role is SECRET. The saboteur appears as "crew" to others.
        - Systems decay every round and suffer minor environmental damage. If ANY system reaches 0 health, the station is destroyed (saboteur wins).
        - The crew wins by ejecting the saboteur or surviving 8 rounds.
        - There are 7 systems but only 6 players — most players will be alone at their system each round.
        - VISIBILITY: You can only see who else was at the SAME system as you. You do NOT know where other players went. You get exact health readings for systems you visit; other systems have slight sensor variance.
        - Ejected players' roles ARE revealed. This gives you confirmed information to reason with.
        - CLUES: After each round, you may find evidence — tool marks, sounds, security footage. Use these in discussion to build your case. Clues are private until you share them.
        - CRISES: The station faces periodic crises (cascade failures, power surges, lockdowns, hull breaches) that force difficult coordination decisions. Pay attention to the active crisis and plan accordingly.
        - If someone asks you a direct question, you should address it. Dodging questions looks suspicious.
        - If you are formally accused, defend yourself with specific evidence. Silence after an accusation is damning.
        - Public discussion should refer to players by their assigned names, not internal ids like player_3.
        - Use internal ids only when calling tools that require a target_id/player_id argument.
        - Think strategically: compare system health between rounds, cross-reference clues, and look for patterns.
        - People may lie about where they were or what they did. Trust must be earned through consistent behavior over multiple rounds.
        - Stay in character based on your personality traits.
        - Your connections with other crew members may influence your judgment.
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
    GameRunner.build_default_opts(projector_opts(), overrides,
      game_name: "Space Station Crisis",
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
      print_setup: &print_setup/1,
      print_result: &print_game_result/1
    )
  end

  @doc """
  Runs a Space Station Crisis game with different models assigned to different players.

  ## Options
    * `:model_assignments` - map of player_id => {%Model{}, api_key_string}
    * `:transcript_path` - path to write JSONL transcript
    * All other opts from `run/1`
  """
  @spec run_multi_model(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run_multi_model(opts \\ []) when is_list(opts) do
    state = initial_state(opts)

    GameRunner.run_multi_model(state, modules(), &default_opts/1, opts,
      print_setup: &print_setup/1,
      print_result: &print_game_result/1,
      announce_turn: &announce_turn/2,
      print_step: &print_step/2,
      transcript_detail: &transcript_detail/1,
      transcript_game_over_extra: &transcript_game_over_extra/1
    )
  end

  # -- View builders for information hiding --

  defp build_player_view(world, actor_id, _actor_role) do
    players = get(world, :players, %{})
    systems = get(world, :systems, %{})
    location_log = get(world, :location_log, [])
    captain_lock = get(world, :captain_lock, nil)
    actor = Map.get(players, actor_id, %{})
    actor_location = get(actor, :location)

    player_summary =
      players
      |> Enum.sort_by(fn {id, _p} -> id end)
      |> Enum.map(fn {id, p} ->
        status = get(p, :status, "alive")

        base = %{"id" => id, "name" => player_name(players, id), "status" => status}

        # Reveal roles of ejected players (confirm ejects)
        if status == "ejected" do
          role = get(p, :role, "unknown")
          Map.put(base, "revealed_role", role)
        else
          base
        end
      end)

    system_summary =
      systems
      |> Enum.sort_by(fn {id, _s} -> id end)
      |> Enum.map(fn {id, s} ->
        exact_health = get(s, :health, 100)

        # Show exact health for systems you personally visited; fuzzy for others
        if id == actor_location do
          %{
            "id" => id,
            "name" => get(s, :name, id),
            "health" => exact_health,
            "health_note" => "exact reading (you are at this system)"
          }
        else
          jitter = Enum.random(-3..3)
          displayed_health = (exact_health + jitter) |> max(0) |> min(100)

          %{
            "id" => id,
            "name" => get(s, :name, id),
            "health" => displayed_health,
            "health_note" => "approximate reading (station sensors have ±3% variance)"
          }
        end
      end)

    # Location visibility
    active_crisis = get(world, :active_crisis)
    lockdown_active = is_map(active_crisis) and get(active_crisis, :type) == "lockdown"

    co_located =
      if lockdown_active do
        # Lockdown: reveal ALL player locations
        location_log
        |> Enum.reject(fn {pid, _sys} -> pid == actor_id end)
        |> Enum.map(fn {pid, sys} ->
          %{
            "player_id" => pid,
            "player_name" => player_name(players, pid),
            "location" => sys
          }
        end)
      else
        # Normal: you only see who else was at the SAME system as you
        if actor_location do
          location_log
          |> Enum.filter(fn {_pid, sys} -> sys == actor_location end)
          |> Enum.reject(fn {pid, _sys} -> pid == actor_id end)
          |> Enum.map(fn {pid, _sys} ->
            %{"player_id" => pid, "player_name" => player_name(players, pid)}
          end)
        else
          []
        end
      end

    location_label =
      if lockdown_active,
        do: "all_crew_locations (LOCKDOWN)",
        else: "co_located_players"

    # Active crisis
    active_crisis = get(world, :active_crisis)

    crisis_info =
      if active_crisis do
        %{
          "type" => get(active_crisis, :type),
          "name" => get(active_crisis, :name),
          "description" => get(active_crisis, :description)
        }
      else
        nil
      end

    # Pending questions directed at this player
    pending_questions = get(world, :pending_questions, [])

    my_pending_questions =
      pending_questions
      |> Enum.filter(fn q -> get(q, :to) == actor_id end)
      |> Enum.map(fn q ->
        %{
          "from" => player_name(players, get(q, :from)),
          "question" => get(q, :question)
        }
      end)

    # Active accusations against this player
    accusations = get(world, :accusations, [])

    accusations_against_me =
      accusations
      |> Enum.filter(fn a -> get(a, :accused) == actor_id end)
      |> Enum.map(fn a ->
        %{
          "accuser" => player_name(players, get(a, :accuser)),
          "evidence" => get(a, :evidence)
        }
      end)

    base = %{
      "phase" => get(world, :phase),
      "round" => get(world, :round),
      "max_rounds" => get(world, :max_rounds, 8),
      "discussion_round" => get(world, :discussion_round, 0),
      "discussion_round_limit" => get(world, :discussion_round_limit, 0),
      "you" => %{"id" => actor_id, "name" => player_name(players, actor_id)},
      "active_player" => %{
        "id" => get(world, :active_actor_id),
        "name" => player_name(players, get(world, :active_actor_id))
      },
      "players" => player_summary,
      "systems" => system_summary,
      "your_location" => actor_location,
      location_label => co_located,
      "captain_lock" => captain_lock,
      "last_round_report" =>
        format_round_report(List.last(get(world, :round_reports, []))),
      "living_count" => length(Roles.living_players(players))
    }

    base
    |> put_if_present("active_crisis", crisis_info)
    |> put_if_present("questions_directed_at_you", non_empty_list(my_pending_questions))
    |> put_if_present("accusations_against_you", non_empty_list(accusations_against_me))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp non_empty_list([]), do: nil
  defp non_empty_list(list), do: list

  defp build_role_info(world, actor_id, actor_role) do
    players = get(world, :players, %{})
    scan_results = get(world, :scan_results, %{})
    actor_name = player_name(players, actor_id)

    # Trait summary for inline role description
    traits = get(world, :traits, %{})
    player_traits = Map.get(traits, actor_name, [])

    trait_summary =
      case player_traits do
        [] -> ""
        ts -> " Your personality: " <> Enum.join(Enum.map(ts, &Roles.trait_description/1), " ")
      end

    # Connection summary for inline role description
    connections = get(world, :connections, [])
    my_connections = Roles.connections_for_player(connections, actor_name)

    connection_summary =
      case my_connections do
        [] -> ""
        conns -> " Backstory: " <> Enum.join(Enum.map(conns, & &1.description), " ")
      end

    base = %{
      "your_id" => actor_id,
      "your_name" => actor_name,
      "your_role" => actor_role
    }

    case actor_role do
      "saboteur" ->
        Map.merge(base, %{
          "description" =>
            "You are the SABOTEUR. You appear as 'crew' to others. " <>
              "ACTIONS: " <>
              "(1) 'repair_system' — actually repairs (use to build trust). " <>
              "(2) 'sabotage_system' — damages a system (your main weapon). " <>
              "(3) 'inspect_system' — you visit a system and appear to work normally, but nothing changes. " <>
              "Useful when you want to be SEEN at a system without repairing it. " <>
              "(4) 'vent' — disappear from all locations (risky, absence noticed). " <>
              "STRATEGY: " <>
              "Round 1: Use 'repair_system' genuinely to build trust. Go where others go. " <>
              "Round 2+: Start mixing in sabotage. Environmental hazards hit 3-5 systems per round for " <>
              "significant damage, so sabotage blends in with the noise. Go to a system WITH another player — " <>
              "they see you there but cannot tell if you repaired or sabotaged. " <>
              "CRITICAL DISCUSSION RULES: " <>
              "(1) Act CALM and NORMAL. Do NOT be aggressive or accusatory — that draws suspicion. " <>
              "(2) BLEND IN with the group. Agree with reasonable proposals. Be cooperative. " <>
              "(3) When reporting your location, always say you 'repaired' the system — never mention " <>
              "inspecting, sabotaging, or any special action. You are crew as far as anyone knows. " <>
              "(4) If questioned, stay calm and give SHORT, CONFIDENT answers. Do not over-explain or get defensive. " <>
              "(5) Let OTHERS start accusations. Only join in when the group is already suspicious of someone. " <>
              "(6) Point out that environmental damage is heavy and unpredictable when systems drop. " <>
              "(7) If a scan accuses you: DENY IT. Scans have a 25% false reading rate — they get it wrong one in four times. " <>
              "Say: 'Scans are unreliable, everyone knows interference causes false readings.' " <>
              "NEVER confess. NEVER admit guilt. ALWAYS claim you repaired and the scan is wrong. " <>
              "Redirect suspicion to someone else — suggest the engineer is the saboteur framing you. " <>
              "Your goal: reduce any system to 0 health." <>
              trait_summary <> connection_summary
        })

      "engineer" ->
        scan_info = Map.get(scan_results, actor_id)

        scan_history =
          if scan_info do
            %{
              "last_scan_target" => player_name(players, get(scan_info, :target)),
              "last_scan_result" => get(scan_info, :result)
            }
          else
            %{"last_scan" => "none"}
          end

        Map.merge(base, %{
          "scan_history" => scan_history,
          "description" =>
            "You are the ENGINEER. You can repair systems or scan a player " <>
              "to learn whether they repaired or sabotaged last turn. WARNING: Station interference " <>
              "means scan results have a 25% error rate — mostly reliable but not perfect. Scan results are private. " <>
              "Use your knowledge wisely during discussions. When scanning, you appear at a random system." <>
              trait_summary <> connection_summary
        })

      "captain" ->
        emergency = get(world, :emergency_meeting_available, true)

        Map.merge(base, %{
          "emergency_meeting_available" => emergency,
          "description" =>
            "You are the CAPTAIN. You can repair systems, lock a room (prevents sabotage there for one round), " <>
              "or call an emergency meeting (skip to discussion+vote, once per game). " <>
              "The lock is public information. Use your authority wisely." <>
              trait_summary <> connection_summary
        })

      "crew" ->
        Map.merge(base, %{
          "description" =>
            "You are CREW. You can repair one system per turn. " <>
              "Repair effectiveness varies. Pay attention to system health trends and who claims to be where. " <>
              "Environmental damage makes exact calculations unreliable — focus on patterns over multiple rounds. " <>
              "Work together to find the saboteur before the station is destroyed." <>
              trait_summary <> connection_summary
        })

      _ ->
        base
    end
  end

  # -- Event visibility filtering --

  @secret_action_events ~w(repair_system sabotage_system fake_repair scan_player vent)
  @engineer_only_events ~w(scan_result)

  defp event_visible?(event, _actor_id, _actor_role) when not is_map(event), do: false

  defp event_visible?(event, actor_id, actor_role) do
    kind = event_kind(event)

    cond do
      # Action events: only the actor who performed them sees them
      kind in @secret_action_events ->
        event_player_id(event) == actor_id

      # Scan results: engineer only
      kind in @engineer_only_events ->
        actor_role == "engineer" and event_engineer_id(event) == actor_id

      # Clues: only the recipient sees them
      kind == "clue_found" ->
        event_player_id(event) == actor_id

      # Action rejections: only the rejected player
      kind == "action_rejected" ->
        event_player_id(event) == actor_id

      # Environmental events are hidden — players don't know which systems were hit
      kind == "environmental_event" ->
        false

      # Everything else is public (phase_changed, round_resolved, player_ejected,
      # vote_result, make_statement, ask_question, accuse, cast_vote,
      # game_over, lock_room, crisis_triggered)
      true ->
        true
    end
  end

  defp sanitize_event(event, _actor_id, _actor_role) when not is_map(event), do: event

  defp sanitize_event(event, _actor_id, _actor_role) do
    kind = event_kind(event)
    payload = event_payload(event)

    case kind do
      # Strip private action details from round_resolved
      "round_resolved" ->
        sanitized_payload =
          payload
          |> Map.delete(:action_log)
          |> Map.delete("action_log")
          |> Map.delete(:system_changes)
          |> Map.delete("system_changes")

        put_payload(event, sanitized_payload)

      # Reveal ejected player's role (confirm ejects) — gives crew meaningful info
      "player_ejected" ->
        player_id = Map.get(payload, :player_id, Map.get(payload, "player_id", "someone"))
        role = Map.get(payload, :role, Map.get(payload, "role", "unknown"))

        sanitized_payload =
          Map.put(payload, "message", "#{player_id} has been ejected from the station. They were #{role}.")

        put_payload(event, sanitized_payload)

      _ ->
        event
    end
  end

  defp event_engineer_id(event) do
    p = event_payload(event)
    Map.get(p, :engineer_id, Map.get(p, "engineer_id"))
  end

  # -- Callbacks --

  defp terminal?(state), do: get(state.world, :status) in ["game_over"]

  defp announce_turn(turn, state) do
    actor_id = get(state.world, :active_actor_id)
    actor_name = player_name(get(state.world, :players, %{}), actor_id)
    phase = get(state.world, :phase)
    round = get(state.world, :round, 1)

    IO.puts("Step #{turn} | round=#{round} phase=#{phase} actor=#{actor_name} (#{actor_id})")
  end

  defp print_step(_turn, %{state: next_state}) do
    world = next_state.world
    phase = get(world, :phase)

    case phase do
      "discussion" ->
        transcript = get(world, :discussion_transcript, [])
        players = get(world, :players, %{})

        case List.last(transcript) do
          nil ->
            :ok

          entry ->
            speaker = player_name(players, get(entry, :player))
            entry_type = get(entry, :type, "statement")
            statement = get(entry, :statement, "")

            case entry_type do
              "question" ->
                target = player_name(players, get(entry, :target))
                IO.puts("  [#{speaker}] asks #{target}: \"#{statement}\"")

              "accusation" ->
                target = player_name(players, get(entry, :target))
                IO.puts("  [#{speaker}] ACCUSES #{target}: \"#{statement}\"")

              _ ->
                IO.puts("  [#{speaker}]: \"#{statement}\"")
            end
        end

      "voting" ->
        votes = get(world, :votes, %{})

        if map_size(votes) > 0 do
          {voter, target} = Enum.max_by(votes, fn {_k, _v} -> map_size(votes) end)

          IO.puts(
            "  #{player_name(get(world, :players, %{}), voter)} voted for #{player_name(get(world, :players, %{}), target)}"
          )
        end

      "action" ->
        systems = get(world, :systems, %{})

        if map_size(systems) > 0 do
          health_str =
            systems
            |> Enum.sort_by(fn {id, _s} -> id end)
            |> Enum.map(fn {id, s} -> "#{id}=#{get(s, :health, "?")}" end)
            |> Enum.join(" ")

          IO.puts("  Systems: #{health_str}")
        end

      "game_over" ->
        IO.puts("  Game over! Winner: #{get(world, :winner)}")

      _ ->
        :ok
    end
  end

  defp print_step(_turn, _result), do: :ok

  defp print_role_assignments(world) do
    players = get(world, :players, %{})

    IO.puts("Role assignments (hidden from players):")

    players
    |> Enum.sort_by(fn {id, _p} -> id end)
    |> Enum.each(fn {id, p} ->
      IO.puts("  #{id} (#{get(p, :name, id)}): #{get(p, :role)}")
    end)

    IO.puts("")
  end

  defp print_system_status(world) do
    systems = get(world, :systems, %{})

    IO.puts("Initial system status:")

    systems
    |> Enum.sort_by(fn {id, _s} -> id end)
    |> Enum.each(fn {id, s} ->
      IO.puts(
        "  #{get(s, :name, id)} (#{id}): #{get(s, :health, 100)} HP, decay #{get(s, :decay_rate, 0)}/round"
      )
    end)

    IO.puts("")
  end

  defp print_game_result(world) do
    winner = get(world, :winner)
    players = get(world, :players, %{})
    systems = get(world, :systems, %{})
    elimination_log = get(world, :elimination_log, [])
    round = get(world, :round, 1)

    IO.puts("Winner: #{winner}")
    IO.puts("Final round: #{round}")

    IO.puts("\nFinal system health:")

    systems
    |> Enum.sort_by(fn {id, _s} -> id end)
    |> Enum.each(fn {id, s} ->
      IO.puts("  #{get(s, :name, id)} (#{id}): #{get(s, :health, 0)} HP")
    end)

    IO.puts("\nFinal player status:")

    players
    |> Enum.sort_by(fn {id, _p} -> id end)
    |> Enum.each(fn {id, p} ->
      IO.puts("  #{id} (#{get(p, :name, id)}): #{get(p, :role)} (#{get(p, :status)})")
    end)

    IO.puts("\nElimination log:")

    Enum.each(elimination_log, fn entry ->
      IO.puts(
        "  Round #{get(entry, :round)}: #{player_name(players, get(entry, :player))} (#{get(entry, :role)}) - #{get(entry, :reason)}"
      )
    end)

    IO.puts("\nPerformance summary:")

    Performance.summarize(world)
    |> get(:players, [])
    |> Enum.each(fn player ->
      IO.puts(
        "  #{get(player, :name)}: role=#{get(player, :role)} team_won=#{get(player, :team_won)} " <>
          "repairs=#{get(player, :repairs)} sabotages=#{get(player, :sabotages)} scans=#{get(player, :scans)} " <>
          "locks=#{get(player, :locks)} vents=#{get(player, :vents)} correct_votes=#{get(player, :correct_votes)}"
      )
    end)
  end

  # -- Transcript detail helpers --

  defp transcript_detail(world) do
    phase = get(world, :phase)

    case phase do
      "discussion" ->
        transcript = get(world, :discussion_transcript, [])
        last = List.last(transcript)

        if last do
          base = %{statement: get(last, :statement), speaker: get(last, :player)}
          entry_type = get(last, :type, "statement")

          case entry_type do
            "question" -> Map.merge(base, %{type: "question", target: get(last, :target)})
            "accusation" -> Map.merge(base, %{type: "accusation", target: get(last, :target)})
            _ -> base
          end
        else
          %{}
        end

      "voting" ->
        %{votes: get(world, :votes, %{})}

      "action" ->
        %{action_log: get(world, :action_log, %{})}

      _ ->
        %{}
    end
  end

  defp transcript_game_over_extra(world) do
    %{
      round: get(world, :round),
      systems: get(world, :systems, %{}),
      elimination_log: get(world, :elimination_log, []),
      discussion_transcript: get(world, :discussion_transcript, []),
      performance: Performance.summarize(world)
    }
  end

  defp print_setup(state) do
    IO.puts(
      "Starting Space Station Crisis with #{map_size(get(state.world, :players, %{}))} players"
    )

    print_role_assignments(state.world)
    print_system_status(state.world)
  end

  defp player_name(_players, nil), do: nil

  defp player_name(players, player_id) do
    players
    |> Map.get(player_id, %{})
    |> get(:name, player_id)
  end

  defp rewrite_public_text(text, players) when is_binary(text) do
    Enum.reduce(players, text, fn {player_id, _info}, acc ->
      Regex.replace(~r/\b#{Regex.escape(player_id)}\b/i, acc, player_name(players, player_id))
    end)
  end

  defp rewrite_public_text(other, _players), do: other

  defp format_round_report(nil), do: nil

  defp format_round_report(report) do
    env_count = length(get(report, :environmental_events, []))

    %{
      "round" => get(report, :round),
      "environmental_note" =>
        if(env_count > 0,
          do:
            "Station sensors detected environmental hazards this round. " <>
              "Exact system impact is unknown — automated damage-control engaged.",
          else: "No significant environmental hazards detected."
        ),
      "critical_systems" => get(report, :critical_systems, []),
      "captain_lock" => get(report, :captain_lock)
    }
  end
end
