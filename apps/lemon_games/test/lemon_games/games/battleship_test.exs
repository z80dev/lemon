defmodule LemonGames.Games.BattleshipTest do
  use ExUnit.Case, async: true

  alias LemonGames.Games.Battleship

  # ---------------------------------------------------------------------------
  # game_type/0
  # ---------------------------------------------------------------------------

  test "game_type returns battleship" do
    assert Battleship.game_type() == "battleship"
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  test "init returns placement phase with empty state" do
    state = Battleship.init(%{})
    assert state["phase"] == "placement"
    assert state["winner"] == nil
    assert state["p1_ships"] == []
    assert state["p2_ships"] == []
    assert state["p1_shots"] == []
    assert state["p2_shots"] == []
    assert state["current_player"] == "p1"
  end

  # ---------------------------------------------------------------------------
  # legal_moves/2 - placement phase
  # ---------------------------------------------------------------------------

  test "legal_moves returns auto_place for p1 during placement" do
    state = Battleship.init(%{})
    moves = Battleship.legal_moves(state, "p1")
    assert [%{"kind" => "auto_place"}] = moves
  end

  test "legal_moves returns empty list for p2 before p1 places ships" do
    state = Battleship.init(%{})
    assert Battleship.legal_moves(state, "p2") == []
  end

  test "legal_moves returns auto_place for p2 after p1 places ships" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    moves = Battleship.legal_moves(state, "p2")
    assert [%{"kind" => "auto_place"}] = moves
  end

  test "legal_moves returns fire moves after both players place ships - battle phase" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})
    # Now in battle phase
    assert state["phase"] == "battle"
    # p1's turn first, so p1 has fire moves
    assert length(Battleship.legal_moves(state, "p1")) == 64
    # p2 has no moves (not their turn)
    assert Battleship.legal_moves(state, "p2") == []
  end

  # ---------------------------------------------------------------------------
  # legal_moves/2 - battle phase
  # ---------------------------------------------------------------------------

  test "legal_moves returns fire moves in battle phase" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # p1's turn first in battle phase
    moves = Battleship.legal_moves(state, "p1")
    # 8x8 board
    assert length(moves) == 64
    assert Enum.all?(moves, fn m -> m["kind"] == "fire" end)
  end

  test "legal_moves excludes already-shot cells" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # p1 fires at (0,0)
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => 0, "col" => 0})

    # Now p2's turn - p2 has all 64 cells available (p1's shots don't affect p2's options)
    moves = Battleship.legal_moves(state, "p2")
    assert length(moves) == 64

    # Verify p1's moves exclude (0,0) on their next turn
    # (unless game ended, in which case no moves)
    if state["winner"] == nil do
      # p2 fires somewhere
      {:ok, state} =
        Battleship.apply_move(state, "p2", %{"kind" => "fire", "row" => 1, "col" => 1})

      if state["winner"] == nil do
        # Now p1's turn again - p1 should have 63 moves (excluded their own shot at 0,0)
        moves = Battleship.legal_moves(state, "p1")
        assert length(moves) == 63
        refute %{"kind" => "fire", "row" => 0, "col" => 0} in moves
      end
    end
  end

  # ---------------------------------------------------------------------------
  # apply_move/3 - auto_place
  # ---------------------------------------------------------------------------

  test "auto_place creates ships for player" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})

    ships = state["p1_ships"]
    # carrier, battleship, destroyer
    assert length(ships) == 3

    # Check ship sizes
    sizes = Enum.map(ships, & &1.size) |> Enum.sort()
    assert sizes == [3, 4, 5]
  end

  test "auto_place places ships without overlap" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})

    ships = state["p1_ships"]
    all_cells = Enum.flat_map(ships, & &1.cells)

    # Total cells should equal sum of ship sizes
    assert length(all_cells) == 3 + 4 + 5

    # No duplicates
    assert length(Enum.uniq(all_cells)) == length(all_cells)
  end

  test "auto_place transitions to battle phase when both players ready" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    assert state["phase"] == "placement"

    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})
    assert state["phase"] == "battle"
  end

  test "auto_place returns error if ships already placed" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})

    assert {:error, :illegal_move, _} =
             Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
  end

  # ---------------------------------------------------------------------------
  # apply_move/3 - fire
  # ---------------------------------------------------------------------------

  test "fire records a miss" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # p1 goes first in battle phase
    assert state["current_player"] == "p1"

    # Find a cell that doesn't have a p2 ship
    p2_ships = state["p2_ships"]
    occupied = MapSet.new(Enum.flat_map(p2_ships, & &1.cells))

    miss_coord =
      Enum.find_value(0..7, fn r ->
        Enum.find_value(0..7, fn c ->
          if not MapSet.member?(occupied, {r, c}), do: {r, c}
        end)
      end)

    {r, c} = miss_coord
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => r, "col" => c})

    assert {r, c, false} in state["p1_shots"]
  end

  test "fire records a hit" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # p1 goes first in battle phase
    assert state["current_player"] == "p1"

    # Fire at a known p2 ship cell
    p2_ships = state["p2_ships"]
    [{r, c} | _] = Enum.flat_map(p2_ships, & &1.cells)

    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => r, "col" => c})

    assert {r, c, true} in state["p1_shots"]

    # Ship should have hit recorded
    ship = Enum.find(state["p2_ships"], fn s -> {r, c} in s.cells end)
    assert {r, c} in ship.hits
  end

  test "fire switches turns" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # p1's turn first in battle phase
    assert state["current_player"] == "p1"

    p2_ships = state["p2_ships"]
    [{r, c} | _] = Enum.flat_map(p2_ships, & &1.cells)

    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => r, "col" => c})

    # Now p2's turn
    assert state["current_player"] == "p2"
  end

  test "fire returns error when not in battle phase" do
    state = Battleship.init(%{})

    assert {:error, :illegal_move, "not in battle phase"} =
             Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => 0, "col" => 0})
  end

  test "fire returns error when not player's turn" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # p1's turn first, p2 cannot fire
    assert {:error, :illegal_move, "not your turn"} =
             Battleship.apply_move(state, "p2", %{"kind" => "fire", "row" => 0, "col" => 0})
  end

  test "fire returns error for out of bounds" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # p1's turn first
    assert {:error, :illegal_move, "position out of range"} =
             Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => -1, "col" => 0})

    assert {:error, :illegal_move, "position out of range"} =
             Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => 0, "col" => 8})
  end

  # ---------------------------------------------------------------------------
  # Winner detection
  # ---------------------------------------------------------------------------

  test "detects winner when all opponent ships sunk" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # Get all p2 ship cells
    p2_ships = state["p2_ships"]
    all_p2_cells = Enum.flat_map(p2_ships, & &1.cells)

    # p2 fires first, then we alternate
    # We need to sink all p2 ships as p2 (since p2 goes first)
    # Actually p2 fires at p1's ships, so let's think:
    # - p2 goes first, fires at p1's ships
    # - p1 goes second, fires at p2's ships
    # To have p1 win, p1 needs to sink all p2 ships

    # Let's just manually verify the win condition works
    # by checking that when all ships are sunk, winner is set

    # Simulate sinking all p2 ships
    p2_cells = Enum.flat_map(state["p2_ships"], & &1.cells)

    state =
      Enum.reduce(p2_cells, state, fn {r, c}, acc_state ->
        # Make sure it's p1's turn
        acc_state =
          if acc_state["current_player"] != "p1" do
            # Skip p2's turn with a dummy shot
            p1_cells = Enum.flat_map(acc_state["p1_ships"], & &1.cells)
            {dummy_r, dummy_c} = List.first(p1_cells) || {0, 0}

            case Battleship.apply_move(acc_state, "p2", %{
                   "kind" => "fire",
                   "row" => dummy_r,
                   "col" => dummy_c
                 }) do
              {:ok, new_state} -> new_state
              _ -> acc_state
            end
          else
            acc_state
          end

        case Battleship.apply_move(acc_state, "p1", %{"kind" => "fire", "row" => r, "col" => c}) do
          {:ok, new_state} -> new_state
          _ -> acc_state
        end
      end)

    assert Battleship.winner(state) == "p1"
    assert Battleship.terminal_reason(state) == "all_ships_sunk"
  end

  # ---------------------------------------------------------------------------
  # public_state/2
  # ---------------------------------------------------------------------------

  test "public_state redacts opponent ship positions" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # From p1's view
    p1_view = Battleship.public_state(state, "p1")

    # p1 can see their own full ships
    assert length(p1_view["p1_ships"]) == 3
    p1_ship = List.first(p1_view["p1_ships"])
    assert length(p1_ship.cells) == p1_ship.size

    # p1 can only see p2's hit cells (none yet)
    p2_ship = List.first(p1_view["p2_ships"])
    assert p2_ship.cells == []
  end

  test "public_state shows all shots" do
    state = Battleship.init(%{})
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "auto_place"})
    {:ok, state} = Battleship.apply_move(state, "p2", %{"kind" => "auto_place"})

    # p1 fires first in battle phase
    p2_ships = state["p2_ships"]
    [{r, c} | _] = Enum.flat_map(p2_ships, & &1.cells)
    {:ok, state} = Battleship.apply_move(state, "p1", %{"kind" => "fire", "row" => r, "col" => c})

    # Both players see the shot
    p1_view = Battleship.public_state(state, "p1")
    p2_view = Battleship.public_state(state, "p2")

    assert {r, c, true} in p1_view["p1_shots"]
    assert {r, c, true} in p2_view["p1_shots"]
  end
end
