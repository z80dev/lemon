defmodule LemonGames.Bot.BattleshipBot do
  @moduledoc """
  Bot strategy for Battleship.

  Strategy:
  1. Auto-place ships during placement phase
  2. During battle: hunt mode (random shots) until a hit
  3. After hit: target mode (shoot adjacent cells to find ship direction)
  4. Continue in direction until ship sunk, then back to hunt
  """

  alias LemonGames.Games.Battleship

  @spec choose_move(map(), String.t()) :: map()
  def choose_move(state, slot) do
    cond do
      state["phase"] == "placement" ->
        %{"kind" => "auto_place"}

      true ->
        # Battle phase - find a shot
        legal = Battleship.legal_moves(state, slot)

        # Get our shots to analyze
        shots_key = if slot == "p1", do: "p1_shots", else: "p2_shots"
        our_shots = state[shots_key]

        # Find last hit that wasn't a sink (has adjacent unshot cells)
        target = find_priority_target(our_shots, legal)

        move = target || random_move(legal)

        case move do
          %{"row" => r, "col" => c} -> %{"kind" => "fire", "row" => r, "col" => c}
          _ -> List.first(legal) || %{"kind" => "fire", "row" => 0, "col" => 0}
        end
    end
  end

  defp random_move(legal) do
    legal
    |> Enum.filter(&(&1["kind"] == "fire"))
    |> case do
      [] -> nil
      moves -> Enum.random(moves)
    end
  end

  defp find_priority_target(shots, legal) do
    # Find hits that might have more ship cells
    hit_cells = for {r, c, true} <- shots, do: {r, c}

    # Get legal fire positions
    legal_fires =
      Enum.filter(legal, &(&1["kind"] == "fire"))
      |> Enum.map(&{&1["row"], &1["col"]})
      |> MapSet.new()

    # Check each hit for adjacent unshot cells
    Enum.find_value(hit_cells, fn {r, c} ->
      # Check if any adjacent cell is legal to shoot
      adjacent = [{r - 1, c}, {r + 1, c}, {r, c - 1}, {r, c + 1}]

      valid_adjacent =
        Enum.filter(adjacent, fn {ar, ac} ->
          ar >= 0 and ar < 8 and ac >= 0 and ac < 8 and
            MapSet.member?(legal_fires, {ar, ac})
        end)

      case valid_adjacent do
        [] -> nil
        cells ->
          {nr, nc} = List.first(cells)
          %{"kind" => "fire", "row" => nr, "col" => nc}
      end
    end)
  end
end
