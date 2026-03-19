defmodule LemonSim.Examples.Werewolf.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, except: [maybe_store_thought: 2]

  alias LemonSim.{Event, State}
  alias LemonSim.Examples.Werewolf.{Events, Roles}

  @wander_sighting_chance 0.05
  @evidence_chance_high 0.10
  @evidence_chance_low 0.05

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    # Extract and store thought if present
    state = maybe_store_thought(state, event)

    case event.kind do
      "choose_victim" -> apply_choose_victim(state, event)
      "investigate_player" -> apply_investigate_player(state, event)
      "protect_player" -> apply_protect_player(state, event)
      "sleep" -> apply_sleep(state, event)
      "night_wander" -> apply_night_wander(state, event)
      "make_statement" -> apply_make_statement(state, event)
      "cast_vote" -> apply_cast_vote(state, event)
      "make_last_words" -> apply_make_last_words(state, event)
      "wolf_chat" -> apply_wolf_chat(state, event)
      "make_accusation" -> apply_make_accusation(state, event)
      "request_meeting" -> apply_request_meeting(state, event)
      "meeting_message" -> apply_meeting_message(state, event)
      "use_item" -> apply_use_item(state, event)
      "anonymous_message" -> apply_anonymous_message(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  defp maybe_store_thought(state, event) do
    thought = Map.get(event.payload, "thought") || Map.get(event.payload, :thought)
    player_id = Map.get(event.payload, "player_id") || Map.get(event.payload, :player_id)

    if is_binary(thought) and thought != "" and is_binary(player_id) do
      journals = get(state.world, :journals, %{})
      player_journal = Map.get(journals, player_id, [])

      entry = %{
        day: get(state.world, :day_number, 1),
        phase: get(state.world, :phase),
        thought: thought
      }

      new_journals = Map.put(journals, player_id, player_journal ++ [entry])
      State.put_world(state, world_updates(state.world, %{journals: new_journals}))
    else
      state
    end
  end

  # -- Night: Werewolf chooses victim --

  defp apply_choose_victim(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    victim_id = fetch(event.payload, :victim_id, "victim_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "werewolf"),
         :ok <- ensure_living(players, victim_id),
         :ok <- ensure_not_role(players, victim_id, "werewolf") do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "choose_victim", target: victim_id})

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{night_actions: night_actions}))
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Night: Seer investigates --

  defp apply_investigate_player(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "seer"),
         :ok <- ensure_seer_can_investigate(state.world),
         :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(player_id, target_id) do
      target_role = get(Map.get(players, target_id, %{}), :role, "unknown")

      # Record the seer's investigation
      seer_history = get(state.world, :seer_history, [])
      new_history = seer_history ++ [%{target: target_id, role: target_role}]

      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "investigate", target: target_id, result: target_role})

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            night_actions: night_actions,
            seer_history: new_history
          })
        )
        |> State.append_event(event)
        |> State.append_event(Events.investigation_result(player_id, target_id, target_role))

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Night: Doctor protects --

  defp apply_protect_player(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "doctor"),
         :ok <- ensure_living(players, target_id) do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "protect", target: target_id})

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{night_actions: night_actions}))
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Night: Villager sleeps --

  defp apply_sleep(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "sleep"})

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{night_actions: night_actions}))
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Night: Villager wanders --

  defp apply_night_wander(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "night"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "wander"})

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{night_actions: night_actions}))
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Day: Make statement --

  defp apply_make_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, ["day_discussion", "runoff_discussion"]),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: player_id, statement: statement}
      new_transcript = transcript ++ [new_entry]

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            discussion_turn_count: discussion_turn_count(state.world) + 1
          })
        )
        |> State.append_event(event)

      advance_day_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Day: Cast vote --

  defp apply_cast_vote(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, ["day_voting", "runoff_voting"]),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_valid_vote_target(players, player_id, target_id) do
      votes =
        state.world
        |> get(:votes, %{})
        |> Map.put(player_id, target_id)

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{votes: votes}))
        |> State.append_event(event)

      advance_voting_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Turn advancement --

  defp advance_night_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All night actors have gone; resolve the night
        resolve_night(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} night action"}}
    end
  end

  defp advance_day_discussion_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)
    discussion_round = get(state.world, :discussion_round, 1)
    discussion_round_limit = get(state.world, :discussion_round_limit, 1)
    day_number = get(state.world, :day_number, 1)
    players = get(state.world, :players, %{})
    phase = get(state.world, :phase)

    if discussion_turn_limit_reached?(state.world) do
      if phase == "runoff_discussion" do
        transition_to_runoff_voting(state)
      else
        transition_to_voting(state)
      end
    else
      case next_in_order(turn_order, active_actor_id) do
        nil ->
          if discussion_round < discussion_round_limit do
            next_round = discussion_round + 1
            next_order = Roles.discussion_turn_order(players, day_number, next_round)
            next_actor = List.first(next_order)

            next_state =
              State.put_world(
                state,
                world_updates(state.world, %{
                  discussion_round: next_round,
                  turn_order: next_order,
                  active_actor_id: next_actor
                })
              )

            {:ok, next_state, {:decide, "#{next_actor} discussion round #{next_round}"}}
          else
            if phase == "runoff_discussion" do
              transition_to_runoff_voting(state)
            else
              transition_to_voting(state)
            end
          end

        next_actor ->
          next_state =
            State.put_world(
              state,
              world_updates(state.world, %{active_actor_id: next_actor})
            )

          {:ok, next_state, {:decide, "#{next_actor} discussion turn"}}
      end
    end
  end

  defp advance_voting_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All votes cast; resolve
        resolve_votes(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} vote"}}
    end
  end

  # -- Wolf Discussion --

  defp apply_wolf_chat(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    message = fetch(event.payload, :message, "message")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "wolf_discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_role(players, player_id, "werewolf") do
      wolf_chat = get(state.world, :wolf_chat_transcript, [])
      new_entry = %{player: player_id, message: message}
      new_chat = wolf_chat ++ [new_entry]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{wolf_chat_transcript: new_chat}))
        |> State.append_event(event)

      advance_wolf_discussion_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp advance_wolf_discussion_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All wolves have spoken; transition to night actions
        transition_to_night_actions(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} wolf chat"}}
    end
  end

  defp transition_to_night_actions(%State{} = state) do
    players = get(state.world, :players, %{})
    night_order = Roles.night_turn_order(players)
    first_actor = List.first(night_order)
    day_number = get(state.world, :day_number, 1)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "night",
          turn_order: night_order,
          active_actor_id: first_actor,
          night_actions: %{}
        })
      )
      |> State.append_event(Events.phase_changed("night", day_number))

    {:ok, next_state, {:decide, "#{first_actor} night action"}}
  end

  # -- Accusations --

  defp apply_make_accusation(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    reason = fetch(event.payload, :reason, "reason")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, ["day_discussion", "runoff_discussion"]),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(player_id, target_id) do
      transcript = get(state.world, :discussion_transcript, [])

      new_entry = %{
        player: player_id,
        statement: reason,
        reason: reason,
        type: "accusation",
        target: target_id
      }

      new_transcript = transcript ++ [new_entry]

      turn_order = get(state.world, :turn_order, [])
      new_turn_order = prioritize_accusation_response(turn_order, player_id, target_id)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            discussion_turn_count: discussion_turn_count(state.world) + 1,
            turn_order: new_turn_order
          })
        )
        |> State.append_event(event)

      advance_day_discussion_turn(next_state)
    else
      {:error, reason_atom} ->
        reject_action(state, event, player_id, reason_atom)
    end
  end

  # -- Last Words --

  defp apply_make_last_words(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase_in(state.world, ["last_words_vote", "last_words_night"]),
         :ok <- ensure_active_actor(state.world, player_id) do
      last_words = get(state.world, :last_words, [])
      new_entry = %{player: player_id, statement: statement}
      new_last_words = last_words ++ [new_entry]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{last_words: new_last_words}))
        |> State.append_event(event)

      complete_elimination(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp complete_elimination(%State{} = state) do
    pending = get(state.world, :pending_elimination)
    players = get(state.world, :players, %{})
    phase = get(state.world, :phase)

    eliminated_id = get(pending, :player_id)
    eliminated_role = get(pending, :role)
    reason = get(pending, :reason)

    # Kill the player
    victim = Map.get(players, eliminated_id, %{})
    updated_players = Map.put(players, eliminated_id, Map.put(victim, :status, "dead"))

    # Build elimination events
    elimination_events = [Events.player_eliminated(eliminated_id, eliminated_role, reason)]

    # Update elimination log
    elimination_log = get(state.world, :elimination_log, [])
    day_number = get(state.world, :day_number, 1)

    new_elimination_log =
      elimination_log ++
        [
          %{
            player: eliminated_id,
            role: eliminated_role,
            reason: if(phase == "last_words_vote", do: "voted", else: "killed"),
            day: day_number
          }
        ]

    # Check win conditions
    {status, winner, game_over_events} = check_win_conditions(updated_players)

    if status == "game_over" do
      # Archive current day's transcript and votes on game over
      past_transcripts = get(state.world, :past_transcripts, %{})
      past_votes = get(state.world, :past_votes, %{})
      current_transcript = get(state.world, :discussion_transcript, [])
      current_votes = get(state.world, :votes, %{})

      new_past_transcripts =
        if length(current_transcript) > 0,
          do: Map.put(past_transcripts, day_number, current_transcript),
          else: past_transcripts

      new_past_votes =
        if map_size(current_votes) > 0,
          do: Map.put(past_votes, day_number, current_votes),
          else: past_votes

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            players: updated_players,
            elimination_log: new_elimination_log,
            pending_elimination: nil,
            past_transcripts: new_past_transcripts,
            past_votes: new_past_votes,
            status: "game_over",
            winner: winner,
            phase: "game_over",
            active_actor_id: nil,
            turn_order: [],
            discussion_round: 0,
            discussion_round_limit: 0,
            discussion_turn_count: 0,
            discussion_turn_limit: 0
          })
        )
        |> State.append_events(elimination_events ++ game_over_events)

      {:ok, next_state, :skip}
    else
      if phase == "last_words_vote" do
        # After vote elimination, transition to night
        vote_history = get(state.world, :vote_history, [])

        transition_to_night(
          %{state | world: Map.merge(state.world, %{players: updated_players})},
          updated_players,
          new_elimination_log,
          elimination_events,
          vote_history
        )
      else
        # After night kill, generate village event + items, then meetings
        village_event_data = maybe_generate_village_event(day_number)
        village_event_history = get(state.world, :village_event_history, [])

        {village_events_list, new_event_history, current_event} =
          case village_event_data do
            {type, desc} ->
              event_entry = %{day: day_number, type: type, description: desc}

              {[Events.village_event(type, desc)], village_event_history ++ [event_entry],
               event_entry}

            nil ->
              {[], village_event_history, nil}
          end

        item_data = maybe_distribute_items(updated_players, day_number)
        existing_items = get(state.world, :player_items, %{})

        {item_events, final_player_items} =
          case item_data do
            {pid, item_type, desc} ->
              current_items = Map.get(existing_items, pid, [])
              new_items = current_items ++ [%{type: item_type, found_day: day_number}]
              new_pi = Map.put(existing_items, pid, new_items)
              {[Events.item_found(pid, item_type, desc)], new_pi}

            nil ->
              {[], existing_items}
          end

        next_state =
          state
          |> State.put_world(
            world_updates(state.world, %{
              players: updated_players,
              pending_elimination: nil,
              elimination_log: new_elimination_log,
              village_event_history: new_event_history,
              current_village_event: current_event,
              player_items: final_player_items
            })
          )
          |> State.append_events(elimination_events ++ village_events_list ++ item_events)

        next_state = apply_village_event_effects(next_state, village_event_data)
        transition_to_meetings_or_discussion(next_state)
      end
    end
  end

  # -- Night resolution --

  defp resolve_night(%State{} = state) do
    night_actions = get(state.world, :night_actions, %{})
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)

    # Find the werewolf target (use the last werewolf's choice as the consensus)
    wolf_targets =
      night_actions
      |> Enum.filter(fn {_id, action} -> get(action, :action) == "choose_victim" end)
      |> Enum.map(fn {_id, action} -> get(action, :target) end)
      |> Enum.reject(&is_nil/1)

    # Use the most common target, or the last one if tied
    victim_id = most_common(wolf_targets)

    # Find doctor's protection target
    protected_id =
      night_actions
      |> Enum.find_value(fn {_id, action} ->
        if get(action, :action) == "protect", do: get(action, :target), else: nil
      end)

    saved? = not is_nil(victim_id) and victim_id == protected_id

    # Check for lock protection (item)
    lock_users =
      night_actions
      |> Enum.filter(fn {_id, action} ->
        get(action, :action) == "use_item" and get(action, :item) == "lock"
      end)
      |> Enum.map(fn {id, _} -> id end)

    lock_saved? = not is_nil(victim_id) and victim_id in lock_users

    # Check for wolfsbane (auto-trigger item)
    player_items = get(state.world, :player_items, %{})
    victim_items = if victim_id, do: Map.get(player_items, victim_id, []), else: []

    has_wolfsbane =
      Enum.any?(victim_items, fn i ->
        (Map.get(i, :type) || Map.get(i, "type")) == "wolfsbane"
      end)

    wolfsbane_saved? = not is_nil(victim_id) and has_wolfsbane and not saved? and not lock_saved?

    # Update saved status to include lock and wolfsbane
    saved? = saved? or lock_saved? or wolfsbane_saved?

    # Consume wolfsbane if triggered
    updated_player_items =
      if wolfsbane_saved? do
        new_victim_items = remove_first_item(victim_items, "wolfsbane")
        Map.put(player_items, victim_id, new_victim_items)
      else
        player_items
      end

    # Wolfsbane events
    wolfsbane_events =
      if wolfsbane_saved?, do: [Events.item_used(victim_id, "wolfsbane")], else: []

    # Lantern users get guaranteed sighting
    lantern_users =
      night_actions
      |> Enum.filter(fn {_id, action} ->
        get(action, :action) == "use_item" and get(action, :item) == "lantern"
      end)
      |> Enum.map(fn {id, _} -> id end)

    lantern_events =
      Enum.flat_map(lantern_users, fn user_id ->
        if not is_nil(victim_id) and not saved? do
          [
            Event.new("lantern_result", %{
              "player_id" => user_id,
              "description" => "Your lantern reveals shadowy figures near #{victim_id}'s house!",
              "saw_target" => victim_id
            })
          ]
        else
          [
            Event.new("lantern_result", %{
              "player_id" => user_id,
              "description" =>
                "Your lantern illuminates the village, but everything seems peaceful tonight.",
              "saw_target" => nil
            })
          ]
        end
      end)

    # Generate evidence tokens
    new_tokens = generate_evidence_tokens(night_actions, victim_id, protected_id, saved?)
    evidence_tokens = get(state.world, :evidence_tokens, [])
    day_evidence = Enum.map(new_tokens, &Map.put(&1, :day, day_number))
    all_evidence = evidence_tokens ++ day_evidence
    evidence_events = if length(new_tokens) > 0, do: [Events.evidence_found(new_tokens)], else: []

    # Process wanderers
    wanderer_results = get(state.world, :wanderer_results, [])

    new_wanderer_results =
      night_actions
      |> Enum.filter(fn {_id, action} -> get(action, :action) == "wander" end)
      |> Enum.map(fn {wanderer_id, _action} ->
        saw_something =
          not is_nil(victim_id) and not saved? and :rand.uniform() < @wander_sighting_chance

        if saw_something do
          %{
            day: day_number,
            wanderer: wanderer_id,
            saw_shadows: true,
            description: "You saw shadowy figures lurking near #{victim_id}'s house."
          }
        else
          %{
            day: day_number,
            wanderer: wanderer_id,
            saw_shadows: false,
            description: "The village was quiet. You saw nothing unusual."
          }
        end
      end)

    all_wanderer_results = wanderer_results ++ new_wanderer_results

    wanderer_events =
      Enum.map(new_wanderer_results, fn r ->
        Events.wanderer_result(
          Map.get(r, :wanderer),
          Map.get(r, :saw_shadows, false),
          Map.get(r, :description, "")
        )
      end)

    # Build resolution events
    resolution_events = [Events.night_resolved(victim_id, protected_id, saved?)]

    extra_events = wolfsbane_events ++ lantern_events ++ evidence_events ++ wanderer_events

    night_history = get(state.world, :night_history, [])

    new_night_history =
      night_history ++
        build_night_history(day_number, players, night_actions, victim_id, protected_id, saved?)

    # If someone was killed and not saved, give them last words unless their role is excluded.
    if not is_nil(victim_id) and not saved? do
      victim_role = get(Map.get(players, victim_id, %{}), :role, "unknown")

      # Mark victim as dead for display but give last words
      updated_players =
        Map.put(players, victim_id, Map.put(Map.get(players, victim_id, %{}), :status, "dead"))

      # Check if game would end
      {status, winner, game_over_events} = check_win_conditions(updated_players)

      if status == "game_over" do
        elimination_events = [
          Events.player_eliminated(victim_id, victim_role, "killed by werewolves")
        ]

        elimination_log = get(state.world, :elimination_log, [])

        new_elimination_log =
          elimination_log ++
            [%{player: victim_id, role: victim_role, reason: "killed", day: day_number}]

        # Archive current day's transcript and votes on game over
        past_transcripts = get(state.world, :past_transcripts, %{})
        past_votes = get(state.world, :past_votes, %{})
        current_transcript = get(state.world, :discussion_transcript, [])
        current_votes = get(state.world, :votes, %{})

        new_past_transcripts =
          if length(current_transcript) > 0,
            do: Map.put(past_transcripts, day_number, current_transcript),
            else: past_transcripts

        new_past_votes =
          if map_size(current_votes) > 0,
            do: Map.put(past_votes, day_number, current_votes),
            else: past_votes

        next_state =
          state
          |> State.put_world(
            world_updates(state.world, %{
              players: updated_players,
              night_actions: %{},
              night_history: new_night_history,
              elimination_log: new_elimination_log,
              past_transcripts: new_past_transcripts,
              past_votes: new_past_votes,
              evidence_tokens: all_evidence,
              wanderer_results: all_wanderer_results,
              player_items: updated_player_items,
              status: "game_over",
              winner: winner,
              phase: "game_over",
              active_actor_id: nil,
              turn_order: [],
              discussion_round: 0,
              discussion_round_limit: 0,
              discussion_turn_count: 0,
              discussion_turn_limit: 0
            })
          )
          |> State.append_events(
            resolution_events ++ elimination_events ++ extra_events ++ game_over_events
          )

        {:ok, next_state, :skip}
      else
        if allows_last_words?(victim_role) do
          # Give victim last words before completing elimination
          next_state =
            state
            |> State.put_world(
              world_updates(state.world, %{
                night_actions: %{},
                night_history: new_night_history,
                evidence_tokens: all_evidence,
                wanderer_results: all_wanderer_results,
                player_items: updated_player_items,
                phase: "last_words_night",
                active_actor_id: victim_id,
                turn_order: [victim_id],
                pending_elimination: %{
                  player_id: victim_id,
                  role: victim_role,
                  reason: "killed by werewolves"
                }
              })
            )
            |> State.append_events(
              resolution_events ++
                extra_events ++
                [Events.phase_changed("last_words_night", day_number)]
            )

          {:ok, next_state, {:decide, "#{victim_id} last words"}}
        else
          state
          |> State.put_world(
            world_updates(state.world, %{
              night_actions: %{},
              night_history: new_night_history,
              evidence_tokens: all_evidence,
              wanderer_results: all_wanderer_results,
              player_items: updated_player_items,
              phase: "last_words_night",
              active_actor_id: nil,
              turn_order: [],
              pending_elimination: %{
                player_id: victim_id,
                role: victim_role,
                reason: "killed by werewolves"
              }
            })
          )
          |> State.append_events(resolution_events ++ extra_events)
          |> complete_elimination()
        end
      end
    else
      # No kill or saved — generate village event and items, then meetings
      updated_players = players

      village_event_data = maybe_generate_village_event(day_number)
      village_event_history = get(state.world, :village_event_history, [])

      {village_events_list, new_event_history, current_event} =
        case village_event_data do
          {type, desc} ->
            event_entry = %{day: day_number, type: type, description: desc}

            {[Events.village_event(type, desc)], village_event_history ++ [event_entry],
             event_entry}

          nil ->
            {[], village_event_history, nil}
        end

      item_data = maybe_distribute_items(updated_players, day_number)

      {item_events, final_player_items} =
        case item_data do
          {pid, item_type, desc} ->
            current_items = Map.get(updated_player_items, pid, [])
            new_items = current_items ++ [%{type: item_type, found_day: day_number}]
            new_pi = Map.put(updated_player_items, pid, new_items)
            {[Events.item_found(pid, item_type, desc)], new_pi}

          nil ->
            {[], updated_player_items}
        end

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            players: updated_players,
            night_actions: %{},
            night_history: new_night_history,
            evidence_tokens: all_evidence,
            wanderer_results: all_wanderer_results,
            village_event_history: new_event_history,
            current_village_event: current_event,
            player_items: final_player_items
          })
        )
        |> State.append_events(
          resolution_events ++
            extra_events ++ village_events_list ++ item_events
        )

      next_state = apply_village_event_effects(next_state, village_event_data)
      transition_to_meetings_or_discussion(next_state)
    end
  end

  # -- Vote resolution --

  defp resolve_votes(%State{} = state) do
    votes = get(state.world, :votes, %{})
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)
    runoff_candidates = get(state.world, :runoff_candidates)

    # Tally votes (exclude "skip")
    vote_tally =
      votes
      |> Enum.reject(fn {_voter, target} -> target == "skip" end)
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    # Find the player with the most votes
    living_count = length(Roles.living_players(players))
    majority_threshold = div(living_count, 2) + 1

    {eliminated_id, _count} =
      vote_tally
      |> Enum.max_by(fn {_target, count} -> count end, fn -> {nil, 0} end)

    eliminated_id =
      if not is_nil(eliminated_id) and Map.get(vote_tally, eliminated_id, 0) >= majority_threshold do
        eliminated_id
      else
        nil
      end

    # Build vote events
    vote_events = [Events.vote_result(eliminated_id, vote_tally)]
    vote_history = get(state.world, :vote_history, [])
    new_vote_history = vote_history ++ build_vote_history(day_number, players, votes)

    cond do
      # Someone got majority — give them last words
      not is_nil(eliminated_id) ->
        victim_role = get(Map.get(players, eliminated_id, %{}), :role, "unknown")

        if allows_last_words?(victim_role) do
          next_state =
            state
            |> State.put_world(
              world_updates(state.world, %{
                votes: %{},
                vote_history: new_vote_history,
                phase: "last_words_vote",
                active_actor_id: eliminated_id,
                turn_order: [eliminated_id],
                pending_elimination: %{
                  player_id: eliminated_id,
                  role: victim_role,
                  reason: "voted out by the village"
                }
              })
            )
            |> State.append_events(
              vote_events ++
                [Events.phase_changed("last_words_vote", day_number)]
            )

          {:ok, next_state, {:decide, "#{eliminated_id} last words"}}
        else
          state
          |> State.put_world(
            world_updates(state.world, %{
              votes: %{},
              vote_history: new_vote_history,
              phase: "last_words_vote",
              active_actor_id: nil,
              turn_order: [],
              pending_elimination: %{
                player_id: eliminated_id,
                role: victim_role,
                reason: "voted out by the village"
              }
            })
          )
          |> State.append_events(vote_events)
          |> complete_elimination()
        end

      # No majority and this is first vote (no runoff yet) — try runoff
      is_nil(runoff_candidates) ->
        top_candidates = find_runoff_candidates(vote_tally)

        if length(top_candidates) >= 2 do
          transition_to_runoff(state, top_candidates, vote_events, new_vote_history)
        else
          # Not enough candidates for runoff, go to night
          transition_to_night(
            state,
            players,
            get(state.world, :elimination_log, []),
            vote_events,
            new_vote_history
          )
        end

      # No majority in runoff — no elimination, go to night
      true ->
        transition_to_night(
          state,
          players,
          get(state.world, :elimination_log, []),
          vote_events,
          new_vote_history
        )
    end
  end

  defp find_runoff_candidates(vote_tally) do
    vote_tally
    |> Enum.filter(fn {_target, count} -> count > 0 end)
    |> Enum.sort_by(fn {_target, count} -> -count end)
    |> Enum.take(2)
    |> Enum.map(fn {target, _count} -> target end)
  end

  defp transition_to_runoff(%State{} = state, candidates, preceding_events, vote_history) do
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)
    discussion_order = Roles.discussion_turn_order(players, day_number, 1)
    first_speaker = List.first(discussion_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "runoff_discussion",
          runoff_candidates: candidates,
          votes: %{},
          vote_history: vote_history,
          discussion_transcript: [],
          discussion_round: 1,
          discussion_round_limit: 1,
          discussion_turn_count: 0,
          discussion_turn_limit: discussion_turn_limit(discussion_order, 1),
          turn_order: discussion_order,
          active_actor_id: first_speaker
        })
      )
      |> State.append_events(
        preceding_events ++
          [Events.phase_changed("runoff_discussion", day_number)]
      )

    {:ok, next_state, {:decide, "#{first_speaker} runoff discussion"}}
  end

  defp transition_to_runoff_voting(%State{} = state) do
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)
    voting_order = Roles.voting_turn_order(players, day_number)
    first_voter = List.first(voting_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "runoff_voting",
          votes: %{},
          discussion_round: 0,
          discussion_round_limit: 0,
          discussion_turn_count: 0,
          discussion_turn_limit: 0,
          turn_order: voting_order,
          active_actor_id: first_voter
        })
      )
      |> State.append_event(Events.phase_changed("runoff_voting", day_number))

    {:ok, next_state, {:decide, "#{first_voter} runoff vote"}}
  end

  # -- Phase transitions --

  defp transition_to_voting(%State{} = state) do
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)
    voting_order = Roles.voting_turn_order(players, day_number)
    first_voter = List.first(voting_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "day_voting",
          votes: %{},
          discussion_round: 0,
          discussion_round_limit: 0,
          discussion_turn_count: 0,
          discussion_turn_limit: 0,
          turn_order: voting_order,
          active_actor_id: first_voter
        })
      )
      |> State.append_event(Events.phase_changed("day_voting", day_number))

    {:ok, next_state, {:decide, "#{first_voter} vote"}}
  end

  defp transition_to_night(
         %State{} = state,
         players,
         elimination_log,
         preceding_events,
         vote_history
       ) do
    current_day = get(state.world, :day_number, 1)
    next_day = current_day + 1

    # Archive current day's transcript and votes
    past_transcripts = get(state.world, :past_transcripts, %{})
    past_votes = get(state.world, :past_votes, %{})
    current_transcript = get(state.world, :discussion_transcript, [])
    current_votes = get(state.world, :votes, %{})

    new_past_transcripts = Map.put(past_transcripts, current_day, current_transcript)
    new_past_votes = Map.put(past_votes, current_day, current_votes)

    # Start with wolf discussion if there are living wolves
    living_wolves = Roles.living_with_role(players, "werewolf")

    {initial_phase, turn_order, first_actor, phase_label} =
      if length(living_wolves) > 0 do
        {"wolf_discussion", living_wolves, List.first(living_wolves), "wolf_discussion"}
      else
        night_order = Roles.night_turn_order(players)
        {"night", night_order, List.first(night_order), "night"}
      end

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          players: players,
          phase: initial_phase,
          day_number: next_day,
          night_actions: %{},
          discussion_transcript: [],
          votes: %{},
          vote_history: vote_history,
          turn_order: turn_order,
          active_actor_id: first_actor,
          elimination_log: elimination_log,
          discussion_round: 0,
          discussion_round_limit: 0,
          discussion_turn_count: 0,
          discussion_turn_limit: 0,
          past_transcripts: new_past_transcripts,
          past_votes: new_past_votes,
          wolf_chat_transcript: [],
          runoff_candidates: nil,
          pending_elimination: nil,
          current_village_event: nil
        })
      )
      |> State.append_events(preceding_events ++ [Events.phase_changed(phase_label, next_day)])

    {:ok, next_state,
     {:decide,
      "#{first_actor} #{if initial_phase == "wolf_discussion", do: "wolf chat", else: "night action"}"}}
  end

  # -- Win condition checks --

  defp check_win_conditions(players) do
    cond do
      Roles.villagers_win?(players) ->
        {"game_over", "villagers",
         [
           Events.game_over(
             "villagers",
             "All werewolves have been eliminated! The village is safe."
           )
         ]}

      Roles.werewolves_win?(players) ->
        {"game_over", "werewolves",
         [Events.game_over("werewolves", "The werewolves have taken over the village!")]}

      true ->
        {"in_progress", nil, []}
    end
  end

  defp allows_last_words?("seer"), do: false
  defp allows_last_words?(_role), do: true

  defp ensure_seer_can_investigate(world) do
    if get(world, :day_number, 1) > 1, do: :ok, else: {:error, :investigation_not_ready}
  end

  # -- Helpers --

  defp most_common([]), do: nil

  defp most_common(list) do
    list
    |> Enum.frequencies()
    |> Enum.max_by(fn {_val, count} -> count end)
    |> elem(0)
  end

  defp build_vote_history(day_number, players, votes) do
    votes
    |> Enum.sort_by(fn {voter, _target} -> voter end)
    |> Enum.map(fn {voter, target} ->
      target_role =
        if target == "skip" do
          nil
        else
          players |> Map.get(target, %{}) |> get(:role)
        end

      %{
        day: day_number,
        voter: voter,
        voter_role: players |> Map.get(voter, %{}) |> get(:role),
        target: target,
        target_role: target_role
      }
    end)
  end

  defp build_night_history(day_number, players, night_actions, victim_id, protected_id, saved?) do
    night_actions
    |> Enum.sort_by(fn {player, _action} -> player end)
    |> Enum.map(fn {player, action} ->
      target = get(action, :target)

      %{
        day: day_number,
        player: player,
        player_role: players |> Map.get(player, %{}) |> get(:role),
        action: get(action, :action),
        target: target,
        target_role: if(is_binary(target), do: players |> Map.get(target, %{}) |> get(:role)),
        result: get(action, :result),
        saved: saved? and target == victim_id and target == protected_id,
        successful: night_action_success?(action, victim_id, protected_id, saved?)
      }
    end)
  end

  defp night_action_success?(action, victim_id, protected_id, saved?) do
    case get(action, :action) do
      "choose_victim" ->
        get(action, :target) == victim_id and (not saved? or victim_id != protected_id)

      "protect" ->
        saved? and get(action, :target) == protected_id and protected_id == victim_id

      "investigate" ->
        get(action, :result) == "werewolf"

      _ ->
        false
    end
  end

  # -- Meeting Selection --

  defp apply_request_meeting(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "meeting_selection"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(player_id, target_id) do
      meeting_requests =
        state.world
        |> get(:meeting_requests, %{})
        |> Map.put(player_id, target_id)

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{meeting_requests: meeting_requests}))
        |> State.append_event(event)

      advance_meeting_selection(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp advance_meeting_selection(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        resolve_meeting_pairs(state)

      next_actor ->
        next_state =
          State.put_world(state, world_updates(state.world, %{active_actor_id: next_actor}))

        {:ok, next_state, {:decide, "#{next_actor} meeting selection"}}
    end
  end

  defp resolve_meeting_pairs(%State{} = state) do
    requests = get(state.world, :meeting_requests, %{})
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)

    living_ids =
      players |> Roles.living_players() |> Enum.map(fn {id, _} -> id end) |> Enum.sort()

    pairs = build_meeting_pairs(requests, living_ids)

    if length(pairs) == 0 do
      transition_to_day_discussion_from_meetings(state)
    else
      [first_pair | _] = pairs
      [first_speaker, second_speaker] = first_pair

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            phase: "private_meeting",
            meeting_pairs: pairs,
            current_meeting_index: 0,
            current_meeting_messages: [],
            turn_order: first_pair,
            active_actor_id: first_speaker
          })
        )
        |> State.append_event(Events.phase_changed("private_meeting", day_number))

      {:ok, next_state, {:decide, "#{first_speaker} meeting with #{second_speaker}"}}
    end
  end

  defp build_meeting_pairs(requests, living_ids) do
    mutual =
      requests
      |> Enum.filter(fn {a, b} -> Map.get(requests, b) == a and a < b end)
      |> Enum.map(fn {a, b} -> [a, b] end)

    paired = mutual |> List.flatten() |> MapSet.new()
    unpaired = Enum.reject(living_ids, &MapSet.member?(paired, &1))
    remaining_pairs = unpaired |> Enum.chunk_every(2, 2, :discard)

    (mutual ++ remaining_pairs)
    |> Enum.take(div(length(living_ids), 2))
  end

  # -- Private Meeting Messages --

  defp apply_meeting_message(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    message = fetch(event.payload, :message, "message")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "private_meeting"),
         :ok <- ensure_active_actor(state.world, player_id) do
      current_messages = get(state.world, :current_meeting_messages, [])
      new_messages = current_messages ++ [%{player: player_id, message: message}]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{current_meeting_messages: new_messages}))
        |> State.append_event(event)

      advance_meeting_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp advance_meeting_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        complete_current_meeting(state)

      next_actor ->
        next_state =
          State.put_world(state, world_updates(state.world, %{active_actor_id: next_actor}))

        {:ok, next_state, {:decide, "#{next_actor} meeting message"}}
    end
  end

  defp complete_current_meeting(%State{} = state) do
    pairs = get(state.world, :meeting_pairs, [])
    current_idx = get(state.world, :current_meeting_index, 0)
    current_messages = get(state.world, :current_meeting_messages, [])
    day_number = get(state.world, :day_number, 1)
    meeting_transcripts = get(state.world, :meeting_transcripts, [])
    current_pair = Enum.at(pairs, current_idx, [])

    new_transcript = %{day: day_number, pair: current_pair, messages: current_messages}
    new_transcripts = meeting_transcripts ++ [new_transcript]
    next_idx = current_idx + 1

    if next_idx < length(pairs) do
      next_pair = Enum.at(pairs, next_idx)
      [first_speaker, second_speaker] = next_pair

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            meeting_transcripts: new_transcripts,
            current_meeting_index: next_idx,
            current_meeting_messages: [],
            turn_order: next_pair,
            active_actor_id: first_speaker
          })
        )

      {:ok, next_state, {:decide, "#{first_speaker} meeting with #{second_speaker}"}}
    else
      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            meeting_transcripts: new_transcripts,
            current_meeting_index: 0,
            current_meeting_messages: []
          })
        )

      transition_to_day_discussion_from_meetings(next_state)
    end
  end

  defp transition_to_day_discussion_from_meetings(%State{} = state) do
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)
    discussion_round_limit = Roles.discussion_round_limit(players, day_number)
    discussion_order = Roles.discussion_turn_order(players, day_number, 1)
    discussion_turn_limit = discussion_turn_limit(discussion_order, discussion_round_limit)
    first_speaker = List.first(discussion_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "day_discussion",
          discussion_transcript: [],
          discussion_round: 1,
          discussion_round_limit: discussion_round_limit,
          discussion_turn_count: 0,
          discussion_turn_limit: discussion_turn_limit,
          votes: %{},
          turn_order: discussion_order,
          active_actor_id: first_speaker,
          meeting_requests: %{},
          meeting_pairs: []
        })
      )
      |> State.append_event(Events.phase_changed("day_discussion", day_number))

    {:ok, next_state, {:decide, "#{first_speaker} discussion turn"}}
  end

  defp transition_to_meetings_or_discussion(%State{} = state) do
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)

    living_ids =
      players |> Roles.living_players() |> Enum.map(fn {id, _} -> id end) |> Enum.sort()

    first_player = List.first(living_ids)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "meeting_selection",
          meeting_requests: %{},
          meeting_pairs: [],
          current_meeting_messages: [],
          turn_order: living_ids,
          active_actor_id: first_player
        })
      )
      |> State.append_event(Events.phase_changed("meeting_selection", day_number))

    {:ok, next_state, {:decide, "#{first_player} meeting selection"}}
  end

  # -- Evidence tokens --

  defp generate_evidence_tokens(night_actions, victim_id, protected_id, saved?) do
    tokens = []

    tokens =
      if not is_nil(victim_id) and not saved? and :rand.uniform() < @evidence_chance_high do
        tokens ++
          [
            %{
              type: "muddy_footprints",
              clue: "Muddy footprints were found near #{victim_id}'s house.",
              related_to: victim_id
            }
          ]
      else
        tokens
      end

    tokens =
      if not is_nil(protected_id) and :rand.uniform() < @evidence_chance_low do
        tokens ++
          [
            %{
              type: "broken_vial",
              clue: "A broken vial was found outside #{protected_id}'s door.",
              related_to: protected_id
            }
          ]
      else
        tokens
      end

    seer_target =
      night_actions
      |> Enum.find_value(fn {_id, action} ->
        if get(action, :action) == "investigate", do: get(action, :target)
      end)

    tokens =
      if not is_nil(seer_target) and :rand.uniform() < @evidence_chance_low do
        tokens ++
          [
            %{
              type: "strange_symbol",
              clue: "A strange symbol was scratched near #{seer_target}'s window.",
              related_to: seer_target
            }
          ]
      else
        tokens
      end

    tokens =
      if :rand.uniform() < @evidence_chance_low do
        tokens ++
          [
            %{
              type: "torn_cloth",
              clue: "A torn piece of dark cloth was caught on a fence near the square.",
              related_to: nil
            }
          ]
      else
        tokens
      end

    if (is_nil(victim_id) or saved?) and :rand.uniform() < @evidence_chance_high do
      tokens ++
        [
          %{
            type: "cold_trail",
            clue:
              "An eerie chill lingered near the village square, but nothing seemed disturbed.",
            related_to: nil
          }
        ]
    else
      tokens
    end
  end

  # -- Village events --

  defp maybe_generate_village_event(day_number) do
    if day_number > 1 and :rand.uniform() < 0.5 do
      events = [
        {"stranger_arrives",
         "A mysterious stranger was seen passing through the village at dawn. No one recognizes them."},
        {"supply_raid", "The village storehouse was raided overnight! Supplies are missing."},
        {"blizzard", "A fierce blizzard is rolling in. The village must make decisions quickly."},
        {"festival",
         "Today is the village harvest festival! Spirits are high and people are willing to talk."},
        {"omen",
         "A black crow was found dead on the village well this morning. Some say it's a dark omen."},
        {"missing_livestock",
         "Several sheep were found dead near the edge of the village. Claw marks cover the fence."}
      ]

      Enum.random(events)
    else
      nil
    end
  end

  defp apply_village_event_effects(state, nil), do: state

  defp apply_village_event_effects(state, {event_type, _description}) do
    case event_type do
      "blizzard" ->
        current_limit = get(state.world, :discussion_round_limit, 2)
        new_limit = max(1, current_limit - 1)
        State.put_world(state, world_updates(state.world, %{discussion_round_limit: new_limit}))

      "festival" ->
        current_limit = get(state.world, :discussion_round_limit, 2)

        State.put_world(
          state,
          world_updates(state.world, %{discussion_round_limit: current_limit + 1})
        )

      _ ->
        state
    end
  end

  # -- Item distribution --

  defp maybe_distribute_items(players, day_number) do
    if day_number > 1 and :rand.uniform() < 0.4 do
      living = Roles.living_players(players) |> Enum.map(fn {id, _} -> id end)
      lucky_player = Enum.random(living)

      item_pool = [
        {"lantern", "You found an old lantern! Use it at night to see clearly."},
        {"lock", "You found a sturdy lock! Use it to secure your door tonight."},
        {"anonymous_letter",
         "You found blank parchment and a disguised seal! Send an anonymous message."},
        {"wolfsbane", "You found a bundle of wolfsbane! If wolves attack you, you'll survive."}
      ]

      {item_type, description} = Enum.random(item_pool)
      {lucky_player, item_type, description}
    else
      nil
    end
  end

  # -- Item usage handlers --

  defp apply_use_item(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    item_type = fetch(event.payload, :item_type, "item_type")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      night_actions =
        state.world
        |> get(:night_actions, %{})
        |> Map.put(player_id, %{action: "use_item", item: item_type})

      player_items = get(state.world, :player_items, %{})
      current_items = Map.get(player_items, player_id, [])
      new_items = remove_first_item(current_items, item_type)
      new_player_items = Map.put(player_items, player_id, new_items)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            night_actions: night_actions,
            player_items: new_player_items
          })
        )
        |> State.append_event(event)

      advance_night_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_anonymous_message(%State{} = state, event) do
    message = fetch(event.payload, :message, "message")
    phase = get(state.world, :phase)

    with :ok <- ensure_in_progress(state.world),
         true <- phase in ["day_discussion", "runoff_discussion"] do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: "Anonymous", statement: message, type: "anonymous"}
      new_transcript = transcript ++ [new_entry]

      active_actor = get(state.world, :active_actor_id)
      player_items = get(state.world, :player_items, %{})
      current_items = Map.get(player_items, active_actor, [])
      new_items = remove_first_item(current_items, "anonymous_letter")
      new_player_items = Map.put(player_items, active_actor, new_items)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            discussion_transcript: new_transcript,
            player_items: new_player_items,
            discussion_turn_count: discussion_turn_count(state.world) + 1
          })
        )
        |> State.append_event(event)

      advance_day_discussion_turn(next_state)
    else
      false ->
        reject_action(state, event, "Anonymous", :wrong_phase)

      {:error, reason} ->
        reject_action(state, event, "Anonymous", reason)
    end
  end

  defp discussion_turn_count(world) do
    get(world, :discussion_turn_count, length(get(world, :discussion_transcript, [])))
  end

  defp discussion_turn_limit_reached?(world) do
    turn_order = get(world, :turn_order, [])
    round_limit = get(world, :discussion_round_limit, 0)

    turn_limit =
      get(world, :discussion_turn_limit, discussion_turn_limit(turn_order, round_limit))

    turn_limit > 0 and discussion_turn_count(world) >= turn_limit
  end

  defp discussion_turn_limit(turn_order, round_limit) do
    length(turn_order) * max(round_limit, 0)
  end

  # Accusations can pull one future speaker forward, but they must not rewind the
  # round back to someone who already spoke or create duplicate turns.
  defp prioritize_accusation_response(turn_order, current_player_id, target_id) do
    case Enum.find_index(turn_order, &(&1 == current_player_id)) do
      nil ->
        turn_order

      current_idx ->
        next_idx = current_idx + 1

        case Enum.find_index(turn_order, &(&1 == target_id)) do
          nil ->
            turn_order

          target_idx when target_idx <= current_idx ->
            turn_order

          target_idx when target_idx == next_idx ->
            turn_order

          target_idx ->
            turn_order
            |> List.delete_at(target_idx)
            |> List.insert_at(next_idx, target_id)
        end
    end
  end

  defp remove_first_item(items, item_type) do
    idx =
      Enum.find_index(items, fn i ->
        (Map.get(i, :type) || Map.get(i, "type")) == item_type
      end)

    if idx, do: List.delete_at(items, idx), else: items
  end
end
