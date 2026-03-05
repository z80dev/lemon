defmodule LemonGames.Games.TicTacToeTest do
  use ExUnit.Case, async: true

  alias LemonGames.Games.TicTacToe

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp place(state, slot, row, col) do
    {:ok, new_state} =
      TicTacToe.apply_move(state, slot, %{"kind" => "place", "row" => row, "col" => col})

    new_state
  end

  defp place_seq(state, moves) do
    Enum.reduce(moves, state, fn {slot, row, col}, acc -> place(acc, slot, row, col) end)
  end

  # ---------------------------------------------------------------------------
  # game_type/0
  # ---------------------------------------------------------------------------

  test "game_type returns tic_tac_toe" do
    assert TicTacToe.game_type() == "tic_tac_toe"
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  test "init returns 3x3 empty board with no winner and p1 as current player" do
    state = TicTacToe.init(%{})
    assert state["winner"] == nil
    assert state["current_player"] == "p1"
    assert length(state["board"]) == 3
    assert Enum.all?(state["board"], fn row -> length(row) == 3 end)
    assert Enum.all?(state["board"], fn row -> Enum.all?(row, &(&1 == nil)) end)
  end

  # ---------------------------------------------------------------------------
  # legal_moves/2
  # ---------------------------------------------------------------------------

  test "legal_moves returns all 9 cells on fresh board for p1" do
    state = TicTacToe.init(%{})
    moves = TicTacToe.legal_moves(state, "p1")
    assert length(moves) == 9
  end

  test "legal_moves returns empty list for p2 on fresh board (not their turn)" do
    state = TicTacToe.init(%{})
    moves = TicTacToe.legal_moves(state, "p2")
    assert moves == []
  end

  test "legal_moves excludes occupied cells" do
    state = TicTacToe.init(%{})
    state = place(state, "p1", 1, 1)
    moves = TicTacToe.legal_moves(state, "p2")
    assert length(moves) == 8
    refute %{"kind" => "place", "row" => 1, "col" => 1} in moves
  end

  test "legal_moves returns empty list when game is finished" do
    state = TicTacToe.init(%{})
    # p1 wins with diagonal
    state =
      place_seq(state, [
        {"p1", 0, 0},
        {"p2", 0, 1},
        {"p1", 1, 1},
        {"p2", 0, 2},
        {"p1", 2, 2}
      ])

    assert TicTacToe.winner(state) == "p1"
    assert TicTacToe.legal_moves(state, "p1") == []
    assert TicTacToe.legal_moves(state, "p2") == []
  end

  # ---------------------------------------------------------------------------
  # apply_move/3 – basic placement
  # ---------------------------------------------------------------------------

  test "p1 places X on board" do
    state = TicTacToe.init(%{})
    state = place(state, "p1", 1, 1)
    assert state["board"] |> Enum.at(1) |> Enum.at(1) == "X"
    assert state["current_player"] == "p2"
  end

  test "p2 places O on board" do
    state = TicTacToe.init(%{})
    state = place(state, "p1", 0, 0)
    state = place(state, "p2", 1, 1)
    assert state["board"] |> Enum.at(1) |> Enum.at(1) == "O"
    assert state["current_player"] == "p1"
  end

  # ---------------------------------------------------------------------------
  # apply_move/3 – error cases
  # ---------------------------------------------------------------------------

  test "apply_move rejects position out of range" do
    state = TicTacToe.init(%{})

    assert {:error, :illegal_move, _msg} =
             TicTacToe.apply_move(state, "p1", %{"kind" => "place", "row" => -1, "col" => 0})

    assert {:error, :illegal_move, _msg} =
             TicTacToe.apply_move(state, "p1", %{"kind" => "place", "row" => 0, "col" => 3})
  end

  test "apply_move rejects move when not player's turn" do
    state = TicTacToe.init(%{})

    assert {:error, :illegal_move, _msg} =
             TicTacToe.apply_move(state, "p2", %{"kind" => "place", "row" => 0, "col" => 0})
  end

  test "apply_move rejects move into occupied cell" do
    state = TicTacToe.init(%{})
    state = place(state, "p1", 1, 1)

    assert {:error, :illegal_move, _msg} =
             TicTacToe.apply_move(state, "p2", %{"kind" => "place", "row" => 1, "col" => 1})
  end

  test "apply_move rejects move after game has finished" do
    state = TicTacToe.init(%{})
    # p1 wins
    state =
      place_seq(state, [
        {"p1", 0, 0},
        {"p2", 0, 1},
        {"p1", 1, 1},
        {"p2", 0, 2},
        {"p1", 2, 2}
      ])

    assert {:error, :illegal_move, _msg} =
             TicTacToe.apply_move(state, "p2", %{"kind" => "place", "row" => 1, "col" => 0})
  end

  test "apply_move rejects invalid move format" do
    state = TicTacToe.init(%{})

    assert {:error, :illegal_move, _msg} =
             TicTacToe.apply_move(state, "p1", %{"kind" => "unknown"})
  end

  # ---------------------------------------------------------------------------
  # Horizontal wins
  # ---------------------------------------------------------------------------

  test "p1 wins with three in a row horizontally (top row)" do
    state = TicTacToe.init(%{})

    state =
      place_seq(state, [
        {"p1", 0, 0},
        {"p2", 1, 0},
        {"p1", 0, 1},
        {"p2", 1, 1},
        {"p1", 0, 2}
      ])

    assert TicTacToe.winner(state) == "p1"
    assert TicTacToe.terminal_reason(state) == "winner"
  end

  test "p2 wins with three in a row horizontally (middle row)" do
    state = TicTacToe.init(%{})

    state =
      place_seq(state, [
        {"p1", 0, 0},
        {"p2", 1, 0},
        {"p1", 2, 0},
        {"p2", 1, 1},
        {"p1", 0, 2},
        {"p2", 1, 2}
      ])

    assert TicTacToe.winner(state) == "p2"
  end

  # ---------------------------------------------------------------------------
  # Vertical wins
  # ---------------------------------------------------------------------------

  test "p1 wins with three in a column vertically" do
    state = TicTacToe.init(%{})

    state =
      place_seq(state, [
        {"p1", 0, 0},
        {"p2", 0, 1},
        {"p1", 1, 0},
        {"p2", 1, 1},
        {"p1", 2, 0}
      ])

    assert TicTacToe.winner(state) == "p1"
  end

  test "p2 wins with three in a column vertically" do
    state = TicTacToe.init(%{})

    state =
      place_seq(state, [
        {"p1", 0, 1},
        {"p2", 0, 0},
        {"p1", 1, 1},
        {"p2", 1, 0},
        {"p1", 2, 2},
        {"p2", 2, 0}
      ])

    assert TicTacToe.winner(state) == "p2"
  end

  # ---------------------------------------------------------------------------
  # Diagonal wins
  # ---------------------------------------------------------------------------

  test "p1 wins with diagonal (top-left to bottom-right)" do
    state = TicTacToe.init(%{})

    state =
      place_seq(state, [
        {"p1", 0, 0},
        {"p2", 0, 1},
        {"p1", 1, 1},
        {"p2", 0, 2},
        {"p1", 2, 2}
      ])

    assert TicTacToe.winner(state) == "p1"
  end

  test "p2 wins with anti-diagonal (top-right to bottom-left)" do
    state = TicTacToe.init(%{})

    state =
      place_seq(state, [
        {"p1", 0, 0},
        {"p2", 0, 2},
        {"p1", 1, 0},
        {"p2", 1, 1},
        {"p1", 0, 1},
        {"p2", 2, 0}
      ])

    assert TicTacToe.winner(state) == "p2"
  end

  # ---------------------------------------------------------------------------
  # Draw
  # ---------------------------------------------------------------------------

  test "draw when board is full with no winner" do
    state = TicTacToe.init(%{})

    # Fill board with alternating moves that result in no winner
    # X O X
    # X X O
    # O X O
    state =
      place_seq(state, [
        {"p1", 0, 0},
        {"p2", 0, 1},
        {"p1", 0, 2},
        {"p2", 1, 0},
        {"p1", 1, 2},
        {"p2", 2, 0},
        {"p1", 2, 1},
        {"p2", 2, 2},
        {"p1", 1, 1}
      ])

    assert TicTacToe.winner(state) == "draw"
    assert TicTacToe.terminal_reason(state) == "draw"
  end

  # ---------------------------------------------------------------------------
  # winner/1 and terminal_reason/1
  # ---------------------------------------------------------------------------

  test "winner returns nil on initial state" do
    assert TicTacToe.winner(TicTacToe.init(%{})) == nil
  end

  test "terminal_reason returns nil on initial state" do
    assert TicTacToe.terminal_reason(TicTacToe.init(%{})) == nil
  end

  # ---------------------------------------------------------------------------
  # public_state/2
  # ---------------------------------------------------------------------------

  test "public_state returns the full state unchanged" do
    state = TicTacToe.init(%{})
    state = place(state, "p1", 1, 1)
    assert TicTacToe.public_state(state, "p1") == state
    assert TicTacToe.public_state(state, "p2") == state
  end
end
