defmodule LemonPoker.View do
  @moduledoc false

  alias LemonPoker.{Card, Table}

  @spec table_snapshot(Table.t() | nil, keyword()) :: map() | nil
  def table_snapshot(table, opts \\ [])
  def table_snapshot(nil, _opts), do: nil

  def table_snapshot(%Table{} = table, opts) do
    show_hole_cards = Keyword.get(opts, :show_hole_cards, true)

    %{
      id: table.id,
      max_seats: table.max_seats,
      small_blind: table.small_blind,
      big_blind: table.big_blind,
      button_seat: table.button_seat,
      hand_id: table.hand_id,
      seats:
        table.seats
        |> Enum.map(fn {seat, player} ->
          %{
            seat: seat,
            player_id: player.player_id,
            stack: player.stack,
            status: player.status
          }
        end)
        |> Enum.sort_by(& &1.seat),
      hand: hand_snapshot(table.hand, show_hole_cards),
      legal_actions: legal_actions_snapshot(table),
      last_hand_result: hand_result_snapshot(table.last_hand_result)
    }
  end

  @spec seat_configs_snapshot(map()) :: [map()]
  def seat_configs_snapshot(seat_configs) when is_map(seat_configs) do
    seat_configs
    |> Enum.map(fn {seat, cfg} ->
      %{
        seat: seat,
        label: cfg.label,
        agent_id: cfg.agent_id,
        session_key: cfg.session_key
      }
    end)
    |> Enum.sort_by(& &1.seat)
  end

  defp hand_snapshot(nil, _show_hole_cards), do: nil

  defp hand_snapshot(hand, show_hole_cards) do
    %{
      id: hand.id,
      street: hand.street,
      button_seat: hand.button_seat,
      small_blind_seat: hand.small_blind_seat,
      big_blind_seat: hand.big_blind_seat,
      board: cards_to_strings(hand.board),
      pot: hand.pot,
      to_call: hand.to_call,
      min_raise: hand.min_raise,
      acting_seat: hand.acting_seat,
      action_queue: hand.action_queue,
      players:
        hand.players
        |> Enum.map(fn {seat, player} ->
          %{
            seat: seat,
            player_id: player.player_id,
            stack: player.stack,
            hole_cards: if(show_hole_cards, do: cards_to_strings(player.hole_cards), else: []),
            committed_round: player.committed_round,
            committed_total: player.committed_total,
            folded: player.folded,
            all_in: player.all_in,
            can_raise: player.can_raise
          }
        end)
        |> Enum.sort_by(& &1.seat)
    }
  end

  defp legal_actions_snapshot(%Table{hand: nil}), do: nil

  defp legal_actions_snapshot(table) do
    case Table.legal_actions(table) do
      {:ok, legal} ->
        %{
          seat: legal.seat,
          street: legal.street,
          to_call: legal.to_call,
          options: legal.options,
          bet: legal.bet,
          raise: legal.raise
        }

      _ ->
        nil
    end
  end

  defp hand_result_snapshot(nil), do: nil

  defp hand_result_snapshot(result) when is_map(result) do
    %{
      hand_id: Map.get(result, :hand_id) || Map.get(result, "hand_id"),
      board: normalize_card_strings(Map.get(result, :board) || Map.get(result, "board") || []),
      winners:
        result
        |> fetch_map(:winners)
        |> winners_to_list(),
      pots:
        result
        |> fetch_list(:pots)
        |> Enum.map(fn pot ->
          %{
            amount: fetch(pot, :amount),
            eligible_seats: fetch(pot, :eligible_seats) || []
          }
        end),
      showdown:
        result
        |> fetch_map(:showdown)
        |> showdown_to_list(),
      ended_by: fetch(result, :ended_by)
    }
  end

  defp cards_to_strings(cards) when is_list(cards) do
    Enum.map(cards, &Card.to_short_string/1)
  end

  defp normalize_card_strings(cards) when is_list(cards) do
    Enum.map(cards, fn
      value when is_binary(value) -> value
      value -> inspect(value)
    end)
  end

  defp winners_to_list(winners) when is_map(winners) do
    winners
    |> Enum.map(fn {seat, amount} ->
      %{
        seat: normalize_seat(seat),
        amount: amount
      }
    end)
    |> Enum.sort_by(& &1.seat)
  end

  defp winners_to_list(_), do: []

  defp showdown_to_list(showdown) when is_map(showdown) do
    showdown
    |> Enum.map(fn {seat, rank} ->
      %{
        seat: normalize_seat(seat),
        category: fetch(rank, :category),
        tiebreaker: fetch(rank, :tiebreaker) || []
      }
    end)
    |> Enum.sort_by(& &1.seat)
  end

  defp showdown_to_list(_), do: []

  defp normalize_seat(seat) when is_integer(seat), do: seat

  defp normalize_seat(seat) when is_binary(seat) do
    case Integer.parse(seat) do
      {parsed, ""} -> parsed
      _ -> seat
    end
  end

  defp normalize_seat(seat), do: seat

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil

  defp fetch_map(map, key) do
    case fetch(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp fetch_list(map, key) do
    case fetch(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end
end
