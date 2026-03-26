defmodule LemonSim.Examples.Poker.Engine.TableTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Poker.Engine.{Card, Deck, Table}

  test "table runs a deterministic showdown and awards the pot" do
    deck = scripted_deck(~w(As Qh Ks Qd 2s Ac 7s 2c 3h 9h 4c 4d))

    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "player_1", 1_000)
      |> then(fn {:ok, table} -> Table.seat_player(table, 2, "player_2", 1_000) end)
      |> then(fn {:ok, table} -> Table.start_hand(table, deck: deck) end)

    final =
      Stream.iterate(table, fn current ->
        if current.hand == nil do
          current
        else
          {:ok, legal} = Table.legal_actions(current)

          action =
            cond do
              :call in legal.options -> :call
              :check in legal.options -> :check
              true -> :fold
            end

          {:ok, next_table} = Table.act(current, legal.seat, action)
          next_table
        end
      end)
      |> Enum.find(fn current -> current.hand == nil end)

    assert final.last_hand_result.ended_by == :showdown
    assert final.last_hand_result.winners == %{1 => 200}
    assert final.seats[1].stack == 1_100
    assert final.seats[2].stack == 900
  end

  defp scripted_deck(cards) do
    prefix =
      Enum.map(cards, fn short ->
        {:ok, card} = Card.from_string(short)
        card
      end)

    prefix_shorts = MapSet.new(cards)

    prefix ++
      (Deck.new()
       |> Enum.reject(fn card -> Card.to_short_string(card) in prefix_shorts end))
  end
end
