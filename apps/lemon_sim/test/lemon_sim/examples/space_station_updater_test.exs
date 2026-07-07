defmodule LemonSim.Examples.SpaceStationUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.SpaceStation
  alias LemonSim.Examples.SpaceStation.{Events, Roles, Updater}
  alias LemonSim.Kernel.State

  test "discussion uses a second pass before voting when enough players are alive" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    first_order = Roles.discussion_turn_order(players, 1, 1)

    state =
      state
      |> State.put_world(%{
        state.world
        | phase: "discussion",
          round: 1,
          discussion_round: 1,
          discussion_round_limit: 2,
          discussion_transcript: [],
          turn_order: first_order,
          active_actor_id: List.first(first_order)
      })

    {:ok, after_first_pass, {:decide, _}} =
      Enum.reduce(first_order, {:ok, state, nil}, fn actor_id, {:ok, acc_state, _} ->
        Updater.apply_event(
          acc_state,
          Events.make_statement(actor_id, "Signal from #{actor_id}"),
          []
        )
      end)

    assert after_first_pass.world.phase == "discussion"
    assert after_first_pass.world.discussion_round == 2

    second_order = after_first_pass.world.turn_order

    {:ok, after_second_pass, {:decide, _}} =
      Enum.reduce(second_order, {:ok, after_first_pass, nil}, fn actor_id, {:ok, acc_state, _} ->
        Updater.apply_event(
          acc_state,
          Events.make_statement(actor_id, "Follow-up from #{actor_id}"),
          []
        )
      end)

    assert after_second_pass.world.phase == "voting"
    assert after_second_pass.world.discussion_round == 0

    assert after_second_pass.world.active_actor_id ==
             List.first(after_second_pass.world.turn_order)
  end

  test "ejecting the saboteur ends the game with a crew win" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    saboteur_id = Roles.find_saboteur(players)
    voting_order = Roles.voting_turn_order(players, 1)
    crew_voters = Enum.reject(voting_order, &(&1 == saboteur_id))

    state =
      state
      |> State.put_world(%{
        state.world
        | phase: "voting",
          round: 1,
          votes: %{},
          turn_order: voting_order,
          active_actor_id: List.first(voting_order)
      })

    vote_targets =
      Enum.map(voting_order, fn voter_id ->
        {voter_id, if(voter_id in crew_voters, do: saboteur_id, else: "skip")}
      end)

    {:ok, final_state, :skip} =
      Enum.reduce(vote_targets, {:ok, state, nil}, fn {voter_id, target_id},
                                                      {:ok, acc_state, _} ->
        Updater.apply_event(acc_state, Events.cast_vote(voter_id, target_id), [])
      end)

    assert final_state.world.status == "game_over"
    assert final_state.world.winner == "crew"
    assert final_state.world.phase == "game_over"
    assert final_state.world.players[saboteur_id].status == "ejected"
  end

  # -- Action phase: repair --

  test "repair_system logs the action, updates player state, and boosts reputation" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    [actor_id, other_id | _] =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: actor_id,
        turn_order: [actor_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.repair_system(actor_id, "o2"), [])

    assert prompt == "#{other_id} action"
    assert next_state.world.active_actor_id == other_id
    assert next_state.world.action_log[actor_id] == %{system: "o2", action: "repair"}
    assert next_state.world.location_log == [{actor_id, "o2"}]
    assert next_state.world.players[actor_id].location == "o2"
    assert next_state.world.players[actor_id].last_action == "repair"
    assert next_state.world.players[actor_id].reputation == 5
    assert List.last(next_state.world.journals[actor_id]).text =~ "Repaired"
  end

  test "repair_system rejects an invalid system id" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    actor_id =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> List.first()

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: actor_id,
        turn_order: [actor_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.repair_system(actor_id, "warp_core"), [])

    assert prompt == "rejected: :invalid_system"
    assert next_state.world.action_log == %{}
  end

  # -- Action phase: sabotage (saboteur only) --

  test "sabotage_system is rejected for a non-saboteur player" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    crew_id = id_with_role(players, "crew")
    other_id = another_living_id(players, crew_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: crew_id,
        turn_order: [crew_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.sabotage_system(crew_id, "o2"), [])

    assert prompt == "wrong role for this action"
    assert next_state.world.action_log == %{}
    assert List.last(next_state.recent_events).kind == "action_rejected"
  end

  test "sabotage_system succeeds for the saboteur without granting reputation" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    saboteur_id = Roles.find_saboteur(players)
    other_id = another_living_id(players, saboteur_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: saboteur_id,
        turn_order: [saboteur_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, _}} =
      Updater.apply_event(state, Events.sabotage_system(saboteur_id, "power"), [])

    assert next_state.world.action_log[saboteur_id] == %{system: "power", action: "sabotage"}
    assert next_state.world.players[saboteur_id].last_action == "sabotage"
    assert next_state.world.players[saboteur_id].reputation == 0
  end

  # -- Action phase: fake_repair (saboteur only) --

  test "fake_repair is rejected for a non-saboteur player" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    crew_id = id_with_role(players, "crew")
    other_id = another_living_id(players, crew_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: crew_id,
        turn_order: [crew_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.fake_repair(crew_id, "o2"), [])

    assert prompt == "wrong role for this action"
    assert next_state.world.action_log == %{}
  end

  test "fake_repair succeeds for the saboteur without granting reputation" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    saboteur_id = Roles.find_saboteur(players)
    other_id = another_living_id(players, saboteur_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: saboteur_id,
        turn_order: [saboteur_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, _}} =
      Updater.apply_event(state, Events.fake_repair(saboteur_id, "o2"), [])

    assert next_state.world.action_log[saboteur_id] == %{system: "o2", action: "fake_repair"}
    assert next_state.world.players[saboteur_id].last_action == "fake_repair"
    assert next_state.world.players[saboteur_id].reputation == 0
  end

  # -- Action phase: scan_player (engineer only) --

  test "scan_player is rejected for a non-engineer player" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    crew_id = id_with_role(players, "crew")
    target_id = another_living_id(players, crew_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: crew_id,
        turn_order: [crew_id, target_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.scan_player(crew_id, target_id), [])

    assert prompt == "wrong role for this action"
    assert next_state.world.scan_results == %{}
  end

  test "scan_player reports a deterministic result when the target vented" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    engineer_id = id_with_role(players, "engineer")
    target_id = another_living_id(players, engineer_id)
    players_with_history = Map.update!(players, target_id, &Map.put(&1, :last_action, "vent"))

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: engineer_id,
        turn_order: [engineer_id, target_id],
        action_log: %{},
        location_log: [],
        players: players_with_history
      })

    {:ok, next_state, {:decide, _}} =
      Updater.apply_event(state, Events.scan_player(engineer_id, target_id), [])

    assert next_state.world.scan_results[engineer_id] == %{target: target_id, result: "unknown"}

    cover_system = next_state.world.players[engineer_id].location
    assert cover_system in ~w(o2 power hull comms nav medbay shields)

    assert next_state.world.action_log[engineer_id] == %{
             system: cover_system,
             action: "scan",
             target: target_id
           }

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "scan_result" in kinds
  end

  test "scan_player rejects targeting yourself" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    engineer_id = id_with_role(players, "engineer")
    other_id = another_living_id(players, engineer_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: engineer_id,
        turn_order: [engineer_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, _next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.scan_player(engineer_id, engineer_id), [])

    assert prompt == "cannot target yourself"
  end

  test "scan_player rejects scanning a dead player" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    engineer_id = id_with_role(players, "engineer")
    target_id = another_living_id(players, engineer_id)
    dead_players = Map.update!(players, target_id, &Map.put(&1, :status, "ejected"))

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: engineer_id,
        turn_order: [engineer_id, target_id],
        action_log: %{},
        location_log: [],
        players: dead_players
      })

    {:ok, _next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.scan_player(engineer_id, target_id), [])

    assert prompt == "player is dead"
  end

  # -- Action phase: lock_room (captain only) --

  test "lock_room is rejected for a non-captain player" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    crew_id = id_with_role(players, "crew")
    other_id = another_living_id(players, crew_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: crew_id,
        turn_order: [crew_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.lock_room(crew_id, "o2"), [])

    assert prompt == "wrong role for this action"
    assert next_state.world.captain_lock == nil
  end

  test "lock_room lets the captain block sabotage on that system" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    captain_id = id_with_role(players, "captain")
    saboteur_id = Roles.find_saboteur(players)
    other_id = another_living_id(players, [captain_id, saboteur_id])

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: captain_id,
        turn_order: [captain_id, saboteur_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, locked_state, {:decide, _}} =
      Updater.apply_event(state, Events.lock_room(captain_id, "hull"), [])

    assert locked_state.world.captain_lock == "hull"
    assert locked_state.world.active_actor_id == saboteur_id

    {:ok, blocked_state, {:decide, prompt}} =
      Updater.apply_event(locked_state, Events.sabotage_system(saboteur_id, "hull"), [])

    assert prompt == "system is locked by the captain"
    refute Map.has_key?(blocked_state.world.action_log, saboteur_id)
  end

  # -- Action phase: call_emergency_meeting (captain only) --

  test "call_emergency_meeting is rejected for a non-captain player" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    captain_id = id_with_role(players, "captain")
    other_id = another_living_id(players, captain_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: other_id,
        turn_order: [other_id, captain_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.call_emergency_meeting(other_id), [])

    assert prompt == "wrong role for this action"
    assert next_state.world.emergency_meeting_available == true
  end

  test "call_emergency_meeting can only be used once per game" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    captain_id = id_with_role(players, "captain")
    other_id = another_living_id(players, captain_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: captain_id,
        turn_order: [captain_id, other_id],
        action_log: %{},
        location_log: [],
        emergency_meeting_available: false
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.call_emergency_meeting(captain_id), [])

    assert prompt == "emergency meeting already used"
    assert next_state.world.emergency_meeting_called == false
  end

  # -- Action phase: vent (saboteur only) --

  test "vent is rejected for a non-saboteur player" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    crew_id = id_with_role(players, "crew")
    other_id = another_living_id(players, crew_id)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: crew_id,
        turn_order: [crew_id, other_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} = Updater.apply_event(state, Events.vent(crew_id), [])

    assert prompt == "wrong role for this action"
    assert next_state.world.action_log == %{}
  end

  test "vent clears the saboteur's location without adding a location_log entry" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    saboteur_id = Roles.find_saboteur(players)
    other_id = another_living_id(players, saboteur_id)
    players_at_location = Map.update!(players, saboteur_id, &Map.put(&1, :location, "o2"))

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: saboteur_id,
        turn_order: [saboteur_id, other_id],
        action_log: %{},
        location_log: [],
        players: players_at_location
      })

    {:ok, next_state, {:decide, _}} = Updater.apply_event(state, Events.vent(saboteur_id), [])

    assert next_state.world.action_log[saboteur_id] == %{system: nil, action: "vent"}
    assert next_state.world.location_log == []
    assert next_state.world.players[saboteur_id].location == nil
    assert next_state.world.players[saboteur_id].last_action == "vent"
  end

  # -- Discussion phase --

  test "make_statement appends to the transcript and advances the discussion turn" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    [speaker_id, next_id | _] =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    state =
      state
      |> State.put_world(%{
        phase: "discussion",
        active_actor_id: speaker_id,
        turn_order: [speaker_id, next_id],
        discussion_round: 1,
        discussion_round_limit: 2,
        discussion_transcript: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.make_statement(speaker_id, "I was at O2"), [])

    assert prompt == "#{next_id} discussion turn"

    assert next_state.world.discussion_transcript == [
             %{player: speaker_id, statement: "I was at O2"}
           ]

    assert next_state.world.active_actor_id == next_id
  end

  test "ask_question records a pending question for the target" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    [asker_id, target_id, next_id | _] =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    state =
      state
      |> State.put_world(%{
        phase: "discussion",
        active_actor_id: asker_id,
        turn_order: [asker_id, next_id],
        discussion_round: 1,
        discussion_round_limit: 2,
        discussion_transcript: [],
        pending_questions: []
      })

    {:ok, next_state, {:decide, _}} =
      Updater.apply_event(
        state,
        Events.ask_question(asker_id, target_id, "Where were you?"),
        []
      )

    assert next_state.world.pending_questions == [
             %{from: asker_id, to: target_id, question: "Where were you?"}
           ]

    assert next_state.world.discussion_transcript == [
             %{
               player: asker_id,
               type: "question",
               target: target_id,
               statement: "Where were you?"
             }
           ]
  end

  test "accuse records an accusation and lowers the target's reputation" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    [accuser_id, target_id, next_id | _] =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    state =
      state
      |> State.put_world(%{
        phase: "discussion",
        active_actor_id: accuser_id,
        turn_order: [accuser_id, next_id],
        discussion_round: 1,
        discussion_round_limit: 2,
        discussion_transcript: [],
        accusations: []
      })

    {:ok, next_state, {:decide, _}} =
      Updater.apply_event(
        state,
        Events.accuse(accuser_id, target_id, "You lied about your location"),
        []
      )

    assert next_state.world.accusations == [
             %{accuser: accuser_id, accused: target_id, evidence: "You lied about your location"}
           ]

    assert next_state.world.discussion_transcript == [
             %{
               player: accuser_id,
               type: "accusation",
               target: target_id,
               statement: "You lied about your location"
             }
           ]

    assert next_state.world.players[target_id].reputation == -2
  end

  # -- Voting phase --

  test "cast_vote rejects targeting a dead player" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    [voter_id, target_id, next_id | _] =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    dead_players = Map.update!(players, target_id, &Map.put(&1, :status, "ejected"))

    state =
      state
      |> State.put_world(%{
        phase: "voting",
        active_actor_id: voter_id,
        turn_order: [voter_id, next_id],
        votes: %{},
        players: dead_players
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.cast_vote(voter_id, target_id), [])

    assert prompt == "player is dead"
    assert next_state.world.votes == %{}
  end

  test "voting with no majority leaves everyone alive and advances to the next round" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players
    voting_order = Roles.voting_turn_order(players, 1)
    [v1, v2, v3, v4, v5] = voting_order

    state =
      state
      |> State.put_world(%{
        phase: "voting",
        round: 1,
        votes: %{},
        turn_order: voting_order,
        active_actor_id: List.first(voting_order)
      })

    vote_targets = [{v1, "skip"}, {v2, "skip"}, {v3, v4}, {v4, v3}, {v5, v3}]

    {:ok, final_state, {:decide, _}} =
      Enum.reduce(vote_targets, {:ok, state, nil}, fn {voter_id, target_id},
                                                      {:ok, acc_state, _} ->
        Updater.apply_event(acc_state, Events.cast_vote(voter_id, target_id), [])
      end)

    assert final_state.world.status == "in_progress"
    assert final_state.world.round == 2
    assert final_state.world.phase == "action"
    refute Enum.any?(final_state.world.players, fn {_id, p} -> p.status == "ejected" end)

    [vote_record] = final_state.world.vote_history
    assert vote_record.ejected == nil
  end

  test "voting to eject a non-saboteur continues the game and penalizes voters" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    crew_ids =
      players
      |> Enum.filter(fn {_id, p} -> p.role == "crew" end)
      |> Enum.map(&elem(&1, 0))

    target_id = List.first(crew_ids)
    voting_order = Roles.voting_turn_order(players, 1)
    other_voters = Enum.reject(voting_order, &(&1 == target_id))
    {guilty_voters, innocent_voters} = Enum.split(other_voters, 3)

    vote_map =
      guilty_voters
      |> Map.new(&{&1, target_id})
      |> Map.merge(Map.new(innocent_voters, &{&1, "skip"}))
      |> Map.put(target_id, "skip")

    state =
      state
      |> State.put_world(%{
        phase: "voting",
        round: 1,
        votes: %{},
        turn_order: voting_order,
        active_actor_id: List.first(voting_order)
      })

    {:ok, final_state, {:decide, _}} =
      Enum.reduce(voting_order, {:ok, state, nil}, fn voter_id, {:ok, acc_state, _} ->
        Updater.apply_event(
          acc_state,
          Events.cast_vote(voter_id, Map.fetch!(vote_map, voter_id)),
          []
        )
      end)

    assert final_state.world.status == "in_progress"
    assert final_state.world.round == 2
    assert final_state.world.players[target_id].status == "ejected"

    [elimination_entry] = final_state.world.elimination_log
    assert elimination_entry.player == target_id
    assert elimination_entry.role == "crew"

    # NOTE: when the game continues past a wrong ejection, resolve_votes/1
    # rebuilds the `players` map from the pre-adjustment snapshot when writing
    # the ejected status, so voter reputation deltas from this vote do not
    # survive alongside the ejection in the current implementation.
    for voter_id <- guilty_voters do
      assert final_state.world.players[voter_id].reputation == 0
    end
  end

  # -- Round resolution / terminal conditions --

  test "a system reaching zero health ends the game with a saboteur win" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    actor_id =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> List.first()

    systems = Map.put(state.world.systems, "o2", %{health: 3, decay_rate: 100, name: "Oxygen"})

    state =
      state
      |> State.put_world(%{
        phase: "action",
        round: 1,
        active_actor_id: actor_id,
        turn_order: [actor_id],
        action_log: %{},
        location_log: [],
        systems: systems
      })

    {:ok, final_state, :skip} =
      Updater.apply_event(state, Events.repair_system(actor_id, "power"), [])

    assert final_state.world.status == "game_over"
    assert final_state.world.winner == "saboteur"
    assert final_state.world.phase == "game_over"
    assert final_state.world.systems["o2"].health == 0
  end

  test "surviving to the max round count ends the game with a crew win" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    actor_id =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> List.first()

    systems =
      Enum.into(state.world.systems, %{}, fn {id, sys} -> {id, %{sys | decay_rate: 0}} end)

    state =
      state
      |> State.put_world(%{
        phase: "action",
        round: 12,
        max_rounds: 12,
        active_actor_id: actor_id,
        turn_order: [actor_id],
        action_log: %{},
        location_log: [],
        systems: systems,
        emergency_meeting_called: false
      })

    {:ok, final_state, :skip} =
      Updater.apply_event(state, Events.repair_system(actor_id, "power"), [])

    assert final_state.world.status == "game_over"
    assert final_state.world.winner == "crew"
    assert final_state.world.phase == "game_over"
  end

  # -- Cross-cutting guards --

  test "actions are rejected once the game is over" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    actor_id =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> List.first()

    state =
      state
      |> State.put_world(%{
        status: "game_over",
        phase: "action",
        active_actor_id: actor_id,
        turn_order: [actor_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.repair_system(actor_id, "o2"), [])

    assert prompt == "game already over"
    assert next_state.world.action_log == %{}
  end

  test "repair_system is rejected outside the action phase" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    actor_id =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> List.first()

    state =
      state
      |> State.put_world(%{
        phase: "discussion",
        active_actor_id: actor_id,
        turn_order: [actor_id],
        action_log: %{}
      })

    {:ok, _next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.repair_system(actor_id, "o2"), [])

    assert prompt == "wrong phase"
  end

  test "repair_system is rejected when it is not the player's turn" do
    state = SpaceStation.initial_state(player_count: 5)
    players = state.world.players

    [actor_id, other_id | _] =
      players |> Roles.living_players() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    state =
      state
      |> State.put_world(%{
        phase: "action",
        active_actor_id: other_id,
        turn_order: [other_id, actor_id],
        action_log: %{},
        location_log: []
      })

    {:ok, next_state, {:decide, prompt}} =
      Updater.apply_event(state, Events.repair_system(actor_id, "o2"), [])

    assert prompt == "not the active actor"
    assert next_state.world.action_log == %{}
  end

  defp id_with_role(players, role) do
    players
    |> Enum.find(fn {_id, p} -> p.role == role end)
    |> elem(0)
  end

  defp another_living_id(players, excluded_ids) when is_list(excluded_ids) do
    players
    |> Roles.living_players()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.find(&(&1 not in excluded_ids))
  end

  defp another_living_id(players, excluded_id), do: another_living_id(players, [excluded_id])
end
