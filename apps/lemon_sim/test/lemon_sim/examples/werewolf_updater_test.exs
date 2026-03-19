defmodule LemonSim.Examples.WerewolfUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.{Events, Roles, Updater}
  alias LemonSim.State

  test "day discussion advances to a second round before voting when enough players are alive" do
    players = sample_players()
    first_round = Roles.discussion_turn_order(players, 1, 1)
    second_round = Roles.discussion_turn_order(players, 1, 2)
    last_speaker = List.last(first_round)

    state =
      State.new(
        sim_id: "werewolf-test",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: last_speaker,
          turn_order: first_round,
          discussion_round: 1,
          discussion_round_limit: 2,
          night_actions: %{},
          night_history: [],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    expected_prompt = "#{hd(second_round)} discussion round 2"

    assert {:ok, next_state, {:decide, ^expected_prompt}} =
             Updater.apply_event(
               state,
               Events.make_statement(last_speaker, "Round one wrap-up."),
               []
             )

    assert next_state.world.phase == "day_discussion"
    assert next_state.world.discussion_round == 2
    assert next_state.world.turn_order == second_round
    assert next_state.world.active_actor_id == hd(second_round)
    assert List.last(next_state.world.discussion_transcript).statement == "Round one wrap-up."
  end

  test "day discussion transitions to voting after the final discussion round" do
    players = sample_players()
    second_round = Roles.discussion_turn_order(players, 1, 2)
    last_speaker = List.last(second_round)
    voting_order = Roles.voting_turn_order(players, 1)

    state =
      State.new(
        sim_id: "werewolf-test",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: last_speaker,
          turn_order: second_round,
          discussion_round: 2,
          discussion_round_limit: 2,
          night_actions: %{},
          night_history: [],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    expected_prompt = "#{hd(voting_order)} vote"

    assert {:ok, next_state, {:decide, ^expected_prompt}} =
             Updater.apply_event(state, Events.make_statement(last_speaker, "Time to vote."), [])

    assert next_state.world.phase == "day_voting"
    assert next_state.world.discussion_round == 0
    assert next_state.world.discussion_round_limit == 0
    assert next_state.world.turn_order == voting_order
    assert next_state.world.active_actor_id == hd(voting_order)
  end

  test "discussion hard cap forces voting even if an accusation extends turn order" do
    players = sample_players()
    discussion_order = Roles.discussion_turn_order(players, 1, 1)
    voting_order = Roles.voting_turn_order(players, 1)

    state =
      State.new(
        sim_id: "werewolf-hard-cap",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: hd(discussion_order),
          turn_order: discussion_order,
          discussion_round: 1,
          discussion_round_limit: 2,
          discussion_turn_count: 0,
          discussion_turn_limit: 1,
          night_actions: %{},
          night_history: [],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    expected_prompt = "#{hd(voting_order)} vote"

    assert {:ok, next_state, {:decide, ^expected_prompt}} =
             Updater.apply_event(
               state,
               Events.make_accusation(hd(discussion_order), "Bram", "Answer this directly."),
               []
             )

    assert next_state.world.phase == "day_voting"
    assert next_state.world.discussion_turn_count == 0
    assert next_state.world.discussion_turn_limit == 0
    assert next_state.world.turn_order == voting_order
    assert next_state.world.active_actor_id == hd(voting_order)
  end

  test "accusation pulls a future speaker forward once and then discussion keeps moving" do
    players = sample_players()
    discussion_order = Roles.discussion_turn_order(players, 1, 1)

    state =
      State.new(
        sim_id: "werewolf-accusation-order",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: "Alice",
          turn_order: discussion_order,
          discussion_round: 1,
          discussion_round_limit: 1,
          discussion_turn_count: 0,
          discussion_turn_limit: length(discussion_order),
          night_actions: %{},
          night_history: [],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, after_accusation, {:decide, "Dane discussion turn"}} =
             Updater.apply_event(
               state,
               Events.make_accusation("Alice", "Dane", "Answer this directly."),
               []
             )

    assert after_accusation.world.turn_order == ["Alice", "Dane", "Bram", "Cora", "Esme"]
    assert after_accusation.world.active_actor_id == "Dane"

    assert {:ok, after_response, {:decide, "Bram discussion turn"}} =
             Updater.apply_event(
               after_accusation,
               Events.make_statement("Dane", "Here's my defense."),
               []
             )

    assert after_response.world.active_actor_id == "Bram"
    assert after_response.world.turn_order == ["Alice", "Dane", "Bram", "Cora", "Esme"]
  end

  test "counter-accusation does not bounce discussion back to an earlier speaker" do
    players = sample_players()

    state =
      State.new(
        sim_id: "werewolf-counter-accusation",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: "Dane",
          turn_order: ["Alice", "Dane", "Bram", "Cora", "Esme"],
          discussion_round: 1,
          discussion_round_limit: 1,
          discussion_turn_count: 1,
          discussion_turn_limit: 5,
          night_actions: %{},
          night_history: [],
          discussion_transcript: [
            %{
              player: "Alice",
              statement: "Answer this directly.",
              type: "accusation",
              target: "Dane"
            }
          ],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, "Bram discussion turn"}} =
             Updater.apply_event(
               state,
               Events.make_accusation("Dane", "Alice", "You're deflecting."),
               []
             )

    assert next_state.world.active_actor_id == "Bram"
    assert next_state.world.turn_order == ["Alice", "Dane", "Bram", "Cora", "Esme"]
  end

  test "seer investigation is rejected on night 1" do
    state =
      State.new(
        sim_id: "werewolf-seer-night-1-reject",
        world: %{
          players: %{
            "Cora" => %{role: "seer", status: "alive"},
            "Nora" => %{role: "werewolf", status: "alive"},
            "Dane" => %{role: "doctor", status: "alive"}
          },
          phase: "night",
          day_number: 1,
          active_actor_id: "Cora",
          turn_order: ["Cora", "Dane", "Nora"],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          night_actions: %{},
          night_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, "rejected: :investigation_not_ready"}} =
             Updater.apply_event(state, Events.investigate_player("Cora", "Nora"), [])

    assert next_state.world.phase == "night"
    assert next_state.world.night_actions == %{}

    assert List.last(next_state.recent_events).kind == "action_rejected"

    assert List.last(next_state.recent_events).payload["reason"] ==
             "rejected: :investigation_not_ready"
  end

  test "night resolution handles seer targets without crashing evidence generation" do
    players = %{
      "Nora" => %{role: "werewolf", status: "alive"},
      "Cora" => %{role: "seer", status: "alive"},
      "Dane" => %{role: "doctor", status: "alive"},
      "Iris" => %{role: "villager", status: "alive"},
      "Lena" => %{role: "villager", status: "alive"}
    }

    state =
      State.new(
        sim_id: "werewolf-night-resolution",
        world: %{
          players: players,
          phase: "night",
          day_number: 2,
          active_actor_id: "Lena",
          turn_order: ["Nora", "Cora", "Dane", "Iris", "Lena"],
          night_actions: %{
            "Nora" => %{action: "choose_victim", target: "Cora"},
            "Cora" => %{action: "investigate", target: "Nora", result: "werewolf"},
            "Dane" => %{action: "protect", target: "Cora"},
            "Iris" => %{action: "wander"}
          },
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [%{target: "Nora", role: "werewolf"}],
          night_history: [],
          evidence_tokens: [],
          wanderer_results: [],
          village_event_history: [],
          current_village_event: nil,
          player_items: %{},
          meeting_requests: %{},
          meeting_pairs: [],
          meeting_transcripts: [],
          current_meeting_index: 0,
          current_meeting_messages: [],
          discussion_round: 0,
          discussion_round_limit: 0,
          past_transcripts: %{},
          past_votes: %{},
          pending_elimination: nil,
          last_words: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, "Cora meeting selection"}} =
             Updater.apply_event(state, Events.sleep("Lena"), [])

    assert next_state.world.phase == "meeting_selection"
    assert next_state.world.active_actor_id == "Cora"
    assert next_state.world.night_actions == %{}
  end

  test "seer killed at night does not receive last words" do
    players = %{
      "Alice" => %{role: "werewolf", status: "alive"},
      "Bram" => %{role: "seer", status: "alive"},
      "Cora" => %{role: "doctor", status: "alive"},
      "Dane" => %{role: "villager", status: "alive"},
      "Esme" => %{role: "villager", status: "alive"}
    }

    state =
      State.new(
        sim_id: "werewolf-seer-no-last-words",
        world: %{
          players: players,
          phase: "night",
          day_number: 2,
          active_actor_id: "Esme",
          turn_order: ["Alice", "Bram", "Cora", "Dane", "Esme"],
          night_actions: %{
            "Alice" => %{action: "choose_victim", target: "Bram"},
            "Bram" => %{action: "investigate", target: "Alice", result: "werewolf"},
            "Cora" => %{action: "protect", target: "Cora"},
            "Dane" => %{action: "sleep"}
          },
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [%{target: "Alice", role: "werewolf"}],
          night_history: [],
          evidence_tokens: [],
          wanderer_results: [],
          village_event_history: [],
          current_village_event: nil,
          player_items: %{},
          meeting_requests: %{},
          meeting_pairs: [],
          meeting_transcripts: [],
          current_meeting_index: 0,
          current_meeting_messages: [],
          discussion_round: 0,
          discussion_round_limit: 0,
          past_transcripts: %{},
          past_votes: %{},
          pending_elimination: nil,
          last_words: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, "Alice meeting selection"}} =
             Updater.apply_event(state, Events.sleep("Esme"), [])

    assert next_state.world.phase == "meeting_selection"
    assert next_state.world.pending_elimination == nil
    assert next_state.world.players["Bram"].status == "dead"
    assert next_state.world.last_words == []
  end

  defp sample_players do
    %{
      "Alice" => %{role: "villager", status: "alive"},
      "Bram" => %{role: "doctor", status: "alive"},
      "Cora" => %{role: "werewolf", status: "alive"},
      "Dane" => %{role: "seer", status: "alive"},
      "Esme" => %{role: "villager", status: "alive"}
    }
  end
end
