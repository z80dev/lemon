defmodule LemonWeb.Games.Components.BoardComponent do
  @moduledoc false

  use Phoenix.Component

  attr :game_type, :string, required: true
  attr :game_state, :map, required: true

  def board(%{game_type: "connect4"} = assigns) do
    rows = Map.get(assigns.game_state, "board", [])
    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div id="connect4-board" class="inline-block rounded-xl border-4 border-blue-600 bg-blue-500 p-3 shadow-lg">
      <%= for row <- @rows do %>
        <div class="flex gap-1.5 mb-1.5">
          <%= for cell <- row do %>
            <span class={c4_cell_class(cell)} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def board(%{game_type: "rock_paper_scissors"} = assigns) do
    throws = Map.get(assigns.game_state, "throws", %{})
    resolved = Map.get(assigns.game_state, "resolved", false)
    winner = Map.get(assigns.game_state, "winner")

    p1_throw = Map.get(throws, "p1")
    p2_throw = Map.get(throws, "p2")

    assigns =
      assigns
      |> assign(:throws, throws)
      |> assign(:resolved, resolved)
      |> assign(:winner, winner)
      |> assign(:p1_throw, p1_throw)
      |> assign(:p2_throw, p2_throw)

    ~H"""
    <div id="rps-board" class="flex flex-col items-center gap-6">
      <%!-- Battle Arena --%>
      <div class="flex items-center gap-6">
        <%!-- Player 1 --%>
        <div class="flex flex-col items-center">
          <div class={["flex h-24 w-24 items-center justify-center rounded-2xl text-5xl shadow-lg transition-all", rps_throw_bg(@p1_throw)]}>
            <%= if @p1_throw do %>
              {rps_emoji(@p1_throw)}
            <% else %>
              <span class="animate-pulse text-slate-400">?</span>
            <% end %>
          </div>
          <span class="mt-2 text-sm font-medium text-slate-600">Player 1</span>
        </div>

        <%!-- VS --%>
        <div class="flex flex-col items-center">
          <span class="text-2xl font-black text-slate-300">VS</span>
          <%= if @resolved do %>
            <span class="mt-1 text-xs font-medium text-emerald-600">Resolved</span>
          <% else %>
            <span class="mt-1 text-xs text-slate-400">Waiting...</span>
          <% end %>
        </div>

        <%!-- Player 2 --%>
        <div class="flex flex-col items-center">
          <div class={["flex h-24 w-24 items-center justify-center rounded-2xl text-5xl shadow-lg transition-all", rps_throw_bg(@p2_throw)]}>
            <%= if @p2_throw do %>
              {rps_emoji(@p2_throw)}
            <% else %>
              <span class="animate-pulse text-slate-400">?</span>
            <% end %>
          </div>
          <span class="mt-2 text-sm font-medium text-slate-600">Player 2</span>
        </div>
      </div>

      <%!-- Result --%>
      <%= if @resolved do %>
        <div class={["rounded-full px-6 py-2 text-sm font-bold", rps_result_class(@winner)]}>
          <%= case @winner do %>
            <% "p1" -> %> 🏆 Player 1 Wins!
            <% "p2" -> %> 🏆 Player 2 Wins!
            <% _ -> %> 🤝 Draw!
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def board(%{game_type: "tic_tac_toe"} = assigns) do
    board = Map.get(assigns.game_state, "board", [])
    winner = Map.get(assigns.game_state, "winner")
    winning_line = Map.get(assigns.game_state, "winning_line", [])

    assigns =
      assigns
      |> assign(:board_rows, board)
      |> assign(:winner, winner)
      |> assign(:winning_line, winning_line)

    ~H"""
    <div id="tic-tac-toe-board" class="inline-block rounded-xl border-4 border-slate-700 bg-slate-700 p-2 shadow-lg">
      <%= for {row, row_idx} <- Enum.with_index(@board_rows) do %>
        <div class="flex gap-0.5 mb-0.5">
          <%= for {cell, col_idx} <- Enum.with_index(row) do %>
            <% pos = {row_idx, col_idx} %>
            <span class={ttt_cell_class(cell, pos in @winning_line)} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def board(assigns) do
    ~H"""
    <div class="rounded-xl border border-slate-200 bg-slate-50 p-8 text-center">
      <div class="mb-2 text-3xl">🎮</div>
      <p class="text-sm text-slate-600">Unsupported game type: {@game_type}</p>
    </div>
    """
  end

  # Connect4 cell styles
  defp c4_cell_class(0), do: "block h-10 w-10 rounded-full bg-white shadow-inner"
  defp c4_cell_class(1), do: "block h-10 w-10 rounded-full bg-red-500 shadow-md ring-2 ring-red-600"
  defp c4_cell_class(2), do: "block h-10 w-10 rounded-full bg-yellow-400 shadow-md ring-2 ring-yellow-500"
  defp c4_cell_class(_), do: "block h-10 w-10 rounded-full bg-slate-300"

  # Tic-tac-toe cell styles
  defp ttt_cell_class(nil, _is_winning) do
    "flex h-16 w-16 items-center justify-center rounded bg-slate-200 text-3xl font-bold text-slate-400 transition-colors hover:bg-slate-300"
  end
  defp ttt_cell_class("X", true) do
    "flex h-16 w-16 items-center justify-center rounded bg-emerald-100 text-3xl font-bold text-emerald-600 ring-2 ring-emerald-400"
  end
  defp ttt_cell_class("O", true) do
    "flex h-16 w-16 items-center justify-center rounded bg-emerald-100 text-3xl font-bold text-emerald-600 ring-2 ring-emerald-400"
  end
  defp ttt_cell_class("X", false) do
    "flex h-16 w-16 items-center justify-center rounded bg-white text-3xl font-bold text-blue-600 shadow-sm"
  end
  defp ttt_cell_class("O", false) do
    "flex h-16 w-16 items-center justify-center rounded bg-white text-3xl font-bold text-rose-500 shadow-sm"
  end
  defp ttt_cell_class(_, _), do: "flex h-16 w-16 items-center justify-center rounded bg-slate-200"

  # RPS helpers
  defp rps_emoji("rock"), do: "✊"
  defp rps_emoji("paper"), do: "✋"
  defp rps_emoji("scissors"), do: "✌️"
  defp rps_emoji(_), do: "❓"

  defp rps_throw_bg(nil), do: "bg-slate-100"
  defp rps_throw_bg(_), do: "bg-white"

  defp rps_result_class("p1"), do: "bg-emerald-100 text-emerald-700"
  defp rps_result_class("p2"), do: "bg-emerald-100 text-emerald-700"
  defp rps_result_class(_), do: "bg-slate-100 text-slate-600"
end
