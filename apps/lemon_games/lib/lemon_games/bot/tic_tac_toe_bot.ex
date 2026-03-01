defmodule LemonGames.Bot.TicTacToeBot do
  @moduledoc """
  Bot strategy for Tic-Tac-Toe.

  Strategy priority:
  1. Play winning move if available
  2. Block opponent's winning move
  3. Play center if available
  4. Play corner if available
  5. Play any available cell
  """

  alias LemonGames.Games.TicTacToe

  @spec choose_move(map(), String.t()) :: map()
  def choose_move(state, slot) do
    opponent = if slot == "p1", do: "p2", else: "p1"
    legal = TicTacToe.legal_moves(state, slot)

    positions = Enum.map(legal, &{Map.get(&1, "row"), Map.get(&1, "col")})

    {row, col} =
      find_winning_move(state, slot, positions) ||
        find_blocking_move(state, opponent, positions) ||
        prefer_center(positions) ||
        prefer_corner(positions) ||
        List.first(positions)

    %{"kind" => "place", "row" => row, "col" => col}
  end

  defp find_winning_move(state, slot, positions) do
    Enum.find(positions, fn {row, col} ->
      case TicTacToe.apply_move(state, slot, %{"kind" => "place", "row" => row, "col" => col}) do
        {:ok, new_state} -> new_state["winner"] == slot
        _ -> false
      end
    end)
  end

  defp find_blocking_move(state, opponent, positions) do
    # Find a move that would give opponent a win (so we block it)
    Enum.find(positions, fn {row, col} ->
      # Simulate opponent having this position available
      # Actually, we need to check if opponent would win if they played here
      # So we check: if opponent played at this position, would they win?
      case TicTacToe.apply_move(state, opponent, %{"kind" => "place", "row" => row, "col" => col}) do
        {:ok, new_state} -> new_state["winner"] == opponent
        _ -> false
      end
    end)
  end

  defp prefer_center(positions) do
    if {1, 1} in positions, do: {1, 1}, else: nil
  end

  defp prefer_corner(positions) do
    corners = [{0, 0}, {0, 2}, {2, 0}, {2, 2}]
    Enum.find(corners, fn corner -> corner in positions end)
  end
end
