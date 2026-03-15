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

    winning_cells = find_winning_cells(board, winner)
    move_history = reconstruct_moves(board)
    x_moves = Enum.count(move_history, fn {mark, _, _} -> mark == "X" end)
    o_moves = Enum.count(move_history, fn {mark, _, _} -> mark == "O" end)
    game_over? = status in ["won", "draw"]

    assigns =
      assigns
      |> assign(:board, board)
      |> assign(:current_player, current_player)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:move_count, move_count)
      |> assign(:winning_cells, winning_cells)
      |> assign(:move_history, move_history)
      |> assign(:x_moves, x_moves)
      |> assign(:o_moves, o_moves)
      |> assign(:game_over, game_over?)

    ~H"""
    <div class="flex flex-col items-center gap-5 relative">
      <style>
        @keyframes ttt-pop-in {
          0% { transform: scale(0) rotate(-20deg); opacity: 0; }
          60% { transform: scale(1.2) rotate(3deg); opacity: 1; }
          100% { transform: scale(1) rotate(0deg); opacity: 1; }
        }
        @keyframes ttt-draw-x-1 {
          0% { stroke-dashoffset: 40; }
          100% { stroke-dashoffset: 0; }
        }
        @keyframes ttt-draw-x-2 {
          0%, 50% { stroke-dashoffset: 40; }
          100% { stroke-dashoffset: 0; }
        }
        @keyframes ttt-draw-o {
          0% { stroke-dashoffset: 126; }
          100% { stroke-dashoffset: 0; }
        }
        @keyframes ttt-win-pulse {
          0%, 100% { box-shadow: 0 0 8px rgba(250, 204, 21, 0.4), inset 0 0 8px rgba(250, 204, 21, 0.1); }
          50% { box-shadow: 0 0 24px rgba(250, 204, 21, 0.8), inset 0 0 16px rgba(250, 204, 21, 0.3); }
        }
        @keyframes ttt-victory-in {
          0% { transform: scale(0.5); opacity: 0; filter: blur(8px); }
          100% { transform: scale(1); opacity: 1; filter: blur(0px); }
        }
        @keyframes ttt-confetti {
          0% { transform: translateY(0) rotate(0deg); opacity: 1; }
          100% { transform: translateY(80px) rotate(720deg); opacity: 0; }
        }
        @keyframes ttt-glow-pulse {
          0%, 100% { opacity: 0.3; }
          50% { opacity: 0.7; }
        }
        @keyframes ttt-turn-pulse {
          0%, 100% { box-shadow: 0 0 8px currentColor; }
          50% { box-shadow: 0 0 20px currentColor; }
        }
        .ttt-mark { animation: ttt-pop-in 0.4s cubic-bezier(0.34, 1.56, 0.64, 1) forwards; }
        .ttt-win-cell { animation: ttt-win-pulse 1.5s ease-in-out infinite; }
        .ttt-victory-text { animation: ttt-victory-in 0.6s ease-out forwards; }
        .ttt-active-player { animation: ttt-turn-pulse 2s ease-in-out infinite; }
        .ttt-x-line-1 { stroke-dasharray: 40; animation: ttt-draw-x-1 0.3s ease-out forwards; }
        .ttt-x-line-2 { stroke-dasharray: 40; animation: ttt-draw-x-2 0.6s ease-out forwards; }
        .ttt-o-circle { stroke-dasharray: 126; animation: ttt-draw-o 0.5s ease-out forwards; }
        .ttt-particle { animation: ttt-confetti 2s ease-out forwards; position: absolute; pointer-events: none; }
        .ttt-grid-glow { animation: ttt-glow-pulse 3s ease-in-out infinite; }
      </style>

      <%!-- Player Status Bar --%>
      <div class="w-full max-w-md flex items-center justify-between gap-3">
        <div class={[
          "flex-1 glass-card rounded-xl px-4 py-3 text-center border transition-all duration-500",
          if(@current_player == "X" && !@game_over,
            do: "border-cyan-500/60 ttt-active-player text-cyan-400",
            else: "border-glass-border text-slate-400")
        ]}>
          <div class="text-2xl font-black text-cyan-400 text-glow-cyan">X</div>
          <div class="text-xs text-slate-500 font-mono mt-1">{@x_moves} moves</div>
          <div :if={@winner == "X"} class="text-xs font-bold text-cyan-300 mt-1 uppercase tracking-wider">Winner</div>
        </div>

        <div class="glass-card rounded-xl px-4 py-2 text-center border border-glass-border">
          <div class="text-xs text-slate-500 font-mono uppercase tracking-widest">vs</div>
          <div class="text-lg font-bold text-slate-300 font-mono">{@move_count}</div>
          <div class="text-[10px] text-slate-600 uppercase">moves</div>
        </div>

        <div class={[
          "flex-1 glass-card rounded-xl px-4 py-3 text-center border transition-all duration-500",
          if(@current_player == "O" && !@game_over,
            do: "border-red-500/60 ttt-active-player text-red-400",
            else: "border-glass-border text-slate-400")
        ]}>
          <div class="text-2xl font-black text-red-400 text-glow-red">O</div>
          <div class="text-xs text-slate-500 font-mono mt-1">{@o_moves} moves</div>
          <div :if={@winner == "O"} class="text-xs font-bold text-red-300 mt-1 uppercase tracking-wider">Winner</div>
        </div>
      </div>

      <%!-- Turn Indicator --%>
      <div :if={@game_status == "in_progress"} class="text-center">
        <span class="text-sm text-slate-500 font-mono tracking-wide">
          <span class={player_color(@current_player)}>{@current_player}</span>'s turn
          <span class="text-slate-600 mx-1">/</span>
          Move {@move_count + 1}
        </span>
      </div>

      <%!-- Game Board --%>
      <div class="relative">
        <%!-- Cyber-grid background --%>
        <div class="absolute inset-0 bg-[linear-gradient(rgba(59,130,246,0.04)_1px,transparent_1px),linear-gradient(90deg,rgba(59,130,246,0.04)_1px,transparent_1px)] bg-[length:8px_8px] pointer-events-none rounded-2xl ttt-grid-glow"></div>

        <div class="grid grid-cols-3 gap-0 bg-slate-800/50 p-1 rounded-2xl glass-panel shadow-neon-blue relative">
          <%!-- Glowing grid lines - horizontal --%>
          <div class="absolute left-3 right-3 top-[calc(33.33%+1px)] h-[2px] bg-gradient-to-r from-transparent via-blue-500/30 to-transparent pointer-events-none z-20 ttt-grid-glow"></div>
          <div class="absolute left-3 right-3 top-[calc(66.66%+1px)] h-[2px] bg-gradient-to-r from-transparent via-blue-500/30 to-transparent pointer-events-none z-20 ttt-grid-glow"></div>
          <%!-- Glowing grid lines - vertical --%>
          <div class="absolute top-3 bottom-3 left-[calc(33.33%+1px)] w-[2px] bg-gradient-to-b from-transparent via-blue-500/30 to-transparent pointer-events-none z-20 ttt-grid-glow"></div>
          <div class="absolute top-3 bottom-3 left-[calc(66.66%+1px)] w-[2px] bg-gradient-to-b from-transparent via-blue-500/30 to-transparent pointer-events-none z-20 ttt-grid-glow"></div>

          <%= for {row, row_idx} <- Enum.with_index(@board) do %>
            <%= for {cell, col_idx} <- Enum.with_index(row) do %>
              <button
                class={[
                  "w-[7rem] h-[7rem] sm:w-[8rem] sm:h-[8rem] flex items-center justify-center relative z-10 m-[2px] rounded-xl transition-all duration-300",
                  cell_class(cell, @interactive && @game_status == "in_progress", @current_player),
                  if({row_idx, col_idx} in @winning_cells, do: "ttt-win-cell ring-2 ring-yellow-400/50", else: "")
                ]}
                phx-click={if @interactive && cell_empty?(cell) && @game_status == "in_progress", do: "human_move"}
                phx-value-row={row_idx}
                phx-value-col={col_idx}
                disabled={!@interactive || !cell_empty?(cell) || @game_status != "in_progress"}
              >
                <%!-- Subtle pattern in empty cells --%>
                <div :if={cell_empty?(cell)} class="absolute inset-2 opacity-[0.03] bg-[linear-gradient(45deg,rgba(148,163,184,0.5)_25%,transparent_25%,transparent_50%,rgba(148,163,184,0.5)_50%,rgba(148,163,184,0.5)_75%,transparent_75%)] bg-[length:6px_6px] rounded-lg pointer-events-none"></div>

                <%!-- Gradient overlay for filled cells --%>
                <div :if={!cell_empty?(cell)} class="absolute inset-0 bg-gradient-to-br from-white/5 to-transparent rounded-xl pointer-events-none"></div>

                <%!-- Animated SVG marks --%>
                <div :if={!cell_empty?(cell)} class="ttt-mark">
                  <%= if display_cell(cell) == "X" do %>
                    <svg width="52" height="52" viewBox="0 0 52 52" class="drop-shadow-lg filter" style={"filter: drop-shadow(0 0 6px rgba(34, 211, 238, 0.6))"}>
                      <line x1="10" y1="10" x2="42" y2="42" stroke="#22d3ee" stroke-width="5" stroke-linecap="round" class="ttt-x-line-1" />
                      <line x1="42" y1="10" x2="10" y2="42" stroke="#22d3ee" stroke-width="5" stroke-linecap="round" class="ttt-x-line-2" />
                    </svg>
                  <% else %>
                    <svg width="52" height="52" viewBox="0 0 52 52" class="drop-shadow-lg" style={"filter: drop-shadow(0 0 6px rgba(248, 113, 113, 0.6))"}>
                      <circle cx="26" cy="26" r="18" fill="none" stroke="#f87171" stroke-width="5" stroke-linecap="round" class="ttt-o-circle" />
                    </svg>
                  <% end %>
                </div>
              </button>
            <% end %>
          <% end %>
        </div>

        <%!-- Victory Overlay --%>
        <div :if={@game_over} class="absolute inset-0 bg-slate-900/70 backdrop-blur-sm rounded-2xl flex flex-col items-center justify-center z-30 ttt-victory-text">
          <div :if={@winner && @winner not in ["draw", nil]} class="text-center">
            <div class={"text-5xl font-black mb-2 #{player_color(@winner)}"}>
              {@winner}
            </div>
            <div class="text-2xl font-bold text-slate-200 uppercase tracking-[0.3em]">
              Victorious
            </div>
            <div class="text-sm text-slate-400 font-mono mt-3">
              in {@move_count} moves
            </div>
          </div>
          <div :if={@winner in ["draw", nil] && @game_status == "draw"} class="text-center">
            <div class="text-4xl font-black text-amber-400 text-glow-amber mb-2 uppercase tracking-[0.2em]">
              Stalemate
            </div>
            <div class="text-sm text-slate-400 font-mono mt-2">
              {@move_count} moves played
            </div>
          </div>

          <%!-- CSS-only confetti particles --%>
          <div :if={@winner && @winner not in ["draw", nil]} class="absolute inset-0 overflow-hidden pointer-events-none rounded-2xl">
            <%= for i <- 0..11 do %>
              <div
                class="ttt-particle rounded-full"
                style={"left: #{rem(i * 37 + 13, 90) + 5}%; top: #{rem(i * 23, 40)}%; width: #{rem(i, 3) + 3}px; height: #{rem(i, 3) + 3}px; background: #{confetti_color(i)}; animation-delay: #{i * 0.15}s; animation-duration: #{1.5 + rem(i, 3) * 0.4}s;"}
              ></div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Score Display --%>
      <div class="flex items-center gap-4 text-xs font-mono text-slate-500">
        <span class="text-cyan-400/70">X: {@x_moves}</span>
        <span class="text-slate-600">|</span>
        <span class="text-red-400/70">O: {@o_moves}</span>
        <span class="text-slate-600">|</span>
        <span class="text-slate-400">Total: {@move_count}</span>
      </div>

      <%!-- Move History Timeline --%>
      <div :if={@move_history != []} class="w-full max-w-md">
        <div class="glass-card rounded-xl border border-glass-border p-3">
          <div class="text-xs text-slate-500 uppercase tracking-widest font-bold mb-2">Move History</div>
          <div class="flex flex-wrap gap-1.5">
            <%= for {{mark, row, col}, idx} <- Enum.with_index(@move_history) do %>
              <div class={[
                "text-[11px] font-mono px-2 py-1 rounded-md border transition-all",
                if(mark == "X",
                  do: "bg-cyan-950/30 border-cyan-800/30 text-cyan-400/80",
                  else: "bg-red-950/30 border-red-800/30 text-red-400/80"),
                if({row, col} in @winning_cells, do: "ring-1 ring-yellow-400/40", else: "")
              ]}>
                <span class="opacity-50">{idx + 1}.</span> {mark} <span class="opacity-60">({row},{col})</span>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp cell_empty?(cell) when cell in [" ", "", nil], do: true
  defp cell_empty?(_), do: false

  defp display_cell(cell) when cell in [" ", "", nil], do: ""
  defp display_cell(cell), do: cell

  defp cell_class(cell, interactive, current_player) do
    base = "bg-slate-900/60 border border-slate-700/40 shadow-inner"

    if cell_empty?(cell) && interactive do
      hover_preview =
        if current_player == "X",
          do: "hover:border-cyan-500/40 hover:shadow-neon-cyan",
          else: "hover:border-red-500/40 hover:shadow-neon-red"

      "#{base} #{hover_preview} hover:bg-slate-800/80 cursor-pointer transform hover:-translate-y-0.5"
    else
      "#{base} cursor-default"
    end
  end

  defp player_color("X"), do: "text-cyan-400 text-glow-cyan"
  defp player_color("O"), do: "text-red-400 text-glow-red"
  defp player_color(_), do: "text-slate-500"

  @doc false
  def find_winning_cells(_board, winner) when winner in [nil, "draw"], do: []

  def find_winning_cells(board, winner) do
    lines = [
      # rows
      [{0, 0}, {0, 1}, {0, 2}],
      [{1, 0}, {1, 1}, {1, 2}],
      [{2, 0}, {2, 1}, {2, 2}],
      # columns
      [{0, 0}, {1, 0}, {2, 0}],
      [{0, 1}, {1, 1}, {2, 1}],
      [{0, 2}, {1, 2}, {2, 2}],
      # diagonals
      [{0, 0}, {1, 1}, {2, 2}],
      [{0, 2}, {1, 1}, {2, 0}]
    ]

    Enum.find(lines, [], fn cells ->
      Enum.all?(cells, fn {r, c} ->
        val = board |> Enum.at(r, []) |> Enum.at(c)
        val == winner
      end)
    end)
  end

  defp reconstruct_moves(board) do
    # Scan the board and reconstruct placement order.
    # Since X always goes first, we know X made ceil(n/2) moves and O made floor(n/2).
    # Without timestamps we can't know order, so list X moves then O moves.
    x_cells =
      for {row, r} <- Enum.with_index(board),
          {cell, c} <- Enum.with_index(row),
          cell == "X",
          do: {"X", r, c}

    o_cells =
      for {row, r} <- Enum.with_index(board),
          {cell, c} <- Enum.with_index(row),
          cell == "O",
          do: {"O", r, c}

    # Interleave: X always plays first
    interleave(x_cells, o_cells)
  end

  defp interleave([], bs), do: bs
  defp interleave(as, []), do: as
  defp interleave([a | as], [b | bs]), do: [a, b | interleave(as, bs)]

  defp confetti_color(i) do
    colors = ["#22d3ee", "#f87171", "#facc15", "#a78bfa", "#34d399", "#fb923c"]
    Enum.at(colors, rem(i, length(colors)))
  end
end
