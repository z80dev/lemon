defmodule LemonSim.Examples.Diplomacy.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.UpdaterHelpers, only: [maybe_store_thought: 2]

  alias LemonCore.MapHelpers
  alias LemonSim.State
  alias LemonSim.Examples.Diplomacy.Events

  @win_threshold 7

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)
    state = maybe_store_thought(state, event)

    case event.kind do
      "send_message" -> apply_send_message(state, event)
      "end_diplomacy" -> apply_end_diplomacy(state, event)
      "issue_order" -> apply_issue_order(state, event)
      "submit_orders" -> apply_submit_orders(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  # -- Send Message --

  defp apply_send_message(%State{} = state, event) do
    sender_id = fetch(event.payload, :sender_id, "sender_id")
    recipient_id = fetch(event.payload, :recipient_id, "recipient_id")
    message = fetch(event.payload, :message, "message", "")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "diplomacy"),
         :ok <- ensure_active_actor(state.world, sender_id),
         :ok <- ensure_valid_player(state.world, recipient_id),
         :ok <- ensure_not_self(sender_id, recipient_id),
         :ok <- ensure_message_quota(state.world, sender_id) do
      round = get(state.world, :round, 1)

      # Store message in recipient's inbox
      inbox = get(state.world, :private_messages, %{})
      recipient_inbox = Map.get(inbox, recipient_id, [])

      new_msg = %{
        "from" => sender_id,
        "to" => recipient_id,
        "message" => message,
        "round" => round
      }

      updated_inbox = Map.put(inbox, recipient_id, recipient_inbox ++ [new_msg])

      # Track messages sent count
      sent_counts = get(state.world, :messages_sent_this_round, %{})
      player_sent = Map.get(sent_counts, sender_id, %{})
      round_count = Map.get(player_sent, round, 0) + 1
      updated_sent = Map.put(sent_counts, sender_id, Map.put(player_sent, round, round_count))
      message_history = get(state.world, :message_history, [])

      next_world =
        state.world
        |> Map.put(:private_messages, updated_inbox)
        |> Map.put(:messages_sent_this_round, updated_sent)
        |> Map.put(
          :message_history,
          message_history ++ [%{round: round, from: sender_id, to: recipient_id}]
        )

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.message_delivered(sender_id, recipient_id, message))

      {:ok, next_state, {:decide, "#{sender_id} sent a message, continue diplomacy"}}
    else
      {:error, reason} ->
        reject_action(state, event, sender_id, reason)
    end
  end

  # -- End Diplomacy --

  defp apply_end_diplomacy(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "diplomacy"),
         :ok <- ensure_active_actor(state.world, player_id) do
      diplomacy_done = get(state.world, :diplomacy_done, MapSet.new())
      diplomacy_done = MapSet.put(diplomacy_done, player_id)

      next_world = Map.put(state.world, :diplomacy_done, diplomacy_done)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.diplomacy_ended(player_id))

      alive_players = alive_player_ids(next_world)
      all_done = Enum.all?(alive_players, &MapSet.member?(diplomacy_done, &1))

      if all_done do
        # Transition to orders phase
        next_world2 =
          next_world
          |> Map.put(:phase, "orders")
          |> Map.put(:active_actor_id, List.first(get(next_world, :turn_order, [])))
          |> Map.put(:pending_orders, %{})

        next_state2 =
          next_state
          |> State.update_world(fn _ -> next_world2 end)
          |> State.append_event(Events.phase_changed("diplomacy", "orders"))

        {:ok, next_state2,
         {:decide,
          "all players finished diplomacy, now in orders phase for #{MapHelpers.get_key(next_world2, :active_actor_id)}"}}
      else
        # Advance to next player for diplomacy
        {next_world2, _} = advance_to_next_player(next_world, player_id, diplomacy_done)

        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} finished diplomacy, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Issue Order --

  defp apply_issue_order(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")
    army_territory = fetch(event.payload, :army_territory, "army_territory")
    order_type = fetch(event.payload, :order_type, "order_type")
    target_territory = fetch(event.payload, :target_territory, "target_territory")
    support_target = fetch(event.payload, :support_target, "support_target")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "orders"),
         :ok <- ensure_active_actor(state.world, player_id),
         :ok <- ensure_owns_territory(state.world, player_id, army_territory),
         :ok <- ensure_has_army(state.world, army_territory),
         :ok <- ensure_valid_order_type(order_type),
         :ok <- ensure_valid_target(state.world, army_territory, order_type, target_territory) do
      pending = get(state.world, :pending_orders, %{})
      player_orders = Map.get(pending, player_id, %{})

      order = %{
        "army_territory" => army_territory,
        "order_type" => order_type,
        "target_territory" => target_territory,
        "support_target" => support_target
      }

      updated_player_orders = Map.put(player_orders, army_territory, order)
      updated_pending = Map.put(pending, player_id, updated_player_orders)

      next_world = Map.put(state.world, :pending_orders, updated_pending)

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(
          Events.order_recorded(
            player_id,
            army_territory,
            order_type,
            target_territory,
            support_target
          )
        )

      {:ok, next_state,
       {:decide, "#{player_id} ordered #{army_territory} to #{order_type} #{target_territory}"}}
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Submit Orders --

  defp apply_submit_orders(%State{} = state, event) do
    player_id = fetch(event.payload, :player_id, "player_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_phase(state.world, "orders"),
         :ok <- ensure_active_actor(state.world, player_id) do
      # Fill in hold orders for any unordered armies
      next_world = fill_default_holds(state.world, player_id)
      round = get(next_world, :round, 1)
      order_history = get(next_world, :order_history, [])
      player_orders = Map.get(get(next_world, :pending_orders, %{}), player_id, %{})

      orders_submitted_set = get(next_world, :orders_submitted, MapSet.new())
      orders_submitted_set = MapSet.put(orders_submitted_set, player_id)

      next_world =
        next_world
        |> Map.put(:orders_submitted, orders_submitted_set)
        |> Map.put(
          :order_history,
          order_history ++
            [
              %{
                round: round,
                player: player_id,
                orders: player_orders
              }
            ]
        )

      next_state =
        state
        |> State.update_world(fn _ -> next_world end)
        |> State.append_event(event)
        |> State.append_event(Events.orders_submitted(player_id))

      alive_players = alive_player_ids(next_world)
      all_submitted = Enum.all?(alive_players, &MapSet.member?(orders_submitted_set, &1))

      if all_submitted do
        # Resolve all orders simultaneously
        {resolved_world, resolution_events} = resolve_orders(next_world)

        # Check for winner
        {final_world, game_events} = check_victory(resolved_world)

        next_state2 =
          next_state
          |> State.update_world(fn _ -> final_world end)
          |> State.append_events(resolution_events)
          |> State.append_events(game_events)

        if get(final_world, :status, "in_progress") != "in_progress" do
          {:ok, next_state2, :skip}
        else
          {:ok, next_state2,
           {:decide,
            "round #{get(final_world, :round, 1)} diplomacy phase for #{MapHelpers.get_key(final_world, :active_actor_id)}"}}
        end
      else
        # Advance to next player for orders
        {next_world2, _} =
          advance_to_next_player(next_world, player_id, orders_submitted_set)

        next_state2 = State.update_world(next_state, fn _ -> next_world2 end)

        {:ok, next_state2,
         {:decide,
          "#{player_id} submitted orders, now #{MapHelpers.get_key(next_world2, :active_actor_id)}'s turn to issue orders"}}
      end
    else
      {:error, reason} ->
        reject_action(state, event, player_id, reason)
    end
  end

  # -- Order Resolution --

  defp resolve_orders(world) do
    pending = get(world, :pending_orders, %{})
    territories = get(world, :territories, %{})
    adjacency = get(world, :adjacency, %{})

    # Collect all orders into a flat list
    all_orders =
      Enum.flat_map(pending, fn {player_id, player_orders} ->
        Enum.map(player_orders, fn {_territory, order} ->
          Map.put(order, "player_id", player_id)
        end)
      end)

    # Separate moves and supports
    moves =
      Enum.filter(all_orders, fn o -> Map.get(o, "order_type") == "move" end)

    supports =
      Enum.filter(all_orders, fn o -> Map.get(o, "order_type") == "support" end)

    # Calculate support for each move target
    # Support counts: territory -> player_id -> support_count
    support_counts =
      Enum.reduce(supports, %{}, fn support, acc ->
        target_terr = Map.get(support, "target_territory")
        supported_player = Map.get(support, "support_target")
        support_from = Map.get(support, "army_territory")

        # Support is only valid if the supporting army is adjacent to the target
        if supported_player && territory_adjacent?(adjacency, support_from, target_terr) do
          key = {target_terr, supported_player}
          Map.update(acc, key, 1, &(&1 + 1))
        else
          acc
        end
      end)

    # Group moves by destination
    moves_by_dest =
      Enum.group_by(moves, fn o -> Map.get(o, "target_territory") end)

    # Resolve each contested territory
    capture_history = get(world, :capture_history, [])

    {updated_territories, resolution_events, updated_capture_history} =
      Enum.reduce(moves_by_dest, {territories, [], capture_history}, fn {dest, incoming_moves},
                                                                        {terr_acc, events_acc,
                                                                         capture_acc} ->
        resolve_territory(
          dest,
          incoming_moves,
          support_counts,
          terr_acc,
          events_acc,
          capture_acc,
          get(world, :round, 1)
        )
      end)

    # Handle holds - armies that held keep their territory
    # (they're already there, nothing to do unless attacked)

    # Produce new armies: each owned territory with armies produces +1 army (capped)
    {final_territories, production_events} = produce_armies(updated_territories)

    # Advance to next round
    round = get(world, :round, 1) + 1

    next_world =
      world
      |> Map.put(:territories, final_territories)
      |> Map.put(:round, round)
      |> Map.put(:phase, "diplomacy")
      |> Map.put(:pending_orders, %{})
      |> Map.put(:orders_submitted, MapSet.new())
      |> Map.put(:capture_history, updated_capture_history)
      |> Map.put(:diplomacy_done, MapSet.new())
      |> Map.put(:messages_sent_this_round, %{})
      |> Map.put(:active_actor_id, List.first(get(world, :turn_order, [])))

    all_events =
      resolution_events ++
        production_events ++
        [Events.phase_changed("orders", "diplomacy"), Events.round_advanced(round)]

    {next_world, all_events}
  end

  defp resolve_territory(
         dest,
         incoming_moves,
         support_counts,
         territories,
         events,
         capture_history,
         round
       ) do
    dest_info = Map.get(territories, dest, %{})
    current_owner = get(dest_info, :owner, nil)
    defending_armies = get(dest_info, :armies, 0)

    # Calculate strength of each contender
    contenders =
      incoming_moves
      |> Enum.map(fn move ->
        player_id = Map.get(move, "player_id")
        from = Map.get(move, "army_territory")
        from_info = Map.get(territories, from, %{})
        moving_armies = get(from_info, :armies, 0)
        support = Map.get(support_counts, {dest, player_id}, 0)

        %{
          player_id: player_id,
          from: from,
          strength: moving_armies + support,
          armies: moving_armies
        }
      end)

    # Add defender if territory is owned and no move order from the owner for this territory
    # (i.e., the owner's army is holding)
    owner_is_moving_in =
      Enum.any?(contenders, fn c -> c.player_id == current_owner end)

    defender_strength =
      if current_owner && defending_armies > 0 && !owner_is_moving_in do
        defense_support = Map.get(support_counts, {dest, current_owner}, 0)
        defending_armies + defense_support
      else
        0
      end

    # Find the strongest contender
    max_strength =
      contenders
      |> Enum.map(& &1.strength)
      |> Enum.max(fn -> 0 end)

    effective_max = max(max_strength, defender_strength)

    # Count how many have the max strength
    max_contenders =
      contenders
      |> Enum.filter(&(&1.strength == effective_max))

    defender_ties = defender_strength == effective_max and defender_strength > 0

    cond do
      # No one actually moves
      length(contenders) == 0 ->
        {territories, events, capture_history}

      # Single winner, beats defense
      length(max_contenders) == 1 and !defender_ties ->
        winner = hd(max_contenders)

        # Move armies: remove from source, place at destination
        source_info = Map.get(territories, winner.from, %{})
        updated_source = Map.put(source_info, :armies, 0)

        updated_dest =
          dest_info
          |> Map.put(:owner, winner.player_id)
          |> Map.put(:armies, winner.armies)

        updated_territories =
          territories
          |> Map.put(winner.from, updated_source)
          |> Map.put(dest, updated_dest)

        # Bounce all losers back
        {bounced_territories, bounce_events} =
          contenders
          |> Enum.reject(&(&1.player_id == winner.player_id))
          |> Enum.reduce({updated_territories, []}, fn loser, {t_acc, e_acc} ->
            {t_acc,
             e_acc ++
               [Events.move_resolved(loser.player_id, loser.from, dest, false)]}
          end)

        move_events = [
          Events.move_resolved(winner.player_id, winner.from, dest, true),
          Events.territory_captured(dest, winner.player_id, current_owner)
        ]

        next_capture_history =
          if current_owner != winner.player_id do
            capture_history ++
              [
                %{
                  round: round,
                  territory: dest,
                  attacker: winner.player_id,
                  defender: current_owner
                }
              ]
          else
            capture_history
          end

        {bounced_territories, events ++ move_events ++ bounce_events, next_capture_history}

      # Tie or defender holds - everyone bounces
      true ->
        contestant_ids = Enum.map(contenders, & &1.player_id)

        contestant_ids =
          if defender_ties, do: contestant_ids ++ [current_owner], else: contestant_ids

        bounce_events =
          Enum.map(contenders, fn c ->
            Events.move_resolved(c.player_id, c.from, dest, false)
          end) ++ [Events.bounce(dest, Enum.uniq(contestant_ids))]

        {territories, events ++ bounce_events, capture_history}
    end
  end

  defp produce_armies(territories) do
    Enum.reduce(territories, {territories, []}, fn {name, info}, {t_acc, e_acc} ->
      owner = get(info, :owner, nil)
      armies = get(info, :armies, 0)

      if owner && armies > 0 do
        new_armies = armies + 1
        updated = Map.put(info, :armies, new_armies)
        {Map.put(t_acc, name, updated), e_acc ++ [Events.armies_produced(name, owner)]}
      else
        {t_acc, e_acc}
      end
    end)
  end

  # -- Victory Check --

  defp check_victory(world) do
    territories = get(world, :territories, %{})
    max_rounds = get(world, :max_rounds, 10)
    round = get(world, :round, 1)

    # Count territories per player
    counts = territory_counts(territories)

    # Check for domination victory (7+ territories)
    dominator =
      Enum.find(counts, fn {_player, count} -> count >= @win_threshold end)

    cond do
      dominator ->
        {player, _count} = dominator

        final_world =
          world
          |> Map.put(:status, "won")
          |> Map.put(:winner, player)

        {final_world, [Events.game_over("won", player)]}

      round > max_rounds ->
        # Most territories wins
        {winner, _count} =
          counts
          |> Enum.max_by(fn {_player, count} -> count end, fn -> {nil, 0} end)

        final_world =
          world
          |> Map.put(:status, "won")
          |> Map.put(:winner, winner)

        {final_world, [Events.game_over("won", winner)]}

      true ->
        {world, []}
    end
  end

  defp territory_counts(territories) do
    territories
    |> Enum.reduce(%{}, fn {_name, info}, acc ->
      owner = get(info, :owner, nil)

      if owner do
        Map.update(acc, owner, 1, &(&1 + 1))
      else
        acc
      end
    end)
  end

  # -- Phase Helpers --

  defp advance_to_next_player(world, current_player, done_set) do
    turn_order = get(world, :turn_order, [])
    alive = alive_player_ids(world)

    # Find next player in turn order who is alive and hasn't finished
    remaining =
      turn_order
      |> Enum.filter(&(&1 in alive))
      |> Enum.reject(&MapSet.member?(done_set, &1))

    next_player =
      case remaining do
        [] -> current_player
        [first | _] -> first
      end

    next_world = Map.put(world, :active_actor_id, next_player)
    {next_world, []}
  end

  defp fill_default_holds(world, player_id) do
    territories = get(world, :territories, %{})
    pending = get(world, :pending_orders, %{})
    player_orders = Map.get(pending, player_id, %{})

    # Find owned territories with armies that have no orders
    owned_with_armies =
      territories
      |> Enum.filter(fn {_name, info} ->
        get(info, :owner, nil) == player_id and get(info, :armies, 0) > 0
      end)
      |> Enum.map(fn {name, _info} -> name end)

    filled_orders =
      Enum.reduce(owned_with_armies, player_orders, fn terr, acc ->
        if Map.has_key?(acc, terr) do
          acc
        else
          Map.put(acc, terr, %{
            "army_territory" => terr,
            "order_type" => "hold",
            "target_territory" => terr,
            "support_target" => nil
          })
        end
      end)

    updated_pending = Map.put(pending, player_id, filled_orders)
    Map.put(world, :pending_orders, updated_pending)
  end

  defp alive_player_ids(world) do
    players = get(world, :players, %{})

    players
    |> Enum.filter(fn {_id, info} -> get(info, :status, "alive") == "alive" end)
    |> Enum.map(fn {id, _info} -> id end)
  end

  defp territory_adjacent?(adjacency, from, to) do
    neighbors = Map.get(adjacency, from, [])
    to in neighbors
  end

  # -- Validation --

  defp ensure_in_progress(world) do
    if get(world, :status, "in_progress") == "in_progress",
      do: :ok,
      else: {:error, :game_over}
  end

  defp ensure_phase(world, expected_phase) do
    if get(world, :phase, nil) == expected_phase,
      do: :ok,
      else: {:error, :wrong_phase}
  end

  defp ensure_active_actor(world, player_id) do
    if MapHelpers.get_key(world, :active_actor_id) == player_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  defp ensure_valid_player(world, player_id) do
    players = get(world, :players, %{})

    if Map.has_key?(players, player_id),
      do: :ok,
      else: {:error, :invalid_player}
  end

  defp ensure_not_self(sender_id, recipient_id) do
    if sender_id != recipient_id,
      do: :ok,
      else: {:error, :cannot_message_self}
  end

  defp ensure_message_quota(world, player_id) do
    round = get(world, :round, 1)
    sent_counts = get(world, :messages_sent_this_round, %{})
    player_sent = Map.get(sent_counts, player_id, %{})
    count = Map.get(player_sent, round, 0)

    if count < 2,
      do: :ok,
      else: {:error, :message_quota_exceeded}
  end

  defp ensure_owns_territory(world, player_id, territory) do
    territories = get(world, :territories, %{})
    info = Map.get(territories, territory, %{})

    if get(info, :owner, nil) == player_id,
      do: :ok,
      else: {:error, :not_owner}
  end

  defp ensure_has_army(world, territory) do
    territories = get(world, :territories, %{})
    info = Map.get(territories, territory, %{})

    if get(info, :armies, 0) > 0,
      do: :ok,
      else: {:error, :no_army}
  end

  defp ensure_valid_order_type(order_type) when order_type in ["move", "hold", "support"], do: :ok
  defp ensure_valid_order_type(_), do: {:error, :invalid_order_type}

  defp ensure_valid_target(world, army_territory, order_type, target_territory) do
    adjacency = get(world, :adjacency, %{})

    case order_type do
      "hold" ->
        :ok

      "move" ->
        if territory_adjacent?(adjacency, army_territory, target_territory),
          do: :ok,
          else: {:error, :not_adjacent}

      "support" ->
        if territory_adjacent?(adjacency, army_territory, target_territory),
          do: :ok,
          else: {:error, :not_adjacent}
    end
  end

  # -- Error handling --

  defp reject_action(%State{} = state, event, player_id, reason) do
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
  defp rejection_reason(:wrong_phase), do: "wrong phase for this action"
  defp rejection_reason(:not_active_actor), do: "not the active player"
  defp rejection_reason(:invalid_player), do: "invalid player id"
  defp rejection_reason(:cannot_message_self), do: "cannot send message to yourself"
  defp rejection_reason(:message_quota_exceeded), do: "message quota exceeded (max 2 per round)"
  defp rejection_reason(:not_owner), do: "you do not own that territory"
  defp rejection_reason(:no_army), do: "no army in that territory"
  defp rejection_reason(:invalid_order_type), do: "invalid order type (use move/hold/support)"
  defp rejection_reason(:not_adjacent), do: "target territory is not adjacent"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"

  # -- Utility --

end
