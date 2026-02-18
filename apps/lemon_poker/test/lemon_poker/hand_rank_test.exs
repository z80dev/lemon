defmodule LemonPoker.HandRankTest do
  use ExUnit.Case, async: true

  alias LemonPoker.HandRank
  import LemonPoker.TestHelpers

  test "straight flush beats four of a kind" do
    {:ok, straight_flush} = HandRank.evaluate(cards!(~w(As Ks Qs Js Ts)))
    {:ok, quads} = HandRank.evaluate(cards!(~w(Ac Ad Ah As 2d)))

    assert HandRank.compare(straight_flush, quads) == :gt
  end

  test "recognizes wheel straight" do
    {:ok, rank} = HandRank.evaluate(cards!(~w(As 2d 3h 4c 5s 9h Kd)))
    assert rank.category == :straight
    assert rank.tiebreaker == [5]
  end

  test "chooses the best five out of seven cards" do
    {:ok, rank} = HandRank.evaluate(cards!(~w(Ah Ad Ac Kd Ks 2h 3h)))
    assert rank.category == :full_house
    assert rank.tiebreaker == [14, 13]
  end

  test "returns equal for tied hands" do
    {:ok, left} = HandRank.evaluate(cards!(~w(As Kd Qh Jh 9s 2c 3d)))
    {:ok, right} = HandRank.evaluate(cards!(~w(Ah Ks Qd Jc 9h 4s 5c)))

    assert HandRank.compare(left, right) == :eq
  end
end
