defmodule LemonGames.Bot.Connect4Bot do
  @moduledoc "Bot strategy for Connect4. Plays winning move > blocks opponent > center > first legal."

  alias LemonGames.Games.Connect4

  @spec choose_move(map(), String.t()) :: map()
  def choose_move(state, slot) do
    opponent = if slot == "p1", do: "p2", else: "p1"
    legal = Connect4.legal_moves(state, slot)
    cols = Enum.map(legal, & &1["column"])

    col =
      find_winning_col(state, slot, cols) ||
        find_winning_col(state, opponent, cols) ||
        prefer_center(cols) ||
        List.first(cols)

    %{"kind" => "drop", "column" => col}
  end

  defp find_winning_col(state, slot, cols) do
    piece = if slot == "p1", do: 1, else: 2

    Enum.find(cols, fn col ->
      case Connect4.apply_move(state, slot, %{"kind" => "drop", "column" => col}) do
        {:ok, new_state} -> new_state["winner"] == if piece == 1, do: "p1", else: "p2"
        _ -> false
      end
    end)
  end

  defp prefer_center(cols) do
    # Prefer columns closer to center (column 3)
    center_order = [3, 2, 4, 1, 5, 0, 6]
    Enum.find(center_order, fn c -> c in cols end)
  end
end
