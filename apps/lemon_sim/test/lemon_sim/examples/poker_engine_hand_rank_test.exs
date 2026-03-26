defmodule LemonSim.Examples.Poker.Engine.HandRankTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Poker.Engine.{Card, HandRank}

  test "straight flush beats four of a kind" do
    straight_flush = cards(~w(As Ks Qs Js Ts 2d 3c))
    four_of_a_kind = cards(~w(Ah Ad Ac As 9d 2h 3s))

    assert {:ok, left} = HandRank.evaluate(straight_flush)
    assert {:ok, right} = HandRank.evaluate(four_of_a_kind)

    assert left.category == :straight_flush
    assert right.category == :four_of_a_kind
    assert HandRank.compare(left, right) == :gt
  end

  test "wheel straight is recognized" do
    assert {:ok, rank} = HandRank.evaluate(cards(~w(As 2d 3h 4c 5s 9d Kc)))
    assert rank.category == :straight
    assert rank.tiebreaker == [5]
  end

  defp cards(shorts) do
    Enum.map(shorts, fn short ->
      {:ok, card} = Card.from_string(short)
      card
    end)
  end
end
