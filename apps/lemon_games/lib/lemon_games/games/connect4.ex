defmodule LemonGames.Games.Connect4 do
  @moduledoc "Connect4 game engine. 7 columns x 6 rows."
  @behaviour LemonGames.Games.Game

  @rows 6
  @cols 7

  @impl true
  def game_type, do: "connect4"

  @impl true
  def init(_opts) do
    board = List.duplicate(List.duplicate(0, @cols), @rows)
    %{"rows" => @rows, "cols" => @cols, "board" => board, "winner" => nil}
  end

  @impl true
  def legal_moves(state, _slot) do
    if state["winner"] != nil do
      []
    else
      for col <- 0..(@cols - 1),
          !column_full?(state["board"], col),
          do: %{"kind" => "drop", "column" => col}
    end
  end

  @impl true
  def apply_move(state, slot, %{"kind" => "drop", "column" => col}) do
    cond do
      col < 0 or col >= @cols ->
        {:error, :illegal_move, "column out of range"}

      state["winner"] != nil ->
        {:error, :illegal_move, "game already finished"}

      column_full?(state["board"], col) ->
        {:error, :illegal_move, "column_full"}

      true ->
        piece = slot_to_piece(slot)
        {board, row} = drop_piece(state["board"], col, piece)
        state = Map.put(state, "board", board)
        winner = check_winner(board, row, col, piece, slot)
        state = if winner, do: Map.put(state, "winner", winner), else: state
        # Check draw (board full, no winner)
        state =
          if winner == nil and board_full?(board),
            do: Map.put(state, "winner", "draw"),
            else: state

        {:ok, state}
    end
  end

  def apply_move(_state, _slot, _move) do
    {:error, :illegal_move, "invalid move format"}
  end

  @impl true
  def winner(state), do: state["winner"]

  @impl true
  def terminal_reason(state) do
    case state["winner"] do
      nil -> nil
      "draw" -> "draw"
      _ -> "winner"
    end
  end

  @impl true
  def public_state(state, _viewer), do: state

  # Internals

  defp slot_to_piece("p1"), do: 1
  defp slot_to_piece("p2"), do: 2

  defp column_full?(board, col) do
    # Top row (index 0) is the top. If top cell is non-zero, column is full.
    board |> Enum.at(0) |> Enum.at(col) != 0
  end

  defp board_full?(board) do
    Enum.all?(board, fn row -> Enum.all?(row, &(&1 != 0)) end)
  end

  defp drop_piece(board, col, piece) do
    # Find lowest empty row (highest index) in the column
    row_idx =
      board
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {row, idx} -> if Enum.at(row, col) == 0, do: idx end)

    new_row = board |> Enum.at(row_idx) |> List.replace_at(col, piece)
    {List.replace_at(board, row_idx, new_row), row_idx}
  end

  defp check_winner(board, row, col, piece, slot) do
    directions = [{0, 1}, {1, 0}, {1, 1}, {1, -1}]

    if Enum.any?(directions, fn {dr, dc} ->
         count_dir(board, row, col, dr, dc, piece) +
           count_dir(board, row, col, -dr, -dc, piece) - 1 >= 4
       end) do
      slot
    else
      nil
    end
  end

  defp count_dir(board, row, col, dr, dc, piece) do
    if row >= 0 and row < @rows and col >= 0 and col < @cols and
         board |> Enum.at(row) |> Enum.at(col) == piece do
      1 + count_dir(board, row + dr, col + dc, dr, dc, piece)
    else
      0
    end
  end
end
