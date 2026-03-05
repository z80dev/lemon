alias AgentCore.Types.{AgentTool, AgentToolResult}
alias LemonSim.{Runner, State}
alias LemonSim.Deciders.ToolLoopDecider
alias LemonSim.Projectors.SectionedProjector

defmodule TicTacToe.Events do
  alias LemonSim.Event

  def normalize(raw_event), do: Event.new(raw_event)

  def place_mark(player, row, col) do
    Event.new("place_mark", %{"player" => player, "row" => row, "col" => col})
  end

  def move_applied(player, row, col, move_count) do
    Event.new("move_applied", %{
      "player" => player,
      "row" => row,
      "col" => col,
      "move_count" => move_count
    })
  end

  def move_rejected(player, row, col, reason, message) do
    Event.new("move_rejected", %{
      "player" => player,
      "row" => row,
      "col" => col,
      "reason" => to_string(reason),
      "message" => message
    })
  end

  def game_over(:won, winner) do
    Event.new("game_over", %{
      "status" => "won",
      "winner" => winner,
      "message" => "#{winner} wins"
    })
  end

  def game_over(:draw) do
    Event.new("game_over", %{
      "status" => "draw",
      "winner" => nil,
      "message" => "draw"
    })
  end
end

defmodule TicTacToe.Outcome do
  defstruct [:status, :winner, :next_player, events: []]
end

