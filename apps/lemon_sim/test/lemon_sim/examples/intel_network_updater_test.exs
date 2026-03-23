defmodule LemonSim.Examples.IntelNetworkUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.IntelNetwork.{Events, Updater}
  alias LemonSim.State

  defp base_world(overrides \\ %{}) do
    Map.merge(
      %{
        players: %{
          "agent_1" => %{
            codename: "CARDINAL",
            role: "operative",
            status: "active",
            intel_fragments: ["fragment_alpha"],
            trust_level: 0.5
          },
          "agent_2" => %{
            codename: "FALCON",
            role: "operative",
            status: "active",
            intel_fragments: ["fragment_bravo"],
            trust_level: 0.5
          },
          "agent_3" => %{
            codename: "RAVEN",
            role: "mole",
            status: "active",
            intel_fragments: ["fragment_charlie"],
            trust_level: 0.5
          }
        },
        adjacency: %{
          "agent_1" => ["agent_2", "agent_3"],
          "agent_2" => ["agent_1", "agent_3"],
          "agent_3" => ["agent_1", "agent_2"]
        },
        intel_pool: ["fragment_alpha", "fragment_bravo", "fragment_charlie"],
        leaked_intel: [],
        suspicion_board: %{},
        message_log: %{},
        operations_log: [],
        analysis_notes: %{},
        journals: %{},
        phase: "communication",
        round: 1,
        max_rounds: 8,
        active_actor_id: "agent_1",
        turn_order: ["agent_1", "agent_2", "agent_3"],
        messages_sent_this_round: %{},
        communication_done: MapSet.new(),
        analysis_done: MapSet.new(),
        operations_done: MapSet.new(),
        briefing_done: MapSet.new(),
        status: "in_progress",
        winner: nil
      },
      overrides
    )
  end

  defp base_state(world_overrides \\ %{}) do
    State.new(
      sim_id: "intel-network-test",
      world: base_world(world_overrides)
    )
  end

  test "send_message records message in log between adjacent agents" do
    state = base_state()

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.send_message("agent_1", "agent_2", "Have you seen anything suspicious?"),
               []
             )

    edge_key = "agent_1--agent_2"
    messages = get_in(next_state.world, [:message_log, edge_key])
    assert is_list(messages)
    assert length(messages) == 1
    assert List.last(messages)["content"] == "Have you seen anything suspicious?"
    assert List.last(messages)["from"] == "agent_1"
    assert List.last(messages)["to"] == "agent_2"
  end

  test "send_message is rejected if recipient is not adjacent" do
    # agent_4 is not in the adjacency for agent_1
    state =
      base_state(%{
        players: %{
          "agent_1" => %{
            codename: "CARDINAL",
            role: "operative",
            status: "active",
            intel_fragments: [],
            trust_level: 0.5
          },
          "agent_2" => %{
            codename: "FALCON",
            role: "operative",
            status: "active",
            intel_fragments: [],
            trust_level: 0.5
          },
          "agent_4" => %{
            codename: "SPHINX",
            role: "operative",
            status: "active",
            intel_fragments: [],
            trust_level: 0.5
          }
        },
        adjacency: %{
          "agent_1" => ["agent_2"],
          "agent_2" => ["agent_1"],
          "agent_4" => []
        },
        turn_order: ["agent_1", "agent_2", "agent_4"]
      })

    assert {:ok, next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.send_message("agent_1", "agent_4", "This should fail"),
               []
             )

    assert reason =~ "not adjacent"
  end

  test "send_message enforces quota of 2 per round" do
    state =
      base_state(%{
        messages_sent_this_round: %{
          "agent_1" => %{1 => 2}
        }
      })

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.send_message("agent_1", "agent_2", "Third message attempt"),
               []
             )

    assert reason =~ "quota"
  end

  test "end_communication advances to next player" do
    state = base_state()

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(state, Events.end_communication("agent_1"), [])

    assert next_state.world.active_actor_id == "agent_2"
    assert MapSet.member?(next_state.world.communication_done, "agent_1")
    assert prompt =~ "agent_2"
  end

  test "end_communication transitions to analysis when all players done" do
    state =
      base_state(%{
        communication_done: MapSet.new(["agent_1", "agent_2"]),
        active_actor_id: "agent_3"
      })

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.end_communication("agent_3"), [])

    assert next_state.world.phase == "analysis"
  end

  test "submit_analysis stores notes privately and advances to next player" do
    state = base_state(%{phase: "analysis", analysis_done: MapSet.new()})

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.submit_analysis("agent_1", "FALCON seems trustworthy. RAVEN was quiet."),
               []
             )

    assert next_state.world.analysis_notes["agent_1"] ==
             "FALCON seems trustworthy. RAVEN was quiet."

    assert MapSet.member?(next_state.world.analysis_done, "agent_1")
    assert next_state.world.phase == "analysis"
  end

  test "submit_analysis transitions to operation when all players done" do
    state =
      base_state(%{
        phase: "analysis",
        analysis_done: MapSet.new(["agent_1", "agent_2"]),
        active_actor_id: "agent_3"
      })

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.submit_analysis("agent_3", "My private analysis"),
               []
             )

    assert next_state.world.phase == "operation"
  end

  test "propose_operation report_suspicion adds to suspicion board" do
    state = base_state(%{phase: "operation", operations_done: MapSet.new()})

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.propose_operation("agent_1", "report_suspicion", "agent_2"),
               []
             )

    assert next_state.world.suspicion_board["agent_2"] == ["agent_1"]
    assert length(next_state.world.operations_log) == 1
  end

  test "propose_operation is rejected for non-adjacent target" do
    state =
      base_state(%{
        phase: "operation",
        operations_done: MapSet.new(),
        adjacency: %{
          "agent_1" => ["agent_2"],
          "agent_2" => ["agent_1"],
          "agent_3" => []
        }
      })

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.propose_operation("agent_1", "report_suspicion", "agent_3"),
               []
             )

    assert reason =~ "not adjacent"
  end

  test "mole_action leak_intel appends to leaked_intel" do
    state =
      base_state(%{
        phase: "mole_action",
        active_actor_id: "agent_3",
        operations_done: MapSet.new(["agent_1", "agent_2", "agent_3"])
      })

    assert {:ok, next_state, _result} =
             Updater.apply_event(
               state,
               Events.mole_action("agent_3", "leak_intel", nil),
               []
             )

    assert length(next_state.world.leaked_intel) == 1
  end

  test "mole_action pass advances round without leaking" do
    state =
      base_state(%{
        phase: "mole_action",
        active_actor_id: "agent_3",
        operations_done: MapSet.new(["agent_1", "agent_2", "agent_3"])
      })

    assert {:ok, next_state, _result} =
             Updater.apply_event(
               state,
               Events.mole_action("agent_3", "pass", nil),
               []
             )

    assert next_state.world.leaked_intel == []
    assert next_state.world.round == 2
    assert next_state.world.phase == "intel_briefing"
  end

  test "mole win condition: 5+ leaks triggers game over" do
    state =
      base_state(%{
        phase: "mole_action",
        active_actor_id: "agent_3",
        leaked_intel: ["f1", "f2", "f3", "f4"],
        players: %{
          "agent_1" => %{
            codename: "CARDINAL",
            role: "operative",
            status: "active",
            intel_fragments: ["fragment_alpha"],
            trust_level: 0.5
          },
          "agent_2" => %{
            codename: "FALCON",
            role: "operative",
            status: "active",
            intel_fragments: [],
            trust_level: 0.5
          },
          "agent_3" => %{
            codename: "RAVEN",
            role: "mole",
            status: "active",
            intel_fragments: ["fragment_charlie"],
            trust_level: 0.5
          }
        }
      })

    assert {:ok, next_state, :skip} =
             Updater.apply_event(
               state,
               Events.mole_action("agent_3", "leak_intel", nil),
               []
             )

    assert next_state.world.status == "won"
    assert next_state.world.winner == "agent_3"
  end

  test "loyalists win when majority vote identifies mole at final round" do
    state =
      base_state(%{
        phase: "mole_action",
        active_actor_id: "agent_3",
        round: 8,
        max_rounds: 8,
        suspicion_board: %{
          "agent_3" => ["agent_1", "agent_2"]
        }
      })

    assert {:ok, next_state, :skip} =
             Updater.apply_event(
               state,
               Events.mole_action("agent_3", "pass", nil),
               []
             )

    assert next_state.world.status == "won"
    assert next_state.world.winner == "loyalists"
  end

  test "mole wins when reaching end undetected (insufficient suspicion votes)" do
    state =
      base_state(%{
        phase: "mole_action",
        active_actor_id: "agent_3",
        round: 8,
        max_rounds: 8,
        # Only 1 vote against the mole (3 players, need 2 for majority)
        suspicion_board: %{
          "agent_3" => ["agent_1"]
        }
      })

    assert {:ok, next_state, :skip} =
             Updater.apply_event(
               state,
               Events.mole_action("agent_3", "pass", nil),
               []
             )

    assert next_state.world.status == "won"
    assert next_state.world.winner == "agent_3"
  end

  test "non-mole cannot perform mole_action" do
    state =
      base_state(%{
        phase: "mole_action",
        active_actor_id: "agent_1"
      })

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(
               state,
               Events.mole_action("agent_1", "leak_intel", nil),
               []
             )

    assert reason =~ "mole"
  end

  test "action rejected when game is over" do
    state = base_state(%{status: "won", winner: "agent_3"})

    assert {:ok, _next_state, {:decide, reason}} =
             Updater.apply_event(state, Events.end_communication("agent_1"), [])

    assert reason =~ "over"
  end
end
