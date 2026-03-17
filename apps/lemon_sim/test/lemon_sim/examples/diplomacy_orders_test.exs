defmodule LemonSim.Examples.DiplomacyOrdersTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Diplomacy.{Events, Updater}
  alias LemonSim.State

  defp base_world do
    %{
      status: "in_progress",
      phase: "orders",
      players: %{
        "player_1" => %{status: "alive"},
        "player_2" => %{status: "alive"}
      },
      territories: %{
        "A" => %{owner: "player_1", armies: 2},
        "B" => %{owner: nil, armies: 0},
        "C" => %{owner: "player_2", armies: 2}
      },
      adjacency: %{
        "A" => ["B", "C"],
        "B" => ["A", "C"],
        "C" => ["A", "B"]
      },
      turn_order: ["player_1", "player_2"],
      active_actor_id: "player_1",
      pending_orders: %{},
      orders_submitted: MapSet.new(),
      round: 1,
      max_rounds: 10,
      private_messages: %{"player_1" => [], "player_2" => []},
      message_history: [],
      messages_sent_this_round: %{},
      order_history: [],
      diplomacy_done: MapSet.new(),
      capture_history: [],
      resolution_log: [],
      winner: nil
    }
  end

  defp base_state(overrides) do
    State.new(sim_id: "diplomacy-orders-test", world: Map.merge(base_world(), overrides))
  end

  test "unopposed move succeeds — player_1 moves from A to empty B" do
    # player_1 issues move A->B, then both players submit
    state = base_state(%{
      territories: %{
        "A" => %{owner: "player_1", armies: 2},
        "B" => %{owner: nil, armies: 0},
        "C" => %{owner: "player_2", armies: 2}
      }
    })

    # player_1 issues move order
    assert {:ok, state2, _} =
             Updater.apply_event(state, Events.issue_order("player_1", "A", "move", "B", nil), [])

    # player_1 submits
    assert {:ok, state3, _} =
             Updater.apply_event(state2, Events.submit_orders("player_1"), [])

    # player_2 holds C and submits
    assert {:ok, final_state, _} =
             Updater.apply_event(state3, Events.submit_orders("player_2"), [])

    # B should now be owned by player_1
    assert final_state.world.territories["B"].owner == "player_1"
    # A should have no armies (they moved out)
    assert final_state.world.territories["A"].armies == 0
  end

  test "supported move beats unsupported defender" do
    # 3 players: player_1 at A, player_2 supports from B, player_3 defends C
    state =
      State.new(
        sim_id: "diplomacy-orders-test",
        world: %{
          status: "in_progress",
          phase: "orders",
          players: %{
            "player_1" => %{status: "alive"},
            "player_2" => %{status: "alive"},
            "player_3" => %{status: "alive"}
          },
          territories: %{
            "A" => %{owner: "player_1", armies: 1},
            "B" => %{owner: "player_2", armies: 1},
            "C" => %{owner: "player_3", armies: 1}
          },
          adjacency: %{
            "A" => ["B", "C"],
            "B" => ["A", "C"],
            "C" => ["A", "B"]
          },
          turn_order: ["player_1", "player_2", "player_3"],
          active_actor_id: "player_1",
          pending_orders: %{},
          orders_submitted: MapSet.new(),
          round: 1,
          max_rounds: 10,
          private_messages: %{"player_1" => [], "player_2" => [], "player_3" => []},
          message_history: [],
          messages_sent_this_round: %{},
          order_history: [],
          diplomacy_done: MapSet.new(),
          capture_history: [],
          resolution_log: [],
          winner: nil
        }
      )

    # player_1 issues move A->C
    assert {:ok, s2, _} =
             Updater.apply_event(state, Events.issue_order("player_1", "A", "move", "C", nil), [])

    # player_1 submits
    assert {:ok, s3, _} = Updater.apply_event(s2, Events.submit_orders("player_1"), [])

    # player_2 issues support for player_1 moving to C
    assert {:ok, s4, _} =
             Updater.apply_event(
               s3,
               Events.issue_order("player_2", "B", "support", "C", "player_1"),
               []
             )

    # player_2 submits
    assert {:ok, s5, _} = Updater.apply_event(s4, Events.submit_orders("player_2"), [])

    # player_3 submits (default hold for C)
    assert {:ok, final_state, _} = Updater.apply_event(s5, Events.submit_orders("player_3"), [])

    # C should now be captured by player_1 (supported attack beats unsupported defense)
    assert final_state.world.territories["C"].owner == "player_1"

    assert Enum.any?(final_state.world.capture_history, fn entry ->
             entry.territory == "C" and entry.attacker == "player_1" and
               entry.defender == "player_3"
           end)
  end

  test "multi-contender bounce — 3 players all move to same territory" do
    state =
      State.new(
        sim_id: "diplomacy-orders-test",
        world: %{
          status: "in_progress",
          phase: "orders",
          players: %{
            "player_1" => %{status: "alive"},
            "player_2" => %{status: "alive"},
            "player_3" => %{status: "alive"}
          },
          territories: %{
            "A" => %{owner: "player_1", armies: 1},
            "B" => %{owner: "player_2", armies: 1},
            "C" => %{owner: "player_3", armies: 1},
            "X" => %{owner: nil, armies: 0}
          },
          adjacency: %{
            "A" => ["X"],
            "B" => ["X"],
            "C" => ["X"],
            "X" => ["A", "B", "C"]
          },
          turn_order: ["player_1", "player_2", "player_3"],
          active_actor_id: "player_1",
          pending_orders: %{},
          orders_submitted: MapSet.new(),
          round: 1,
          max_rounds: 10,
          private_messages: %{"player_1" => [], "player_2" => [], "player_3" => []},
          message_history: [],
          messages_sent_this_round: %{},
          order_history: [],
          diplomacy_done: MapSet.new(),
          capture_history: [],
          resolution_log: [],
          winner: nil
        }
      )

    # All 3 players move to X
    assert {:ok, s2, _} =
             Updater.apply_event(state, Events.issue_order("player_1", "A", "move", "X", nil), [])

    assert {:ok, s3, _} = Updater.apply_event(s2, Events.submit_orders("player_1"), [])

    assert {:ok, s4, _} =
             Updater.apply_event(s3, Events.issue_order("player_2", "B", "move", "X", nil), [])

    assert {:ok, s5, _} = Updater.apply_event(s4, Events.submit_orders("player_2"), [])

    assert {:ok, s6, _} =
             Updater.apply_event(s5, Events.issue_order("player_3", "C", "move", "X", nil), [])

    assert {:ok, final_state, _} = Updater.apply_event(s6, Events.submit_orders("player_3"), [])

    # X should still be unowned — everyone bounced
    assert final_state.world.territories["X"].owner == nil
    # No captures
    assert final_state.world.capture_history == []
  end

  test "non-adjacent move rejected" do
    # A is not adjacent to a territory not in adjacency list
    # Add a territory Z that is not adjacent to A
    state = base_state(%{
      territories: %{
        "A" => %{owner: "player_1", armies: 2},
        "B" => %{owner: nil, armies: 0},
        "C" => %{owner: "player_2", armies: 2},
        "Z" => %{owner: nil, armies: 0}
      },
      adjacency: %{
        "A" => ["B"],
        "B" => ["A", "C"],
        "C" => ["B"],
        "Z" => []
      }
    })

    # player_1 tries to move A->Z (non-adjacent)
    assert {:ok, _next_state, {:decide, msg}} =
             Updater.apply_event(state, Events.issue_order("player_1", "A", "move", "Z", nil), [])

    assert msg == "target territory is not adjacent"
  end

  test "message quota enforced — third message in a round is rejected" do
    state = base_state(%{
      phase: "diplomacy",
      players: %{
        "player_1" => %{status: "alive"},
        "player_2" => %{status: "alive"}
      }
    })

    # Send first message — OK
    assert {:ok, s2, _} =
             Updater.apply_event(
               state,
               Events.send_message("player_1", "player_2", "Hello"),
               []
             )

    # Send second message — OK
    assert {:ok, s3, _} =
             Updater.apply_event(
               s2,
               Events.send_message("player_1", "player_2", "Alliance?"),
               []
             )

    # Send third message — quota exceeded
    assert {:ok, _s4, {:decide, msg}} =
             Updater.apply_event(
               s3,
               Events.send_message("player_1", "player_2", "Please respond"),
               []
             )

    assert msg == "message quota exceeded (max 2 per round)"
  end

  test "victory by domination — player_1 reaches 7 territories after resolution" do
    # Set up 8 territories where player_1 owns 6 and will capture a 7th
    territories =
      Enum.into(1..7, %{}, fn i ->
        {"T#{i}", %{owner: "player_1", armies: 1}}
      end)
      |> Map.put("T8", %{owner: "player_2", armies: 1})
      |> Map.put("Neutral", %{owner: nil, armies: 0})

    # Build adjacency so player_1 can move T7->T8
    adjacency =
      Enum.into(1..8, %{}, fn i ->
        {"T#{i}", ["T#{i - 1}", "T#{i + 1}"] |> Enum.filter(fn t -> t != "T0" and t != "T9" end)}
      end)
      |> Map.put("Neutral", [])

    state =
      State.new(
        sim_id: "diplomacy-orders-test",
        world: %{
          status: "in_progress",
          phase: "orders",
          players: %{
            "player_1" => %{status: "alive"},
            "player_2" => %{status: "alive"}
          },
          territories: territories,
          adjacency: adjacency,
          turn_order: ["player_1", "player_2"],
          active_actor_id: "player_1",
          pending_orders: %{},
          orders_submitted: MapSet.new(),
          round: 5,
          max_rounds: 10,
          private_messages: %{"player_1" => [], "player_2" => []},
          message_history: [],
          messages_sent_this_round: %{},
          order_history: [],
          diplomacy_done: MapSet.new(),
          capture_history: [],
          resolution_log: [],
          winner: nil
        }
      )

    # player_1 moves T7->T8 to capture it (total = 7)
    assert {:ok, s2, _} =
             Updater.apply_event(
               state,
               Events.issue_order("player_1", "T7", "move", "T8", nil),
               []
             )

    assert {:ok, s3, _} = Updater.apply_event(s2, Events.submit_orders("player_1"), [])

    # player_2 submits (default hold)
    assert {:ok, final_state, :skip} = Updater.apply_event(s3, Events.submit_orders("player_2"), [])

    assert final_state.world.status == "won"
    assert final_state.world.winner == "player_1"
  end
end
