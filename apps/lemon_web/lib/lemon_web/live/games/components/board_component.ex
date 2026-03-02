defmodule LemonWeb.Games.Components.BoardComponent do
  @moduledoc false

  use Phoenix.Component

  attr :game_type, :string, required: true
  attr :game_state, :map, required: true

  def board(%{game_type: "connect4"} = assigns) do
    rows = Map.get(assigns.game_state, "board", [])
    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div id="connect4-board" class="inline-block rounded-xl border-4 border-blue-600 bg-blue-500 p-2 shadow-lg">
      <%= for {row, row_idx} <- Enum.with_index(@rows) do %>
        <div class="flex gap-1">
          <%= for {cell, col_idx} <- Enum.with_index(row) do %>
            <span class={connect4_cell_class(cell)} style={"animation-delay: #{row_idx * 50 + col_idx * 30}ms"} />
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

    assigns =
      assigns
      |> assign(:throws, throws)
      |> assign(:resolved, resolved)
      |> assign(:winner, winner)

    ~H"""
    <div id="rps-board" class="flex items-center gap-6 rounded-xl bg-slate-50 p-6">
      <.rps_throw player="p1" throw={Map.get(@throws, "p1")} />
      <div class="text-2xl font-black text-slate-300">VS</div>
      <.rps_throw player="p2" throw={Map.get(@throws, "p2")} />
    </div>
    """
  end

  def board(%{game_type: "tic_tac_toe"} = assigns) do
    rows = Map.get(assigns.game_state, "board", [])
    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div id="tic-tac-toe-board" class="inline-block rounded-xl bg-slate-800 p-2 shadow-lg">
      <%= for row <- @rows do %>
        <div class="flex gap-1">
          <%= for cell <- row do %>
            <span class={tictactoe_cell_class(cell)}>
              {tictactoe_cell_content(cell)}
            </span>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def board(%{game_type: "battleship"} = assigns) do
    my_grid = Map.get(assigns.game_state, "my_grid", [])
    opponent_grid = Map.get(assigns.game_state, "opponent_grid", [])
    my_ships = Map.get(assigns.game_state, "my_ships", [])
    opponent_ships = Map.get(assigns.game_state, "opponent_ships", [])
    phase = Map.get(assigns.game_state, "phase", "setup")
    last_move = Map.get(assigns.game_state, "last_move")
    winner = Map.get(assigns.game_state, "winner")

    assigns =
      assigns
      |> assign(:my_grid, my_grid)
      |> assign(:opponent_grid, opponent_grid)
      |> assign(:my_ships, my_ships)
      |> assign(:opponent_ships, opponent_ships)
      |> assign(:phase, phase)
      |> assign(:last_move, last_move)
      |> assign(:winner, winner)

    ~H"""
    <div id="battleship-board" class="space-y-4">
      <%!-- Phase Indicator --%>
      <div class="flex justify-center">
        <span class={[
          "rounded-full px-3 py-1 text-xs font-medium",
          @phase == "setup" && "bg-amber-100 text-amber-700",
          @phase == "battle" && "bg-rose-100 text-rose-700"
        ]}>
          <%= case @phase do %>
            <% "setup" -> %>⚓ Setup Phase
            <% "battle" -> %>💥 Battle Phase
            <% _ -> %>Unknown Phase
          <% end %>
        </span>
      </div>

      <%!-- Last Move Banner --%>
      <%= if @last_move do %>
        <div class={[
          "rounded-lg px-4 py-2 text-center text-sm font-medium",
          @last_move["result"] == "hit" && "bg-rose-100 text-rose-700",
          @last_move["result"] == "miss" && "bg-slate-100 text-slate-600"
        ]}>
          <%= if @last_move["result"] == "hit" do %>
            💥 HIT at {<<65 + @last_move["row"]>>}{@last_move["col"] + 1}
            <%= if @last_move["sunk_ship"] do %>
              <span class="ml-2 font-bold">— Ship Sunk!</span>
            <% end %>
          <% else %>
            💨 Miss at {<<65 + @last_move["row"]>>}{@last_move["col"] + 1}
          <% end %>
        </div>
      <% end %>

      <%!-- Winner Banner --%>
      <%= if @winner do %>
        <div class="rounded-lg bg-emerald-100 px-4 py-2 text-center text-sm font-bold text-emerald-700">
          🏆 {@winner} Wins!
        </div>
      <% end %>

      <%!-- Dual Grid Layout --%>
      <div class="flex flex-col gap-6 lg:flex-row lg:justify-center">
        <%!-- My Fleet --%>
        <div class="rounded-xl border-2 border-blue-300 bg-blue-50 p-3">
          <div class="mb-2 text-center text-sm font-semibold text-blue-700">🚢 My Fleet</div>
          <div class="inline-block rounded bg-blue-200 p-1">
            <%= for {row, row_idx} <- Enum.with_index(@my_grid) do %>
              <div class="flex">
                <%= for {cell, col_idx} <- Enum.with_index(row) do %>
                  <span class={battleship_my_cell_class(cell)} />
                <% end %>
              </div>
            <% end %>
          </div>
          <%!-- My Ships Status --%>
          <div class="mt-2 space-y-1">
            <%= for ship <- @my_ships do %>
              <div class="flex items-center justify-between text-xs">
                <span class="capitalize text-slate-600">{ship.name}</span>
                <span class={ship.hits >= ship.size && "text-rose-600 font-bold" || "text-emerald-600"}>
                  {ship.hits}/{ship.size}
                </span>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Enemy Waters --%>
        <div class="rounded-xl border-2 border-rose-300 bg-rose-50 p-3">
          <div class="mb-2 text-center text-sm font-semibold text-rose-700">🎯 Enemy Waters</div>
          <div class="inline-block rounded bg-rose-200 p-1">
            <%= for {row, row_idx} <- Enum.with_index(@opponent_grid) do %>
              <div class="flex">
                <%= for {cell, col_idx} <- Enum.with_index(row) do %>
                  <% is_last = @last_move && @last_move["row"] == row_idx && @last_move["col"] == col_idx %>
                  <span class={battleship_opponent_cell_class(cell, is_last)} />
                <% end %>
              </div>
            <% end %>
          </div>
          <%!-- Opponent Ships Status (hidden until sunk) --%>
          <div class="mt-2 space-y-1">
            <%= for ship <- @opponent_ships do %>
              <div class="flex items-center justify-between text-xs">
                <span class="capitalize text-slate-600">{ship.name}</span>
                <%= if ship.sunk do %>
                  <span class="font-bold text-rose-600">💀 Sunk</span>
                <% else %>
                  <span class="text-slate-400">???</span>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def board(assigns) do
    ~H"""
    <p class="text-sm text-slate-600">Unsupported game type: {@game_type}</p>
    """
  end

  def rps_throw(assigns) do
    icon = case @throw do
      "rock" -> "✊"
      "paper" -> "✋"
      "scissors" -> "✌️"
      _ -> "❓"
    end

    color = case @throw do
      nil -> "bg-slate-200 text-slate-400"
      _ -> "bg-white text-slate-900 shadow-md"
    end

    assigns = assign(assigns, icon: icon, color: color)

    ~H"""
    <div class={["flex h-20 w-20 items-center justify-center rounded-full text-4xl transition-all", @color]}>
      {@icon}
    </div>
    """
  end

  defp connect4_cell_class(0), do: "block h-10 w-10 rounded-full bg-slate-200 shadow-inner"
  defp connect4_cell_class(1), do: "block h-10 w-10 rounded-full bg-red-500 shadow-md"
  defp connect4_cell_class(2), do: "block h-10 w-10 rounded-full bg-yellow-400 shadow-md"
  defp connect4_cell_class(_), do: "block h-10 w-10 rounded-full bg-slate-400"

  defp tictactoe_cell_class(nil), do: "flex h-16 w-16 items-center justify-center rounded-lg bg-slate-700 text-2xl font-bold text-slate-600 transition-all hover:bg-slate-600"
  defp tictactoe_cell_class("X"), do: "flex h-16 w-16 items-center justify-center rounded-lg bg-slate-700 text-2xl font-bold text-blue-400 shadow-lg"
  defp tictactoe_cell_class("O"), do: "flex h-16 w-16 items-center justify-center rounded-lg bg-slate-700 text-2xl font-bold text-rose-400 shadow-lg"
  defp tictactoe_cell_class(_), do: "flex h-16 w-16 items-center justify-center rounded-lg bg-slate-700 text-2xl font-bold"

  defp tictactoe_cell_content(nil), do: ""
  defp tictactoe_cell_content(cell), do: cell

  # Battleship cell styling
  defp battleship_my_cell_class(nil), do: "block h-6 w-6 bg-blue-300 m-0.5 rounded-sm"
  defp battleship_my_cell_class(%{"fired" => true, "hit" => false}), do: "block h-6 w-6 bg-slate-400 m-0.5 rounded-sm"
  defp battleship_my_cell_class(%{"fired" => true, "hit" => true}), do: "block h-6 w-6 bg-rose-500 m-0.5 rounded-sm"
  defp battleship_my_cell_class(%{"ship" => true}), do: "block h-6 w-6 bg-emerald-500 m-0.5 rounded-sm"
  defp battleship_my_cell_class(_), do: "block h-6 w-6 bg-blue-300 m-0.5 rounded-sm"

  defp battleship_opponent_cell_class(cell, is_last \\ false)
  defp battleship_opponent_cell_class(%{"fired" => false}, false), do: "block h-6 w-6 bg-rose-300 m-0.5 rounded-sm"
  defp battleship_opponent_cell_class(%{"fired" => false}, true), do: "block h-6 w-6 bg-rose-300 m-0.5 rounded-sm ring-2 ring-yellow-400"
  defp battleship_opponent_cell_class(%{"fired" => true, "hit" => false}, false), do: "block h-6 w-6 bg-slate-400 m-0.5 rounded-sm"
  defp battleship_opponent_cell_class(%{"fired" => true, "hit" => false}, true), do: "block h-6 w-6 bg-slate-400 m-0.5 rounded-sm ring-2 ring-yellow-400"
  defp battleship_opponent_cell_class(%{"fired" => true, "hit" => true}, false), do: "block h-6 w-6 bg-rose-600 m-0.5 rounded-sm"
  defp battleship_opponent_cell_class(%{"fired" => true, "hit" => true}, true), do: "block h-6 w-6 bg-rose-600 m-0.5 rounded-sm ring-2 ring-yellow-400"
  defp battleship_opponent_cell_class(_, false), do: "block h-6 w-6 bg-rose-300 m-0.5 rounded-sm"
  defp battleship_opponent_cell_class(_, true), do: "block h-6 w-6 bg-rose-300 m-0.5 rounded-sm ring-2 ring-yellow-400"
end
