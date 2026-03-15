defmodule LemonSim.Examples.Auction.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.Auction.{Events, Items}

  @min_increment 2

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "place_bid" -> apply_place_bid(state, event)
      "pass_auction" -> apply_pass_auction(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Place Bid --

  defp apply_place_bid(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    amount = fetch(event.payload, :amount, "amount")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_bidding_phase(state.world),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_active_bidder(state.world, player_id),
         {:ok, player} <- fetch_player(state.world, player_id),
         :ok <- ensure_valid_bid(state.world, player, amount) do
      current_item = get(state.world, :current_item, %{})
      item_name = get(current_item, :name, "Unknown")

      next_world =
        state.world
        |> Map.put(:high_bid, amount)
        |> Map.put(:high_bidder, player_id)
        |> Map.put(
          :bid_history,
          get(state.world, :bid_history, []) ++ [{player_id, amount}]
        )

      action_events = [
        Events.bid_accepted(player_id, amount, item_name)
      ]

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> append_events(action_events)

      # Advance to next bidder
      advance_bidding(next_state)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Pass Auction --

  defp apply_pass_auction(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_bidding_phase(state.world),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_active_bidder(state.world, player_id) do
      active_bidders = get(state.world, :active_bidders, [])
      remaining_bidders = List.delete(active_bidders, player_id)

      next_world =
        state.world
        |> Map.put(:active_bidders, remaining_bidders)

      action_events = [Events.player_passed(player_id)]

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> append_events(action_events)

      # Check if auction resolves
      resolve_after_pass(next_state, remaining_bidders)
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Bidding Advancement --

  defp advance_bidding(%State{} = state) do
    active_bidders = get(state.world, :active_bidders, [])
    current_actor = MapHelpers.get_key(state.world, :active_actor_id)

    # Find the next bidder after the current one
    next_actor = next_bidder(active_bidders, current_actor)

    # If the next bidder is the high bidder and they're the only one who hasn't had a chance
    # to respond to the latest bid, continue cycling
    high_bidder = get(state.world, :high_bidder, nil)

    if length(active_bidders) <= 1 do
      # Only one bidder left (the one who just bid), resolve
      resolve_auction(state)
    else
      next_state = State.update_world(state, fn w -> Map.put(w, :active_actor_id, next_actor) end)
      {:ok, next_state, {:decide, "#{next_actor}'s turn to bid (high bid: #{get(state.world, :high_bid, 0)} by #{high_bidder})"}}
    end
  end

  defp resolve_after_pass(%State{} = state, remaining_bidders) do
    high_bidder = get(state.world, :high_bidder, nil)

    cond do
      # No bidders left and no high bidder - item unsold
      length(remaining_bidders) == 0 and is_nil(high_bidder) ->
        resolve_auction_unsold(state)

      # Only one bidder left - they win (even if they haven't bid, the item resolves)
      length(remaining_bidders) == 1 and not is_nil(high_bidder) ->
        resolve_auction(state)

      # No bidders left but there was a high bidder - they win
      length(remaining_bidders) == 0 and not is_nil(high_bidder) ->
        resolve_auction(state)

      # Multiple bidders remain - continue to next bidder
      true ->
        current_actor = MapHelpers.get_key(state.world, :active_actor_id)
        next_actor = next_bidder(remaining_bidders, current_actor)

        next_state =
          State.update_world(state, fn w -> Map.put(w, :active_actor_id, next_actor) end)

        {:ok, next_state, {:decide, "#{next_actor}'s turn to bid"}}
    end
  end

  # -- Auction Resolution --

  defp resolve_auction(%State{} = state) do
    high_bidder = get(state.world, :high_bidder, nil)
    high_bid = get(state.world, :high_bid, 0)
    current_item = get(state.world, :current_item, %{})
    item_name = get(current_item, :name, "Unknown")
    category = get(current_item, :category, "unknown")

    if is_nil(high_bidder) or high_bid == 0 do
      resolve_auction_unsold(state)
    else
      # Award item to winner
      players = get(state.world, :players, %{})
      winner = Map.get(players, high_bidder, %{})
      winner_gold = get(winner, :gold, 0)
      winner_items = get(winner, :items, [])

      updated_winner =
        winner
        |> Map.put(:gold, winner_gold - high_bid)
        |> Map.put(:items, winner_items ++ [current_item])

      updated_players = Map.put(players, high_bidder, updated_winner)

      # Track auction result
      auction_results = get(state.world, :auction_results, [])

      new_result = %{
        item: item_name,
        category: category,
        winner: high_bidder,
        price: high_bid
      }

      action_events = [Events.item_won(high_bidder, item_name, category, high_bid)]

      next_world =
        state.world
        |> Map.put(:players, updated_players)
        |> Map.put(:auction_results, auction_results ++ [new_result])

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> append_events(action_events)

      # Move to next item or next round
      advance_to_next_item(next_state)
    end
  end

  defp resolve_auction_unsold(%State{} = state) do
    current_item = get(state.world, :current_item, %{})
    item_name = get(current_item, :name, "Unknown")

    action_events = [Events.item_unsold(item_name)]

    next_state = append_events(state, action_events)

    advance_to_next_item(next_state)
  end

  # -- Round/Item Advancement --

  defp advance_to_next_item(%State{} = state) do
    schedule = get(state.world, :auction_schedule, [])
    current_item_index = get(state.world, :current_item_index, 0)
    items_per_round = Items.items_per_round()
    current_round = get(state.world, :current_round, 1)

    # Calculate which item in the schedule we're at
    # Sum items from previous rounds + current index within round
    items_before_round =
      items_per_round
      |> Enum.take(current_round - 1)
      |> Enum.sum()

    round_item_count = Enum.at(items_per_round, current_round - 1, 1)
    next_item_in_round = current_item_index + 1

    cond do
      # More items this round
      next_item_in_round < round_item_count ->
        global_index = items_before_round + next_item_in_round
        next_item = Enum.at(schedule, global_index)

        if is_nil(next_item) do
          finish_game(state)
        else
          start_new_auction(state, next_item, current_round, next_item_in_round)
        end

      # Move to next round
      current_round < get(state.world, :max_rounds, 8) ->
        next_round = current_round + 1
        items_before_next = items_before_round + round_item_count
        next_item = Enum.at(schedule, items_before_next)

        if is_nil(next_item) do
          finish_game(state)
        else
          round_events = [Events.round_started(next_round, [next_item])]

          next_state =
            state
            |> State.update_world(fn w -> Map.put(w, :current_round, next_round) end)
            |> append_events(round_events)

          start_new_auction(next_state, next_item, next_round, 0)
        end

      # All rounds complete
      true ->
        finish_game(state)
    end
  end

  defp start_new_auction(%State{} = state, item, round, item_index) do
    player_ids = get(state.world, :turn_order, [])
    item_name = get(item, :name, "Unknown")
    category = get(item, :category, "unknown")
    base_value = get(item, :base_value, 0)

    # All players with gold > 0 can participate
    players = get(state.world, :players, %{})

    active_bidders =
      player_ids
      |> Enum.filter(fn pid ->
        player = Map.get(players, pid, %{})
        get(player, :gold, 0) > 0 and get(player, :status, "active") == "active"
      end)

    first_bidder = List.first(active_bidders)

    auction_events = [Events.auction_started(item_name, category, base_value)]

    next_world =
      state.world
      |> Map.put(:current_item, item)
      |> Map.put(:current_item_index, item_index)
      |> Map.put(:current_round, round)
      |> Map.put(:high_bid, 0)
      |> Map.put(:high_bidder, nil)
      |> Map.put(:active_bidders, active_bidders)
      |> Map.put(:bid_history, [])
      |> Map.put(:active_actor_id, first_bidder)

    next_state =
      state
      |> State.update_world(fn _ -> next_world end)
      |> append_events(auction_events)

    if is_nil(first_bidder) do
      # No one can bid, skip this item
      resolve_auction_unsold(next_state)
    else
      {:ok, next_state, {:decide, "#{first_bidder} opens bidding on #{item_name} (#{category}, base value: #{base_value})"}}
    end
  end

  # -- Game Finish --

  defp finish_game(%State{} = state) do
    players = get(state.world, :players, %{})
    turn_order = get(state.world, :turn_order, [])
    auction_results = get(state.world, :auction_results, [])

    # Calculate game stats
    gold_spent =
      Enum.into(turn_order, %{}, fn pid ->
        player = Map.get(players, pid, %{})
        spent = 100 - get(player, :gold, 0)
        {pid, spent}
      end)

    auction_wins =
      auction_results
      |> Enum.reduce(%{}, fn result, acc ->
        winner = get(result, :winner, nil)
        if winner, do: Map.update(acc, winner, 1, &(&1 + 1)), else: acc
      end)

    game_stats = %{gold_spent: gold_spent, auction_wins: auction_wins}

    # Calculate scores
    scores =
      Enum.into(turn_order, %{}, fn pid ->
        player = Map.get(players, pid, %{}) |> Map.put(:id, pid)
        score = Items.calculate_score(player, game_stats)
        {pid, score}
      end)

    # Find winner
    {winner_id, _winner_score} =
      scores
      |> Enum.max_by(fn {_pid, score} -> Map.get(score, :total, 0) end)

    action_events = [
      Events.scoring_complete(scores),
      Events.game_over(winner_id, scores)
    ]

    next_world =
      state.world
      |> Map.put(:phase, "game_over")
      |> Map.put(:status, "game_over")
      |> Map.put(:winner, winner_id)
      |> Map.put(:scores, scores)
      |> Map.put(:active_actor_id, nil)

    next_state =
      state
      |> State.update_world(fn _ -> next_world end)
      |> append_events(action_events)

    {:ok, next_state, :skip}
  end

  # -- Validation Helpers --

  defp ensure_in_progress(world) do
    if get(world, :status, "in_progress") == "in_progress", do: :ok, else: {:error, :game_over}
  end

  defp ensure_bidding_phase(world) do
    if get(world, :phase, "bidding") == "bidding", do: :ok, else: {:error, :wrong_phase}
  end

  defp ensure_active_actor(world, player_id) do
    if MapHelpers.get_key(world, :active_actor_id) == player_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  defp ensure_active_bidder(world, player_id) do
    active_bidders = get(world, :active_bidders, [])
    if player_id in active_bidders, do: :ok, else: {:error, :not_active_bidder}
  end

  defp fetch_player(world, player_id) when is_binary(player_id) do
    case get(world, :players, %{}) |> Map.get(player_id) do
      nil -> {:error, :unknown_player}
      player -> {:ok, player}
    end
  end

  defp fetch_player(_world, _player_id), do: {:error, :invalid_player}

  defp ensure_valid_bid(world, player, amount) do
    high_bid = get(world, :high_bid, 0)
    gold = get(player, :gold, 0)
    min_bid = high_bid + @min_increment

    cond do
      not is_integer(amount) -> {:error, :invalid_amount}
      amount < min_bid -> {:error, :bid_too_low}
      amount > gold -> {:error, :insufficient_gold}
      true -> :ok
    end
  end

  # -- Utility --

  defp next_bidder(active_bidders, current_actor) do
    case Enum.find_index(active_bidders, &(&1 == current_actor)) do
      nil ->
        List.first(active_bidders)

      idx ->
        next_idx = rem(idx + 1, length(active_bidders))
        Enum.at(active_bidders, next_idx)
    end
  end

  defp reject_action(state, event, player_id, reason) do
    message = rejection_reason(reason)

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(
        Events.action_rejected(event.kind, to_string(player_id || "unknown"), message)
      )

    {:ok, next_state, {:decide, message}}
  end

  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(:wrong_phase), do: "not in bidding phase"
  defp rejection_reason(:not_active_actor), do: "not the active actor"
  defp rejection_reason(:not_active_bidder), do: "not an active bidder"
  defp rejection_reason(:unknown_player), do: "unknown player"
  defp rejection_reason(:invalid_player), do: "invalid player"
  defp rejection_reason(:invalid_amount), do: "bid amount must be an integer"
  defp rejection_reason(:bid_too_low), do: "bid must be at least high bid + 2"
  defp rejection_reason(:insufficient_gold), do: "not enough gold"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"

  defp append_events(%State{} = state, events) do
    State.append_events(state, Enum.reject(events, &is_nil/1))
  end

end
