defmodule LemonSim.Examples.TicTacToe.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  alias LemonSim.State
  alias LemonSim.Examples.TicTacToe.{Events, Outcome}

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "place_mark" -> apply_place_mark(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  defp apply_place_mark(%State{} = state, event) do
    player = state.world[:current_player]

    with :ok <- ensure_in_progress(state),
         {:ok, row, col} <- parse_coords(event.payload),
         :ok <- ensure_empty_cell(state.world, row, col) do
      board_after = put_in(state.world, [:board, Access.at(row), Access.at(col)], player)
      move_count = (state.world[:move_count] || 0) + 1
      outcome = resolve_outcome(board_after, player)

      next_state =
        state
        |> State.put_world(%{
          board: board_after[:board],
          current_player: outcome.next_player,
          status: outcome.status,
          winner: outcome.winner,
          move_count: move_count
        })
        |> State.append_event(Events.move_applied(player, row, col, move_count))
        |> State.append_events(outcome.events)

      signal = if outcome.status == "in_progress", do: {:decide, "next turn"}, else: :skip
      {:ok, next_state, signal}
    else
      {:error, reason} ->
        {:ok, rejection_state(state, event, player, reason), {:decide, rejection_reason(reason)}}
    end
  end

  defp rejection_state(state, event, player, reason) do
    {row, col} = raw_coords(event.payload)

    State.append_event(
      state,
      Events.move_rejected(player, row, col, reason, rejection_message(reason, player, row, col))
    )
  end

  defp parse_coords(payload) when is_map(payload) do
    {row, col} = raw_coords(payload)

    cond do
      not (is_integer(row) and is_integer(col)) -> {:error, :invalid_coords}
      row < 0 or row > 2 or col < 0 or col > 2 -> {:error, :out_of_bounds}
      true -> {:ok, row, col}
    end
  end

  defp parse_coords(_), do: {:error, :invalid_payload}

  defp raw_coords(payload) when is_map(payload) do
    row = Map.get(payload, "row", Map.get(payload, :row))
    col = Map.get(payload, "col", Map.get(payload, :col))
    {row, col}
  end

  defp raw_coords(_), do: {nil, nil}

  defp ensure_in_progress(%State{world: world}) do
    if world[:status] in [nil, "in_progress"], do: :ok, else: {:error, :game_over}
  end

  defp ensure_empty_cell(world, row, col) do
    cell = get_in(world, [:board, Access.at(row), Access.at(col)])
    if cell == " ", do: :ok, else: {:error, :occupied_cell}
  end

  defp winner?(board_world, player) do
    board = board_world[:board]

    lines = [
      [at(board, 0, 0), at(board, 0, 1), at(board, 0, 2)],
      [at(board, 1, 0), at(board, 1, 1), at(board, 1, 2)],
      [at(board, 2, 0), at(board, 2, 1), at(board, 2, 2)],
      [at(board, 0, 0), at(board, 1, 0), at(board, 2, 0)],
      [at(board, 0, 1), at(board, 1, 1), at(board, 2, 1)],
      [at(board, 0, 2), at(board, 1, 2), at(board, 2, 2)],
      [at(board, 0, 0), at(board, 1, 1), at(board, 2, 2)],
      [at(board, 0, 2), at(board, 1, 1), at(board, 2, 0)]
    ]

    Enum.any?(lines, fn line -> Enum.all?(line, &(&1 == player)) end)
  end

  defp board_full?(board_world) do
    board = board_world[:board]
    board |> List.flatten() |> Enum.all?(&(&1 != " "))
  end

  defp resolve_outcome(board_after, player) do
    cond do
      winner?(board_after, player) ->
        %Outcome{
          status: "won",
          winner: player,
          next_player: nil,
          events: [Events.game_over(:won, player)]
        }

      board_full?(board_after) ->
        %Outcome{
          status: "draw",
          winner: nil,
          next_player: nil,
          events: [Events.game_over(:draw)]
        }

      true ->
        %Outcome{
          status: "in_progress",
          winner: nil,
          next_player: other_player(player),
          events: []
        }
    end
  end

  defp at(board, row, col), do: get_in(board, [Access.at(row), Access.at(col)])

  defp other_player("X"), do: "O"
  defp other_player("O"), do: "X"

  defp rejection_reason(:occupied_cell), do: "cell occupied"
  defp rejection_reason(:out_of_bounds), do: "row/col out of bounds"
  defp rejection_reason(:invalid_coords), do: "invalid coordinates"
  defp rejection_reason(:invalid_payload), do: "invalid payload"
  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"

  defp rejection_message(reason, player, row, col) do
    "Move rejected (#{reason}): #{player} at (#{inspect(row)}, #{inspect(col)})"
  end
end
