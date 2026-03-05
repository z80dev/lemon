defmodule LemonSim.Examples.TicTacToe.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Examples.TicTacToe.Events

  @impl true
  def tools(state, _opts) do
    if state.world[:status] == "in_progress" do
      player = state.world[:current_player]
      {:ok, [place_mark_tool(player)]}
    else
      {:ok, []}
    end
  end

  defp place_mark_tool(player) do
    %AgentTool{
      name: "place_mark",
      description: "Place your mark (#{player}) on the board at the specified row and column.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "row" => %{"type" => "integer", "description" => "Row index (0-2)"},
          "col" => %{"type" => "integer", "description" => "Column index (0-2)"}
        },
        "required" => ["row", "col"],
        "additionalProperties" => false
      },
      label: "Place Mark",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        row = Map.get(params || %{}, "row", Map.get(params || %{}, :row))
        col = Map.get(params || %{}, "col", Map.get(params || %{}, :col))
        event = Events.place_mark(player, row, col)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("proposed #{player} at (#{inspect(row)}, #{inspect(col)})")
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end
end
