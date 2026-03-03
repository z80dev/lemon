defmodule LemonWeb.Games.Components.BoardComponent do
  @moduledoc false

  use Phoenix.Component

  attr(:game_type, :string, required: true)
  attr(:game_state, :map, required: true)

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
    p1_shots = Map.get(assigns.game_state, "p1_shots", [])
    p2_shots = Map.get(assigns.game_state, "p2_shots", [])
    p1_ships = Map.get(assigns.game_state, "p1_ships", [])
    p2_ships = Map.get(assigns.game_state, "p2_ships", [])
    phase = Map.get(assigns.game_state, "phase", "placement")

    assigns =
      assigns
      |> assign(:p1_shots, p1_shots)
      |> assign(:p2_shots, p2_shots)
      |> assign(:p1_ships, p1_ships)
      |> assign(:p2_ships, p2_ships)
      |> assign(:phase, phase)

    ~H"""
    <div id="battleship-board" class="flex flex-col gap-4">
      <%= if @phase == "placement" do %>
        <div class="rounded-xl bg-slate-100 p-4 text-center">
          <p class="text-slate-600">🚢 Ships being placed...</p>
        </div>
      <% else %>
        <div class="flex flex-wrap justify-center gap-4">
          <div class="rounded-xl border-2 border-blue-300 bg-slate-900 p-2">
            <p class="mb-2 text-center text-xs text-blue-300">P1 Shots</p>
            <.battleship_grid shots={@p1_shots} ships={@p2_ships} />
          </div>
          <div class="rounded-xl border-2 border-rose-300 bg-slate-900 p-2">
            <p class="mb-2 text-center text-xs text-rose-300">P2 Shots</p>
            <.battleship_grid shots={@p2_shots} ships={@p1_ships} />
          </div>
        </div>
        <div class="flex justify-center gap-6 text-xs text-slate-500">
          <div class="flex items-center gap-1"><span class="h-3 w-3 rounded-sm bg-slate-700"></span> Miss</div>
          <div class="flex items-center gap-1"><span class="h-3 w-3 rounded-sm bg-red-500"></span> Hit</div>
          <div class="flex items-center gap-1"><span class="h-3 w-3 rounded-sm bg-emerald-600"></span> Sunk</div>
        </div>
      <% end %>
    </div>
    """
  end

  def board(assigns) do
    ~H"""
    <p class="text-sm text-slate-600">Unsupported game type: {@game_type}</p>
    """
  end

  attr(:player, :string, default: nil)
  attr(:throw, :string, default: nil)

  def rps_throw(assigns) do
    throw = Map.get(assigns, :throw)

    icon =
      case throw do
        "rock" -> "✊"
        "paper" -> "✋"
        "scissors" -> "✌️"
        _ -> "❓"
      end

    color =
      case throw do
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

  defp tictactoe_cell_class(nil),
    do:
      "flex h-16 w-16 items-center justify-center rounded-lg bg-slate-700 text-2xl font-bold text-slate-600 transition-all hover:bg-slate-600"

  defp tictactoe_cell_class("X"),
    do:
      "flex h-16 w-16 items-center justify-center rounded-lg bg-slate-700 text-2xl font-bold text-blue-400 shadow-lg"

  defp tictactoe_cell_class("O"),
    do:
      "flex h-16 w-16 items-center justify-center rounded-lg bg-slate-700 text-2xl font-bold text-rose-400 shadow-lg"

  defp tictactoe_cell_class(_),
    do: "flex h-16 w-16 items-center justify-center rounded-lg bg-slate-700 text-2xl font-bold"

  defp tictactoe_cell_content(nil), do: ""
  defp tictactoe_cell_content(cell), do: cell

  # Battleship grid component
  attr(:shots, :list, required: true)
  attr(:ships, :list, required: true)

  def battleship_grid(assigns) do
    # Build shot map: {r,c} -> :hit/:miss
    shot_map =
      for {r, c, hit?} <- assigns.shots, into: %{} do
        {{r, c}, if(hit?, do: :hit, else: :miss)}
      end

    # Build sunk ship cells
    sunk_cells =
      for ship <- assigns.ships,
          length(ship.hits) == ship.size,
          cell <- ship.cells,
          into: MapSet.new() do
        cell
      end

    # Build hit ship cells (not sunk)
    hit_cells =
      for ship <- assigns.ships,
          length(ship.hits) < ship.size,
          {r, c} <- ship.hits,
          into: MapSet.new() do
        {r, c}
      end

    assigns =
      assigns
      |> assign(:shot_map, shot_map)
      |> assign(:sunk_cells, sunk_cells)
      |> assign(:hit_cells, hit_cells)

    ~H"""
    <div class="grid grid-cols-8 gap-0.5">
      <%= for r <- 0..7, c <- 0..7 do %>
        <div class={battleship_cell_class(r, c, @shot_map, @sunk_cells, @hit_cells)}></div>
      <% end %>
    </div>
    """
  end

  defp battleship_cell_class(r, c, shot_map, sunk_cells, hit_cells) do
    coord = {r, c}

    case Map.get(shot_map, coord) do
      :hit ->
        cond do
          MapSet.member?(sunk_cells, coord) -> "h-4 w-4 rounded-sm bg-emerald-600"
          MapSet.member?(hit_cells, coord) -> "h-4 w-4 rounded-sm bg-red-500"
          true -> "h-4 w-4 rounded-sm bg-red-500"
        end

      :miss ->
        "h-4 w-4 rounded-sm bg-slate-700"

      nil ->
        "h-4 w-4 rounded-sm bg-slate-800"
    end
  end
end
