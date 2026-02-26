defmodule LemonGames.Bot.RockPaperScissorsBot do
  @moduledoc "Bot strategy for Rock Paper Scissors. Uniform random."

  @spec choose_move(map(), String.t()) :: map()
  def choose_move(_state, _slot) do
    %{"kind" => "throw", "value" => Enum.random(["rock", "paper", "scissors"])}
  end
end
