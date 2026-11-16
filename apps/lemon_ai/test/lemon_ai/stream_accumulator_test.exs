defmodule LemonAi.StreamAccumulatorTest do
  use ExUnit.Case, async: true

  alias LemonAi.StreamAccumulator
  alias LemonAi.Types.{AssistantMessage, TextContent, ThinkingContent, ToolCall, Usage}

  test "partial snapshots are available between deltas without changing retained chunks" do
    accumulator =
      %AssistantMessage{model: "fixture", timestamp: 42}
      |> StreamAccumulator.new()
      |> StreamAccumulator.apply({:text_start, 0})
      |> StreamAccumulator.apply({:text_delta, 0, "Hello "})

    assert %AssistantMessage{
             model: "fixture",
             timestamp: 42,
             content: [%TextContent{text: "Hello "}]
           } =
             StreamAccumulator.snapshot(accumulator)

    continued = StreamAccumulator.apply(accumulator, {:text_delta, 0, "world"})
    assert continued.chunks == %{0 => ["world", "Hello "]}
    assert [%TextContent{text: "Hello world"}] = StreamAccumulator.snapshot(continued).content
    assert [%TextContent{text: "Hello "}] = StreamAccumulator.snapshot(accumulator).content
    assert StreamAccumulator.metadata(continued).content == []
  end

  test "on-demand tool previews repair incomplete nested JSON without changing chunks" do
    accumulator =
      StreamAccumulator.new()
      |> StreamAccumulator.apply({:tool_call_start, 0, %ToolCall{id: "partial", name: "echo"}})
      |> StreamAccumulator.apply({:tool_call_delta, 0, ~s({"items":[{"text":"partial)})

    assert [%ToolCall{arguments: %{"items" => [%{"text" => "partial"}]}}] =
             StreamAccumulator.snapshot(accumulator).content

    assert accumulator.chunks == %{0 => [~s({"items":[{"text":"partial)]}
  end

  test "interleaved blocks retain order and tool arguments decode only at snapshot" do
    call = %ToolCall{id: "call_1", name: "echo"}

    accumulator =
      StreamAccumulator.new()
      |> StreamAccumulator.apply({:tool_call_start, 2, call})
      |> StreamAccumulator.apply({:thinking_delta, 0, "reason"})
      |> StreamAccumulator.apply({:text_delta, 1, "answer"})
      |> StreamAccumulator.apply({:tool_call_delta, 2, ~s({"text":)})
      |> StreamAccumulator.apply({:tool_call_delta, 2, ~s("value"})})

    assert accumulator.blocks[2] == call

    assert [
             %ThinkingContent{thinking: "reason"},
             %TextContent{text: "answer"},
             %ToolCall{id: "call_1", name: "echo", arguments: %{"text" => "value"}}
           ] = StreamAccumulator.snapshot(accumulator).content
  end

  test "block ends replace chunks and terminal messages retain signatures and usage" do
    call = %ToolCall{id: "call_1", name: "echo", arguments: %{"text" => "final"}}

    accumulator =
      StreamAccumulator.new()
      |> StreamAccumulator.apply({:text_delta, 0, "old"})
      |> StreamAccumulator.apply({:text_end, 0, "final"})
      |> StreamAccumulator.apply({:tool_call_start, 1, call})
      |> StreamAccumulator.apply({:tool_call_delta, 1, "broken"})
      |> StreamAccumulator.apply({:tool_call_end, 1, call})

    assert accumulator.chunks == %{}
    assert [%TextContent{text: "final"}, ^call] = StreamAccumulator.snapshot(accumulator).content

    final = %AssistantMessage{
      content: [%ThinkingContent{thinking: "reason", thinking_signature: "signature"}],
      usage: %Usage{output: 12},
      stop_reason: :stop
    }

    assert accumulator
           |> StreamAccumulator.apply({:done, :stop, final})
           |> StreamAccumulator.snapshot() == final
  end

  test "a 100 KiB argument retains only incoming chunks before snapshot" do
    chunk = String.duplicate("x", 1024)
    call = %ToolCall{id: "large", name: "echo"}

    accumulator =
      StreamAccumulator.new()
      |> StreamAccumulator.apply({:tool_call_start, 0, call})
      |> StreamAccumulator.apply({:tool_call_delta, 0, ~s({"text":")})

    accumulator =
      Enum.reduce(1..100, accumulator, fn _, acc ->
        StreamAccumulator.apply(acc, {:tool_call_delta, 0, chunk})
      end)
      |> StreamAccumulator.apply({:tool_call_delta, 0, ~s("})})

    assert length(accumulator.chunks[0]) == 102
    assert accumulator.blocks[0] == call

    assert [%ToolCall{arguments: %{"text" => value}}] =
             StreamAccumulator.snapshot(accumulator).content

    assert byte_size(value) == 102_400
  end
end
