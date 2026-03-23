defmodule LemonSim.Examples.CourtroomUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Courtroom.{Events, Updater}
  alias LemonSim.State

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp base_world(overrides \\ %{}) do
    default = %{
      case_file: %{
        title: "The Test Case",
        description: "A test crime.",
        defendant: "John Doe",
        evidence_list: ["fingerprints_at_scene", "alibi_receipt", "security_footage"],
        evidence_details: %{
          "fingerprints_at_scene" => %{description: "Fingerprints", incriminating: true},
          "alibi_receipt" => %{description: "Alibi", incriminating: false},
          "security_footage" => %{description: "Camera footage", incriminating: true}
        },
        witnesses: %{
          "witness_1" => %{
            archetype: "eyewitness",
            testimony: "I saw someone.",
            knows_evidence: []
          },
          "witness_2" => %{
            archetype: "expert",
            testimony: "Forensic analysis.",
            knows_evidence: []
          }
        }
      },
      players: %{
        "prosecution" => %{role: "prosecution", status: "active"},
        "defense" => %{role: "defense", status: "active"},
        "witness_1" => %{role: "witness", status: "active"},
        "witness_2" => %{role: "witness", status: "active"},
        "juror_1" => %{role: "juror", status: "active"},
        "juror_2" => %{role: "juror", status: "active"},
        "juror_3" => %{role: "juror", status: "active"}
      },
      turn_order: [
        "prosecution",
        "defense",
        "witness_1",
        "witness_2",
        "juror_1",
        "juror_2",
        "juror_3"
      ],
      phase: "opening_statements",
      actors_in_phase: ["prosecution", "defense"],
      active_actor_id: "prosecution",
      phase_done: MapSet.new(),
      testimony_log: [],
      evidence_presented: [],
      objections: [],
      jury_notes: %{},
      verdict_votes: %{},
      current_witness_id: nil,
      journals: %{},
      status: "in_progress",
      winner: nil,
      outcome: nil
    }

    Map.merge(default, overrides)
  end

  defp base_state(world_overrides \\ %{}) do
    State.new(
      sim_id: "courtroom-test",
      world: base_world(world_overrides)
    )
  end

  # ---------------------------------------------------------------------------
  # Opening statements tests
  # ---------------------------------------------------------------------------

  test "prosecution makes opening statement and turn advances to defense" do
    state = base_state()

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.make_statement("prosecution", "Ladies and gentlemen of the jury..."),
               []
             )

    assert length(next_state.world.testimony_log) == 1
    [entry] = next_state.world.testimony_log
    assert entry["player_id"] == "prosecution"
    assert entry["type"] == "statement"
    assert entry["phase"] == "opening_statements"
    # Defense should be next
    assert next_state.world.active_actor_id == "defense"
  end

  test "both opening statements advance to prosecution_case phase" do
    state = base_state()

    {:ok, after_prosecution, _} =
      Updater.apply_event(
        state,
        Events.make_statement("prosecution", "Opening for prosecution."),
        []
      )

    assert after_prosecution.world.active_actor_id == "defense"

    {:ok, after_defense, _} =
      Updater.apply_event(
        after_prosecution,
        Events.make_statement("defense", "Opening for defense."),
        []
      )

    assert after_defense.world.phase == "prosecution_case"
    assert after_defense.world.active_actor_id == "prosecution"
  end

  # ---------------------------------------------------------------------------
  # Evidence presentation tests
  # ---------------------------------------------------------------------------

  test "prosecution can present valid evidence during prosecution_case" do
    state =
      base_state(%{
        phase: "prosecution_case",
        actors_in_phase: ["prosecution"],
        active_actor_id: "prosecution"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.present_evidence("prosecution", "fingerprints_at_scene"),
               []
             )

    assert "fingerprints_at_scene" in next_state.world.evidence_presented
  end

  test "presenting invalid evidence is rejected" do
    state =
      base_state(%{
        phase: "prosecution_case",
        actors_in_phase: ["prosecution"],
        active_actor_id: "prosecution"
      })

    assert {:ok, next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.present_evidence("prosecution", "nonexistent_evidence"),
               []
             )

    assert String.contains?(reason, "evidence")
    # evidence_presented should be empty since the action was rejected
    assert next_state.world.evidence_presented == []
  end

  test "presenting evidence twice does not duplicate it" do
    state =
      base_state(%{
        phase: "prosecution_case",
        actors_in_phase: ["prosecution"],
        active_actor_id: "prosecution",
        evidence_presented: ["fingerprints_at_scene"]
      })

    assert {:ok, next_state, _} =
             Updater.apply_event(
               state,
               Events.present_evidence("prosecution", "fingerprints_at_scene"),
               []
             )

    count =
      next_state.world.evidence_presented
      |> Enum.count(&(&1 == "fingerprints_at_scene"))

    assert count == 1
  end

  # ---------------------------------------------------------------------------
  # Objection tests
  # ---------------------------------------------------------------------------

  test "short objection reason is overruled" do
    state =
      base_state(%{
        phase: "prosecution_case",
        actors_in_phase: ["prosecution"],
        active_actor_id: "prosecution"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.object("defense", "hearsay"),
               []
             )

    assert length(next_state.world.objections) == 1
    [obj] = next_state.world.objections
    assert obj["ruling"] == "overruled"
  end

  test "well-articulated objection is sustained" do
    state =
      base_state(%{
        phase: "prosecution_case",
        actors_in_phase: ["prosecution"],
        active_actor_id: "prosecution"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.object(
                 "defense",
                 "This is hearsay — the witness is repeating what someone else told them, not direct knowledge"
               ),
               []
             )

    assert length(next_state.world.objections) == 1
    [obj] = next_state.world.objections
    assert obj["ruling"] == "sustained"
  end

  # ---------------------------------------------------------------------------
  # Verdict tests
  # ---------------------------------------------------------------------------

  test "all jurors voting guilty results in guilty verdict" do
    state =
      base_state(%{
        phase: "verdict",
        actors_in_phase: ["juror_1", "juror_2", "juror_3"],
        active_actor_id: "juror_1",
        verdict_votes: %{}
      })

    {:ok, after_j1, _} =
      Updater.apply_event(state, Events.cast_verdict("juror_1", "guilty"), [])

    {:ok, after_j2, _} =
      Updater.apply_event(after_j1, Events.cast_verdict("juror_2", "guilty"), [])

    assert {:ok, final_state, :skip} =
             Updater.apply_event(after_j2, Events.cast_verdict("juror_3", "guilty"), [])

    assert final_state.world.outcome == "guilty"
    assert final_state.world.winner == "prosecution"
    assert final_state.world.status == "complete"
  end

  test "majority not_guilty results in defense win" do
    state =
      base_state(%{
        phase: "verdict",
        actors_in_phase: ["juror_1", "juror_2", "juror_3"],
        active_actor_id: "juror_1",
        verdict_votes: %{}
      })

    {:ok, after_j1, _} =
      Updater.apply_event(state, Events.cast_verdict("juror_1", "not_guilty"), [])

    {:ok, after_j2, _} =
      Updater.apply_event(after_j1, Events.cast_verdict("juror_2", "not_guilty"), [])

    assert {:ok, final_state, :skip} =
             Updater.apply_event(after_j2, Events.cast_verdict("juror_3", "guilty"), [])

    assert final_state.world.outcome == "not_guilty"
    assert final_state.world.winner == "defense"
    assert final_state.world.status == "complete"
  end

  test "a juror cannot vote twice" do
    state =
      base_state(%{
        phase: "verdict",
        actors_in_phase: ["juror_1", "juror_2", "juror_3"],
        active_actor_id: "juror_1",
        verdict_votes: %{"juror_1" => "guilty"}
      })

    assert {:ok, next_state, {:decide, reason}} =
             Updater.apply_event(state, Events.cast_verdict("juror_1", "not_guilty"), [])

    # Vote should not have changed
    assert next_state.world.verdict_votes["juror_1"] == "guilty"
    assert String.contains?(reason, "already")
  end

  test "invalid vote value is rejected" do
    state =
      base_state(%{
        phase: "verdict",
        actors_in_phase: ["juror_1", "juror_2", "juror_3"],
        active_actor_id: "juror_1",
        verdict_votes: %{}
      })

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(state, Events.cast_verdict("juror_1", "maybe"), [])

    assert String.contains?(reason, "vote")
  end

  # ---------------------------------------------------------------------------
  # Phase guard tests
  # ---------------------------------------------------------------------------

  test "action in wrong phase is rejected" do
    state = base_state()

    # Trying to cast_verdict during opening_statements
    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(state, Events.cast_verdict("juror_1", "guilty"), [])

    assert String.contains?(reason, "phase")
  end

  test "non-active actor is rejected" do
    state = base_state()

    # prosecution is active, defense tries to act
    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.make_statement("defense", "Jumping in early"),
               []
             )

    assert String.contains?(reason, "active")
  end

  # ---------------------------------------------------------------------------
  # Deliberation tests
  # ---------------------------------------------------------------------------

  test "juror can take a note during deliberation" do
    state =
      base_state(%{
        phase: "deliberation",
        actors_in_phase: ["juror_1", "juror_2", "juror_3"],
        active_actor_id: "juror_1"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.take_note("juror_1", "The fingerprint evidence seems compelling."),
               []
             )

    assert next_state.world.jury_notes["juror_1"] == [
             "The fingerprint evidence seems compelling."
           ]
  end
end
