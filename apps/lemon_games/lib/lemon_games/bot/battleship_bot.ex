defmodule LemonGames.Bot.BattleshipBot do
  @moduledoc """
  Bot strategy for Battleship.
  
  Setup phase: Places ships in fixed positions for determinism.
  Battle phase: Uses a mix of random and hunt/target strategy.
  """

  @ships [
    %{name: "carrier", size: 5},
    %{name: "battleship", size: 4},
    %{name: "cruiser", size: 3},
    %{name: "submarine", size: 3},
    %{name: "destroyer", size: 2}
  ]

  # Fixed ship placements for deterministic bot behavior
  @default_placements [
    %{ship_name: "carrier", row: 0, col: 0, orientation: "horizontal"},
    %{ship_name: "battleship", row: 2, col: 0, orientation: "horizontal"},
    %{ship_name: "cruiser", row: 4, col: 0, orientation: "horizontal"},
    %{ship_name: "submarine", row: 6, col: 0, orientation: "horizontal"},
    %{ship_name: "destroyer", row: 8, col: 0, orientation: "horizontal"}
  ]

  @doc """
  Choose a move for Battleship based on current game state.
  """
  @spec choose_move(map(), String.t()) :: map()
  def choose_move(state, _slot) do
    phase = state["phase"] || "setup"

    case phase do
      "setup" -> choose_setup_move(state)
      "battle" -> choose_battle_move(state)
      _ -> %{"kind" => "ready"}  # Fallback
    end
  end

  defp choose_setup_move(state) do
    my_ships = state["my_ships"] || []
    my_ready = state["my_ready"] || false

    cond do
      my_ready ->
        # Already ready, shouldn't happen but handle gracefully
        %{"kind" => "ready"}

      length(my_ships) < length(@ships) ->
        # Place next ship
        placed_names = Enum.map(my_ships, & &1.name)
        ship_to_place = Enum.find(@ships, fn s -> s.name not in placed_names end)
        
        placement = Enum.find(@default_placements, &(&1.ship_name == ship_to_place.name))
        
        %{
          "kind" => "place_ship",
          "ship_name" => placement.ship_name,
          "row" => placement.row,
          "col" => placement.col,
          "orientation" => placement.orientation
        }

      true ->
        # All ships placed, signal ready
        %{"kind" => "ready"}
    end
  end

  defp choose_battle_move(state) do
    opponent_grid = state["opponent_grid"] || []
    current_player = state["current_player"]
    
    # Get all valid firing positions
    valid_moves = 
      for {row, r} <- Enum.with_index(opponent_grid),
          {cell, c} <- Enum.with_index(row),
          not_fired?(cell) do
        {r, c}
      end

    if valid_moves == [] do
      # No valid moves, shouldn't happen in normal play
      %{"kind" => "fire", "row" => 0, "col" => 0}
    else
      # Prioritize cells adjacent to hits (hunt/target strategy)
      prioritized = prioritize_moves(valid_moves, opponent_grid)
      
      {row, col} = hd(prioritized)
      %{"kind" => "fire", "row" => row, "col" => col}
    end
  end

  defp not_fired?(cell) do
    case cell do
      %{"fired" => true} -> false
      _ -> true
    end
  end

  defp prioritize_moves(moves, grid) do
    # Find cells adjacent to hits
    hits = 
      for {row, r} <- Enum.with_index(grid),
          {cell, c} <- Enum.with_index(row),
          is_hit?(cell) do
        {r, c}
      end

    # Score each move based on proximity to hits
    scored = Enum.map(moves, fn {r, c} = move ->
      score = 
        hits
        |> Enum.map(fn {hr, hc} -> abs(hr - r) + abs(hc - c) end)
        |> Enum.min(fn -> 100 end)
      
      {move, score}
    end)

    # Sort by score (lower is better) and return moves
    scored
    |> Enum.sort_by(fn {_move, score} -> score end)
    |> Enum.map(fn {move, _score} -> move end)
  end

  defp is_hit?(cell) do
    case cell do
      %{"hit" => true, "fired" => true} -> true
      _ -> false
    end
  end
end
