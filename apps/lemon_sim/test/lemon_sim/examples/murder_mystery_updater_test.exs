defmodule LemonSim.Examples.MurderMysteryUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.MurderMystery.{Events, Updater}
  alias LemonSim.State

  defp base_world do
    %{
      rooms: %{
        "library" => %{name: "Library", clues_present: ["clue_lib_1", "clue_lib_2"], searched_by: []},
        "kitchen" => %{name: "Kitchen", clues_present: ["clue_kit_1"], searched_by: []}
      },
      players: %{
        "player_1" => %{
          role: "investigator",
          alibi: "was in the library",
          clues_found: [],
          accusations_remaining: 1,
          status: "alive"
        },
        "player_2" => %{
          role: "killer",
          alibi: "was in the kitchen",
          clues_found: [],
          accusations_remaining: 1,
          status: "alive"
        },
        "player_3" => %{
          role: "investigator",
          alibi: "was playing cards",
          clues_found: [],
          accusations_remaining: 1,
          status: "alive"
        }
      },
      evidence: %{
        "clue_lib_1" => %{clue_id: "clue_lib_1", clue_type: "fingerprint", room_id: "library", points_to: "player_2", is_false: false},
        "clue_lib_2" => %{clue_id: "clue_lib_2", clue_type: "footprint", room_id: "library", points_to: "player_1", is_false: false},
        "clue_kit_1" => %{clue_id: "clue_kit_1", clue_type: "weapon_trace", room_id: "kitchen", points_to: "player_2", is_false: false}
      },
      solution: %{killer_id: "player_2", weapon: "knife", room_id: "library"},
      turn_order: ["player_1", "player_2", "player_3"],
      interrogation_log: [],
      discussion_log: [],
      accusations: [],
      planted_evidence: [],
      destroyed_evidence: [],
      pending_question: nil,
      asked_this_round: MapSet.new(),
      searched_this_round: MapSet.new(),
      discussion_done: MapSet.new(),
      deduction_done: MapSet.new(),
      journals: %{},
      phase: "investigation",
      round: 1,
      max_rounds: 5,
      active_actor_id: "player_1",
      status: "in_progress",
      winner: nil
    }
  end

  test "search_room records clues found and advances to next player" do
    state = State.new(sim_id: "mm-test", world: base_world())

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(state, Events.search_room("player_1", "library"), [])

    player1 = next_state.world.players["player_1"]
    assert length(player1.clues_found) == 2
    assert "clue_lib_1" in player1.clues_found
    assert "clue_lib_2" in player1.clues_found

    room = next_state.world.rooms["library"]
    assert "player_1" in room.searched_by

    assert String.contains?(prompt, "clue")
  end

  test "search_room with wrong phase returns rejection" do
    world = Map.put(base_world(), :phase, "discussion")
    state = State.new(sim_id: "mm-test", world: world)

    assert {:ok, next_state, {:decide, reason}} =
             Updater.apply_event(state, Events.search_room("player_1", "library"), [])

    assert String.contains?(reason, "wrong phase")
  end

  test "ask_player records question in interrogation_log and switches active actor to target" do
    world =
      base_world()
      |> Map.put(:phase, "interrogation")
      |> Map.put(:active_actor_id, "player_1")

    state = State.new(sim_id: "mm-test", world: world)

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.ask_player("player_1", "player_2", "Where were you at midnight?"),
               []
             )

    assert length(next_state.world.interrogation_log) == 1
    log_entry = List.last(next_state.world.interrogation_log)
    assert Map.get(log_entry, "asker_id") == "player_1"
    assert Map.get(log_entry, "target_id") == "player_2"
    assert Map.get(log_entry, "question") == "Where were you at midnight?"
    assert Map.get(log_entry, "answer") == nil

    # Active actor should switch to the target
    assert next_state.world.active_actor_id == "player_2"
  end

  test "answer_question records answer in interrogation_log" do
    world =
      base_world()
      |> Map.put(:phase, "interrogation")
      |> Map.put(:active_actor_id, "player_2")
      |> Map.put(:interrogation_log, [
        %{"round" => 1, "asker_id" => "player_1", "target_id" => "player_2",
          "question" => "Where were you?", "answer" => nil}
      ])
      |> Map.put(:pending_question, %{
        "round" => 1, "asker_id" => "player_1", "target_id" => "player_2",
        "question" => "Where were you?", "answer" => nil
      })

    state = State.new(sim_id: "mm-test", world: world)

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.answer_question("player_2", "I was in the kitchen all evening."),
               []
             )

    log_entry = List.last(next_state.world.interrogation_log)
    assert Map.get(log_entry, "answer") == "I was in the kitchen all evening."
    assert next_state.world.pending_question == nil
  end

  test "make_accusation with correct solution ends game with investigators winning" do
    world =
      base_world()
      |> Map.put(:phase, "deduction_vote")
      |> Map.put(:active_actor_id, "player_1")

    state = State.new(sim_id: "mm-test", world: world)

    # Correct solution: killer=player_2, weapon=knife, room=library
    assert {:ok, next_state, :skip} =
             Updater.apply_event(
               state,
               Events.make_accusation("player_1", "player_2", "knife", "library"),
               []
             )

    assert next_state.world.status == "won"
    assert next_state.world.winner == "investigators"
    assert next_state.world.winning_player == "player_1"
  end

  test "make_accusation with wrong solution deducts accusation and advances" do
    world =
      base_world()
      |> Map.put(:phase, "deduction_vote")
      |> Map.put(:active_actor_id, "player_1")

    state = State.new(sim_id: "mm-test", world: world)

    # Wrong: player_3 is not the killer
    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.make_accusation("player_1", "player_3", "rope", "kitchen"),
               []
             )

    assert next_state.world.status == "in_progress"
    player1 = next_state.world.players["player_1"]
    assert player1.accusations_remaining == 0
    assert String.contains?(prompt, "wrong accusation")
  end

  test "killer can plant evidence during killer_action phase" do
    world =
      base_world()
      |> Map.put(:phase, "killer_action")
      |> Map.put(:active_actor_id, "player_2")

    state = State.new(sim_id: "mm-test", world: world)

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.plant_evidence("player_2", "kitchen", "fingerprint"),
               []
             )

    assert length(next_state.world.planted_evidence) == 1
    planted_id = List.first(next_state.world.planted_evidence)

    kitchen = next_state.world.rooms["kitchen"]
    assert planted_id in kitchen.clues_present

    planted_clue = next_state.world.evidence[planted_id]
    assert planted_clue.is_false == true
    assert planted_clue.room_id == "kitchen"

    assert String.contains?(prompt, "deduction")
  end

  test "killer can destroy a clue during killer_action phase" do
    world =
      base_world()
      |> Map.put(:phase, "killer_action")
      |> Map.put(:active_actor_id, "player_2")

    state = State.new(sim_id: "mm-test", world: world)

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(
               state,
               Events.destroy_clue("player_2", "library", "clue_lib_1"),
               []
             )

    assert "clue_lib_1" in next_state.world.destroyed_evidence
    library = next_state.world.rooms["library"]
    refute "clue_lib_1" in library.clues_present
    assert String.contains?(prompt, "deduction")
  end

  test "investigator cannot plant evidence" do
    world =
      base_world()
      |> Map.put(:phase, "killer_action")
      |> Map.put(:active_actor_id, "player_1")

    state = State.new(sim_id: "mm-test", world: world)

    assert {:ok, next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.plant_evidence("player_1", "kitchen", "footprint"),
               []
             )

    assert String.contains?(reason, "killer")
    assert next_state.world.planted_evidence == []
  end

  test "deduction vote phase advances round after all players voted" do
    world =
      base_world()
      |> Map.put(:phase, "deduction_vote")
      |> Map.put(:active_actor_id, "player_1")
      |> Map.put(:deduction_done, MapSet.new(["player_2", "player_3"]))

    state = State.new(sim_id: "mm-test", world: world)

    # player_1 skips - everyone has now voted, should advance round
    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(state, Events.skip_accusation("player_1"), [])

    assert next_state.world.round == 2
    assert next_state.world.phase == "investigation"
    assert String.contains?(prompt, "round 2")
  end

  test "killer wins when all rounds pass without correct accusation" do
    world =
      base_world()
      |> Map.put(:phase, "deduction_vote")
      |> Map.put(:round, 5)
      |> Map.put(:max_rounds, 5)
      |> Map.put(:active_actor_id, "player_1")
      |> Map.put(:deduction_done, MapSet.new(["player_2", "player_3"]))

    state = State.new(sim_id: "mm-test", world: world)

    # Last player skips in the final round
    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(state, Events.skip_accusation("player_1"), [])

    assert next_state.world.status == "won"
    assert next_state.world.winner == "killer"
    assert String.contains?(prompt, "killer")
  end
end
