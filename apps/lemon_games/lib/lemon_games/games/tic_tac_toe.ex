defmodule LemonGames.Games.TicTacToe do
  @moduledoc "Tic-Tac-Toe game engine. 3x3 grid."
  @behaviour LemonGames.Games.Game

  @board_size 3

  @impl true
  def game_type, do: "tic_tac_toe"

  @impl true
  def init(_opts) do
    board = List.duplicate(List.duplicate(nil, @board_size), @board_size)

    %{
      "board" => board,
      "winner" => nil,
      "current_player" => "p1"
    }
  end

  @impl true
  def legal_moves(state, slot) do
    cond do
      state["winner"] != nil ->
        []

      state["current_player"] != slot ->
        []

      true ->
        for row <- 0..(@board_size - 1),
            col <- 0..(@board_size - 1),
            cell_empty?(state["board"], row, col),
            do: %{"kind" => "place", "row" => row, "col" => col}
    end
  end

  @impl true
  def apply_move(state, slot, %{"kind" => "place", "row" => row, "col" => col}) do
    cond do
      row < 0 or row >= @board_size or col < 0 or col >= @board_size ->
        {:error, :illegal_move, "position out of range"}

      state["winner"] != nil ->
        {:error, :illegal_move, "game already finished"}

      state["current_player"] != slot ->
        {:error, :illegal_move, "not your turn"}

      not cell_empty?(state["board"], row, col) ->
        {:error, :illegal_move, "cell already occupied"}

      true ->
        piece = slot_to_piece(slot)
        board = place_piece(state["board"], row, col, piece)
        winner = check_winner(board, slot)

        state =
          %{state | "board" => board, "winner" => winner, "current_player" => next_player(slot)}

        # Check for draw if no winner and board is full
        state =
          if winner == nil and board_full?(board) do
            Map.put(state, "winner", "draw")
          else
            state
          end

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

  defp slot_to_piece("p1"), do: "X"
  defp slot_to_piece("p2"), do: "O"

  defp next_player("p1"), do: "p2"
  defp next_player("p2"), do: "p1"

  defp cell_empty?(board, row, col) do
    board |> Enum.at(row) |> Enum.at(col) == nil
  end

  defp place_piece(board, row, col, piece) do
    new_row = board |> Enum.at(row) |> List.replace_at(col, piece)
    List.replace_at(board, row, new_row)
  end

  defp board_full?(board) do
    Enum.all?(board, fn row ->
      Enum.all?(row, &(&1 != nil))
    end)
  end

  defp check_winner(board, slot) do
    piece = slot_to_piece(slot)

    # Check rows
    row_win =
      Enum.any?(board, fn row ->
        Enum.all?(row, &(&1 == piece))
      end)

    # Check columns
    col_win =
      Enum.any?(0..(@board_size - 1), fn col ->
        Enum.all?(0..(@board_size - 1), fn row ->
          board |> Enum.at(row) |> Enum.at(col) == piece
        end)
      end)

    # Check diagonal (top-left to bottom-right)
    diag1_win =
      Enum.all?(0..(@board_size - 1), fn i ->
        board |> Enum.at(i) |> Enum.at(i) == piece
      end)

    # Check anti-diagonal (top-right to bottom-left)
    diag2_win =
      Enum.all?(0..(@board_size - 1), fn i ->
        board |> Enum.at(i) |> Enum.at(@board_size - 1 - i) == piece
      end)

    if row_win or col_win or diag1_win or diag2_win do
      slot
    else
      nil
    end
  end
end
