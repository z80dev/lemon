defmodule LemonSim.Examples.SurvivorMechanicsTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Survivor.{Events, Updater}
  alias LemonSim.State

  defp base_world do
    %{
      players: %{
        "player_1" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false},
        "player_2" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false},
        "player_3" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false},
        "player_4" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false}
      },
      tribes: %{"Solana" => ["player_1", "player_2", "player_3", "player_4"]},
      phase: "tribal_council",
      episode: 3,
      merged: true,
      active_actor_id: "player_1",
      turn_order: ["player_1", "player_2", "player_3", "player_4"],
      challenge_choices: %{},
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
      idol_turn_order: ["player_1", "player_2", "player_3", "player_4"],
      tc_voters: ["player_1", "player_2", "player_3", "player_4"],
      elimination_log: [],
      jury: [],
      jury_votes: %{},
      jury_statements: [],
      ftc_sub_phase: nil,
      status: "in_progress",
      winner: nil
    }
  end

  defp new_state(world_overrides) do
    State.new(
      sim_id: "survivor-test",
      world: Map.merge(base_world(), world_overrides)
    )
  end

  test "idol play sets idol_played_by and negates votes cast against that player" do
    state =
      new_state(%{
        players: %{
          "player_1" => %{status: "alive", tribe: "Solana", has_idol: true, jury_member: false},
          "player_2" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false},
          "player_3" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false},
          "player_4" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false}
        },
        # Votes cast against player_1 before idol play is resolved at vote time
        votes: %{
          "player_2" => "player_1",
          "player_3" => "player_1"
        },
        # idol phase: player_1 is the active actor
        idol_turn_order: ["player_1"],
        tc_voters: ["player_1", "player_2", "player_3", "player_4"],
        active_actor_id: "player_1"
      })

    assert {:ok, next_state, _signal} =
             Updater.apply_event(state, Events.play_idol("player_1"), [])

    assert next_state.world.idol_played_by == "player_1"
    assert next_state.world.players["player_1"].has_idol == false
  end

  test "idol skip leaves idol_played_by nil and votes count normally" do
    state =
      new_state(%{
        players: %{
          "player_1" => %{status: "alive", tribe: "Solana", has_idol: true, jury_member: false},
          "player_2" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false},
          "player_3" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false},
          "player_4" => %{status: "alive", tribe: "Solana", has_idol: false, jury_member: false}
        },
        votes: %{
          "player_2" => "player_4",
          "player_3" => "player_4"
        },
        idol_turn_order: ["player_1"],
        tc_voters: ["player_1", "player_2", "player_3", "player_4"],
        active_actor_id: "player_1"
      })

    assert {:ok, next_state, _signal} =
             Updater.apply_event(state, Events.skip_idol("player_1"), [])

    assert next_state.world.idol_played_by == nil
    assert next_state.world.players["player_1"].has_idol == true
  end

  test "challenge scoring: physical beats endurance, endurance beats puzzle, puzzle beats physical" do
    # physical vs endurance: physical wins
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

    # player_4 chooses endurance for Manu. Tala: [physical, physical] vs Manu: [endurance, endurance]
    # physical beats endurance, so Tala wins
    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.challenge_choice("player_4", "endurance"), [])

    assert next_state.world.challenge_winner == "Tala"
    assert next_state.world.losing_tribe == "Manu"
  end

  test "merge triggers when living player count drops to merge_threshold (<=6) after elimination" do
    # 7 players, one from losing tribe is eliminated -> 6 remain -> should merge
    state =
      State.new(
        sim_id: "survivor-test",
        world: %{
          players: %{
            "player_1" => %{status: "alive", tribe: "Tala", has_idol: false, jury_member: false},
            "player_2" => %{status: "alive", tribe: "Tala", has_idol: false, jury_member: false},
            "player_3" => %{status: "alive", tribe: "Tala", has_idol: false, jury_member: false},
            "player_4" => %{status: "alive", tribe: "Manu", has_idol: false, jury_member: false},
            "player_5" => %{status: "alive", tribe: "Manu", has_idol: false, jury_member: false},
            "player_6" => %{status: "alive", tribe: "Manu", has_idol: false, jury_member: false},
            "player_7" => %{status: "alive", tribe: "Manu", has_idol: false, jury_member: false}
          },
          tribes: %{
            "Tala" => ["player_1", "player_2", "player_3"],
            "Manu" => ["player_4", "player_5", "player_6", "player_7"]
          },
          phase: "tribal_council",
          episode: 3,
          merged: false,
          active_actor_id: "player_7",
          turn_order: ["player_4", "player_5", "player_6", "player_7"],
          challenge_choices: %{},
          challenge_winner: nil,
          challenge_history: [],
          losing_tribe: "Manu",
          immune_player: nil,
          whisper_log: [],
          whisper_history: [],
          whisper_graph: [],
          statements: [],
          strategy_actions: %{},
          votes: %{
            "player_4" => "player_7",
            "player_5" => "player_7",
            "player_6" => "player_7"
          },
          vote_history: [],
          idol_played_by: nil,
          idol_history: [],
          idol_phase_done: true,
          idol_turn_order: [],
          tc_voters: ["player_4", "player_5", "player_6", "player_7"],
          elimination_log: [],
          jury: [],
          jury_votes: %{},
          jury_statements: [],
          ftc_sub_phase: nil,
          status: "in_progress",
          winner: nil
        }
      )

    # player_7 casts the last vote, which resolves the vote and triggers elimination and merge
    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.cast_vote("player_7", "player_4"), [])

    assert next_state.world.merged == true

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "tribes_merged" in kinds
  end

  test "FTC sub-phase progression: jury_statements -> finalist_pleas -> jury_voting" do
    # 2 finalists, 1 juror for simplicity
    state =
      State.new(
        sim_id: "survivor-test",
        world: %{
          players: %{
            "finalist_1" => %{
              status: "alive",
              tribe: "Solana",
              has_idol: false,
              jury_member: false
            },
            "finalist_2" => %{
              status: "alive",
              tribe: "Solana",
              has_idol: false,
              jury_member: false
            },
            "juror_1" => %{
              status: "eliminated",
              tribe: "Solana",
              has_idol: false,
              jury_member: true
            }
          },
          tribes: %{"Solana" => ["finalist_1", "finalist_2"]},
          phase: "final_tribal_council",
          episode: 8,
          merged: true,
          active_actor_id: "juror_1",
          turn_order: ["juror_1"],
          challenge_choices: %{},
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
          jury: ["juror_1"],
          jury_votes: %{},
          jury_statements: [],
          ftc_sub_phase: "jury_statements",
          status: "in_progress",
          winner: nil
        }
      )

    # juror_1 gives statement, sub-phase should advance to finalist_pleas
    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.jury_statement("juror_1", "You both played great games."),
               []
             )

    assert next_state.world.ftc_sub_phase == "finalist_pleas"
    assert next_state.world.turn_order == ["finalist_1", "finalist_2"]
  end

  test "jury vote determines the winner with the most jury votes" do
    state =
      State.new(
        sim_id: "survivor-test",
        world: %{
          players: %{
            "finalist_1" => %{
              status: "alive",
              tribe: "Solana",
              has_idol: false,
              jury_member: false
            },
            "finalist_2" => %{
              status: "alive",
              tribe: "Solana",
              has_idol: false,
              jury_member: false
            },
            "juror_1" => %{
              status: "eliminated",
              tribe: "Solana",
              has_idol: false,
              jury_member: true
            },
            "juror_2" => %{
              status: "eliminated",
              tribe: "Solana",
              has_idol: false,
              jury_member: true
            },
            "juror_3" => %{
              status: "eliminated",
              tribe: "Solana",
              has_idol: false,
              jury_member: true
            }
          },
          tribes: %{"Solana" => ["finalist_1", "finalist_2"]},
          phase: "final_tribal_council",
          episode: 10,
          merged: true,
          active_actor_id: "juror_3",
          turn_order: ["juror_3"],
          challenge_choices: %{},
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
          jury: ["juror_1", "juror_2", "juror_3"],
          jury_votes: %{
            "juror_1" => "finalist_1",
            "juror_2" => "finalist_1"
          },
          jury_statements: [],
          ftc_sub_phase: "jury_voting",
          status: "in_progress",
          winner: nil
        }
      )

    # juror_3 is the last jury voter; after vote all jury has voted -> resolve winner
    assert {:ok, next_state, :skip} =
             Updater.apply_event(state, Events.jury_vote("juror_3", "finalist_1"), [])

    # finalist_1 has 3 votes (majority), finalist_2 has 0
    assert next_state.world.winner == "finalist_1"
    assert next_state.world.status == "game_over"

    kinds = Enum.map(next_state.recent_events, & &1.kind)
    assert "game_over" in kinds
  end
end
