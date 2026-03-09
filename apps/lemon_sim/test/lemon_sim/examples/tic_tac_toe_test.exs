defmodule LemonSim.Examples.TicTacToeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonSim.Examples.TicTacToe
  alias LemonSim.Examples.TicTacToe.{ActionSpace, Updater}
  alias LemonSim.State

  test "example runs to completion with scripted tool calls" do
    {:ok, moves} =
      Agent.start_link(fn ->
        [
          %{"row" => 0, "col" => 0},
          %{"row" => 1, "col" => 0},
          %{"row" => 0, "col" => 1},
          %{"row" => 1, "col" => 1},
          %{"row" => 0, "col" => 2}
        ]
      end)

    complete_fn = fn _model, _context, _stream_opts ->
      move =
        Agent.get_and_update(moves, fn
          [next | rest] -> {next, rest}
          [] -> {nil, []}
        end)

      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "tic-tac-toe-#{System.unique_integer([:positive])}",
             name: "place_mark",
             arguments: move
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    output =
      capture_io(fn ->
        assert {:ok, final_state} =
                 TicTacToe.run(
                   model: fake_model(),
                   complete_fn: complete_fn,
                   stream_options: %{},
                   persist?: false,
                   max_turns: 10
                 )

        assert final_state.world[:status] == "won"
        assert final_state.world[:winner] == "X"
        assert final_state.world[:move_count] == 5
      end)

    assert output =~ "Starting Tic Tac Toe self-play"
    assert output =~ "Final state:"
  end

  test "action space and updater tolerate string-keyed world state" do
    state =
      State.new(
        sim_id: "tic_tac_toe_string_keys",
        world: %{
          "board" => [
            [" ", " ", " "],
            [" ", " ", " "],
            [" ", " ", " "]
          ],
          "current_player" => "X",
          "status" => "in_progress",
          "winner" => nil,
          "move_count" => 0
        }
      )

    assert {:ok, [tool]} = ActionSpace.tools(state, [])
    assert tool.name == "place_mark"

    assert {:ok, next_state, {:decide, "next turn"}} =
             Updater.apply_event(
               state,
               %{"kind" => "place_mark", "payload" => %{"player" => "X", "row" => 0, "col" => 0}},
               []
             )

    assert get_in(next_state.world, ["board", Access.at(0), Access.at(0)]) == "X"
    assert next_state.world["current_player"] == "O"
    assert next_state.world["move_count"] == 1
  end

  defp fake_model do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end
end
