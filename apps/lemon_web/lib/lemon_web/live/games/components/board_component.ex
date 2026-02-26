defmodule LemonWeb.Games.Components.BoardComponent do
  @moduledoc false

  use Phoenix.Component

  attr :game_type, :string, required: true
  attr :game_state, :map, required: true

  def board(%{game_type: "connect4"} = assigns) do
    rows = Map.get(assigns.game_state, "board", [])
    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div id="connect4-board" class="inline-block rounded-lg border border-slate-200 bg-slate-50 p-2">
      <%= for row <- @rows do %>
        <div class="flex gap-1">
          <%= for cell <- row do %>
            <span class={cell_class(cell)} />
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
    <div id="rps-board" class="space-y-1 text-sm">
      <p>p1 throw: {Map.get(@throws, "p1", "?")}</p>
      <p>p2 throw: {Map.get(@throws, "p2", "?")}</p>
      <p>resolved: {to_string(@resolved)}</p>
      <p>winner: {@winner || "—"}</p>
    </div>
    """
  end

  def board(%{game_type: "tic_tac_toe"} = assigns) do
    board = Map.get(assigns.game_state, "board", [])
    assigns = assign(assigns, :board_rows, board)

    ~H"""
    <div id="tic-tac-toe-board" class="inline-block rounded-lg border-2 border-slate-300 bg-slate-100 p-3">
      <%= for row <- @board_rows do %>
        <div class="flex gap-1 mb-1">
          <%= for cell <- row do %>
            <span class={ttt_cell_class(cell)} />
          <% end %>
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

  defp cell_class(0), do: "block h-6 w-6 rounded-full bg-slate-200"
  defp cell_class(1), do: "block h-6 w-6 rounded-full bg-red-500"
  defp cell_class(2), do: "block h-6 w-6 rounded-full bg-yellow-400"
  defp cell_class(_), do: "block h-6 w-6 rounded-full bg-slate-400"

  defp ttt_cell_class(nil), do: "flex h-12 w-12 items-center justify-center rounded bg-white text-2xl font-bold text-slate-300"
  defp ttt_cell_class("X"), do: "flex h-12 w-12 items-center justify-center rounded bg-white text-2xl font-bold text-blue-600"
  defp ttt_cell_class("O"), do: "flex h-12 w-12 items-center justify-center rounded bg-white text-2xl font-bold text-rose-500"
  defp ttt_cell_class(_), do: "flex h-12 w-12 items-center justify-center rounded bg-slate-200 text-2xl"
end
