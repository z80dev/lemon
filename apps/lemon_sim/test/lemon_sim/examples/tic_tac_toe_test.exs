defmodule LemonSim.Examples.TicTacToeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonSim.Examples.TicTacToe
  alias LemonSim.Examples.TicTacToe.{ActionSpace, Updater}
  alias LemonSim.Kernel.State

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

  test "offline random strategy is seeded and still records normal events" do
    run = fn seed ->
      capture_io(fn ->
        assert {:ok, final_state} =
                 TicTacToe.run_offline_strategy(:random,
                   seed: seed,
                   persist?: false,
                   driver_max_turns: 10
                 )

        send(self(), {:offline_state, final_state})
      end)

      assert_received {:offline_state, final_state}
      {normalize_events(final_state.recent_events), final_state.world}
    end

    {events_a, world_a} = run.(42)
    {events_b, world_b} = run.(42)
    {events_c, world_c} = run.(7)

    assert events_a == events_b
    assert world_a == world_b
    assert events_a != events_c
    assert world_a != world_c
    assert Enum.any?(events_a, fn {kind, _payload, _meta} -> kind == "move_applied" end)
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

  defp normalize_events(events) do
    Enum.map(events, fn event ->
      {event.kind, event.payload, event.meta}
    end)
  end
end
