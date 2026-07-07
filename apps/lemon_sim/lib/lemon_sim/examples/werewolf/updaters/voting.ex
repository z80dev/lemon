defmodule LemonSim.Examples.Werewolf.Updaters.Voting do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.Werewolf.{Events, Roles}
  alias LemonSim.Examples.Werewolf.Updaters.Discussion
  alias LemonSim.Examples.Werewolf.Updaters.Elimination

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  def apply_cast_vote(%State{} = state, event) do
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

        if Elimination.allows_last_words?(victim_role) do
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
          |> Elimination.complete_elimination()
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
          discussion_turn_limit: Discussion.discussion_turn_limit(discussion_order, 1),
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

  def transition_to_runoff_voting(%State{} = state) do
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

  def transition_to_voting(%State{} = state) do
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

  def transition_to_night(
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
      if living_wolves != [] do
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
end
