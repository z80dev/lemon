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

  def board(%{game_type: "battleship"} = assigns) do
    phase = Map.get(assigns.game_state, "phase", "setup")
    my_grid = Map.get(assigns.game_state, "my_grid", [])
    opponent_grid = Map.get(assigns.game_state, "opponent_grid", [])
    my_ships = Map.get(assigns.game_state, "my_ships", [])
    opponent_ships = Map.get(assigns.game_state, "opponent_ships", [])
    last_move = Map.get(assigns.game_state, "last_move")
    winner = Map.get(assigns.game_state, "winner")

    assigns =
      assigns
      |> assign(:phase, phase)
      |> assign(:my_grid, my_grid)
      |> assign(:opponent_grid, opponent_grid)
      |> assign(:my_ships, my_ships)
      |> assign(:opponent_ships, opponent_ships)
      |> assign(:last_move, last_move)
      |> assign(:winner, winner)

    ~H"""
    <div id="battleship-board" class="flex flex-col gap-4">
      <%!-- Phase indicator --%>
      <div class="flex justify-center">
        <span class={["rounded-full px-4 py-1 text-xs font-bold uppercase tracking-wide",
          if(@phase == "setup", do: "bg-amber-100 text-amber-700", else: "bg-rose-100 text-rose-700")]}>
          <%= if @phase == "setup", do: "⚓ Setup Phase", else: "💥 Battle Phase" %>
        </span>
      </div>

      <%!-- Dual grid display --%>
      <div class="flex flex-col gap-6 lg:flex-row lg:gap-8">
        <%!-- My Fleet (left) --%>
        <div class="flex flex-col items-center gap-2">
          <div class="flex items-center gap-2">
            <span class="text-sm font-bold text-slate-700">🚢 My Fleet</span>
            <span class="text-xs text-slate-500">({{ships_alive(@my_ships)}}/{{length(@my_ships)}})</span>
          </div>
          <div class="rounded-xl border-4 border-blue-600 bg-blue-500 p-2 shadow-lg">
            <%= for {row, row_idx} <- Enum.with_index(@my_grid) do %>
              <div class="flex gap-0.5 mb-0.5">
                <%= for {cell, col_idx} <- Enum.with_index(row) do %>
                  <span class={bs_my_cell_class(cell)} />
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- VS indicator --%>
        <div class="hidden items-center justify-center lg:flex">
          <span class="text-2xl font-black text-slate-300">VS</span>
        </div>

        <%!-- Enemy Waters (right) --%>
        <div class="flex flex-col items-center gap-2">
          <div class="flex items-center gap-2">
            <span class="text-sm font-bold text-slate-700">🎯 Enemy Waters</span>
            <span class="text-xs text-slate-500">({{ships_alive(@opponent_ships)}}/{{length(@opponent_ships)}})</span>
          </div>
          <div class="rounded-xl border-4 border-rose-600 bg-rose-500 p-2 shadow-lg">
            <%= for {row, row_idx} <- Enum.with_index(@opponent_grid) do %>
              <div class="flex gap-0.5 mb-0.5">
                <%= for {cell, col_idx} <- Enum.with_index(row) do %>
                  <% is_last = @last_move && @last_move["row"] == row_idx && @last_move["col"] == col_idx %>
                  <span class={bs_opponent_cell_class(cell, is_last)} />
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Last move indicator --%>
      <%= if @last_move do %>
        <div class="flex justify-center">
          <div class={["rounded-lg px-4 py-2 text-sm font-medium",
            if(@last_move["result"] == "hit", do: "bg-rose-100 text-rose-700", else: "bg-slate-100 text-slate-600")]}>
            <%= if @last_move["result"] == "hit" do %>
              💥 Hit at <%= to_letter(@last_move["col"]) %><%= @last_move["row"] + 1 %>
              <%= if @last_move["sunk_ship"] do %>
                <span class="ml-1 font-bold">— Ship Sunk!</span>
              <% end %>
            <% else %>
              💨 Miss at <%= to_letter(@last_move["col"]) %><%= @last_move["row"] + 1 %>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Ship status --%>
      <div class="grid grid-cols-2 gap-4 rounded-lg bg-slate-50 p-3">
        <div>
          <p class="mb-1 text-xs font-bold text-slate-500">My Ships</p>
          <div class="flex flex-wrap gap-1">
            <%= for ship <- @my_ships do %>
              <span class={["rounded px-2 py-0.5 text-xs",
                if(ship_sunk?(ship), do: "bg-rose-100 text-rose-600 line-through", else: "bg-emerald-100 text-emerald-600")]}>
                <%= ship_emoji(ship.name) %> <%= String.capitalize(ship.name) %>
              </span>
            <% end %>
          </div>
        </div>
        <div>
          <p class="mb-1 text-xs font-bold text-slate-500">Enemy Ships</p>
          <div class="flex flex-wrap gap-1">
            <%= for ship <- @opponent_ships do %>
              <span class={["rounded px-2 py-0.5 text-xs",
                if(ship.sunk, do: "bg-emerald-100 text-emerald-600", else: "bg-slate-200 text-slate-500")]}>
                <%= if ship.sunk, do: "💥", else: "❓" %> <%= String.capitalize(ship.name) %>
              </span>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Winner banner --%>
      <%= if @winner do %>
        <div class="flex justify-center">
          <div class="rounded-full bg-emerald-100 px-6 py-2 text-sm font-bold text-emerald-700">
            🏆 <%= String.upcase(@winner) %> Wins!
          </div>
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

  # Battleship helpers
  defp bs_my_cell_class(nil), do: "block h-6 w-6 rounded-sm bg-blue-400"
  defp bs_my_cell_class(%{"ship" => true, "hit" => true}), do: "block h-6 w-6 rounded-sm bg-rose-500 ring-1 ring-rose-600"
  defp bs_my_cell_class(%{"ship" => true}), do: "block h-6 w-6 rounded-sm bg-slate-600"
  defp bs_my_cell_class(%{"fired" => true}), do: "block h-6 w-6 rounded-sm bg-blue-300"
  defp bs_my_cell_class(_), do: "block h-6 w-6 rounded-sm bg-blue-400"

  defp bs_opponent_cell_class(%{"hit" => true}, true), do: "block h-6 w-6 rounded-sm bg-rose-500 ring-2 ring-rose-400 animate-pulse"
  defp bs_opponent_cell_class(%{"hit" => true}, false), do: "block h-6 w-6 rounded-sm bg-rose-500"
  defp bs_opponent_cell_class(%{"fired" => true}, true), do: "block h-6 w-6 rounded-sm bg-slate-300 ring-2 ring-slate-400 animate-pulse"
  defp bs_opponent_cell_class(%{"fired" => true}, false), do: "block h-6 w-6 rounded-sm bg-slate-300"
  defp bs_opponent_cell_class(_, _), do: "block h-6 w-6 rounded-sm bg-rose-400"

  defp ship_sunk?(%{hits: hits, size: size}), do: hits >= size
  defp ship_sunk?(%{} = ship), do: Map.get(ship, :sunk, false)
  defp ship_sunk?(_), do: false

  defp ships_alive(ships) do
    Enum.count(ships, fn ship -> not ship_sunk?(ship) end)
  end

  defp ship_emoji("carrier"), do: "🛳️"
  defp ship_emoji("battleship"), do: "🚢"
  defp ship_emoji("cruiser"), do: "⛴️"
  defp ship_emoji("submarine"), do: "🛥️"
  defp ship_emoji("destroyer"), do: "🚤"
  defp ship_emoji(_), do: "🚢"

  defp to_letter(col), do: String.at("ABCDEFGHIJ", col)
end
