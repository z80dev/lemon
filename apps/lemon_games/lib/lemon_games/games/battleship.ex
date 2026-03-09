defmodule LemonGames.Games.Battleship do
  @moduledoc """
  Battleship game engine. Simplified 8x8 grid with 3 ships:
  - Carrier (5 cells)
  - Battleship (4 cells)
  - Destroyer (3 cells)

  Each player places ships secretly, then takes turns firing.
  First to sink all opponent ships wins.
  """
  @behaviour LemonGames.Games.Game

  @board_size 8
  @ships [
    %{name: "carrier", size: 5},
    %{name: "battleship", size: 4},
    %{name: "destroyer", size: 3}
  ]

  @impl true
  def game_type, do: "battleship"

  @impl true
  def init(_opts) do
    %{
      # placement -> battle
      "phase" => "placement",
      # List of %{name, cells: [{r,c}, ...], hits: []}
      "p1_ships" => [],
      "p2_ships" => [],
      # List of {r, c, hit?}
      "p1_shots" => [],
      "p2_shots" => [],
      "current_player" => "p1",
      "winner" => nil,
      "turn_number" => 0
    }
  end

  @impl true
  def legal_moves(state, slot) do
    cond do
      state["winner"] != nil ->
        []

      state["phase"] == "placement" ->
        # Auto-placement: p1 must place first, then p2
        cond do
          slot == "p1" and state["p1_ships"] == [] ->
            [%{"kind" => "auto_place"}]

          slot == "p2" and state["p1_ships"] != [] and state["p2_ships"] == [] ->
            [%{"kind" => "auto_place"}]

          true ->
            []
        end

      state["current_player"] != slot ->
        []

      true ->
        # Battle phase: all unshot cells are legal
        shots = if slot == "p1", do: state["p1_shots"], else: state["p2_shots"]
        shot_cells = MapSet.new(for {r, c, _} <- shots, do: {r, c})

        for row <- 0..(@board_size - 1),
            col <- 0..(@board_size - 1),
            not MapSet.member?(shot_cells, {row, col}),
            do: %{"kind" => "fire", "row" => row, "col" => col}
    end
  end

  @impl true
  def apply_move(state, slot, %{"kind" => "auto_place"}) do
    ships_key = if slot == "p1", do: "p1_ships", else: "p2_ships"

    if state[ships_key] != [] do
      {:error, :illegal_move, "ships already placed"}
    else
      ships = place_ships_randomly()
      state = Map.put(state, ships_key, ships)

      # Check if both players have placed ships
      state =
        if state["p1_ships"] != [] and state["p2_ships"] != [] do
          Map.put(state, "phase", "battle")
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

      state["winner"] != nil ->
        {:error, :illegal_move, "game already finished"}

      state["current_player"] != slot ->
        {:error, :illegal_move, "not your turn"}

      row < 0 or row >= @board_size or col < 0 or col >= @board_size ->
        {:error, :illegal_move, "position out of range"}

      true ->
        opponent = if slot == "p1", do: "p2", else: "p1"
        opponent_ships_key = if slot == "p1", do: "p2_ships", else: "p1_ships"
        shots_key = if slot == "p1", do: "p1_shots", else: "p2_shots"

        opponent_ships = state[opponent_ships_key]

        # Check if hit
        {hit, ship_name} = check_hit(opponent_ships, row, col)

        # Update shots
        shots = state[shots_key]
        state = Map.put(state, shots_key, shots ++ [{row, col, hit}])

        # Update ship hits if hit
        state =
          if hit do
            updated_ships = mark_ship_hit(opponent_ships, ship_name, row, col)
            Map.put(state, opponent_ships_key, updated_ships)
          else
            state
          end

        # Check for winner
        all_sunk = all_ships_sunk?(state[opponent_ships_key])

        state =
          if all_sunk do
            Map.put(state, "winner", slot)
          else
            state
            |> Map.put("current_player", opponent)
            |> Map.update("turn_number", 1, &(&1 + 1))
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
      _ -> "all_ships_sunk"
    end
  end

  @impl true
  def public_state(state, viewer) do
    # Viewer sees their own ships, all shots, but not opponent's unhit ship positions
    phase = state["phase"] || "placement"
    p1_ships_raw = state["p1_ships"] || []
    p2_ships_raw = state["p2_ships"] || []
    p1_shots = state["p1_shots"] || []
    p2_shots = state["p2_shots"] || []
    current_player = state["current_player"] || "p1"
    winner = state["winner"]
    turn_number = state["turn_number"] || 0

    p1_ships = if viewer == "p1", do: p1_ships_raw, else: redact_ships(p1_ships_raw)
    p2_ships = if viewer == "p2", do: p2_ships_raw, else: redact_ships(p2_ships_raw)

    %{
      "phase" => phase,
      "p1_ships" => p1_ships,
      "p2_ships" => p2_ships,
      "p1_shots" => p1_shots,
      "p2_shots" => p2_shots,
      "current_player" => current_player,
      "winner" => winner,
      "turn_number" => turn_number
    }
  end

  # Internals

  defp place_ships_randomly do
    place_ships(@ships, [], [])
  end

  defp place_ships([], placed, _attempts), do: placed

  defp place_ships([_ship | _rest], _placed, attempts) when length(attempts) > 1000 do
    # Too many attempts, start over
    place_ships(@ships, [], [])
  end

  defp place_ships([ship | rest], placed, attempts) do
    orientation = if :rand.uniform(2) == 1, do: :horizontal, else: :vertical

    {row, col} =
      case orientation do
        :horizontal ->
          {:rand.uniform(@board_size) - 1, :rand.uniform(@board_size - ship.size)}

        :vertical ->
          {:rand.uniform(@board_size - ship.size), :rand.uniform(@board_size) - 1}
      end

    cells =
      case orientation do
        :horizontal ->
          for c <- col..(col + ship.size - 1), do: {row, c}

        :vertical ->
          for r <- row..(row + ship.size - 1), do: {r, col}
      end

    # Check overlap with existing ships
    occupied = MapSet.new(Enum.flat_map(placed, & &1.cells))

    if Enum.any?(cells, &MapSet.member?(occupied, &1)) do
      place_ships([ship | rest], placed, [1 | attempts])
    else
      ship_data = %{
        name: ship.name,
        size: ship.size,
        cells: cells,
        hits: []
      }

      place_ships(rest, [ship_data | placed], attempts)
    end
  end

  defp check_hit(ships, row, col) do
    Enum.reduce(ships, {false, nil}, fn ship, acc ->
      if {row, col} in ship.cells do
        {true, ship.name}
      else
        acc
      end
    end)
  end

  defp mark_ship_hit(ships, ship_name, row, col) do
    Enum.map(ships, fn ship ->
      if ship.name == ship_name do
        %{ship | hits: [{row, col} | ship.hits]}
      else
        ship
      end
    end)
  end

  defp all_ships_sunk?(ships) do
    Enum.all?(ships, fn ship -> length(ship.hits) == ship.size end)
  end

  defp redact_ships(ships) do
    # Only reveal cells that have been hit
    Enum.map(ships, fn ship ->
      %{ship | cells: ship.hits}
    end)
  end
end
