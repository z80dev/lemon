defmodule LemonSim.Examples.SkirmishTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonSim.Examples.Skirmish

  test "example runs to completion with scripted attacks" do
    {:ok, moves} =
      Agent.start_link(fn ->
        [
          %{"attacker_id" => "red_1", "target_id" => "blue_1"},
          %{"attacker_id" => "red_1", "target_id" => "blue_1"},
          %{"attacker_id" => "blue_1", "target_id" => "red_1"},
          %{"attacker_id" => "blue_1", "target_id" => "red_1"},
          %{"attacker_id" => "red_1", "target_id" => "blue_1"}
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
             id: "skirmish-#{System.unique_integer([:positive])}",
             name: "attack_unit",
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
                 Skirmish.run(
                   model: fake_model(),
                   complete_fn: complete_fn,
                   stream_options: %{},
                   persist?: false,
                   max_turns: 10
                 )

        assert final_state.world.status == "won"
        assert final_state.world.winner == "red"
        assert final_state.world.round == 2
        assert final_state.world.units["blue_1"].status == "dead"
        assert final_state.world.units["red_1"].hp == 2
      end)

    assert output =~ "Starting skirmish self-play"
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
