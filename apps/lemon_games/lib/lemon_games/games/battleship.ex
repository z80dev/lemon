defmodule LemonGames.Games.Battleship do
  @moduledoc """
  Battleship game engine. 10x10 grid per player.

  Game phases:
  1. :setup - Players place their ships (Carrier 5, Battleship 4, Cruiser 3, Submarine 3, Destroyer 2)
  2. :battle - Players take turns firing at opponent's grid
  3. Terminal - One player sinks all opponent's ships

  State includes both grids (for validation), but public_state hides opponent ships.
  """
  @behaviour LemonGames.Games.Game

  @board_size 10
  @ships [
    %{name: "carrier", size: 5},
    %{name: "battleship", size: 4},
    %{name: "cruiser", size: 3},
    %{name: "submarine", size: 3},
    %{name: "destroyer", size: 2}
  ]

  @impl true
  def game_type, do: "battleship"

  @impl true
  def init(_opts) do
    empty_grid = List.duplicate(List.duplicate(nil, @board_size), @board_size)

    %{
      "phase" => "setup",
      "current_player" => "p1",
      "p1_grid" => empty_grid,
      "p2_grid" => empty_grid,
      "p1_ships" => [],
      "p2_ships" => [],
      "p1_ready" => false,
      "p2_ready" => false,
      "winner" => nil,
      "last_move" => nil
    }
  end

  @impl true
  def legal_moves(state, slot) do
    cond do
      state["winner"] != nil ->
        []

      state["phase"] == "setup" ->
        if state["#{slot}_ready"] do
          []
        else
          ships_to_place = get_ships_to_place(state, slot)

          if ships_to_place == [] do
            [%{"kind" => "ready"}]
          else
            ship = hd(ships_to_place)

            for row <- 0..(@board_size - 1),
                col <- 0..(@board_size - 1),
                orientation <- ["horizontal", "vertical"],
                valid_placement?(state["#{slot}_grid"], row, col, ship.size, orientation),
                do: %{
                  "kind" => "place_ship",
                  "ship_name" => ship.name,
                  "row" => row,
                  "col" => col,
                  "orientation" => orientation
                }
          end
        end

      state["phase"] == "battle" ->
        if state["current_player"] != slot do
          []
        else
          opponent = opponent(slot)
          opponent_grid = state["#{opponent}_grid"]

          for row <- 0..(@board_size - 1),
              col <- 0..(@board_size - 1),
              not_already_fired?(opponent_grid, row, col),
              do: %{"kind" => "fire", "row" => row, "col" => col}
        end

      true ->
        []
    end
  end

  @impl true
  def apply_move(state, slot, %{"kind" => "place_ship"} = move) do
    %{"ship_name" => ship_name, "row" => row, "col" => col, "orientation" => orientation} =
      move

    cond do
      state["phase"] != "setup" ->
        {:error, :illegal_move, "not in setup phase"}

      state["#{slot}_ready"] ->
        {:error, :illegal_move, "already ready"}

      not valid_placement?(state["#{slot}_grid"], row, col, ship_size(ship_name), orientation) ->
        {:error, :illegal_move, "invalid ship placement"}

      true ->
        size = ship_size(ship_name)
        positions = ship_positions(row, col, size, orientation)
        ship = %{name: ship_name, size: size, hits: 0, positions: positions}
        new_grid = place_ship(state["#{slot}_grid"], row, col, size, orientation)
        ships = [ship | state["#{slot}_ships"]]

        state =
          %{state |
            "#{slot}_grid" => new_grid,
            "#{slot}_ships" => ships
          }

        {:ok, state}
    end
  end

  def apply_move(state, slot, %{"kind" => "ready"}) do
    cond do
      state["phase"] != "setup" ->
        {:error, :illegal_move, "not in setup phase"}

      state["#{slot}_ready"] ->
        {:error, :illegal_move, "already ready"}

      not all_ships_placed?(state, slot) ->
        {:error, :illegal_move, "not all ships placed"}

      true ->
        state = %{state | "#{slot}_ready" => true}

        # Check if both players are ready to transition to battle
        state =
          if state["p1_ready"] and state["p2_ready"] do
            %{state | "phase" => "battle", "current_player" => "p1"}
          else
            state
          end

        {:ok, state}
    end
  end

  def apply_move(state, slot, %{"kind" => "fire", "row" => row, "col" => col}) do
    cond do
      state["phase"] != "battle" ->
        {:error, :illegal_move, "not in battle phase"}

      state["current_player"] != slot ->
        {:error, :illegal_move, "not your turn"}

      row < 0 or row >= @board_size or col < 0 or col >= @board_size ->
        {:error, :illegal_move, "position out of range"}

      true ->
        opponent = opponent(slot)
        opponent_grid = state["#{opponent}_grid"]

        if already_fired?(opponent_grid, row, col) do
          {:error, :illegal_move, "already fired at this position"}
        else
          {new_grid, hit, sunk_ship} = fire_at(opponent_grid, row, col)
          ships = update_ships(state["#{opponent}_ships"], hit, sunk_ship, row, col)

          state =
            %{state |
              "#{opponent}_grid" => new_grid,
              "#{opponent}_ships" => ships,
              "last_move" => %{
                "player" => slot,
                "row" => row,
                "col" => col,
                "result" => if(hit, do: "hit", else: "miss"),
                "sunk_ship" => sunk_ship
              }
            }

          # Check for winner
          state =
            if all_ships_sunk?(ships) do
              %{state | "winner" => slot}
            else
              %{state | "current_player" => opponent}
            end

          {:ok, state}
        end
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
      _ -> "winner"
    end
  end

  @impl true
  def public_state(state, viewer) do
    opponent = opponent(viewer)

    # Hide opponent's ship positions - only show hits/misses
    opponent_grid = state["#{opponent}_grid"]
    hidden_opponent_grid = hide_ships(opponent_grid)

    %{
      "phase" => state["phase"],
      "current_player" => state["current_player"],
      "my_grid" => state["#{viewer}_grid"],
      "opponent_grid" => hidden_opponent_grid,
      "my_ships" => state["#{viewer}_ships"],
      "opponent_ships" => hide_opponent_ships(state["#{opponent}_ships"]),
      "my_ready" => state["#{viewer}_ready"],
      "opponent_ready" => state["#{opponent}_ready"],
      "winner" => state["winner"],
      "last_move" => state["last_move"]
    }
  end

  # Internals

  defp opponent("p1"), do: "p2"
  defp opponent("p2"), do: "p1"

  defp ship_size(name) do
    Enum.find(@ships, &(&1.name == name)).size
  end

  defp get_ships_to_place(state, slot) do
    placed_names = Enum.map(state["#{slot}_ships"], & &1.name)
    Enum.reject(@ships, &(&1.name in placed_names))
  end

  defp all_ships_placed?(state, slot) do
    length(state["#{slot}_ships"]) == length(@ships)
  end

  defp valid_placement?(grid, row, col, size, orientation) do
    positions = ship_positions(row, col, size, orientation)

    Enum.all?(positions, fn {r, c} ->
      r >= 0 and r < @board_size and c >= 0 and c < @board_size and
        cell_empty?(grid, r, c)
    end)
  end

  defp ship_positions(row, col, size, "horizontal") do
    for c <- col..(col + size - 1), do: {row, c}
  end

  defp ship_positions(row, col, size, "vertical") do
    for r <- row..(row + size - 1), do: {r, col}
  end

  defp cell_empty?(grid, row, col) do
    grid |> Enum.at(row) |> Enum.at(col) == nil
  end

  defp place_ship(grid, row, col, size, orientation) do
    positions = ship_positions(row, col, size, orientation)

    Enum.reduce(positions, grid, fn {r, c}, acc ->
      new_row = acc |> Enum.at(r) |> List.replace_at(c, %{ship: true, hit: false, fired: false})
      List.replace_at(acc, r, new_row)
    end)
  end

  defp not_already_fired?(grid, row, col) do
    cell = grid |> Enum.at(row) |> Enum.at(col)
    cell == nil or (is_map(cell) and not cell.fired)
  end

  defp already_fired?(grid, row, col) do
    not not_already_fired?(grid, row, col)
  end

  defp fire_at(grid, row, col) do
    cell = grid |> Enum.at(row) |> Enum.at(col)

    case cell do
      nil ->
        # Miss - mark as fired empty cell
        new_row = grid |> Enum.at(row) |> List.replace_at(col, %{fired: true, hit: false})
        {List.replace_at(grid, row, new_row), false, nil}

      %{ship: true, hit: false} = ship_cell ->
        # Hit
        new_cell = %{ship_cell | hit: true, fired: true}
        new_row = grid |> Enum.at(row) |> List.replace_at(col, new_cell)
        new_grid = List.replace_at(grid, row, new_row)

        # Check if ship is sunk
        sunk_ship = check_ship_sunk(new_grid, row, col)
        {new_grid, true, sunk_ship}

      _ ->
        # Already fired
        {grid, false, nil}
    end
  end

  defp check_ship_sunk(grid, row, col) do
    # Find all connected ship cells and check if all are hit
    ship_cells = find_ship_cells(grid, row, col, [])

    if Enum.all?(ship_cells, fn {r, c} ->
         cell = grid |> Enum.at(r) |> Enum.at(c)
         cell.hit
       end) do
      length(ship_cells)
    else
      nil
    end
  end

  defp find_ship_cells(grid, row, col, visited) do
    if {row, col} in visited do
      visited
    else
      cell = grid |> Enum.at(row) |> Enum.at(col)

      if is_map(cell) and cell.ship do
        visited = [{row, col} | visited]

        # Check all 4 directions
        [{0, 1}, {0, -1}, {1, 0}, {-1, 0}]
        |> Enum.reduce(visited, fn {dr, dc}, acc ->
          nr = row + dr
          nc = col + dc

          if nr >= 0 and nr < @board_size and nc >= 0 and nc < @board_size do
            neighbor = grid |> Enum.at(nr) |> Enum.at(nc)

            if is_map(neighbor) and neighbor.ship do
              find_ship_cells(grid, nr, nc, acc)
            else
              acc
            end
          else
            acc
          end
        end)
      else
        visited
      end
    end
  end

  defp update_ships(ships, false, nil, _hit_row, _hit_col), do: ships

  defp update_ships(ships, true, sunk_size, hit_row, hit_col) do
    # Find which ship was hit by checking if the hit position is in the ship's positions
    hit_pos = {hit_row, hit_col}

    Enum.map(ships, fn ship ->
      cond do
        # This ship was hit - check if hit position is in ship's positions
        hit_pos in ship.positions ->
          if sunk_size && ship.size == sunk_size do
            # Ship was sunk - mark all hits
            %{ship | hits: ship.size}
          else
            # Just a hit - increment hits
            %{ship | hits: ship.hits + 1}
          end

        # Ship was sunk (size matches) but not the one we just hit
        sunk_size && ship.size == sunk_size && ship.hits < ship.size ->
          %{ship | hits: ship.size}

        # Not this ship
        true ->
          ship
      end
    end)
  end

  defp all_ships_sunk?(ships) do
    Enum.all?(ships, &(&1.hits >= &1.size))
  end

  defp hide_ships(grid) do
    Enum.map(grid, fn row ->
      Enum.map(row, fn cell ->
        case cell do
          nil -> %{fired: false, hit: false}
          %{fired: true, hit: true} -> %{fired: true, hit: true}
          %{fired: true, hit: false} -> %{fired: true, hit: false}
          %{ship: true} -> %{fired: false, hit: false}
        end
      end)
    end)
  end

  defp hide_opponent_ships(ships) do
    Enum.map(ships, fn ship ->
      # Only reveal if sunk (hits == size)
      sunk = ship.hits >= ship.size
      %{name: ship.name, size: ship.size, sunk: sunk}
    end)
  end
end
