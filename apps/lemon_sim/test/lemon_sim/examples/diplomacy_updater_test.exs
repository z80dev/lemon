defmodule LemonSim.Examples.DiplomacyUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Diplomacy.{Events, Updater}
  alias LemonSim.State

  test "send_message records public negotiation history without leaking inbox contents" do
    state =
      State.new(
        sim_id: "diplomacy-test",
        world: %{
          territories: %{},
          adjacency: %{},
          players: %{
            "player_1" => %{status: "alive"},
            "player_2" => %{status: "alive"}
          },
          phase: "diplomacy",
          round: 2,
          max_rounds: 10,
          active_actor_id: "player_1",
          turn_order: ["player_1", "player_2"],
          private_messages: %{"player_1" => [], "player_2" => []},
          message_history: [],
          messages_sent_this_round: %{},
          pending_orders: %{},
          orders_submitted: MapSet.new(),
          order_history: [],
          diplomacy_done: MapSet.new(),
          capture_history: [],
          resolution_log: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(
               state,
               Events.send_message("player_1", "player_2", "Let's attack north."),
               []
             )

    assert next_state.world.message_history == [%{round: 2, from: "player_1", to: "player_2"}]

    assert next_state.world.private_messages["player_2"] |> List.last() |> Map.fetch!("message") ==
             "Let's attack north."
  end

  test "resolving a winning move records submitted orders and capture history" do
    state =
      State.new(
        sim_id: "diplomacy-test",
        world: %{
          territories: %{
            "A" => %{owner: "player_2", armies: 2},
            "B" => %{owner: "player_1", armies: 1}
          },
          adjacency: %{"A" => ["B"], "B" => ["A"]},
          players: %{
            "player_1" => %{status: "alive"},
            "player_2" => %{status: "alive"}
          },
          phase: "orders",
          round: 3,
          max_rounds: 10,
          active_actor_id: "player_2",
          turn_order: ["player_1", "player_2"],
          private_messages: %{"player_1" => [], "player_2" => []},
          message_history: [],
          messages_sent_this_round: %{},
          pending_orders: %{
            "player_1" => %{
              "B" => %{
                "army_territory" => "B",
                "order_type" => "hold",
                "target_territory" => "B",
                "support_target" => nil
              }
            },
            "player_2" => %{
              "A" => %{
                "army_territory" => "A",
                "order_type" => "move",
                "target_territory" => "B",
                "support_target" => nil
              }
            }
          },
          orders_submitted: MapSet.new(["player_1"]),
          order_history: [],
          diplomacy_done: MapSet.new(),
          capture_history: [],
          resolution_log: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.submit_orders("player_2"), [])

    assert next_state.world.round == 4
    assert next_state.world.phase == "diplomacy"

    assert next_state.world.capture_history == [
             %{round: 3, territory: "B", attacker: "player_2", defender: "player_1"}
           ]

    assert next_state.world.order_history == [
             %{
               round: 3,
               player: "player_2",
               orders: %{
                 "A" => %{
                   "army_territory" => "A",
                   "order_type" => "move",
                   "target_territory" => "B",
                   "support_target" => nil
                 }
               }
             }
           ]

    assert next_state.world.territories["B"].owner == "player_2"
  end
end
