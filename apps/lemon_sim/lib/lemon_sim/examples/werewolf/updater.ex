defmodule LemonSim.Examples.Werewolf.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers

  alias LemonSim.State
  alias LemonSim.Examples.Werewolf.{Events, Roles}

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "choose_victim" -> apply_choose_victim(state, event)
      "investigate_player" -> apply_investigate_player(state, event)
      "protect_player" -> apply_protect_player(state, event)
      "sleep" -> apply_sleep(state, event)
      "make_statement" -> apply_make_statement(state, event)
      "cast_vote" -> apply_cast_vote(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
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

  # -- Day: Make statement --

  defp apply_make_statement(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    statement = fetch(event.payload, :statement, "statement")
    players = get(state.world, :players, %{})

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "day_discussion"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_living(players, player_id) do
      transcript = get(state.world, :discussion_transcript, [])
      new_entry = %{player: player_id, statement: statement}
      new_transcript = transcript ++ [new_entry]

      next_state =
        state
        |> State.put_world(world_updates(state.world, %{discussion_transcript: new_transcript}))
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
         :ok <- ensure_phase(state.world, "day_voting"),
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
          transition_to_voting(state)
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

    # Apply the kill if not saved
    updated_players =
      if not is_nil(victim_id) and not saved? do
        victim = Map.get(players, victim_id, %{})
        Map.put(players, victim_id, Map.put(victim, :status, "dead"))
      else
        players
      end

    # Build events
    resolution_events = [Events.night_resolved(victim_id, protected_id, saved?)]

    elimination_events =
      if not is_nil(victim_id) and not saved? do
        victim_role = get(Map.get(players, victim_id, %{}), :role, "unknown")
        [Events.player_eliminated(victim_id, victim_role, "killed by werewolves")]
      else
        []
      end

    # Update elimination log
    elimination_log = get(state.world, :elimination_log, [])

    new_elimination_log =
      if not is_nil(victim_id) and not saved? do
        victim_role = get(Map.get(players, victim_id, %{}), :role, "unknown")

        elimination_log ++
          [
            %{
              player: victim_id,
              role: victim_role,
              reason: "killed",
              day: get(state.world, :day_number, 1)
            }
          ]
      else
        elimination_log
      end

    # Check win conditions
    {status, winner, game_over_events} = check_win_conditions(updated_players)
    night_history = get(state.world, :night_history, [])

    new_night_history =
      night_history ++
        build_night_history(day_number, players, night_actions, victim_id, protected_id, saved?)

    if status == "game_over" do
      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            players: updated_players,
            night_actions: %{},
            night_history: new_night_history,
            elimination_log: new_elimination_log,
            status: "game_over",
            winner: winner,
            phase: "game_over",
            active_actor_id: nil,
            turn_order: [],
            discussion_round: 0,
            discussion_round_limit: 0
          })
        )
        |> State.append_events(resolution_events ++ elimination_events ++ game_over_events)

      {:ok, next_state, :skip}
    else
      # Transition to day discussion
      discussion_round_limit = Roles.discussion_round_limit(updated_players)
      discussion_order = Roles.discussion_turn_order(updated_players, day_number, 1)
      first_speaker = List.first(discussion_order)

      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            players: updated_players,
            night_actions: %{},
            phase: "day_discussion",
            discussion_transcript: [],
            discussion_round: 1,
            discussion_round_limit: discussion_round_limit,
            votes: %{},
            turn_order: discussion_order,
            active_actor_id: first_speaker,
            elimination_log: new_elimination_log,
            night_history: new_night_history
          })
        )
        |> State.append_events(
          resolution_events ++
            elimination_events ++
            [Events.phase_changed("day_discussion", day_number)]
        )

      {:ok, next_state, {:decide, "#{first_speaker} discussion turn"}}
    end
  end

  # -- Vote resolution --

  defp resolve_votes(%State{} = state) do
    votes = get(state.world, :votes, %{})
    players = get(state.world, :players, %{})
    day_number = get(state.world, :day_number, 1)

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

    # Apply elimination
    updated_players =
      if not is_nil(eliminated_id) do
        victim = Map.get(players, eliminated_id, %{})
        Map.put(players, eliminated_id, Map.put(victim, :status, "dead"))
      else
        players
      end

    # Build events
    vote_events = [Events.vote_result(eliminated_id, vote_tally)]

    elimination_events =
      if not is_nil(eliminated_id) do
        victim_role = get(Map.get(players, eliminated_id, %{}), :role, "unknown")
        [Events.player_eliminated(eliminated_id, victim_role, "voted out by the village")]
      else
        []
      end

    # Update elimination log
    elimination_log = get(state.world, :elimination_log, [])

    new_elimination_log =
      if not is_nil(eliminated_id) do
        victim_role = get(Map.get(players, eliminated_id, %{}), :role, "unknown")

        elimination_log ++
          [
            %{
              player: eliminated_id,
              role: victim_role,
              reason: "voted",
              day: get(state.world, :day_number, 1)
            }
          ]
      else
        elimination_log
      end

    # Check win conditions
    {status, winner, game_over_events} = check_win_conditions(updated_players)
    vote_history = get(state.world, :vote_history, [])
    new_vote_history = vote_history ++ build_vote_history(day_number, players, votes)

    if status == "game_over" do
      next_state =
        state
        |> State.put_world(
          world_updates(state.world, %{
            players: updated_players,
            votes: %{},
            vote_history: new_vote_history,
            elimination_log: new_elimination_log,
            status: "game_over",
            winner: winner,
            phase: "game_over",
            active_actor_id: nil,
            turn_order: [],
            discussion_round: 0,
            discussion_round_limit: 0
          })
        )
        |> State.append_events(vote_events ++ elimination_events ++ game_over_events)

      {:ok, next_state, :skip}
    else
      # Transition to next night
      transition_to_night(
        state,
        updated_players,
        new_elimination_log,
        vote_events ++ elimination_events,
        new_vote_history
      )
    end
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
    day_number = get(state.world, :day_number, 1) + 1
    night_order = Roles.night_turn_order(players)
    first_actor = List.first(night_order)

    next_state =
      state
      |> State.put_world(
        world_updates(state.world, %{
          players: players,
          phase: "night",
          day_number: day_number,
          night_actions: %{},
          discussion_transcript: [],
          votes: %{},
          vote_history: vote_history,
          turn_order: night_order,
          active_actor_id: first_actor,
          elimination_log: elimination_log,
          discussion_round: 0,
          discussion_round_limit: 0
        })
      )
      |> State.append_events(preceding_events ++ [Events.phase_changed("night", day_number)])

    {:ok, next_state, {:decide, "#{first_actor} night action"}}
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
end
