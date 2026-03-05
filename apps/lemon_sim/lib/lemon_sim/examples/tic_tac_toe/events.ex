defmodule LemonSim.Examples.TicTacToe.Events do
  @moduledoc false

  alias LemonSim.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  @spec place_mark(String.t(), integer(), integer()) :: Event.t()
  def place_mark(player, row, col) do
    Event.new("place_mark", %{"player" => player, "row" => row, "col" => col})
  end

  @spec move_applied(String.t(), integer(), integer(), non_neg_integer()) :: Event.t()
  def move_applied(player, row, col, move_count) do
    Event.new("move_applied", %{
      "player" => player,
      "row" => row,
      "col" => col,
      "move_count" => move_count
    })
  end

  @spec move_rejected(String.t(), term(), term(), term(), String.t()) :: Event.t()
  def move_rejected(player, row, col, reason, message) do
    Event.new("move_rejected", %{
      "player" => player,
      "row" => row,
      "col" => col,
      "reason" => to_string(reason),
      "message" => message
    })
  end

  @spec game_over(:won, String.t()) :: Event.t()
  def game_over(:won, winner) do
    Event.new("game_over", %{
      "status" => "won",
      "winner" => winner,
      "message" => "#{winner} wins"
    })
  end

  @spec game_over(:draw) :: Event.t()
  def game_over(:draw) do
    Event.new("game_over", %{
      "status" => "draw",
      "winner" => nil,
      "message" => "draw"
    })
  end
end
