defmodule LemonGames.Bot.RockPaperScissorsBotTest do
  use ExUnit.Case, async: true

  alias LemonGames.Bot.RockPaperScissorsBot

  test "returns a valid throw move" do
    move = RockPaperScissorsBot.choose_move(%{}, "p2")

    assert move["kind"] == "throw"
    assert move["value"] in ["rock", "paper", "scissors"]
  end
end
