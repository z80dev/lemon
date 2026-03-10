defmodule LemonSimUi.Live.Components.TicTacToeBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    board = MapHelpers.get_key(assigns.world, :board) || [["", "", ""], ["", "", ""], ["", "", ""]]
    current_player = MapHelpers.get_key(assigns.world, :current_player)
    status = MapHelpers.get_key(assigns.world, :status)
    winner = MapHelpers.get_key(assigns.world, :winner)
    move_count = MapHelpers.get_key(assigns.world, :move_count) || 0

    assigns =
      assigns
      |> assign(:board, board)
      |> assign(:current_player, current_player)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:move_count, move_count)

    ~H"""
    <div class="flex flex-col items-center gap-4">
      <div class="text-center">
        <div :if={@game_status == "in_progress"} class="text-lg font-semibold text-gray-200">
          <span class={player_color(@current_player)}>{@current_player}</span>'s turn
          <span class="text-gray-500 text-sm ml-2">Move {@move_count + 1}</span>
        </div>
        <div :if={@game_status in ["won", "draw"]} class="text-lg font-semibold">
          <span :if={@winner && @winner != "draw"} class={player_color(@winner)}>
            {@winner} wins!
          </span>
          <span :if={@winner == "draw" || @game_status == "draw"} class="text-amber-400">
            Draw!
          </span>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-1 bg-gray-700 p-1 rounded-xl">
        <%= for {row, row_idx} <- Enum.with_index(@board) do %>
          <%= for {cell, col_idx} <- Enum.with_index(row) do %>
            <button
              class={[
                "w-20 h-20 flex items-center justify-center text-3xl font-bold rounded-lg transition-all",
                cell_class(cell, @interactive && @game_status == "in_progress")
              ]}
              phx-click={if @interactive && cell_empty?(cell) && @game_status == "in_progress", do: "human_move"}
              phx-value-row={row_idx}
              phx-value-col={col_idx}
              disabled={!@interactive || !cell_empty?(cell) || @game_status != "in_progress"}
            >
              <span class={player_color(cell)}>{display_cell(cell)}</span>
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp cell_empty?(cell) when cell in [" ", "", nil], do: true
  defp cell_empty?(_), do: false

  defp display_cell(cell) when cell in [" ", "", nil], do: ""
  defp display_cell(cell), do: cell

  defp cell_class(cell, interactive) do
    base = "bg-gray-800"

    if cell_empty?(cell) && interactive do
      "#{base} hover:bg-gray-700 cursor-pointer"
    else
      "#{base} cursor-default"
    end
  end

  defp player_color("X"), do: "text-blue-400"
  defp player_color("O"), do: "text-rose-400"
  defp player_color(_), do: "text-gray-500"
end