defmodule TicTacToeUpdater do
  @behaviour LemonSim.Updater

  alias LemonSim.State
  alias TicTacToe.{Events, Outcome}

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "place_mark" -> apply_place_mark(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  defp apply_place_mark(%State{} = state, event) do
    player = state.world[:current_player]

    with :ok <- ensure_in_progress(state),
         {:ok, row, col} <- parse_coords(event.payload),
         :ok <- ensure_empty_cell(state.world, row, col) do
      board_after = put_in(state.world, [:board, Access.at(row), Access.at(col)], player)
      move_count = (state.world[:move_count] || 0) + 1
      outcome = resolve_outcome(board_after, player)

      next_state =
        state
        |> State.put_world(%{
          board: board_after[:board],
          current_player: outcome.next_player,
          status: outcome.status,
          winner: outcome.winner,
          move_count: move_count
        })
        |> State.append_event(Events.move_applied(player, row, col, move_count))
        |> State.append_events(outcome.events)

      signal = if outcome.status == "in_progress", do: {:decide, "next turn"}, else: :skip
      {:ok, next_state, signal}
    else
      {:error, reason} ->
        {:ok, rejection_state(state, event, player, reason), {:decide, rejection_reason(reason)}}
    end
  end

  defp rejection_state(state, event, player, reason) do
    {row, col} = raw_coords(event.payload)

    State.append_event(
      state,
      Events.move_rejected(player, row, col, reason, rejection_message(reason, player, row, col))
    )
  end

  defp parse_coords(payload) when is_map(payload) do
    {row, col} = raw_coords(payload)

    cond do
      not (is_integer(row) and is_integer(col)) -> {:error, :invalid_coords}
      row < 0 or row > 2 or col < 0 or col > 2 -> {:error, :out_of_bounds}
      true -> {:ok, row, col}
    end
  end

  defp parse_coords(_), do: {:error, :invalid_payload}

  defp raw_coords(payload) when is_map(payload) do
    row = Map.get(payload, "row", Map.get(payload, :row))
    col = Map.get(payload, "col", Map.get(payload, :col))
    {row, col}
  end

  defp raw_coords(_), do: {nil, nil}

  defp ensure_in_progress(%State{world: world}) do
    if world[:status] in [nil, "in_progress"], do: :ok, else: {:error, :game_over}
  end

  defp ensure_empty_cell(world, row, col) do
    cell = get_in(world, [:board, Access.at(row), Access.at(col)])
    if cell == " ", do: :ok, else: {:error, :occupied_cell}
  end

  defp winner?(board_world, player) do
    board = board_world[:board]

    lines = [
      [at(board, 0, 0), at(board, 0, 1), at(board, 0, 2)],
      [at(board, 1, 0), at(board, 1, 1), at(board, 1, 2)],
      [at(board, 2, 0), at(board, 2, 1), at(board, 2, 2)],
      [at(board, 0, 0), at(board, 1, 0), at(board, 2, 0)],
      [at(board, 0, 1), at(board, 1, 1), at(board, 2, 1)],
      [at(board, 0, 2), at(board, 1, 2), at(board, 2, 2)],
      [at(board, 0, 0), at(board, 1, 1), at(board, 2, 2)],
      [at(board, 0, 2), at(board, 1, 1), at(board, 2, 0)]
    ]

    Enum.any?(lines, fn line -> Enum.all?(line, &(&1 == player)) end)
  end

  defp board_full?(board_world) do
    board = board_world[:board]
    board |> List.flatten() |> Enum.all?(&(&1 != " "))
  end

  defp resolve_outcome(board_after, player) do
    cond do
      winner?(board_after, player) ->
        %Outcome{
          status: "won",
          winner: player,
          next_player: nil,
          events: [Events.game_over(:won, player)]
        }

      board_full?(board_after) ->
        %Outcome{
          status: "draw",
          winner: nil,
          next_player: nil,
          events: [Events.game_over(:draw)]
        }

      true ->
        %Outcome{
          status: "in_progress",
          winner: nil,
          next_player: other_player(player),
          events: []
        }
    end
  end

  defp at(board, row, col), do: get_in(board, [Access.at(row), Access.at(col)])

  defp other_player("X"), do: "O"
  defp other_player("O"), do: "X"

  defp rejection_reason(:occupied_cell), do: "cell occupied"
  defp rejection_reason(:out_of_bounds), do: "row/col out of bounds"
  defp rejection_reason(:invalid_coords), do: "invalid coordinates"
  defp rejection_reason(:invalid_payload), do: "invalid payload"
  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"

  defp rejection_message(reason, player, row, col) do
    "Move rejected (#{reason}): #{player} at (#{inspect(row)}, #{inspect(col)})"
  end
end

defmodule TicTacToeActionSpace do
  @behaviour LemonSim.ActionSpace

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
              event = TicTacToe.Events.place_mark(player, row, col)

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

defmodule TicTacToeDecisionAdapter do
  @behaviour LemonSim.DecisionAdapter

  alias LemonSim.State

  @impl true
  def to_events(%{"type" => "tool_call", "result_details" => details}, %State{}, _opts)
      when is_map(details) do
    case Map.get(details, "event") || Map.get(details, :event) do
      nil -> {:error, {:missing_event_in_decision, details}}
      event -> {:ok, [event]}
    end
  end

  def to_events(other, %State{}, _opts), do: {:error, {:unsupported_decision, other}}
end

defmodule TicTacToeDriver do
  alias LemonSim.{Runner, State}

  def run(%State{} = state, modules, opts) do
    do_run(state, modules, opts, 0)
  end

  defp do_run(%State{} = state, modules, opts, turn) do
    max_turns = Keyword.get(opts, :max_driver_turns, 50)

    cond do
      turn >= max_turns ->
        {:error, {:turn_limit_exceeded, max_turns}}

      state.world[:status] in ["won", "draw"] ->
        {:ok, state}

      true ->
        IO.puts("Turn #{turn + 1} | player=#{state.world[:current_player]}")

        case Runner.step(state, modules, opts) do
          {:ok, %{state: next_state}} ->
            print_board(next_state)
            do_run(next_state, modules, opts, turn + 1)

          {:error, reason} ->
            {:error, {:step_failed, reason}}
        end
    end
  end

  defp print_board(state) do
    board = state.world[:board]

    IO.puts("Board:")
    Enum.each(board, fn row -> IO.puts(Enum.join(row, " | ")) end)

    IO.puts(
      "status=#{state.world[:status]} winner=#{inspect(state.world[:winner])} next=#{inspect(state.world[:current_player])}"
    )
  end
end

initial_world = %{
  board: [
    [" ", " ", " "],
    [" ", " ", " "],
    [" ", " ", " "]
  ],
  current_player: "X",
  status: "in_progress",
  winner: nil,
  move_count: 0
}

start_state =
  State.new(
    sim_id: "tic_tac_toe_1",
    world: initial_world,
    intent: %{goal: "Play tic tac toe and win the game"},
    plan_history: []
  )

projector_opts = [
  section_builders: %{
    world_state: fn frame, _tools, _opts ->
      %{
        id: :world_state,
        title: "Current Board",
        format: :json,
        content: %{
          "board" => frame.world[:board],
          "current_player" => frame.world[:current_player],
          "status" => frame.world[:status],
          "winner" => frame.world[:winner],
          "move_count" => frame.world[:move_count]
        }
      }
    end,
    recent_events: fn frame, _tools, _opts ->
      %{
        id: :recent_events,
        title: "Recent Events",
        format: :json,
        content: Enum.take(frame.recent_events, -8)
      }
    end
  },
  section_overrides: %{
    decision_contract: """
    - Use exactly one tool call: `place_mark`.
    - Choose an empty cell only.
    - If a move is rejected, choose a different cell.
    - Play optimally for the current player shown in world state.
    """
  },
  section_order: [
    :world_state,
    :recent_events,
    :current_intent,
    :available_actions,
    :decision_contract
  ]
]

model = Ai.Models.get_model(:kimi, "kimi-for-coding") || raise "Model not found"

api_key = System.get_env("KIMI_API_KEY") || System.get_env("MOONSHOT_API_KEY") || ""
stream_options = if api_key == "", do: %{}, else: %{api_key: api_key}

modules = %{
  action_space: TicTacToeActionSpace,
  projector: SectionedProjector,
  decider: ToolLoopDecider,
  updater: TicTacToeUpdater,
  decision_adapter: TicTacToeDecisionAdapter
}

opts =
  projector_opts ++
    [
      model: model,
      stream_options: stream_options,
      max_driver_turns: 20
    ]

IO.puts("Starting Tic Tac Toe self-play")

case TicTacToeDriver.run(start_state, modules, opts) do
  {:ok, final_state} ->
    IO.puts("Final state:")
    IO.inspect(final_state.world)
    _ = LemonSim.Store.put_state(final_state)

  {:error, reason} ->
    IO.puts("Driver failed:")
    IO.inspect(reason)
end
