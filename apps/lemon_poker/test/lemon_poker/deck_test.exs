defmodule LemonPoker.DeckTest do
  use ExUnit.Case, async: true

  alias LemonPoker.Deck

  test "deterministic shuffle returns same order for same seed" do
    deck_a = Deck.shuffle(Deck.new(), seed: 1234)
    deck_b = Deck.shuffle(Deck.new(), seed: 1234)
    deck_c = Deck.shuffle(Deck.new(), seed: 5678)

    assert deck_a == deck_b
    refute deck_a == deck_c
  end

  test "deal returns top cards and remaining deck" do
    deck = Deck.new()
    {:ok, cards, rest} = Deck.deal(deck, 5)

    assert length(cards) == 5
    assert length(rest) == 47
    assert cards ++ rest == deck
  end

  test "deal fails when requesting more cards than remain" do
    assert {:error, :not_enough_cards} = Deck.deal([], 1)
  end
end
