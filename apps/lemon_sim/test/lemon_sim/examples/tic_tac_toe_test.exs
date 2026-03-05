defmodule LemonSim.Examples.TicTacToeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonSim.Examples.TicTacToe

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
