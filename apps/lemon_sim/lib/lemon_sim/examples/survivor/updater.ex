defmodule LemonSim.Examples.Survivor.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers

  alias LemonSim.State
  alias LemonSim.Examples.Survivor.{Events, Tribes}

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "challenge_choice" -> apply_challenge_choice(state, event)
      "make_statement" -> apply_make_statement(state, event)
      "send_whisper" -> apply_send_whisper(state, event)
      "play_idol" -> apply_play_idol(state, event)
      "skip_idol" -> apply_skip_idol(state, event)
      "cast_vote" -> apply_cast_vote(state, event)
      "jury_statement" -> apply_jury_statement(state, event)
      "make_final_plea" -> apply_make_final_plea(state, event)
      "jury_vote" -> apply_jury_vote(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Challenge phase --

  defp apply_challenge_choice(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    strategy = fetch(event.payload, :strategy, "strategy")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "challenge"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_valid_strategy(strategy) do
      challenge_choices =
        state.world
        |> get(:challenge_choices, %{})
        |> Map.put(player_id, strategy)

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{challenge_choices: challenge_choices}))
        |> State.append_event(event)

      advance_challenge_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Strategy phase --

  defp apply_make_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "strategy"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      statements = get(state.world, :statements, [])
      new_entry = %{player: player_id, statement: statement}
      new_statements = statements ++ [new_entry]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{statements: new_statements}))
        |> State.append_event(event)

      # In strategy phase, each player gets statement then whisper.
      # After statement, same player whispers next (handled by the strategy sub-phase logic).
      strategy_actions = get(state.world, :strategy_actions, %{})
      player_actions = Map.get(strategy_actions, player_id, %{})

      if Map.get(player_actions, :stated, false) do
        # Already stated, advance to next player
        advance_strategy_turn(next_state)
      else
        # Mark as stated, keep same actor for whisper
        updated_actions =
          Map.put(strategy_actions, player_id, Map.put(player_actions, :stated, true))

        next_state2 =
          State.put_world(
            next_state,
            world_updates(next_state.world, %{strategy_actions: updated_actions})
          )

        # Let the same actor do their whisper next
        {:ok, next_state2, {:decide, "#{player_id} whisper turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_send_whisper(%State{} = state, event) do
    from_id =
      fetch(event.payload, :from_id, "from_id") || fetch(event.payload, :player_id, "player_id")

    to_id = fetch(event.payload, :to_id, "to_id")
    message = fetch(event.payload, :message, "message")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "strategy"),
         :ok <- ensure_active_actor(state.world, from_id),
         :ok <- ensure_living(players, from_id),
         :ok <- ensure_living(players, to_id),
         :ok <- ensure_different(from_id, to_id) do
      whisper_log = get(state.world, :whisper_log, [])
      new_whisper = %{from: from_id, to: to_id, message: message}
      new_whisper_log = whisper_log ++ [new_whisper]
      whisper_history = get(state.world, :whisper_history, [])
      episode = get(state.world, :episode, 1)

      whisper_graph = get(state.world, :whisper_graph, [])
      new_graph_entry = %{from: from_id, to: to_id}
      new_whisper_graph = whisper_graph ++ [new_graph_entry]

      # Mark whisper done for this player
      strategy_actions = get(state.world, :strategy_actions, %{})
      player_actions = Map.get(strategy_actions, from_id, %{})

      updated_actions =
        Map.put(strategy_actions, from_id, Map.put(player_actions, :whispered, true))

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            whisper_log: new_whisper_log,
            whisper_history: whisper_history ++ [%{episode: episode, from: from_id, to: to_id}],
            whisper_graph: new_whisper_graph,
            strategy_actions: updated_actions
          })
        )
        |> State.append_event(event)

      advance_strategy_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, from_id, reason)
    end
  end

  # -- Tribal council: idol --

  defp apply_play_idol(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "tribal_council"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_has_idol(players, player_id) do
      # Remove idol from player, record it
      actor = Map.get(players, player_id, %{})
      updated_actor = Map.put(actor, :has_idol, false)
      updated_players = Map.put(players, player_id, updated_actor)
      idol_history = get(state.world, :idol_history, [])
      episode = get(state.world, :episode, 1)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            players: updated_players,
            idol_played_by: player_id,
            idol_history: idol_history ++ [%{episode: episode, player: player_id}]
          })
        )
        |> State.append_event(event)

      advance_idol_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_skip_idol(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "tribal_council"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      next_state =
        state
        |> State.append_event(event)

      advance_idol_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Tribal council: voting --

  defp apply_cast_vote(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "tribal_council"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id),
         :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(player_id, target_id) do
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

  # -- Final tribal council --

  defp apply_jury_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "final_tribal_council"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_jury_member(state.world, player_id) do
      jury_statements = get(state.world, :jury_statements, [])
      new_entry = %{player: player_id, statement: statement}
      new_statements = jury_statements ++ [new_entry]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{jury_statements: new_statements}))
        |> State.append_event(event)

      advance_ftc_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_make_final_plea(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    plea = fetch(event.payload, :plea, "plea")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "final_tribal_council"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      statements = get(state.world, :jury_statements, [])
      new_entry = %{player: player_id, statement: plea, type: "final_plea"}
      new_statements = statements ++ [new_entry]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{jury_statements: new_statements}))
        |> State.append_event(event)

      advance_ftc_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  defp apply_jury_vote(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    target_id = fetch(event.payload, :target_id, "target_id")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "final_tribal_council"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_jury_member(state.world, player_id),
         :ok <- ensure_living(players, target_id) do
      jury_votes =
        state.world
        |> get(:jury_votes, %{})
        |> Map.put(player_id, target_id)

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{jury_votes: jury_votes}))
        |> State.append_event(event)

      advance_ftc_turn(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Turn advancement: Challenge --

  defp advance_challenge_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # All players have chosen; resolve the challenge
        resolve_challenge(state)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} challenge choice"}}
    end
  end

  # -- Turn advancement: Strategy --

  defp advance_strategy_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)
    strategy_actions = get(state.world, :strategy_actions, %{})

    # Check if current player has both stated and whispered
    current_actions = Map.get(strategy_actions, active_actor_id, %{})

    current_done =
      Map.get(current_actions, :stated, false) and Map.get(current_actions, :whispered, false)

    if not current_done do
      # Current player still needs to do something
      {:ok, state, {:decide, "#{active_actor_id} strategy action"}}
    else
      case next_in_order(turn_order, active_actor_id) do
        nil ->
          # Strategy phase over, transition to tribal council
          transition_to_tribal_council(state)

        next_actor ->
          next_state =
            State.put_world(
              state,
              world_updates(state.world, %{active_actor_id: next_actor})
            )

          {:ok, next_state, {:decide, "#{next_actor} strategy turn"}}
      end
    end
  end

  # -- Turn advancement: Idol phase --

  defp advance_idol_turn(%State{} = state) do
    turn_order = get(state.world, :idol_turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # Idol phase done, transition to voting
        tc_voters = get(state.world, :tc_voters, [])
        first_voter = List.first(tc_voters)
        episode = get(state.world, :episode, 1)

        next_state =
          state
          |> State.put_world(
            world_updates(state.world, %{
              idol_phase_done: true,
              turn_order: tc_voters,
              active_actor_id: first_voter
            })
          )

        {:ok, next_state, {:decide, "#{first_voter} vote at tribal council episode #{episode}"}}

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} idol decision"}}
    end
  end

  # -- Turn advancement: Voting --

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

  # -- Turn advancement: Final Tribal Council --

  defp advance_ftc_turn(%State{} = state) do
    turn_order = get(state.world, :turn_order, [])
    active_actor_id = get(state.world, :active_actor_id, nil)
    sub_phase = get(state.world, :ftc_sub_phase, "jury_statements")

    case next_in_order(turn_order, active_actor_id) do
      nil ->
        # Current sub-phase complete, advance to next
        advance_ftc_sub_phase(state, sub_phase)

      next_actor ->
        next_state =
          State.put_world(
            state,
            world_updates(state.world, %{active_actor_id: next_actor})
          )

        {:ok, next_state, {:decide, "#{next_actor} #{sub_phase}"}}
    end
  end

  defp advance_ftc_sub_phase(%State{} = state, "jury_statements") do
    # Jury statements done, now finalists plead
    players = get(state.world, :players, %{})

    {_jury_order, finalist_order} =
      Tribes.final_tribal_council_order(players, get(state.world, :jury, []))

    first_finalist = List.first(finalist_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          ftc_sub_phase: "finalist_pleas",
          turn_order: finalist_order,
          active_actor_id: first_finalist
        })
      )

    {:ok, next_state, {:decide, "#{first_finalist} final plea"}}
  end

  defp advance_ftc_sub_phase(%State{} = state, "finalist_pleas") do
    # Finalist pleas done, now jury votes
    jury = get(state.world, :jury, [])
    first_juror = List.first(jury)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          ftc_sub_phase: "jury_voting",
          turn_order: jury,
          active_actor_id: first_juror
        })
      )

    {:ok, next_state, {:decide, "#{first_juror} jury vote"}}
  end

  defp advance_ftc_sub_phase(%State{} = state, "jury_voting") do
    # All jury votes in, resolve the winner
    resolve_jury_votes(state)
  end

  defp advance_ftc_sub_phase(%State{} = state, _sub_phase) do
    {:ok, state, :skip}
  end

  # -- Challenge resolution --

  defp resolve_challenge(%State{} = state) do
    challenge_choices = get(state.world, :challenge_choices, %{})
    players = get(state.world, :players, %{})
    merged = get(state.world, :merged, false)
    episode = get(state.world, :episode, 1)

    if merged do
      resolve_individual_challenge(state, challenge_choices, players, episode)
    else
      resolve_tribal_challenge(state, challenge_choices, players, episode)
    end
  end

  defp resolve_tribal_challenge(%State{} = state, choices, players, episode) do
    tribes = get(state.world, :tribes, %{})

    tribe_choices =
      Enum.into(tribes, %{}, fn {tribe_name, _members} ->
        living_choices =
          players
          |> Tribes.living_tribe_members(tribe_name)
          |> Enum.map(fn id -> Map.get(choices, id, "physical") end)

        {tribe_name, living_choices}
      end)

    tribe_scores =
      Enum.into(tribe_choices, %{}, fn {tribe_name, own_choices} ->
        opposing_choices =
          tribe_choices
          |> Enum.reject(fn {other_name, _choices} -> other_name == tribe_name end)
          |> Enum.flat_map(fn {_other_name, other_choices} -> other_choices end)

        score =
          own_choices
          |> Enum.map(&strategy_match_score(&1, opposing_choices))
          |> Enum.sum()

        {tribe_name, score}
      end)

    # Tribe with highest aggregate score wins
    {winning_tribe, _score} =
      tribe_scores
      |> Enum.max_by(fn {_name, score} -> score end, fn -> {nil, 0} end)

    # Determine losing tribe
    losing_tribe =
      tribes
      |> Map.keys()
      |> Enum.find(fn name -> name != winning_tribe end)

    results = %{
      "tribe_scores" => tribe_scores,
      "choices" => choices
    }

    challenge_history = get(state.world, :challenge_history, [])

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          challenge_choices: %{},
          challenge_winner: winning_tribe,
          losing_tribe: losing_tribe,
          challenge_history:
            challenge_history ++
              [
                %{
                  episode: episode,
                  merged: false,
                  choices: choices,
                  winner: winning_tribe,
                  losing_tribe: losing_tribe,
                  scores: tribe_scores
                }
              ]
        })
      )
      |> State.append_event(Events.challenge_resolved(winning_tribe, results))

    # Transition to strategy phase for losing tribe
    transition_to_strategy(next_state, losing_tribe, episode)
  end

  defp resolve_individual_challenge(%State{} = state, choices, players, episode) do
    living = Tribes.living_player_ids(players)

    player_scores =
      Enum.map(living, fn id ->
        strategy = Map.get(choices, id, "physical")

        opposing_choices =
          living
          |> Enum.reject(&(&1 == id))
          |> Enum.map(fn other_id -> Map.get(choices, other_id, "physical") end)

        {id, strategy_match_score(strategy, opposing_choices)}
      end)

    {winner, _score} =
      player_scores
      |> Enum.max_by(fn {id, score} -> {score, id} end, fn -> {nil, 0} end)

    results = %{
      "player_scores" => Enum.into(player_scores, %{}),
      "choices" => choices
    }

    challenge_history = get(state.world, :challenge_history, [])

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          challenge_choices: %{},
          challenge_winner: winner,
          immune_player: winner,
          challenge_history:
            challenge_history ++
              [
                %{
                  episode: episode,
                  merged: true,
                  choices: choices,
                  winner: winner,
                  scores: Enum.into(player_scores, %{})
                }
              ]
        })
      )
      |> State.append_event(Events.challenge_resolved(winner, results))

    # Transition to strategy phase for all players
    transition_to_strategy(next_state, nil, episode)
  end

  defp strategy_match_score(strategy, opposing_choices) do
    Enum.reduce(opposing_choices, 0, fn opposing, score ->
      score + matchup_result(strategy, opposing)
    end)
  end

  defp matchup_result("physical", "endurance"), do: 1
  defp matchup_result("physical", "puzzle"), do: -1
  defp matchup_result("puzzle", "physical"), do: 1
  defp matchup_result("puzzle", "endurance"), do: -1
  defp matchup_result("endurance", "puzzle"), do: 1
  defp matchup_result("endurance", "physical"), do: -1
  defp matchup_result(strategy, strategy), do: 0
  defp matchup_result(_, _), do: 0

  # -- Vote resolution --

  defp resolve_votes(%State{} = state) do
    votes = get(state.world, :votes, %{})
    players = get(state.world, :players, %{})
    idol_played_by = get(state.world, :idol_played_by)
    merged = get(state.world, :merged, false)
    jury = get(state.world, :jury, [])
    episode = get(state.world, :episode, 1)

    # Negate votes against idol player
    effective_votes =
      if idol_played_by do
        votes
        |> Enum.reject(fn {_voter, target} -> target == idol_played_by end)
        |> Enum.into(%{})
      else
        votes
      end

    # Tally votes
    vote_tally =
      effective_votes
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    # Find player with most votes
    {eliminated_id, _count} =
      vote_tally
      |> Enum.max_by(fn {_target, count} -> count end, fn -> {nil, 0} end)

    # Always eliminate the plurality leader (no majority needed in Survivor)
    eliminated_id =
      if eliminated_id && Map.get(vote_tally, eliminated_id, 0) > 0 do
        eliminated_id
      else
        nil
      end

    # Apply elimination
    {updated_players, updated_jury} =
      if eliminated_id do
        Tribes.eliminate_player(players, eliminated_id, jury, merged)
      else
        {players, jury}
      end

    # Build events
    vote_events = [Events.vote_result(eliminated_id, vote_tally)]

    elimination_events =
      if eliminated_id do
        [Events.player_eliminated(eliminated_id, "voted out at tribal council")]
      else
        []
      end

    # Update elimination log
    elimination_log = get(state.world, :elimination_log, [])
    vote_history = get(state.world, :vote_history, [])

    new_elimination_log =
      if eliminated_id do
        elimination_log ++ [%{player: eliminated_id, reason: "voted out", episode: episode}]
      else
        elimination_log
      end

    vote_history_entries =
      Enum.map(votes, fn {voter, target} ->
        %{
          episode: episode,
          voter: voter,
          target: target,
          target_eliminated: target == eliminated_id,
          merged: merged
        }
      end)

    # Check if it's time for final tribal council (3 players left)
    if eliminated_id && Tribes.at_final_tribal?(updated_players) do
      transition_to_final_tribal(
        state,
        updated_players,
        updated_jury,
        new_elimination_log,
        vote_history ++ vote_history_entries,
        vote_events ++ elimination_events
      )
    else
      # Check if we should merge
      should_merge = Tribes.should_merge?(updated_players, merged)

      if should_merge do
        {merge_players, merge_tribes} = Tribes.merge_tribes(updated_players)
        merge_name = Tribes.merge_tribe_name()

        next_state =
          state
          |> State.put_world(
            world_updates(state.world, %{
              players: merge_players,
              tribes: merge_tribes,
              merged: true,
              merge_tribe_name: merge_name,
              jury: updated_jury,
              elimination_log: new_elimination_log,
              vote_history: vote_history ++ vote_history_entries,
              votes: %{},
              idol_played_by: nil,
              idol_phase_done: false,
              immune_player: nil,
              statements: [],
              whisper_log: [],
              whisper_graph: [],
              strategy_actions: %{}
            })
          )
          |> State.append_events(
            vote_events ++ elimination_events ++ [Events.tribes_merged(merge_name)]
          )

        # Start next episode with challenge
        transition_to_challenge(next_state)
      else
        # Next episode
        next_state =
          state
          |> State.put_world(
            world_updates(state.world, %{
              players: updated_players,
              jury: updated_jury,
              elimination_log: new_elimination_log,
              vote_history: vote_history ++ vote_history_entries,
              votes: %{},
              idol_played_by: nil,
              idol_phase_done: false,
              immune_player: nil,
              statements: [],
              whisper_log: [],
              whisper_graph: [],
              strategy_actions: %{}
            })
          )
          |> State.append_events(vote_events ++ elimination_events)

        transition_to_challenge(next_state)
      end
    end
  end

  # -- Jury vote resolution --

  defp resolve_jury_votes(%State{} = state) do
    jury_votes = get(state.world, :jury_votes, %{})

    vote_tally =
      jury_votes
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    {winner, _count} =
      vote_tally
      |> Enum.max_by(fn {_target, count} -> count end, fn -> {nil, 0} end)

    message = "The jury has spoken! #{winner} is the Sole Survivor!"

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          status: "game_over",
          winner: winner,
          phase: "game_over",
          active_actor_id: nil,
          turn_order: [],
          jury_votes: jury_votes
        })
      )
      |> State.append_events([
        Events.vote_result(winner, vote_tally),
        Events.game_over(winner, message)
      ])

    {:ok, next_state, :skip}
  end

  # -- Phase transitions --

  defp transition_to_challenge(%State{} = state) do
    players = get(state.world, :players, %{})
    episode = get(state.world, :episode, 1) + 1
    challenge_order = Tribes.challenge_turn_order(players)
    first_player = List.first(challenge_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "challenge",
          episode: episode,
          challenge_choices: %{},
          challenge_winner: nil,
          losing_tribe: nil,
          turn_order: challenge_order,
          active_actor_id: first_player
        })
      )
      |> State.append_event(Events.phase_changed("challenge", episode))

    {:ok, next_state, {:decide, "#{first_player} challenge choice"}}
  end

  defp transition_to_strategy(%State{} = state, losing_tribe, episode) do
    players = get(state.world, :players, %{})
    merged = get(state.world, :merged, false)
    strategy_order = Tribes.strategy_turn_order(players, losing_tribe, merged)
    first_player = List.first(strategy_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "strategy",
          statements: [],
          whisper_log: [],
          whisper_graph: [],
          strategy_actions: %{},
          turn_order: strategy_order,
          active_actor_id: first_player
        })
      )
      |> State.append_event(Events.phase_changed("strategy", episode))

    {:ok, next_state, {:decide, "#{first_player} strategy turn"}}
  end

  defp transition_to_tribal_council(%State{} = state) do
    players = get(state.world, :players, %{})
    merged = get(state.world, :merged, false)
    losing_tribe = get(state.world, :losing_tribe)
    episode = get(state.world, :episode, 1)

    tc_voters = Tribes.tribal_council_turn_order(players, losing_tribe, merged)

    # Idol phase: all TC participants get a chance to play idol
    idol_order = tc_voters
    first_player = List.first(idol_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          phase: "tribal_council",
          votes: %{},
          idol_played_by: nil,
          idol_phase_done: false,
          idol_turn_order: idol_order,
          tc_voters: tc_voters,
          turn_order: idol_order,
          active_actor_id: first_player
        })
      )
      |> State.append_event(Events.phase_changed("tribal_council", episode))

    {:ok, next_state, {:decide, "#{first_player} idol decision"}}
  end

  defp transition_to_final_tribal(
         %State{} = state,
         players,
         jury,
         elimination_log,
         vote_history,
         preceding_events
       ) do
    {jury_order, _finalist_order} = Tribes.final_tribal_council_order(players, jury)
    first_juror = List.first(jury_order)
    episode = get(state.world, :episode, 1)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          players: players,
          jury: jury,
          elimination_log: elimination_log,
          vote_history: vote_history,
          phase: "final_tribal_council",
          ftc_sub_phase: "jury_statements",
          jury_statements: [],
          jury_votes: %{},
          votes: %{},
          turn_order: jury_order,
          active_actor_id: first_juror
        })
      )
      |> State.append_events(
        preceding_events ++ [Events.phase_changed("final_tribal_council", episode)]
      )

    {:ok, next_state, {:decide, "#{first_juror} jury statement"}}
  end

  # -- Game-specific helpers --

  defp ensure_has_idol(players, player_id) do
    case Map.get(players, player_id) do
      nil ->
        {:error, :unknown_player}

      player ->
        if get(player, :has_idol, false), do: :ok, else: {:error, :no_idol}
    end
  end

  defp ensure_valid_strategy(strategy) do
    if strategy in ["physical", "puzzle", "endurance"],
      do: :ok,
      else: {:error, :invalid_strategy}
  end

  defp ensure_jury_member(world, player_id) do
    jury = get(world, :jury, [])
    if player_id in jury, do: :ok, else: {:error, :not_jury_member}
  end
end
