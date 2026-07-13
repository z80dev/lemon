defmodule LemonSim.Examples.Werewolf.Updaters.NightResolution do
  @moduledoc false

  alias LemonSim.Kernel.{Event, State}
  alias LemonSim.Examples.Werewolf.{Events, Roles, RulesConfig}
  alias LemonSim.Examples.Werewolf.Updaters.Elimination
  alias LemonSim.Examples.Werewolf.Updaters.Items
  alias LemonSim.Examples.Werewolf.Updaters.Meetings
  alias LemonSim.Examples.Werewolf.Updaters.VillageEvents

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  @wander_sighting_chance 0.25
  @evidence_chance 0.55
  @clue_accuracy 0.70

  def resolve_night(%State{} = state) do
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

    wolf_id =
      night_actions
      |> Enum.find_value(fn {player_id, action} ->
        if get(action, :action) == "choose_victim", do: player_id
      end)

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
        new_victim_items = Items.remove_first_item(victim_items, "wolfsbane")
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
    new_tokens =
      if RulesConfig.enabled?(state.world, :evidence) do
        generate_evidence_tokens(players, wolf_id, victim_id, saved?)
      else
        []
      end

    evidence_tokens = get(state.world, :evidence_tokens, [])
    day_evidence = Enum.map(new_tokens, &Map.put(&1, :day, day_number))
    all_evidence = evidence_tokens ++ day_evidence
    evidence_events = if new_tokens != [], do: [Events.evidence_found(new_tokens)], else: []

    # Process wanderers
    wanderer_results = get(state.world, :wanderer_results, [])

    new_wanderer_results =
      night_actions
      |> Enum.filter(fn {_id, action} -> get(action, :action) == "wander" end)
      |> Enum.map(fn {wanderer_id, _action} ->
        saw_something =
          not is_nil(victim_id) and not saved? and :rand.uniform() < @wander_sighting_chance

        if saw_something do
          lead_id = noisy_wolf_lead(players, wolf_id, victim_id)

          %{
            day: day_number,
            wanderer: wanderer_id,
            saw_shadows: true,
            description:
              "In poor visibility, you saw a silhouette moving from #{lead_id}'s side of the village toward #{victim_id}'s house. This is a low-confidence observation, not proof."
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
      {status, winner, game_over_events} = Elimination.check_win_conditions(updated_players)

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
          if current_transcript != [],
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
        if Elimination.allows_last_words?(victim_role) do
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
          |> Elimination.complete_elimination()
        end
      end
    else
      # No kill or saved — generate village event and items, then meetings
      updated_players = players

      village_event_data = VillageEvents.maybe_generate_village_event(day_number, state.world)
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

      item_data = Items.maybe_distribute_items(updated_players, day_number, state.world)

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

      Meetings.transition_to_meetings_or_discussion(next_state)
    end
  end

  defp most_common([]), do: nil

  defp most_common(list) do
    list
    |> Enum.frequencies()
    |> Enum.max_by(fn {value, count} -> {count, value} end)
    |> elem(0)
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
        get(action, :target) == victim_id and not saved?

      "protect" ->
        saved? and get(action, :target) == protected_id and protected_id == victim_id

      "investigate" ->
        get(action, :result) == "werewolf"

      _ ->
        false
    end
  end

  defp generate_evidence_tokens(players, wolf_id, victim_id, saved?) do
    if not is_nil(wolf_id) and not is_nil(victim_id) and not saved? and
         :rand.uniform() < @evidence_chance do
      lead_id = noisy_wolf_lead(players, wolf_id, victim_id)

      [
        %{
          type: "muddy_footprints",
          clue:
            "A partial trail near #{victim_id}'s house appears to lead toward #{lead_id}'s side of the village.",
          related_to: lead_id,
          reliability: "medium",
          interpretation:
            "Comparable trails identify the killer about 70% of the time; weather or deliberate misdirection can produce a false lead. This is not proof."
        }
      ]
    else
      []
    end
  end

  defp noisy_wolf_lead(players, wolf_id, victim_id) do
    decoys =
      players
      |> Roles.living_players()
      |> Enum.map(fn {player_id, _player} -> player_id end)
      |> Enum.reject(&(&1 in [wolf_id, victim_id]))

    if :rand.uniform() <= @clue_accuracy or decoys == [] do
      wolf_id
    else
      Enum.random(decoys)
    end
  end
end
