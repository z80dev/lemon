alias AgentCore.Types.{AgentTool, AgentToolResult}
alias LemonSim.{State, DecisionFrame}
alias LemonSim.Projectors.SectionedProjector
alias LemonSim.Deciders.ToolLoopDecider

# We're going to make an agent play tic tac toe
# The agent will be given a description of the game, and a set of tools it can use to interact with the game
# The agent will then be asked to make a move, and we will see how it does
# First, let's define the game state and the tools the agent can use

# World State (the tic tac toe board)
initial_world = %{
  board: [
    [" ", " ", " "],
    [" ", " ", " "],
    [" ", " ", " "]
  ],
  current_player: "X"
}

# Game State
start_state =
  State.new(
    sim_id: "tic_tac_toe_1",
    world: initial_world,
    intent: %{
      goal: "Play tic tac toe and win the game as X"
    },
    plan_history: []
  )

IO.puts("Initial State:")
IO.inspect(start_state)

frame = DecisionFrame.from_state(start_state)

occupied? = fn board, row, col ->
  case Enum.at(board, row) do
    nil ->
      false

    row_cells ->
      case Enum.at(row_cells, col) do
        nil -> false
        " " -> false
        "" -> false
        _ -> true
      end
  end
end

tools = [
  %AgentTool{
    name: "place_mark",
    description: "Place your mark (X) on the board at the specified row and column.",
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
      board = get_in(frame.world, [:board]) || []

      cond do
        not (is_integer(row) and is_integer(col)) ->
          {:error, "row/col must be integers"}

        row < 0 or row > 2 or col < 0 or col > 2 ->
          {:error, "row/col out of bounds (expected 0..2)"}

        occupied?.(board, row, col) ->
          {:error, "cell (#{row}, #{col}) is already occupied"}

        true ->
          {:ok,
           %AgentToolResult{
             content: [AgentCore.text_content("placed X at (#{row}, #{col})")],
             details: %{
               "event" => %{
                 "kind" => "place_mark",
                 "payload" => %{
                   "player" => "X",
                   "row" => row,
                   "col" => col
                 }
               }
             },
             trust: :trusted
           }}
      end
    end
  }
]
