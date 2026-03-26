defmodule LemonSim.Examples.Poker.Events do
  @moduledoc false

  alias LemonSim.Event
  alias LemonSim.Examples.Poker.Engine.Table

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  @spec player_action(String.t(), pos_integer(), atom(), integer() | nil, map()) :: Event.t()
  def player_action(player_id, seat, action, total \\ nil, extras \\ %{}) do
    payload =
      %{
        "player_id" => player_id,
        "seat" => seat,
        "action" => to_string(action)
      }
      |> maybe_put_total(total)
      |> Map.merge(Map.new(extras))

    Event.new("poker_action", payload)
  end

  @spec player_note(String.t(), pos_integer(), String.t(), map()) :: Event.t()
  def player_note(player_id, seat, content, extras \\ %{}) do
    payload =
      %{
        "player_id" => player_id,
        "seat" => seat,
        "content" => to_string(content)
      }
      |> Map.merge(Map.new(extras))

    Event.new("player_note", payload)
  end

  @spec action_rejected(term(), term(), term(), term(), String.t()) :: Event.t()
  def action_rejected(player_id, seat, action, reason, message) do
    Event.new("action_rejected", %{
      "player_id" => player_id,
      "seat" => seat,
      "action" => normalize_optional_string(action),
      "reason" => to_string(reason),
      "message" => message
    })
  end

  @spec hand_started(Table.Hand.t(), map()) :: Event.t()
  def hand_started(%Table.Hand{} = hand, seats) when is_map(seats) do
    Event.new("hand_started", %{
      "hand_id" => hand.id,
      "button_seat" => hand.button_seat,
      "button_player_id" => player_id_for(seats, hand.button_seat),
      "small_blind_seat" => hand.small_blind_seat,
      "small_blind_player_id" => player_id_for(seats, hand.small_blind_seat),
      "big_blind_seat" => hand.big_blind_seat,
      "big_blind_player_id" => player_id_for(seats, hand.big_blind_seat)
    })
  end

  @spec hand_completed(map(), map()) :: Event.t()
  def hand_completed(result, seats) when is_map(result) and is_map(seats) do
    winners =
      result
      |> Map.get(:winners, Map.get(result, "winners", %{}))
      |> Enum.map(fn {seat, amount} ->
        %{
          "seat" => seat,
          "player_id" => player_id_for(seats, seat),
          "amount" => amount
        }
      end)

    Event.new("hand_completed", %{
      "hand_id" => Map.get(result, :hand_id, Map.get(result, "hand_id")),
      "board" => Map.get(result, :board, Map.get(result, "board", [])),
      "ended_by" =>
        normalize_optional_string(Map.get(result, :ended_by, Map.get(result, "ended_by"))),
      "winners" => winners,
      "pots" => Map.get(result, :pots, Map.get(result, "pots", [])),
      "showdown" => Map.get(result, :showdown, Map.get(result, "showdown", %{}))
    })
  end

  @spec game_over(atom(), [String.t()], map(), non_neg_integer()) :: Event.t()
  def game_over(reason, winner_ids, chip_counts, completed_hands) do
    Event.new("game_over", %{
      "reason" => to_string(reason),
      "winner_ids" => winner_ids,
      "chip_counts" => chip_counts,
      "completed_hands" => completed_hands
    })
  end

  defp maybe_put_total(payload, total) when is_integer(total),
    do: Map.put(payload, "total", total)

  defp maybe_put_total(payload, _total), do: payload

  defp player_id_for(seats, seat) do
    case Map.get(seats, seat) do
      %{player_id: player_id} -> player_id
      _ -> nil
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_string(value), do: to_string(value)
end
