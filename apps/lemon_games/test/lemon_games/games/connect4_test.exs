defmodule LemonGames.Games.Connect4Test do
  use ExUnit.Case, async: true

  alias LemonGames.Games.Connect4

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp drop(state, slot, col) do
    {:ok, new_state} = Connect4.apply_move(state, slot, %{"kind" => "drop", "column" => col})
    new_state
  end

  # Alternate drops for p1 and p2. cols is a list of column indices for p1
  # moves; p2 drops into col 0 as a filler unless overridden.
  defp drop_seq(state, moves) do
    Enum.reduce(moves, state, fn {slot, col}, acc -> drop(acc, slot, col) end)
  end

  # ---------------------------------------------------------------------------
  # game_type/0
  # ---------------------------------------------------------------------------

  test "game_type returns connect4" do
    assert Connect4.game_type() == "connect4"
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  test "init returns 6x7 empty board with no winner" do
    state = Connect4.init(%{})
    assert state["rows"] == 6
    assert state["cols"] == 7
    assert state["winner"] == nil
    assert length(state["board"]) == 6
    assert Enum.all?(state["board"], fn row -> length(row) == 7 end)
    assert Enum.all?(state["board"], fn row -> Enum.all?(row, &(&1 == 0)) end)
  end

  # ---------------------------------------------------------------------------
  # Piece drops to lowest empty row
  # ---------------------------------------------------------------------------

  test "first piece dropped lands on the bottom row" do
    state = Connect4.init(%{})
    state = drop(state, "p1", 3)
    board = state["board"]
    # Bottom row (index 5) col 3 should be piece 1
    assert Enum.at(board, 5) |> Enum.at(3) == 1
  end

  test "second piece dropped into same column lands on next row up" do
    state = Connect4.init(%{})
    state = drop(state, "p1", 3)
    state = drop(state, "p2", 3)
    board = state["board"]
    assert Enum.at(board, 5) |> Enum.at(3) == 1
    assert Enum.at(board, 4) |> Enum.at(3) == 2
  end

  # ---------------------------------------------------------------------------
  # legal_moves/2
  # ---------------------------------------------------------------------------

  test "legal_moves returns all 7 columns on fresh board" do
    state = Connect4.init(%{})
    moves = Connect4.legal_moves(state, "p1")
    assert length(moves) == 7
    cols = Enum.map(moves, & &1["column"])
    assert Enum.sort(cols) == Enum.to_list(0..6)
  end

  test "legal_moves excludes full column" do
    state = Connect4.init(%{})
    # Fill column 0 (6 rows)
    state =
      Enum.reduce(1..6, state, fn i, acc ->
        slot = if rem(i, 2) == 1, do: "p1", else: "p2"
        drop(acc, slot, 0)
      end)

    moves = Connect4.legal_moves(state, "p1")
    cols = Enum.map(moves, & &1["column"])
    refute 0 in cols
    assert length(moves) == 6
  end

  test "legal_moves returns empty list when game is finished" do
    state = Connect4.init(%{})
    # p1 wins with 4 in col 0, p2 throws into col 1
    state =
      drop_seq(state, [
        {"p1", 0},
        {"p2", 1},
        {"p1", 0},
        {"p2", 1},
        {"p1", 0},
        {"p2", 1},
        {"p1", 0}
      ])

    assert Connect4.winner(state) == "p1"
    assert Connect4.legal_moves(state, "p1") == []
    assert Connect4.legal_moves(state, "p2") == []
  end

  # ---------------------------------------------------------------------------
  # apply_move/3 – error cases
  # ---------------------------------------------------------------------------

  test "apply_move rejects column out of range (negative)" do
    state = Connect4.init(%{})

    assert {:error, :illegal_move, _msg} =
             Connect4.apply_move(state, "p1", %{"kind" => "drop", "column" => -1})
  end

  test "apply_move rejects column out of range (>= 7)" do
    state = Connect4.init(%{})

    assert {:error, :illegal_move, _msg} =
             Connect4.apply_move(state, "p1", %{"kind" => "drop", "column" => 7})
  end

  test "apply_move rejects drop into full column" do
    state = Connect4.init(%{})

    state =
      Enum.reduce(1..6, state, fn i, acc ->
        slot = if rem(i, 2) == 1, do: "p1", else: "p2"
        drop(acc, slot, 0)
      end)

    assert {:error, :illegal_move, _msg} =
             Connect4.apply_move(state, "p1", %{"kind" => "drop", "column" => 0})
  end

  test "apply_move rejects move after game has already finished" do
    state = Connect4.init(%{})

    state =
      drop_seq(state, [
        {"p1", 0},
        {"p2", 1},
        {"p1", 0},
        {"p2", 1},
        {"p1", 0},
        {"p2", 1},
        {"p1", 0}
      ])

    assert {:error, :illegal_move, _msg} =
             Connect4.apply_move(state, "p2", %{"kind" => "drop", "column" => 1})
  end

  test "apply_move rejects invalid move format" do
    state = Connect4.init(%{})

    assert {:error, :illegal_move, _msg} =
             Connect4.apply_move(state, "p1", %{"kind" => "unknown"})
  end

  test "apply_move rejects move map missing kind key" do
    state = Connect4.init(%{})

    assert {:error, :illegal_move, _msg} =
             Connect4.apply_move(state, "p1", %{"column" => 3})
  end

  # ---------------------------------------------------------------------------
  # Horizontal win
  # ---------------------------------------------------------------------------

  test "p1 wins with four in a row horizontally" do
    state = Connect4.init(%{})
    # p1 drops cols 0,1,2,3; p2 drops col 6 as filler
    state =
      drop_seq(state, [
        {"p1", 0},
        {"p2", 6},
        {"p1", 1},
        {"p2", 6},
        {"p1", 2},
        {"p2", 6},
        {"p1", 3}
      ])

    assert Connect4.winner(state) == "p1"
    assert Connect4.terminal_reason(state) == "winner"
  end

  test "p2 wins with four in a row horizontally" do
    state = Connect4.init(%{})

    state =
      drop_seq(state, [
        {"p1", 6},
        {"p2", 0},
        {"p1", 6},
        {"p2", 1},
        {"p1", 6},
        {"p2", 2},
        {"p1", 5},
        {"p2", 3}
      ])

    assert Connect4.winner(state) == "p2"
  end

  # ---------------------------------------------------------------------------
  # Vertical win
  # ---------------------------------------------------------------------------

  test "p1 wins with four in a column vertically" do
    state = Connect4.init(%{})

    state =
      drop_seq(state, [
        {"p1", 0},
        {"p2", 1},
        {"p1", 0},
        {"p2", 1},
        {"p1", 0},
        {"p2", 1},
        {"p1", 0}
      ])

    assert Connect4.winner(state) == "p1"
    assert Connect4.terminal_reason(state) == "winner"
  end

  test "p2 wins with four in a column vertically" do
    state = Connect4.init(%{})

    state =
      drop_seq(state, [
        {"p1", 6},
        {"p2", 0},
        {"p1", 6},
        {"p2", 0},
        {"p1", 6},
        {"p2", 0},
        {"p1", 5},
        {"p2", 0}
      ])

    assert Connect4.winner(state) == "p2"
  end

  # ---------------------------------------------------------------------------
  # Diagonal win (down-right: dr=1, dc=1)
  # ---------------------------------------------------------------------------

  test "p1 wins with four in a diagonal (down-right)" do
    state = Connect4.init(%{})
    # Build the staircase so p1 lands at rows 5,4,3,2 in cols 0,1,2,3
    # Col 0: p1 at row 5 (1 piece needed)
    # Col 1: p1 at row 4 (need 1 filler below -> p2 at row 5, then p1)
    # Col 2: p1 at row 3 (need 2 fillers -> p2,p2, then p1)
    # Col 3: p1 at row 2 (need 3 fillers -> p2,p2,p2, then p1)
    state =
      drop_seq(state, [
        # Seed col 1 bottom with p2
        {"p2", 1},
        # Seed col 2 bottom two with p2
        {"p2", 2},
        {"p2", 2},
        # Seed col 3 bottom three with p2
        {"p2", 3},
        {"p2", 3},
        {"p2", 3},
        # Now p1 diagonal
        {"p1", 0},
        {"p1", 1},
        {"p1", 2},
        {"p1", 3}
      ])

    assert Connect4.winner(state) == "p1"
  end

  # ---------------------------------------------------------------------------
  # Diagonal win (down-left: dr=1, dc=-1)
  # ---------------------------------------------------------------------------

  test "p1 wins with four in a diagonal (down-left)" do
    state = Connect4.init(%{})
    # p1 at rows 5,4,3,2 in cols 3,2,1,0
    # Col 3: no filler needed (lands row 5)
    # Col 2: 1 filler (p2 at row 5, p1 at row 4)
    # Col 1: 2 fillers (p2,p2 then p1 at row 3)
    # Col 0: 3 fillers (p2,p2,p2 then p1 at row 2)
    state =
      drop_seq(state, [
        {"p2", 2},
        {"p2", 1},
        {"p2", 1},
        {"p2", 0},
        {"p2", 0},
        {"p2", 0},
        {"p1", 3},
        {"p1", 2},
        {"p1", 1},
        {"p1", 0}
      ])

    assert Connect4.winner(state) == "p1"
  end

  # ---------------------------------------------------------------------------
  # winner/1 and terminal_reason/1
  # ---------------------------------------------------------------------------

  test "winner returns nil on initial state" do
    assert Connect4.winner(Connect4.init(%{})) == nil
  end

  test "terminal_reason returns nil on initial state" do
    assert Connect4.terminal_reason(Connect4.init(%{})) == nil
  end

  # ---------------------------------------------------------------------------
  # Draw
  # ---------------------------------------------------------------------------

  test "draw when board is full with no winner" do
    # Build a full board directly (without going through apply_move) using a
    # pattern that produces no four-in-a-row in any direction, then verify that
    # winner/1 and terminal_reason/1 correctly report "draw" when the winner
    # field is set to "draw".
    #
    # Board layout (rows 0=top..5=bottom, values: 1=p1, 2=p2).
    # Rows alternate between two patterns with blocks of 2; no run of 4 exists
    # in any direction (horizontal max=2, vertical max=1, diagonal max=2).
    #
    #   row 0: 1 1 2 2 1 1 2
    #   row 1: 2 2 1 1 2 2 1
    #   row 2: 1 1 2 2 1 1 2
    #   row 3: 2 2 1 1 2 2 1
    #   row 4: 1 1 2 2 1 1 2
    #   row 5: 2 2 1 1 2 2 1
    #
    # This board is full (no zeroes) and has no four-in-a-row, representing a draw.
    board = [
      [1, 1, 2, 2, 1, 1, 2],
      [2, 2, 1, 1, 2, 2, 1],
      [1, 1, 2, 2, 1, 1, 2],
      [2, 2, 1, 1, 2, 2, 1],
      [1, 1, 2, 2, 1, 1, 2],
      [2, 2, 1, 1, 2, 2, 1]
    ]

    state = %{
      "rows" => 6,
      "cols" => 7,
      "board" => board,
      "winner" => "draw"
    }

    assert Connect4.winner(state) == "draw"
    assert Connect4.terminal_reason(state) == "draw"
  end

  test "draw is detected automatically when last move fills board with no winner" do
    # Use a 1-column board substitute: fill 6 columns with non-winning arrangements
    # then fill the 7th column's last cell to trigger board_full? detection.
    #
    # Strategy: play a game that is almost full but has no winner.  We seed a
    # known near-draw position by injecting the state, leaving only one empty
    # cell, and then applying the final move.
    #
    # Board with one empty cell at (row 0, col 6) – top of col 6.
    # Same pattern as the draw board above but with board[0][6] = 0.
    board = [
      [1, 1, 2, 2, 1, 1, 0],
      [2, 2, 1, 1, 2, 2, 1],
      [1, 1, 2, 2, 1, 1, 2],
      [2, 2, 1, 1, 2, 2, 1],
      [1, 1, 2, 2, 1, 1, 2],
      [2, 2, 1, 1, 2, 2, 1]
    ]

    state = %{"rows" => 6, "cols" => 7, "board" => board, "winner" => nil}

    # p1 drops into col 6 – piece lands at row 0 (only empty cell in col 6).
    # The drop does NOT create a four-in-a-row, so the result should be "draw".
    {:ok, final_state} = Connect4.apply_move(state, "p1", %{"kind" => "drop", "column" => 6})

    assert final_state["winner"] == "draw"
    assert Connect4.terminal_reason(final_state) == "draw"
  end

  # ---------------------------------------------------------------------------
  # public_state/2
  # ---------------------------------------------------------------------------

  test "public_state returns the full state unchanged" do
    state = Connect4.init(%{})
    state = drop(state, "p1", 3)
    assert Connect4.public_state(state, "p1") == state
    assert Connect4.public_state(state, "p2") == state
  end
end
