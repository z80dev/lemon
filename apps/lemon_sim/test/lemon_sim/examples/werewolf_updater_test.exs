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

  test "night resolution does not crash when a seer investigation target is present" do
    players = sample_players()

    state =
      State.new(
        sim_id: "werewolf-night-test",
        world: %{
          players: players,
          phase: "night",
          day_number: 1,
          active_actor_id: "Esme",
          turn_order: ["Esme"],
          night_actions: %{
            "Dane" => %{action: "investigate", target: "Cora"}
          },
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
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

    assert {:ok, next_state, prompt} =
             Updater.apply_event(state, Events.sleep("Esme"), [])

    assert next_state.world.night_actions == %{}
    assert match?({:decide, _}, prompt) or prompt == :skip
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
