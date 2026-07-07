defmodule LemonSim.Examples.Werewolf.Updaters.Elimination do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.{Events, Roles}
  alias LemonSim.Examples.Werewolf.Updaters.Items
  alias LemonSim.Examples.Werewolf.Updaters.Meetings
  alias LemonSim.Examples.Werewolf.Updaters.VillageEvents
  alias LemonSim.Examples.Werewolf.Updaters.Voting

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def apply_make_last_words(%State{} = state, event) do
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

  def complete_elimination(%State{} = state) do
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

        Voting.transition_to_night(
          %{state | world: Map.merge(state.world, %{players: updated_players})},
          updated_players,
          new_elimination_log,
          elimination_events,
          vote_history
        )
      else
        # After night kill, generate village event + items, then meetings
        village_event_data = VillageEvents.maybe_generate_village_event(day_number)
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

        item_data = Items.maybe_distribute_items(updated_players, day_number)
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

        next_state = VillageEvents.apply_village_event_effects(next_state, village_event_data)
        Meetings.transition_to_meetings_or_discussion(next_state)
      end
    end
  end

  def check_win_conditions(players) do
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

  def allows_last_words?("seer"), do: false
  def allows_last_words?(_role), do: true
end
