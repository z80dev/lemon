defmodule LemonSim.Examples.PokerBanterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Poker.Banter

  describe "clean banter passes" do
    test "generic trash talk is allowed" do
      assert {:ok, "You fold more than a laundromat."} =
               Banter.sanitize("You fold more than a laundromat.", [])
    end

    test "bluff talk without specifics is allowed" do
      assert {:ok, _} = Banter.sanitize("I have the nuts, save your chips.", [])
      assert {:ok, _} = Banter.sanitize("That river changes nothing for me.", [])
    end

    test "whitespace is normalized and long messages are capped" do
      long = String.duplicate("chip and a chair ", 30)
      assert {:ok, clean} = Banter.sanitize("  hello \n there  ", [])
      assert clean == "hello there"
      assert {:ok, capped} = Banter.sanitize(long, [])
      assert String.length(capped) <= 240
    end

    test "sentence-initial As/Ah are treated as English words" do
      assert {:ok, _} = Banter.sanitize("As expected, you all folded.", [])
      assert {:ok, _} = Banter.sanitize("Ah, there it is. Ship it.", [])
      assert {:ok, _} = Banter.sanitize("Wow! As always, too easy.", [])
    end
  end

  describe "card leaks are blocked" do
    test "short notation for off-board cards is blocked" do
      assert {:error, msg} = Banter.sanitize("Kings up: Kh Kd baby", [])
      assert msg =~ "not on the board"
      assert {:error, _} = Banter.sanitize("holding 10s over here", [])
    end

    test "mid-sentence card-like tokens are blocked" do
      assert {:error, _} = Banter.sanitize("My favorite card is Ah", ["Qh", "7c", "2d"])
    end

    test "board cards may be referenced" do
      board = ["Qh", "7c", "2d"]
      assert {:ok, _} = Banter.sanitize("That Qh is a scary card for you.", board)
      assert {:error, _} = Banter.sanitize("That Qs is a scary card for you.", board)
    end

    test "verbose card names are blocked unless on the board" do
      board = ["Qh", "7c", "2d"]
      assert {:error, _} = Banter.sanitize("The ace of spades is my friend.", board)
      assert {:ok, _} = Banter.sanitize("The queen of hearts saved nobody.", board)
    end

    test "pocket-X talk is always blocked" do
      assert {:error, msg} = Banter.sanitize("Easy call with pocket aces.", [])
      assert msg =~ "describes your holding"
      assert {:error, _} = Banter.sanitize("pocket rockets again!", [])
    end

    test "first-person holding claims with concrete ranks are blocked" do
      assert {:error, _} = Banter.sanitize("I have two kings, just fold.", [])
      assert {:error, _} = Banter.sanitize("I'm holding suited connectors.", [])
      assert {:error, _} = Banter.sanitize("My hole cards are both hearts.", [])
    end

    test "empty messages are rejected" do
      assert {:error, _} = Banter.sanitize("   ", [])
    end
  end
end
