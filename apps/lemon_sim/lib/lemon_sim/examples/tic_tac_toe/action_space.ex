defmodule LemonSim.Examples.TicTacToe.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Examples.TicTacToe.Events

  @spec game_tools(String.t()) :: [AgentTool.t()]
  def game_tools(player) do
    [
      %AgentTool{
        name: "place_mark",
        description: "Place your mark (#{player}) on the board at the specified row and column.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "row" => %{"type" => "integer", "description" => "Row index (0-2)"},
            "col" => %{"type" => "integer", "description" => "Column index (0-2)"}
          },
          "required" => ["row", "col"]
        },
        label: "Place Mark",
        execute: fn _tool_call_id, params, _signal, _on_update ->
          row = Map.get(params, "row")
          col = Map.get(params, "col")

          cond do
            not (is_integer(row) and is_integer(col)) ->
              {:error, "row/col must be integers"}

            row < 0 or row > 2 or col < 0 or col > 2 ->
              {:error, "row/col out of bounds (expected 0..2)"}

            true ->
              event = Events.place_mark(player, row, col)

              {:ok,
               %AgentToolResult{
                 content: [AgentCore.text_content("proposed #{player} at (#{row}, #{col})")],
                 details: %{"event" => event},
                 trust: :trusted
               }}
          end
        end
      }
    ]
  end

  @impl true
  def tools(state, _opts) do
    if state.world[:status] == "in_progress" do
      {:ok, game_tools(state.world[:current_player])}
    else
      {:ok, []}
    end
  end
end
