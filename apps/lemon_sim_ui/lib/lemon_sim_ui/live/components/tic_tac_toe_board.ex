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
    <div class="flex flex-col items-center gap-6">
      <div class="text-center bg-slate-900/40 px-6 py-3 rounded-xl border border-glass-border shadow-inner">
        <div :if={@game_status == "in_progress"} class="text-lg font-bold text-slate-200 tracking-wide">
          <span class={player_color(@current_player)}>{@current_player}</span>'s turn
          <span class="text-slate-500 font-mono text-sm ml-3">Move {@move_count + 1}</span>
        </div>
        <div :if={@game_status in ["won", "draw"]} class="text-2xl font-black uppercase tracking-widest text-glow-cyan">
          <span :if={@winner && @winner != "draw"} class={player_color(@winner)}>
            {@winner} VICTORIOUS!
          </span>
          <span :if={@winner == "draw" || @game_status == "draw"} class="text-amber-400 text-glow-amber">
            STALEMATE
          </span>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-2 bg-slate-800/50 p-3 rounded-2xl glass-panel shadow-neon-blue relative">
        <div class="absolute inset-0 bg-[linear-gradient(rgba(59,130,246,0.05)_1px,transparent_1px),linear-gradient(90deg,rgba(59,130,246,0.05)_1px,transparent_1px)] bg-[length:10px_10px] pointer-events-none rounded-2xl"></div>
        <%= for {row, row_idx} <- Enum.with_index(@board) do %>
          <%= for {cell, col_idx} <- Enum.with_index(row) do %>
            <button
              class={[
                "w-24 h-24 sm:w-28 sm:h-28 flex items-center justify-center text-5xl font-black rounded-xl transition-all duration-300 relative z-10",
                cell_class(cell, @interactive && @game_status == "in_progress")
              ]}
              phx-click={if @interactive && cell_empty?(cell) && @game_status == "in_progress", do: "human_move"}
              phx-value-row={row_idx}
              phx-value-col={col_idx}
              disabled={!@interactive || !cell_empty?(cell) || @game_status != "in_progress"}
            >
              <div :if={!cell_empty?(cell)} class="absolute inset-0 bg-gradient-to-br from-white/5 to-transparent rounded-xl pointer-events-none"></div>
              <span class={[player_color(cell), "drop-shadow-lg scale-110"]}>{display_cell(cell)}</span>
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
    base = "bg-slate-900/60 border border-slate-700/50 shadow-inner"

    if cell_empty?(cell) && interactive do
      "#{base} hover:bg-slate-800/80 hover:border-cyan-500/50 hover:shadow-neon-cyan cursor-pointer transform hover:-translate-y-1"
    else
      "#{base} cursor-default"
    end
  end

  defp player_color("X"), do: "text-cyan-400 text-glow-cyan"
  defp player_color("O"), do: "text-red-400 text-glow-red"
  defp player_color(_), do: "text-slate-500"
end
