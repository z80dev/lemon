defmodule LemonGames.Games.BattleshipTest do
  use ExUnit.Case, async: true

  alias LemonGames.Games.Battleship

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp place_ship(state, slot, name, row, col, orientation) do
    {:ok, new_state} =
      Battleship.apply_move(state, slot, %{
        "kind" => "place_ship",
        "ship_name" => name,
        "row" => row,
        "col" => col,
        "orientation" => orientation
      })

    new_state
  end

  defp ready(state, slot) do
    {:ok, new_state} = Battleship.apply_move(state, slot, %{"kind" => "ready"})
    new_state
  end

  defp fire(state, slot, row, col) do
    {:ok, new_state} =
      Battleship.apply_move(state, slot, %{"kind" => "fire", "row" => row, "col" => col})

    new_state
  end

  defp setup_complete_game(state) do
    # Place all ships for p1
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")
    state = place_ship(state, "p1", "battleship", 2, 0, "horizontal")
    state = place_ship(state, "p1", "cruiser", 4, 0, "horizontal")
    state = place_ship(state, "p1", "submarine", 6, 0, "horizontal")
    state = place_ship(state, "p1", "destroyer", 8, 0, "horizontal")

    # Place all ships for p2
    state = place_ship(state, "p2", "carrier", 0, 5, "horizontal")
    state = place_ship(state, "p2", "battleship", 2, 5, "horizontal")
    state = place_ship(state, "p2", "cruiser", 4, 5, "horizontal")
    state = place_ship(state, "p2", "submarine", 6, 5, "horizontal")
    state = place_ship(state, "p2", "destroyer", 8, 5, "horizontal")

    # Both ready
    state = ready(state, "p1")
    ready(state, "p2")
  end

  # ---------------------------------------------------------------------------
  # game_type/0
  # ---------------------------------------------------------------------------

  test "game_type returns battleship" do
    assert Battleship.game_type() == "battleship"
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  test "init returns empty 10x10 grids and setup phase" do
    state = Battleship.init(%{})
    assert state["phase"] == "setup"
    assert state["current_player"] == "p1"
    assert state["p1_ready"] == false
    assert state["p2_ready"] == false
    assert state["winner"] == nil
    assert length(state["p1_grid"]) == 10
    assert length(state["p2_grid"]) == 10
    assert Enum.all?(state["p1_grid"], fn row -> length(row) == 10 end)
  end

  # ---------------------------------------------------------------------------
  # Setup phase - ship placement
  # ---------------------------------------------------------------------------

  test "can place carrier horizontally" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")

    assert length(state["p1_ships"]) == 1
    assert hd(state["p1_ships"]).name == "carrier"
    assert hd(state["p1_ships"]).size == 5
  end

  test "can place carrier vertically" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "vertical")

    assert length(state["p1_ships"]) == 1
  end

  test "can place all 5 ships" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")
    state = place_ship(state, "p1", "battleship", 2, 0, "horizontal")
    state = place_ship(state, "p1", "cruiser", 4, 0, "horizontal")
    state = place_ship(state, "p1", "submarine", 6, 0, "horizontal")
    state = place_ship(state, "p1", "destroyer", 8, 0, "horizontal")

    assert length(state["p1_ships"]) == 5
  end

  test "cannot place ship out of bounds" do
    state = Battleship.init(%{})

    assert {:error, :illegal_move, _} =
             Battleship.apply_move(state, "p1", %{
               "kind" => "place_ship",
               "ship_name" => "carrier",
               "row" => 0,
               "col" => 6,
               "orientation" => "horizontal"
             })
  end

  test "cannot place ships overlapping" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")

    assert {:error, :illegal_move, _} =
             Battleship.apply_move(state, "p1", %{
               "kind" => "place_ship",
               "ship_name" => "battleship",
               "row" => 0,
               "col" => 3,
               "orientation" => "horizontal"
             })
  end

  test "cannot place same ship twice" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")

    # After placing carrier, it shouldn't be in legal moves anymore
    moves = Battleship.legal_moves(state, "p1")
    refute Enum.any?(moves, &(&1["ship_name"] == "carrier"))
  end

  # ---------------------------------------------------------------------------
  # Setup phase - ready
  # ---------------------------------------------------------------------------

  test "cannot ready until all ships placed" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")

    assert {:error, :illegal_move, _} =
             Battleship.apply_move(state, "p1", %{"kind" => "ready"})
  end

  test "can ready after all ships placed" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")
    state = place_ship(state, "p1", "battleship", 2, 0, "horizontal")
    state = place_ship(state, "p1", "cruiser", 4, 0, "horizontal")
    state = place_ship(state, "p1", "submarine", 6, 0, "horizontal")
    state = place_ship(state, "p1", "destroyer", 8, 0, "horizontal")

    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "ready"})
    assert state["p1_ready"] == true
  end

  test "phase transitions to battle when both ready" do
    state = Battleship.init(%{})

    # Place all ships for p1
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")
    state = place_ship(state, "p1", "battleship", 2, 0, "horizontal")
    state = place_ship(state, "p1", "cruiser", 4, 0, "horizontal")
    state = place_ship(state, "p1", "submarine", 6, 0, "horizontal")
    state = place_ship(state, "p1", "destroyer", 8, 0, "horizontal")

    # Place all ships for p2
    state = place_ship(state, "p2", "carrier", 0, 5, "horizontal")
    state = place_ship(state, "p2", "battleship", 2, 5, "horizontal")
    state = place_ship(state, "p2", "cruiser", 4, 5, "horizontal")
    state = place_ship(state, "p2", "submarine", 6, 5, "horizontal")
    state = place_ship(state, "p2", "destroyer", 8, 5, "horizontal")

    # p1 ready
    state = ready(state, "p1")
    assert state["phase"] == "setup"

    # p2 ready - transition to battle
    state = ready(state, "p2")
    assert state["phase"] == "battle"
    assert state["current_player"] == "p1"
  end

  # ---------------------------------------------------------------------------
  # Battle phase - firing
  # ---------------------------------------------------------------------------

  test "can fire at opponent grid in battle phase" do
    state = setup_complete_game(Battleship.init(%{}))

    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => 0, "col" => 5})

    assert state["last_move"]["result"] == "hit"
    assert state["current_player"] == "p2"
  end

  test "miss when firing at empty cell" do
    state = setup_complete_game(Battleship.init(%{}))

    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => 0, "col" => 0})

    assert state["last_move"]["result"] == "miss"
  end

  test "cannot fire out of turn" do
    state = setup_complete_game(Battleship.init(%{}))

    assert {:error, :illegal_move, _} =
             Battleship.apply_move(state, "p2", %{"kind" => "fire", "row" => 0, "col" => 5})
  end

  test "cannot fire at same position twice" do
    state = setup_complete_game(Battleship.init(%{}))
    # p1 fires at p2's grid position (0,5)
    state = fire(state, "p1", 0, 5)
    # p2 fires at p1's grid position (0,5) - this is valid, different grid
    state = fire(state, "p2", 0, 9)
    # Now p1 tries to fire at same position again
    assert {:error, :illegal_move, _} =
             Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => 0, "col" => 5})
  end

  test "cannot fire out of bounds" do
    state = setup_complete_game(Battleship.init(%{}))

    assert {:error, :illegal_move, _} =
             Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => 10, "col" => 0})
  end

  # ---------------------------------------------------------------------------
  # Winner detection
  # ---------------------------------------------------------------------------

  test "winner detected when all opponent ships sunk" do
    state = setup_complete_game(Battleship.init(%{}))

    # Sink all p2 ships (placed at row 0,2,4,6,8 starting at col 5)
    # Carrier (5): cols 5-9 at row 0
    state = fire(state, "p1", 0, 5)
    state = fire(state, "p2", 9, 9)
    state = fire(state, "p1", 0, 6)
    state = fire(state, "p2", 9, 8)
    state = fire(state, "p1", 0, 7)
    state = fire(state, "p2", 9, 7)
    state = fire(state, "p1", 0, 8)
    state = fire(state, "p2", 9, 6)
    state = fire(state, "p1", 0, 9)
    state = fire(state, "p2", 9, 5)

    # Battleship (4): cols 5-8 at row 2
    state = fire(state, "p1", 2, 5)
    state = fire(state, "p2", 9, 4)
    state = fire(state, "p1", 2, 6)
    state = fire(state, "p2", 9, 3)
    state = fire(state, "p1", 2, 7)
    state = fire(state, "p2", 9, 2)
    state = fire(state, "p1", 2, 8)
    state = fire(state, "p2", 9, 1)

    # Cruiser (3): cols 5-7 at row 4
    state = fire(state, "p1", 4, 5)
    state = fire(state, "p2", 9, 0)
    state = fire(state, "p1", 4, 6)
    state = fire(state, "p2", 8, 9)
    state = fire(state, "p1", 4, 7)
    state = fire(state, "p2", 8, 8)

    # Submarine (3): cols 5-7 at row 6
    state = fire(state, "p1", 6, 5)
    state = fire(state, "p2", 8, 7)
    state = fire(state, "p1", 6, 6)
    state = fire(state, "p2", 8, 6)
    state = fire(state, "p1", 6, 7)
    state = fire(state, "p2", 8, 5)

    # Destroyer (2): cols 5-6 at row 8
    state = fire(state, "p1", 8, 5)
    state = fire(state, "p2", 8, 4)
    state = fire(state, "p1", 8, 6)

    assert Battleship.winner(state) == "p1"
    assert Battleship.terminal_reason(state) == "winner"
  end

  # ---------------------------------------------------------------------------
  # public_state/2 - hidden information
  # ---------------------------------------------------------------------------

  test "public_state hides opponent ships during setup" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")

    public = Battleship.public_state(state, "p1")

    assert public["my_grid"] == state["p1_grid"]
    # Opponent grid should be hidden (empty)
    assert public["opponent_grid"] != state["p2_grid"]
  end

  test "public_state reveals hits but not ship positions" do
    state = setup_complete_game(Battleship.init(%{}))
    state = fire(state, "p1", 0, 5)

    public = Battleship.public_state(state, "p2")

    # p2's view: their own grid shows ships, opponent grid shows hit at 0,5
    assert length(public["my_ships"]) == 5
    # Opponent ships should be hidden (only show sunk status)
    assert length(public["opponent_ships"]) == 5
  end

  # ---------------------------------------------------------------------------
  # legal_moves/2
  # ---------------------------------------------------------------------------

  test "legal_moves empty when game finished" do
    state = setup_complete_game(Battleship.init(%{}))

    # Sink all p2 ships by hitting every cell where they are placed
    # p2 ships are at rows 0,2,4,6,8 cols 5-9
    # Carrier (5): 0,5-0,9
    state = fire(state, "p1", 0, 5)
    state = fire(state, "p2", 9, 9)
    state = fire(state, "p1", 0, 6)
    state = fire(state, "p2", 9, 8)
    state = fire(state, "p1", 0, 7)
    state = fire(state, "p2", 9, 7)
    state = fire(state, "p1", 0, 8)
    state = fire(state, "p2", 9, 6)
    state = fire(state, "p1", 0, 9)
    state = fire(state, "p2", 9, 5)

    # Battleship (4): 2,5-2,8
    state = fire(state, "p1", 2, 5)
    state = fire(state, "p2", 9, 4)
    state = fire(state, "p1", 2, 6)
    state = fire(state, "p2", 9, 3)
    state = fire(state, "p1", 2, 7)
    state = fire(state, "p2", 9, 2)
    state = fire(state, "p1", 2, 8)
    state = fire(state, "p2", 9, 1)

    # Cruiser (3): 4,5-4,7
    state = fire(state, "p1", 4, 5)
    state = fire(state, "p2", 9, 0)
    state = fire(state, "p1", 4, 6)
    state = fire(state, "p2", 8, 9)
    state = fire(state, "p1", 4, 7)
    state = fire(state, "p2", 8, 8)

    # Submarine (3): 6,5-6,7
    state = fire(state, "p1", 6, 5)
    state = fire(state, "p2", 8, 7)
    state = fire(state, "p1", 6, 6)
    state = fire(state, "p2", 8, 6)
    state = fire(state, "p1", 6, 7)
    state = fire(state, "p2", 8, 5)

    # Destroyer (2): 8,5-8,6
    state = fire(state, "p1", 8, 5)
    state = fire(state, "p2", 8, 4)
    state = fire(state, "p1", 8, 6)

    assert Battleship.winner(state) == "p1"
    assert Battleship.legal_moves(state, "p1") == []
    assert Battleship.legal_moves(state, "p2") == []
  end

  test "legal_moves in setup shows ship placements" do
    state = Battleship.init(%{})

    moves = Battleship.legal_moves(state, "p1")

    # Should have placements for carrier (first ship to place)
    carrier_moves = Enum.filter(moves, &(&1["ship_name"] == "carrier"))
    assert length(carrier_moves) > 0
    assert Enum.all?(carrier_moves, &(&1["kind"] == "place_ship"))
  end

  test "legal_moves includes ready when all ships placed" do
    state = Battleship.init(%{})
    state = place_ship(state, "p1", "carrier", 0, 0, "horizontal")
    state = place_ship(state, "p1", "battleship", 2, 0, "horizontal")
    state = place_ship(state, "p1", "cruiser", 4, 0, "horizontal")
    state = place_ship(state, "p1", "submarine", 6, 0, "horizontal")
    state = place_ship(state, "p1", "destroyer", 8, 0, "horizontal")

    moves = Battleship.legal_moves(state, "p1")

    assert Enum.any?(moves, &(&1["kind"] == "ready"))
  end
end
