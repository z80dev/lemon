defmodule LemonSim.Examples.SurvivorUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Survivor.{Events, Updater}
  alias LemonSim.State

  test "pre-merge challenge resolution rewards the tribe with the favorable strategy matchup" do
    state =
      State.new(
        sim_id: "survivor-test",
        world: %{
          players: %{
            "player_1" => %{status: "alive", tribe: "Tala"},
            "player_2" => %{status: "alive", tribe: "Tala"},
            "player_3" => %{status: "alive", tribe: "Manu"},
            "player_4" => %{status: "alive", tribe: "Manu"}
          },
          tribes: %{
            "Tala" => ["player_1", "player_2"],
            "Manu" => ["player_3", "player_4"]
          },
          phase: "challenge",
          episode: 1,
          merged: false,
          active_actor_id: "player_4",
          turn_order: ["player_1", "player_2", "player_3", "player_4"],
          challenge_choices: %{
            "player_1" => "physical",
            "player_2" => "physical",
            "player_3" => "endurance"
          },
          challenge_winner: nil,
          challenge_history: [],
          losing_tribe: nil,
          immune_player: nil,
          whisper_log: [],
          whisper_history: [],
          whisper_graph: [],
          statements: [],
          strategy_actions: %{},
          votes: %{},
          vote_history: [],
          idol_played_by: nil,
          idol_history: [],
          idol_phase_done: false,
          idol_turn_order: [],
          tc_voters: [],
          elimination_log: [],
          jury: [],
          jury_votes: %{},
          jury_statements: [],
          ftc_sub_phase: nil,
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.challenge_choice("player_4", "endurance"), [])

    assert next_state.world.phase == "strategy"
    assert next_state.world.challenge_winner == "Tala"
    assert next_state.world.losing_tribe == "Manu"

    assert [
             %{
               episode: 1,
               merged: false,
               winner: "Tala",
               losing_tribe: "Manu",
               scores: %{"Manu" => -4, "Tala" => 4}
             }
           ] = next_state.world.challenge_history
  end

  test "vote history is preserved when tribal council transitions directly to final tribal" do
    state =
      State.new(
        sim_id: "survivor-test",
        world: %{
          players: %{
            "player_1" => %{status: "alive", tribe: "Solana", jury_member: false},
            "player_2" => %{status: "alive", tribe: "Solana", jury_member: false},
            "player_3" => %{status: "alive", tribe: "Solana", jury_member: false},
            "player_4" => %{status: "alive", tribe: "Solana", jury_member: false}
          },
          tribes: %{"Solana" => ["player_1", "player_2", "player_3", "player_4"]},
          phase: "tribal_council",
          episode: 5,
          merged: true,
          active_actor_id: "player_4",
          turn_order: ["player_1", "player_2", "player_3", "player_4"],
          challenge_choices: %{},
          challenge_winner: "player_1",
          challenge_history: [],
          losing_tribe: nil,
          immune_player: "player_1",
          whisper_log: [],
          whisper_history: [],
          whisper_graph: [],
          statements: [],
          strategy_actions: %{},
          votes: %{
            "player_1" => "player_4",
            "player_2" => "player_4",
            "player_3" => "player_4"
          },
          vote_history: [],
          idol_played_by: nil,
          idol_history: [],
          idol_phase_done: true,
          idol_turn_order: [],
          tc_voters: ["player_1", "player_2", "player_3", "player_4"],
          elimination_log: [],
          jury: [],
          jury_votes: %{},
          jury_statements: [],
          ftc_sub_phase: nil,
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.cast_vote("player_4", "player_2"), [])

    assert next_state.world.phase == "final_tribal_council"
    assert next_state.world.players["player_4"].status == "eliminated"
    assert next_state.world.jury == ["player_4"]

    assert Enum.sort_by(next_state.world.vote_history, & &1.voter) == [
             %{
               episode: 5,
               merged: true,
               target: "player_4",
               target_eliminated: true,
               voter: "player_1"
             },
             %{
               episode: 5,
               merged: true,
               target: "player_4",
               target_eliminated: true,
               voter: "player_2"
             },
             %{
               episode: 5,
               merged: true,
               target: "player_4",
               target_eliminated: true,
               voter: "player_3"
             },
             %{
               episode: 5,
               merged: true,
               target: "player_2",
               target_eliminated: false,
               voter: "player_4"
             }
           ]
  end
end
