defmodule LemonSim.Examples.SupplyChainUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.SupplyChain.{Events, Updater}
  alias LemonSim.State

  @initial_tiers %{
    "retailer" => %{
      role: "Retailer",
      inventory: 20,
      backlog: 0,
      pending_order: 0,
      incoming_deliveries: [],
      cash: 0.0,
      total_cost: 0.0,
      safety_stock: 5,
      order_history: [],
      cost_history: [],
      orders_received: 0,
      orders_fulfilled: 0,
      order_placed_this_round: false
    },
    "distributor" => %{
      role: "Distributor",
      inventory: 20,
      backlog: 0,
      pending_order: 0,
      incoming_deliveries: [],
      cash: 0.0,
      total_cost: 0.0,
      safety_stock: 5,
      order_history: [],
      cost_history: [],
      orders_received: 0,
      orders_fulfilled: 0,
      order_placed_this_round: false
    },
    "factory" => %{
      role: "Factory",
      inventory: 20,
      backlog: 0,
      pending_order: 0,
      incoming_deliveries: [],
      cash: 0.0,
      total_cost: 0.0,
      safety_stock: 5,
      order_history: [],
      cost_history: [],
      orders_received: 0,
      orders_fulfilled: 0,
      order_placed_this_round: false
    },
    "raw_materials" => %{
      role: "Raw Materials Supplier",
      inventory: 20,
      backlog: 0,
      pending_order: 0,
      incoming_deliveries: [],
      cash: 0.0,
      total_cost: 0.0,
      safety_stock: 5,
      order_history: [],
      cost_history: [],
      orders_received: 0,
      orders_fulfilled: 0,
      order_placed_this_round: false
    }
  }

  defp base_world(overrides \\ %{}) do
    Map.merge(
      %{
        tiers: @initial_tiers,
        phase: "observe",
        round: 1,
        max_rounds: 20,
        active_actor_id: "retailer",
        observe_done: MapSet.new(),
        communicate_done: MapSet.new(),
        order_done: MapSet.new(),
        messages: %{"retailer" => [], "distributor" => [], "factory" => [], "raw_materials" => []},
        message_log: [],
        consumer_demand: 0,
        demand_history: [],
        demand_seed: 12345,
        costs: %{
          holding_cost_per_unit: 0.5,
          stockout_penalty_per_unit: 2.0,
          order_cost: 1.0,
          expedite_surcharge_per_unit: 3.0
        },
        cost_threshold: 600.0,
        delivery_delay: 2,
        journals: %{},
        status: "in_progress",
        winner: nil,
        team_bonus: false,
        total_chain_cost: nil
      },
      overrides
    )
  end

  defp make_state(world_overrides \\ %{}) do
    State.new(
      sim_id: "supply-chain-test",
      world: base_world(world_overrides)
    )
  end

  # -- Observe phase tests --

  test "check_inventory advances from observe phase and records observed state" do
    state = make_state()

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.check_inventory("retailer"), [])

    assert MapSet.member?(next_state.world.observe_done, "retailer")

    # Active actor should advance to next tier in observe
    assert next_state.world.active_actor_id == "distributor"
    assert next_state.world.phase == "observe"
  end

  test "check_inventory transitions to communicate phase when all tiers observe" do
    world = base_world(%{
      observe_done: MapSet.new(["distributor", "factory", "raw_materials"]),
      active_actor_id: "retailer"
    })

    state = State.new(sim_id: "test", world: world)

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(state, Events.check_inventory("retailer"), [])

    assert next_state.world.phase == "communicate"
    assert next_state.world.active_actor_id == "retailer"
    assert prompt =~ "communicate"
  end

  test "check_inventory rejected if wrong phase" do
    state = make_state(%{phase: "communicate"})

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(state, Events.check_inventory("retailer"), [])

    assert msg =~ "wrong phase"
    assert next_state.world.phase == "communicate"
  end

  # -- Communicate phase tests --

  test "send_forecast adds message to recipient inbox" do
    state = make_state(%{
      phase: "communicate",
      communicate_done: MapSet.new(),
      active_actor_id: "retailer"
    })

    forecast = %{"expected_demand" => 12, "notes" => "spike expected"}

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.send_forecast("retailer", "distributor", forecast),
               []
             )

    msgs = next_state.world.messages["distributor"]
    assert length(msgs) == 1
    assert List.first(msgs)["type"] == "forecast"
    assert List.first(msgs)["from"] == "retailer"

    log = next_state.world.message_log
    assert length(log) == 1
    assert hd(log).from == "retailer"
    assert hd(log).to == "distributor"
  end

  test "send_forecast rejected for non-adjacent tier" do
    state = make_state(%{
      phase: "communicate",
      communicate_done: MapSet.new(),
      active_actor_id: "retailer"
    })

    # retailer cannot communicate directly with factory (not adjacent)
    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.send_forecast("retailer", "factory", %{}),
               []
             )

    assert msg =~ "adjacent"
    # No message was recorded
    assert next_state.world.messages["factory"] == []
  end

  test "end_communicate advances tier and transitions to order when all done" do
    state = make_state(%{
      phase: "communicate",
      communicate_done: MapSet.new(["distributor", "factory", "raw_materials"]),
      active_actor_id: "retailer"
    })

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(state, Events.end_communicate("retailer"), [])

    assert next_state.world.phase == "order"
    assert next_state.world.active_actor_id == "retailer"
    assert prompt =~ "order"
  end

  # -- Order phase tests --

  test "place_order records the order on the tier" do
    state = make_state(%{
      phase: "order",
      order_done: MapSet.new(),
      active_actor_id: "retailer"
    })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.place_order("retailer", 15), [])

    retailer = next_state.world.tiers["retailer"]
    assert retailer.pending_order == 15
    assert retailer.order_placed_this_round == true
    assert length(retailer.order_history) == 1
    assert hd(retailer.order_history).quantity == 15
  end

  test "place_order triggers round resolution when all tiers order" do
    world = base_world(%{
      phase: "order",
      order_done: MapSet.new(["distributor", "factory", "raw_materials"]),
      active_actor_id: "retailer"
    })

    # Give all other tiers a pending order so fulfillment can run
    tiers =
      world.tiers
      |> put_in(["distributor", :pending_order], 10)
      |> put_in(["factory", :pending_order], 10)
      |> put_in(["raw_materials", :pending_order], 10)

    state = State.new(sim_id: "test", world: Map.put(world, :tiers, tiers))

    assert {:ok, next_state, {:decide, prompt}} =
             Updater.apply_event(state, Events.place_order("retailer", 10), [])

    # Round should have advanced
    assert next_state.world.round == 2
    assert next_state.world.phase == "observe"
    assert prompt =~ "observe"
  end

  test "place_order rejected with negative quantity" do
    state = make_state(%{
      phase: "order",
      order_done: MapSet.new(),
      active_actor_id: "retailer"
    })

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(state, Events.place_order("retailer", -1), [])

    assert msg =~ "non-negative"
    assert next_state.world.tiers["retailer"].pending_order == 0
  end

  # -- Adjust safety stock test --

  test "adjust_safety_stock updates tier safety stock target" do
    state = make_state(%{
      phase: "observe",
      active_actor_id: "retailer"
    })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.adjust_safety_stock("retailer", 12), [])

    assert next_state.world.tiers["retailer"].safety_stock == 12
  end

  # -- Victory / accounting tests --

  test "game ends after max_rounds with lowest-cost tier winning" do
    # Set up world at the final round to trigger victory
    world = base_world(%{
      phase: "order",
      round: 20,
      max_rounds: 20,
      order_done: MapSet.new(["distributor", "factory", "raw_materials"]),
      active_actor_id: "retailer"
    })

    # Retailer has lowest total cost
    tiers =
      world.tiers
      |> put_in(["retailer", :total_cost], 50.0)
      |> put_in(["distributor", :total_cost], 120.0)
      |> put_in(["factory", :total_cost], 90.0)
      |> put_in(["raw_materials", :total_cost], 80.0)

    state = State.new(sim_id: "test", world: Map.put(world, :tiers, tiers))

    assert {:ok, next_state, :skip} =
             Updater.apply_event(state, Events.place_order("retailer", 10), [])

    assert next_state.world.status == "won"
    assert next_state.world.winner == "retailer"
  end
end
