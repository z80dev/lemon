defmodule LemonPoker.TestHelpers do
  @moduledoc false

  alias LemonPoker.{Card, Deck, Table}

  def card!(short) do
    {:ok, card} = Card.from_string(short)
    card
  end

  def cards!(shorts), do: Enum.map(shorts, &card!/1)

  def deck_with_top(shorts) do
    top_cards = cards!(shorts)
    full_deck = Deck.new()
    top_cards ++ Enum.reject(full_deck, &(&1 in top_cards))
  end

  def seat_players!(table, player_specs) do
    Enum.reduce(player_specs, table, fn {seat, player_id, stack}, acc ->
      {:ok, updated} = Table.seat_player(acc, seat, player_id, stack)
      updated
    end)
  end
end
