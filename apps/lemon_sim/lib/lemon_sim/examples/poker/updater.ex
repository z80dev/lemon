defmodule LemonSim.Examples.Poker.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  require Logger

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.Poker.Engine.Table
  alias LemonSim.Examples.Poker.Events
  alias LemonSim.State

  @max_consecutive_rejections 3

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "poker_action" -> apply_poker_action(state, event)
      "player_note" -> apply_player_note(state, event)
      _ -> {:ok, State.append_event(state, event), :skip}
    end
  end

  defp apply_poker_action(%State{} = state, event) do
    table = MapHelpers.get_key(state.world, :table)
    payload = event.payload || %{}

    with :ok <- ensure_in_progress(state),
         :ok <- ensure_hand_available(table),
         {:ok, seat, player_id, action, engine_action} <- parse_action(payload),
         :ok <- ensure_current_actor(table, seat, player_id),
         {:ok, next_table} <- Table.act(table, seat, engine_action) do
      event = enrich_action_event(event, table, engine_action)

      {final_table, world_updates, derived_events, signal} =
        state.world
        |> update_player_action_stats(table, seat, action)
        |> Map.put(:consecutive_rejections, %{})
        |> advance_world(table, next_table)

      next_state =
        state
        |> State.put_world(Map.put(world_updates, :table, final_table))
        |> State.append_event(event)
        |> State.append_events(derived_events)

      {:ok, next_state, signal}
    else
      {:error, reason} ->
        handle_rejection(state, table, payload, reason)
    end
  end

  defp apply_player_note(%State{} = state, event) do
    payload = event.payload || %{}
    player_id = Map.get(payload, "player_id", Map.get(payload, :player_id))

    note = %{
      "content" => Map.get(payload, "content", Map.get(payload, :content, "")),
      "hand_id" => Map.get(payload, "hand_id", Map.get(payload, :hand_id)),
      "street" => Map.get(payload, "street", Map.get(payload, :street)),
      "ts_ms" => event.ts_ms
    }

    next_world =
      update_in(state.world, [:player_notes], fn notes ->
        Map.update(notes || %{}, player_id, [note], &(&1 ++ [note]))
      end)

    {:ok, state |> State.put_world(next_world) |> State.append_event(event), :skip}
  end

  defp advance_world(world, previous_table, next_table) do
    completed_hands_before = MapHelpers.get_key(world, :completed_hands) || 0
    hand_completed? = is_nil(next_table.hand) and is_map(next_table.last_hand_result)

    world =
      if hand_completed? do
        finalize_completed_hand_stats(world, previous_table, next_table.last_hand_result)
      else
        world
      end

    completed_hands =
      if hand_completed?, do: completed_hands_before + 1, else: completed_hands_before

    derived_events =
      if hand_completed? do
        [Events.hand_completed(next_table.last_hand_result, next_table.seats)]
      else
        []
      end

    cond do
      terminal_state?(next_table, completed_hands, MapHelpers.get_key(world, :max_hands) || 1) ->
        winner_ids = winner_ids(next_table)
        chip_counts = chip_counts(next_table)
        reason = game_over_reason(next_table, completed_hands, world)

        updates =
          base_world_updates(world, next_table, completed_hands)
          |> Map.put(:status, "game_over")
          |> Map.put(:winner, List.first(winner_ids))
          |> Map.put(:winner_ids, winner_ids)
          |> Map.put(:game_over_reason, reason)
          |> Map.put(:consecutive_rejections, %{})

        game_over = Events.game_over(reason, winner_ids, chip_counts, completed_hands)
        {next_table, updates, derived_events ++ [game_over], :skip}

      hand_completed? ->
        restart_seed = hand_seed(world, completed_hands + 1)
        next_hand_number = completed_hands + 1
        {small_blind, big_blind} = Poker.blind_schedule_for_hand(world, next_hand_number)

        with {:ok, blind_adjusted_table} <- Table.set_blinds(next_table, small_blind, big_blind),
             {:ok, restarted_table} <- Table.start_hand(blind_adjusted_table, seed: restart_seed) do
          updates =
            world
            |> reset_current_hand_flags()
            |> base_world_updates(restarted_table, completed_hands)
            |> Map.put(:status, "in_progress")
            |> Map.put(:winner, nil)
            |> Map.put(:winner_ids, [])
            |> Map.put(:game_over_reason, nil)
            |> Map.put(:consecutive_rejections, %{})

          started = Events.hand_started(restarted_table.hand, restarted_table.seats)
          {restarted_table, updates, derived_events ++ [started], {:decide, "next hand"}}
        else
          {:error, _reason} ->
            winner_ids = winner_ids(next_table)
            chip_counts = chip_counts(next_table)

            updates =
              base_world_updates(world, next_table, completed_hands)
              |> Map.put(:status, "game_over")
              |> Map.put(:winner, List.first(winner_ids))
              |> Map.put(:winner_ids, winner_ids)
              |> Map.put(:game_over_reason, :table_stalled)
              |> Map.put(:consecutive_rejections, %{})

            game_over =
              Events.game_over(:table_stalled, winner_ids, chip_counts, completed_hands)

            {next_table, updates, derived_events ++ [game_over], :skip}
        end

      true ->
        updates =
          base_world_updates(world, next_table, completed_hands)
          |> Map.put(:status, "in_progress")
          |> Map.put(:winner, nil)
          |> Map.put(:winner_ids, [])
          |> Map.put(:game_over_reason, nil)

        {next_table, updates, derived_events, {:decide, "next action"}}
    end
  end

  defp base_world_updates(world, table, completed_hands) do
    {current_seat, current_actor_id} = current_actor(table)

    world
    |> Map.merge(%{
      current_actor_id: current_actor_id,
      current_seat: current_seat,
      active_actor_id: current_actor_id,
      completed_hands: completed_hands,
      last_hand_result: table.last_hand_result,
      chip_counts: chip_counts(table),
      player_count: MapHelpers.get_key(world, :player_count),
      small_blind: table.small_blind,
      big_blind: table.big_blind
    })
  end

  defp parse_action(payload) when is_map(payload) do
    seat = Map.get(payload, "seat", Map.get(payload, :seat))
    player_id = Map.get(payload, "player_id", Map.get(payload, :player_id))
    raw_action = Map.get(payload, "action", Map.get(payload, :action))
    total = Map.get(payload, "total", Map.get(payload, :total))

    action = normalize_action(raw_action)

    cond do
      not is_integer(seat) ->
        {:error, :invalid_seat}

      not is_binary(player_id) or player_id == "" ->
        {:error, :invalid_player}

      action in [:fold, :check, :call] ->
        {:ok, seat, player_id, action, action}

      action in [:bet, :raise] and is_integer(total) ->
        {:ok, seat, player_id, action, {action, total}}

      action in [:bet, :raise] ->
        {:error, :invalid_amount}

      true ->
        {:error, :invalid_action}
    end
  end

  defp parse_action(_payload), do: {:error, :invalid_payload}

  defp normalize_action(value) when is_atom(value), do: value

  defp normalize_action(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :invalid
  end

  defp normalize_action(_value), do: :invalid

  defp ensure_in_progress(state) do
    if MapHelpers.get_key(state.world, :status) == "in_progress" do
      :ok
    else
      {:error, :game_over}
    end
  end

  defp ensure_hand_available(%Table{hand: %Table.Hand{}}), do: :ok
  defp ensure_hand_available(_table), do: {:error, :no_hand_in_progress}

  defp ensure_current_actor(%Table{hand: %Table.Hand{} = hand}, seat, player_id) do
    cond do
      hand.acting_seat != seat ->
        {:error, :not_your_turn}

      true ->
        player = Map.get(hand.players, seat)

        if player && player.player_id == player_id do
          :ok
        else
          {:error, :invalid_player}
        end
    end
  end

  defp handle_rejection(state, table, payload, reason) do
    player_id = Map.get(payload, "player_id", Map.get(payload, :player_id))
    seat = Map.get(payload, "seat", Map.get(payload, :seat))
    action = Map.get(payload, "action", Map.get(payload, :action))
    message = rejection_message(reason)
    rejection = Events.action_rejected(player_id, seat, action, reason, message)

    if auto_fold?(state.world, table, player_id, seat) do
      do_auto_fold(state, table, rejection)
    else
      next_world =
        if current_actor_rejection?(table, player_id, seat) do
          increment_rejection_count(state.world, player_id)
        else
          state.world
        end

      {:ok, state |> State.put_world(next_world) |> State.append_event(rejection),
       {:decide, message}}
    end
  end

  defp auto_fold?(world, table, player_id, seat) do
    {current_seat, current_actor_id} = current_actor(table)
    count = Map.get(MapHelpers.get_key(world, :consecutive_rejections) || %{}, player_id, 0)

    player_id == current_actor_id and seat == current_seat and
      count + 1 >= @max_consecutive_rejections
  end

  defp current_actor_rejection?(%Table{hand: %Table.Hand{} = hand}, player_id, seat) do
    current_seat = hand.acting_seat
    current_actor_id = hand.players[current_seat] && hand.players[current_seat].player_id
    player_id == current_actor_id and seat == current_seat
  end

  defp current_actor_rejection?(_table, _player_id, _seat), do: false

  defp do_auto_fold(state, table, rejection) do
    {seat, player_id} = current_actor(table)

    Logger.warning("Poker auto-fold after repeated rejected actions for #{player_id}")

    fold_event =
      Events.player_action(player_id, seat, :fold, nil, %{"auto_fold" => true})

    {:ok, next_table} = Table.act(table, seat, :fold)

    {final_table, world_updates, derived_events, signal} =
      state.world
      |> increment_rejection_count(player_id)
      |> update_player_action_stats(table, seat, :fold)
      |> reset_rejection_count(player_id)
      |> advance_world(table, next_table)

    next_state =
      state
      |> State.put_world(Map.put(world_updates, :table, final_table))
      |> State.append_event(rejection)
      |> State.append_event(fold_event)
      |> State.append_events(derived_events)

    {:ok, next_state, signal}
  end

  defp increment_rejection_count(world, nil), do: world

  defp increment_rejection_count(world, player_id) do
    update_in(world, [:consecutive_rejections], fn counts ->
      Map.update(counts || %{}, player_id, 1, &(&1 + 1))
    end)
  end

  defp reset_rejection_count(world, nil), do: world

  defp reset_rejection_count(world, player_id) do
    update_in(world, [:consecutive_rejections], fn counts ->
      Map.put(counts || %{}, player_id, 0)
    end)
  end

  defp update_player_action_stats(world, %Table{hand: %Table.Hand{} = hand}, seat, action) do
    player_stats = MapHelpers.get_key(world, :player_stats) || %{}

    case Map.get(hand.players, seat) do
      %{player_id: player_id} ->
        updated =
          update_in(player_stats, [player_id], fn stats ->
            stats
            |> Map.update!(:total_actions, &(&1 + 1))
            |> increment_action_counter(action)
            |> maybe_mark_vpip(hand.street, action)
            |> maybe_mark_pfr(hand.street, action)
          end)

        Map.put(world, :player_stats, updated)

      _ ->
        world
    end
  end

  defp update_player_action_stats(world, _table, _seat, _action), do: world

  defp increment_action_counter(stats, :fold), do: Map.update!(stats, :fold_count, &(&1 + 1))
  defp increment_action_counter(stats, :check), do: Map.update!(stats, :check_count, &(&1 + 1))
  defp increment_action_counter(stats, :call), do: Map.update!(stats, :call_count, &(&1 + 1))
  defp increment_action_counter(stats, :bet), do: Map.update!(stats, :bet_count, &(&1 + 1))
  defp increment_action_counter(stats, :raise), do: Map.update!(stats, :raise_count, &(&1 + 1))
  defp increment_action_counter(stats, _action), do: stats

  defp maybe_mark_vpip(stats, :preflop, action) when action in [:call, :bet, :raise] do
    current_hand = Map.get(stats, :current_hand, %{})

    if Map.get(current_hand, :vpip, false) do
      stats
    else
      stats
      |> Map.update!(:vpip_hands, &(&1 + 1))
      |> put_in([:current_hand, :vpip], true)
    end
  end

  defp maybe_mark_vpip(stats, _street, _action), do: stats

  defp maybe_mark_pfr(stats, :preflop, action) when action in [:bet, :raise] do
    current_hand = Map.get(stats, :current_hand, %{})

    if Map.get(current_hand, :pfr, false) do
      stats
    else
      stats
      |> Map.update!(:pfr_hands, &(&1 + 1))
      |> put_in([:current_hand, :pfr], true)
    end
  end

  defp maybe_mark_pfr(stats, _street, _action), do: stats

  defp finalize_completed_hand_stats(world, previous_table, result) do
    participants =
      previous_table.hand.players
      |> Map.values()
      |> Enum.map(& &1.player_id)

    winner_ids =
      result
      |> Map.get(:winners, %{})
      |> Map.keys()
      |> Enum.map(fn seat ->
        case Map.get(previous_table.seats, seat) do
          %{player_id: player_id} -> player_id
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    updated_stats =
      (MapHelpers.get_key(world, :player_stats) || %{})
      |> Enum.into(%{}, fn {player_id, stats} ->
        {player_id,
         stats
         |> maybe_increment_hands_played(player_id in participants)
         |> maybe_increment_hands_won(player_id in winner_ids)
         |> Map.put(:current_hand, %{vpip: false, pfr: false})}
      end)

    Map.put(world, :player_stats, updated_stats)
  end

  defp maybe_increment_hands_played(stats, true),
    do: Map.update!(stats, :hands_played, &(&1 + 1))

  defp maybe_increment_hands_played(stats, false), do: stats

  defp maybe_increment_hands_won(stats, true), do: Map.update!(stats, :hands_won, &(&1 + 1))
  defp maybe_increment_hands_won(stats, false), do: stats

  defp reset_current_hand_flags(world) do
    player_stats = MapHelpers.get_key(world, :player_stats) || %{}

    Map.put(
      world,
      :player_stats,
      Enum.into(player_stats, %{}, fn {player_id, stats} ->
        {player_id, Map.put(stats, :current_hand, %{vpip: false, pfr: false})}
      end)
    )
  end

  defp enrich_action_event(event, %Table{hand: %Table.Hand{} = hand}, engine_action) do
    payload =
      event.payload
      |> Map.put_new("hand_id", hand.id)
      |> Map.put_new("street", to_string(hand.street))
      |> maybe_put_amount(hand, engine_action)

    %{event | payload: payload}
  end

  defp enrich_action_event(event, _table, _engine_action), do: event

  defp maybe_put_amount(payload, hand, :call) do
    seat = Map.get(payload, "seat", Map.get(payload, :seat))
    player = hand.players[seat]
    committed_round = if player, do: player.committed_round, else: 0
    amount = max(hand.to_call - committed_round, 0)

    Map.put_new(payload, "amount", amount)
  end

  defp maybe_put_amount(payload, _hand, {:bet, total}),
    do: Map.put_new(payload, "amount", total)

  defp maybe_put_amount(payload, _hand, {:raise, total}),
    do: Map.put_new(payload, "amount", total)

  defp maybe_put_amount(payload, _hand, _action), do: payload

  defp terminal_state?(table, completed_hands, max_hands) do
    remaining_players =
      table.seats
      |> Enum.filter(fn {_seat, player} -> player.status != :busted and player.stack > 0 end)
      |> length()

    remaining_players <= 1 or completed_hands >= max_hands
  end

  defp winner_ids(table) do
    surviving =
      table.seats
      |> Enum.filter(fn {_seat, player} -> player.status != :busted and player.stack > 0 end)

    cond do
      length(surviving) == 1 ->
        surviving
        |> Enum.map(fn {_seat, player} -> player.player_id end)

      true ->
        max_stack =
          table.seats
          |> Enum.map(fn {_seat, player} -> player.stack end)
          |> Enum.max(fn -> 0 end)

        table.seats
        |> Enum.filter(fn {_seat, player} -> player.stack == max_stack end)
        |> Enum.map(fn {_seat, player} -> player.player_id end)
        |> Enum.sort()
    end
  end

  defp chip_counts(table) do
    table.seats
    |> Enum.sort_by(fn {seat, _player} -> seat end)
    |> Enum.map(fn {seat, player} ->
      %{
        "seat" => seat,
        "player_id" => player.player_id,
        "stack" => player.stack,
        "status" => to_string(player.status)
      }
    end)
  end

  defp game_over_reason(table, completed_hands, world) do
    remaining_players =
      table.seats
      |> Enum.filter(fn {_seat, player} -> player.status != :busted and player.stack > 0 end)
      |> length()

    cond do
      remaining_players <= 1 ->
        :last_player_standing

      completed_hands >= (MapHelpers.get_key(world, :max_hands) || 1) ->
        :hand_limit

      true ->
        :table_stalled
    end
  end

  defp current_actor(%Table{hand: %Table.Hand{} = hand}) do
    case hand.acting_seat do
      nil ->
        {nil, nil}

      seat ->
        player = Map.get(hand.players, seat)
        {seat, player && player.player_id}
    end
  end

  defp current_actor(_table), do: {nil, nil}

  defp hand_seed(world, hand_number) do
    (MapHelpers.get_key(world, :base_seed) || 1) + hand_number - 1
  end

  defp rejection_message(:game_over), do: "hand already finished"
  defp rejection_message(:no_hand_in_progress), do: "no hand in progress"
  defp rejection_message(:invalid_action), do: "invalid action"
  defp rejection_message(:invalid_amount), do: "invalid amount"
  defp rejection_message(:invalid_payload), do: "invalid payload"
  defp rejection_message(:invalid_player), do: "invalid player"
  defp rejection_message(:invalid_seat), do: "invalid seat"
  defp rejection_message(:not_your_turn), do: "not your turn"
  defp rejection_message(:hand_in_progress), do: "hand already in progress"
  defp rejection_message(:not_enough_players), do: "not enough players"
  defp rejection_message(other), do: "action rejected: #{inspect(other)}"
end
