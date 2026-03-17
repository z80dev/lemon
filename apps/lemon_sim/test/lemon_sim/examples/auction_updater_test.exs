defmodule LemonSim.Examples.AuctionUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Auction.{Events, Updater}
  alias LemonSim.State

  defp base_world do
    %{
      status: "in_progress",
      phase: "bidding",
      players: %{
        "player_1" => %{gold: 100, items: [], status: "active"},
        "player_2" => %{gold: 100, items: [], status: "active"},
        "player_3" => %{gold: 100, items: [], status: "active"}
      },
      turn_order: ["player_1", "player_2", "player_3"],
      active_actor_id: "player_1",
      active_bidders: ["player_1", "player_2", "player_3"],
      current_item: %{name: "Ruby", category: "gem", base_value: 10},
      current_item_index: 0,
      current_round: 1,
      max_rounds: 8,
      high_bid: 0,
      high_bidder: nil,
      bid_history: [],
      auction_results: [],
      auction_schedule: [
        %{name: "Ruby", category: "gem", base_value: 10},
        %{name: "Sapphire", category: "gem", base_value: 8},
        %{name: "Emerald", category: "gem", base_value: 12},
        %{name: "Crown", category: "artifact", base_value: 15},
        %{name: "Scepter", category: "artifact", base_value: 12},
        %{name: "Chalice", category: "artifact", base_value: 8},
        %{name: "Fire Scroll", category: "scroll", base_value: 7},
        %{name: "Ice Scroll", category: "scroll", base_value: 5},
        %{name: "Lightning Scroll", category: "scroll", base_value: 10},
        %{name: "Shadow Scroll", category: "scroll", base_value: 3}
      ],
      scores: %{}
    }
  end

  defp base_state(overrides \\ %{}) do
    State.new(sim_id: "auction-test", world: Map.merge(base_world(), overrides))
  end

  test "bid accepted updates high_bid and high_bidder" do
    state = base_state()

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.place_bid("player_1", 10), [])

    assert next_state.world.high_bid == 10
    assert next_state.world.high_bidder == "player_1"
  end

  test "bid rejected when amount exceeds player gold" do
    state = base_state(%{players: %{
      "player_1" => %{gold: 5, items: [], status: "active"},
      "player_2" => %{gold: 100, items: [], status: "active"},
      "player_3" => %{gold: 100, items: [], status: "active"}
    }})

    assert {:ok, _next_state, {:decide, msg}} =
             Updater.apply_event(state, Events.place_bid("player_1", 10), [])

    assert msg == "not enough gold"
  end

  test "bid rejected when amount is below minimum increment" do
    # high_bid is 10, so min next bid is 12 (10 + 2)
    state = base_state(%{
      high_bid: 10,
      high_bidder: "player_2",
      active_bidders: ["player_1", "player_3"],
      active_actor_id: "player_1"
    })

    assert {:ok, _next_state, {:decide, msg}} =
             Updater.apply_event(state, Events.place_bid("player_1", 11), [])

    assert msg == "bid must be at least high bid + 2"
  end

  test "pass auction removes player from active_bidders" do
    state = base_state()

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.pass_auction("player_1"), [])

    assert "player_1" not in next_state.world.active_bidders
    assert length(next_state.world.active_bidders) == 2
  end

  test "item won when remaining bidders pass after a high bid" do
    # player_1 already bid 10, player_2 is next, player_3 is left
    # active_bidders has only player_3; when player_3 passes, player_1 (high_bidder) wins
    state = base_state(%{
      high_bid: 10,
      high_bidder: "player_1",
      active_bidders: ["player_3"],
      active_actor_id: "player_3"
    })

    assert {:ok, next_state, _} =
             Updater.apply_event(state, Events.pass_auction("player_3"), [])

    # player_1 should have spent 10 gold and have the Ruby
    player_1 = next_state.world.players["player_1"]
    assert player_1.gold == 90
    assert Enum.any?(player_1.items, fn item -> Map.get(item, :name) == "Ruby" end)

    # auction_results should record the win
    assert length(next_state.world.auction_results) == 1
    [result] = next_state.world.auction_results
    assert result.winner == "player_1"
    assert result.price == 10
    assert result.item == "Ruby"
  end

  test "item unsold when all players pass with no bids" do
    state = base_state(%{
      active_bidders: ["player_2", "player_3"],
      active_actor_id: "player_2"
    })

    # player_2 passes
    assert {:ok, state2, _} =
             Updater.apply_event(state, Events.pass_auction("player_2"), [])

    # player_3 passes — no high_bidder so item is unsold
    assert {:ok, next_state, _} =
             Updater.apply_event(state2, Events.pass_auction("player_3"), [])

    # No auction results — item was unsold
    assert next_state.world.auction_results == []

    # No player received an item
    Enum.each(next_state.world.players, fn {_id, player} ->
      assert player.items == []
    end)
  end

  test "round advancement when all items in current round are exhausted" do
    # Round 1 has 1 item (items_per_round = [1,1,2,1,1,2,1,1])
    # After this item resolves, we should move to round 2
    state = base_state(%{
      high_bid: 10,
      high_bidder: "player_1",
      active_bidders: ["player_3"],
      active_actor_id: "player_3",
      current_round: 1,
      current_item_index: 0
    })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.pass_auction("player_3"), [])

    # Should have advanced to round 2
    assert next_state.world.current_round == 2
    # New auction should have started with a new item
    assert next_state.world.current_item.name == "Sapphire"
  end

  test "game completion sets status to game_over and calculates winner" do
    # Set up state at the last round, last item, about to resolve
    # Round 8 has 1 item (index 1 in the schedule-position for round 8)
    # With items_per_round = [1,1,2,1,1,2,1,1], total items = 10
    # Round 8 starts at schedule index 9 (last item)
    last_item = %{name: "Shadow Scroll", category: "scroll", base_value: 3}

    state = base_state(%{
      current_round: 8,
      max_rounds: 8,
      current_item_index: 0,
      current_item: last_item,
      high_bid: 5,
      high_bidder: "player_1",
      active_bidders: ["player_3"],
      active_actor_id: "player_3",
      auction_schedule: [
        %{name: "Ruby", category: "gem", base_value: 10},
        %{name: "Sapphire", category: "gem", base_value: 8},
        %{name: "Emerald", category: "gem", base_value: 12},
        %{name: "Crown", category: "artifact", base_value: 15},
        %{name: "Scepter", category: "artifact", base_value: 12},
        %{name: "Chalice", category: "artifact", base_value: 8},
        %{name: "Fire Scroll", category: "scroll", base_value: 7},
        %{name: "Ice Scroll", category: "scroll", base_value: 5},
        %{name: "Lightning Scroll", category: "scroll", base_value: 10},
        last_item
      ]
    })

    assert {:ok, next_state, :skip} =
             Updater.apply_event(state, Events.pass_auction("player_3"), [])

    assert next_state.world.status == "game_over"
    assert next_state.world.winner != nil
    assert next_state.world.scores != %{}
  end
end
