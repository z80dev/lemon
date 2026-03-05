defmodule LemonSim.Examples.TicTacToe.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias LemonSim.ActionSpace, as: SimActionSpace
  alias LemonSim.Examples.TicTacToe.Events

  @impl true
  def tools(state, _opts) do
    if state.world[:status] == "in_progress" do
      player = state.world[:current_player]

      legal_actions =
        for row <- 0..2,
            col <- 0..2,
            empty_cell?(state.world[:board], row, col) do
          SimActionSpace.legal_action(
            "place_mark",
            %{"row" => row, "col" => col},
            description:
              "Place your mark (#{player}) on the board at the specified row and column.",
            label: "Place Mark",
            event: Events.place_mark(player, row, col),
            result_text: "proposed #{player} at (#{row}, #{col})"
          )
        end

      {:ok, SimActionSpace.to_tools(legal_actions)}
    else
      {:ok, []}
    end
  end

  defp empty_cell?(board, row, col) do
    get_in(board, [Access.at(row), Access.at(col)]) == " "
  end
end
