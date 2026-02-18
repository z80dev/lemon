defmodule LemonPoker.CardTest do
  use ExUnit.Case, async: true

  alias LemonPoker.Card

  test "builds full unique 52-card deck" do
    deck = Card.full_deck()
    assert length(deck) == 52
    assert MapSet.size(MapSet.new(deck)) == 52
  end

  test "parses and serializes short card notation" do
    {:ok, ace_spades} = Card.from_string("As")
    assert ace_spades.rank == :ace
    assert ace_spades.suit == :spades
    assert Card.to_short_string(ace_spades) == "As"

    {:ok, ten_diamonds} = Card.from_string("Td")
    assert Card.to_short_string(ten_diamonds) == "Td"
  end

  test "rejects invalid card strings" do
    assert {:error, :invalid_card} = Card.from_string("1s")
    assert {:error, :invalid_card} = Card.from_string("AcX")
    assert {:error, :invalid_card} = Card.from_string("ZZ")
  end
end
