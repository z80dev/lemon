defmodule LemonSim.Examples.SpaceStation.Updaters.Voting do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers
  import LemonSim.Examples.SpaceStation.Updaters.Support

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.SpaceStation.{Events, Roles}
  alias LemonSim.Examples.SpaceStation.Updaters.Crises

  # -- Voting: Cast vote --

  def apply_cast_vote(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "voting"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_valid_vote_target(players, player_id, target_id) do
      votes =
        state.world
        |> get(:votes, %{})
        |> Map.put(player_id, target_id)

      vote_journal =
        if target_id == "skip" do
          "Decided to skip the vote. Not enough evidence to eject anyone."
        else
          target_name = get(Map.get(players, target_id, %{}), :name, target_id)
          "Voted to eject #{target_name}."
        end

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{votes: votes}))
        |> State.append_event(event)
        |> add_journal_entry(player_id, vote_journal)

      advance_voting_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Turn advancement --

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

  # -- Vote resolution --

  defp resolve_votes(%State{} = state) do
    votes = get(state.world, :votes, %{})
    players = get(state.world, :players, %{})
    round = get(state.world, :round, 1)

    # Tally votes (exclude "skip")
    vote_tally =
      votes
      |> Enum.reject(fn {_voter, target} -> target == "skip" end)
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    # Find the player with the most votes
    living_count = length(Roles.living_players(players))
    majority_threshold = div(living_count, 2) + 1

    {ejected_id, _count} =
      vote_tally
      |> Enum.max_by(fn {_target, count} -> count end, fn -> {nil, 0} end)

    ejected_id =
      if not is_nil(ejected_id) and Map.get(vote_tally, ejected_id, 0) >= majority_threshold do
        ejected_id
      else
        nil
      end

    # Build events
    vote_events = [Events.vote_result(ejected_id, vote_tally)]

    ejection_events =
      if not is_nil(ejected_id) do
        victim_role = get(Map.get(players, ejected_id, %{}), :role, "unknown")
        [Events.player_ejected(ejected_id, victim_role)]
      else
        []
      end

    # Update elimination log
    elimination_log = get(state.world, :elimination_log, [])

    new_elimination_log =
      if not is_nil(ejected_id) do
        victim_role = get(Map.get(players, ejected_id, %{}), :role, "unknown")

        elimination_log ++
          [
            %{
              player: ejected_id,
              role: victim_role,
              reason: "ejected",
              round: get(state.world, :round, 1)
            }
          ]
      else
        elimination_log
      end

    vote_history =
      get(state.world, :vote_history, []) ++
        [
          %{
            round: round,
            votes: votes,
            vote_tally: vote_tally,
            ejected: ejected_id
          }
        ]

    # Apply reputation changes based on ejection result
    state_with_rep =
      if not is_nil(ejected_id) do
        victim_role = get(Map.get(players, ejected_id, %{}), :role, "unknown")
        ejected_name = get(Map.get(players, ejected_id, %{}), :name, ejected_id)

        # Journal entries for all living players about the ejection
        living_ids = Roles.living_players(players) |> Enum.map(fn {id, _p} -> id end)

        state_after_journals =
          Enum.reduce(living_ids, state, fn pid, acc ->
            if pid == ejected_id do
              acc
            else
              add_journal_entry(
                acc,
                pid,
                "#{ejected_name} was ejected. They were #{victim_role}."
              )
            end
          end)

        if victim_role == "saboteur" do
          # Correct ejection: +10 for voters who voted for the saboteur
          # +15 for captain if emergency meeting was called this game
          Enum.reduce(votes, state_after_journals, fn {voter_id, target}, acc ->
            if target == ejected_id do
              adjust_reputation(acc, voter_id, 10)
            else
              acc
            end
          end)
        else
          # Wrong ejection: -5 for voters who voted for a crew member
          Enum.reduce(votes, state_after_journals, fn {voter_id, target}, acc ->
            if target == ejected_id do
              adjust_reputation(acc, voter_id, -5)
            else
              acc
            end
          end)
        end
      else
        state
      end

    # Apply the ejection status on top of state_with_rep's players map so
    # this round's reputation deltas survive when the game continues past
    # the vote (previously this rebuilt from the pre-adjustment `players`
    # snapshot, silently discarding voter reputation changes).
    updated_players =
      if not is_nil(ejected_id) do
        players_with_rep = get(state_with_rep.world, :players, players)
        victim = Map.get(players_with_rep, ejected_id, %{})
        Map.put(players_with_rep, ejected_id, Map.put(victim, :status, "ejected"))
      else
        get(state_with_rep.world, :players, players)
      end

    if not is_nil(ejected_id) and get(Map.get(players, ejected_id, %{}), :role) == "saboteur" do
      next_state =
        state_with_rep
        |> State.put_world(
          world_updates(state_with_rep.world, %{
            players: updated_players,
            votes: %{},
            vote_history: vote_history,
            elimination_log: new_elimination_log,
            status: "game_over",
            winner: "crew",
            phase: "game_over",
            active_actor_id: nil,
            turn_order: []
          })
        )
        |> State.append_events(
          vote_events ++
            ejection_events ++
            [Events.game_over("crew", "The crew ejected the saboteur. The station is safe!")]
        )

      {:ok, next_state, :skip}
    else
      # Check if crew survived all rounds after this vote
      # (last round vote happens, then game ends)
      if round >= get(state_with_rep.world, :max_rounds, 8) do
        # Game over: crew survived
        game_over_events = [
          Events.game_over("crew", "The crew survived all #{round} rounds! The station is saved!")
        ]

        next_state =
          state_with_rep
          |> State.put_world(
            world_updates(state_with_rep.world, %{
              players: updated_players,
              votes: %{},
              vote_history: vote_history,
              elimination_log: new_elimination_log,
              status: "game_over",
              winner: "crew",
              phase: "game_over",
              active_actor_id: nil,
              turn_order: []
            })
          )
          |> State.append_events(vote_events ++ ejection_events ++ game_over_events)

        {:ok, next_state, :skip}
      else
        transition_to_next_round(
          state_with_rep,
          updated_players,
          new_elimination_log,
          vote_history,
          vote_events ++ ejection_events
        )
      end
    end
  end

  # -- Phase transitions --

  def transition_to_voting(%State{} = state) do
    players = get(state.world, :players, %{})
    round = get(state.world, :round, 1)
    voting_order = Roles.voting_turn_order(players, round)
    first_voter = List.first(voting_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "voting",
          votes: %{},
          discussion_round: 0,
          discussion_round_limit: 0,
          turn_order: voting_order,
          active_actor_id: first_voter
        })
      )
      |> State.append_event(Events.phase_changed("voting", round))

    {:ok, next_state, {:decide, "#{first_voter} vote"}}
  end

  defp transition_to_next_round(
         %State{} = state,
         players,
         elimination_log,
         vote_history,
         preceding_events
       ) do
    round = get(state.world, :round, 1) + 1
    action_order = Roles.action_turn_order(players, round)
    first_actor = List.first(action_order)

    # Generate crisis for rounds 3, 5, 7
    {active_crisis, crisis_events} =
      if round in [3, 5, 7] do
        crisis = Crises.generate_crisis(round, state.world)
        {crisis, [Events.crisis_triggered(crisis)]}
      else
        {nil, []}
      end

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          players: players,
          phase: "action",
          round: round,
          action_log: %{},
          location_log: [],
          discussion_transcript: [],
          vote_history: vote_history,
          votes: %{},
          discussion_round: 0,
          discussion_round_limit: 0,
          turn_order: action_order,
          active_actor_id: first_actor,
          elimination_log: elimination_log,
          captain_lock: nil,
          scan_results: %{},
          emergency_meeting_called: false,
          active_crisis: active_crisis,
          pending_questions: [],
          accusations: []
        })
      )
      |> State.append_events(
        preceding_events ++ crisis_events ++ [Events.phase_changed("action", round)]
      )

    {:ok, next_state, {:decide, "#{first_actor} action"}}
  end
end
