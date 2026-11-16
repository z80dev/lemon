defmodule LemonAi.StreamDeltaBenchmarkTest do
  @moduledoc """
  Opt-in deterministic byte-materialization model for provider event delivery.

      mix test apps/lemon_ai/test/lemon_ai/stream_delta_benchmark_test.exs --include benchmark

  This is NOT a VM allocator/copy profiler or a latency benchmark. Both paths send
  real events to a receiver that retains them until measurement finishes. The old
  path explicitly copies every growing raw-argument snapshot with `:binary.copy/1`;
  its counter sums those copy lengths. The new path keeps reversed chunks and
  counts the one `IO.iodata_to_binary/1` materialization at completion. Uncounted
  allocations (including the old path's append, decoding and process heaps) are
  deliberately excluded. Thus these are measured explicit materialization bytes
  in a model, not a claim about total bytes copied by the BEAM in production.

  The receiver separately counts raw argument bytes referenced by sent events.
  That payload-byte metric is not physical inter-process copying: BEAM reference
  binaries may be shared. The retained old snapshot models the sharing that can
  invalidate append optimization. A separate real Responses reducer run verifies
  that production intermediate events carry only the original argument chunks.
  """
  use ExUnit.Case, async: true

  @moduletag :benchmark

  alias LemonAi.{EventStream, StreamAccumulator}
  alias LemonAi.Providers.OpenAIResponsesShared
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, ToolCall}

  @chunk_bytes 1_024

  test "50/100/200 KiB tool arguments have linear delta materialization and sent payload bytes" do
    measurements =
      for bytes <- [50, 100, 200] do
        argument_bytes = bytes * 1_024
        overhead = byte_size(Jason.encode!(%{"input" => ""}))
        json = Jason.encode!(%{"input" => :binary.copy("x", argument_bytes - overhead)})
        assert byte_size(json) == argument_bytes
        chunks = for <<chunk::binary-size(@chunk_bytes) <- json>>, do: :binary.copy(chunk)

        old = measure(:snapshots, chunks)
        new = measure(:deltas, chunks)
        count = length(chunks)
        assert old.materialized_bytes == div(@chunk_bytes * count * (count + 1), 2)
        assert old.sent_payload_bytes == old.materialized_bytes + argument_bytes
        assert new.materialized_bytes == argument_bytes
        assert new.sent_payload_bytes == argument_bytes
        assert old.result == new.result
        assert new.result == json
        assert_real_provider(chunks, json)

        row = %{
          argument_bytes: argument_bytes,
          old_materialized_bytes: old.materialized_bytes,
          new_materialized_bytes: new.materialized_bytes,
          old_sent_payload_bytes: old.sent_payload_bytes,
          new_sent_payload_bytes: new.sent_payload_bytes
        }

        IO.puts("stream_delta_byte_model " <> Jason.encode!(row))
        row
      end

    [small, medium, large] = measurements

    for {left, right} <- [{small, medium}, {medium, large}] do
      assert right.new_materialized_bytes == 2 * left.new_materialized_bytes
      assert right.new_sent_payload_bytes == 2 * left.new_sent_payload_bytes
      assert right.old_materialized_bytes > 3 * left.old_materialized_bytes
      assert right.old_sent_payload_bytes > 3 * left.old_sent_payload_bytes
    end
  end

  defp measure(mode, chunks) do
    owner = self()
    {receiver, monitor} = spawn_monitor(fn -> retain_events(owner, [], 0) end)

    {result, materialized_bytes} =
      case mode do
        :snapshots ->
          Enum.reduce(chunks, {"", 0}, fn chunk, {partial, bytes} ->
            # Force the counted copy explicitly; do not infer it from heap size.
            snapshot = :binary.copy(partial <> chunk)
            call = Map.put(%ToolCall{id: "call", name: "lookup"}, :partial_json, snapshot)
            message = %AssistantMessage{content: [call]}
            send(receiver, {:event, {:tool_call_delta, 0, chunk, message}})
            {snapshot, bytes + byte_size(snapshot)}
          end)

        :deltas ->
          reversed =
            Enum.reduce(chunks, [], fn chunk, acc ->
              send(receiver, {:event, {:tool_call_delta, 0, chunk}})
              [chunk | acc]
            end)

          result = reversed |> Enum.reverse() |> IO.iodata_to_binary()
          {result, byte_size(result)}
      end

    send(receiver, :finish)
    assert_receive {:payload_bytes, ^receiver, sent_payload_bytes, count}, 5_000
    assert count == length(chunks)
    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 5_000

    %{
      result: result,
      materialized_bytes: materialized_bytes,
      sent_payload_bytes: sent_payload_bytes
    }
  end

  defp retain_events(owner, events, bytes) do
    receive do
      {:event, {:tool_call_delta, 0, chunk, %AssistantMessage{content: [call]}} = wrapped} ->
        retain_events(
          owner,
          [wrapped | events],
          bytes + byte_size(chunk) + byte_size(call.partial_json)
        )

      {:event, {:tool_call_delta, 0, chunk}} = wrapped ->
        retain_events(owner, [wrapped | events], bytes + byte_size(chunk))

      :finish ->
        send(owner, {:payload_bytes, self(), bytes, length(events)})
    end
  end

  defp assert_real_provider(chunks, json) do
    {:ok, stream} = EventStream.start_link(max_queue: length(chunks) + 8)
    item = %{"type" => "function_call", "id" => "fc", "call_id" => "call", "name" => "lookup"}

    events =
      [%{"type" => "response.output_item.added", "item" => item}] ++
        Enum.map(chunks, &%{"type" => "response.function_call_arguments.delta", "delta" => &1}) ++
        [
          %{"type" => "response.output_item.done", "item" => Map.put(item, "arguments", json)},
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]

    output = %AssistantMessage{}
    model = %Model{provider: :openai, cost: %ModelCost{}}
    assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
    EventStream.complete(stream, final)
    emitted = Enum.to_list(EventStream.events(stream))
    assert [{:tool_call_start, 0, %ToolCall{name: "lookup"}} | _] = emitted
    assert Enum.slice(emitted, 1, length(chunks)) == Enum.map(chunks, &{:tool_call_delta, 0, &1})
    assert length(emitted) == length(chunks) + 3
    assert [%ToolCall{arguments: arguments}] = final.content
    assert arguments == Jason.decode!(json)

    accumulator =
      emitted
      |> Enum.drop(-1)
      |> Enum.reduce(StreamAccumulator.new(output), &StreamAccumulator.apply(&2, &1))

    assert StreamAccumulator.snapshot(accumulator).content == final.content
    GenServer.stop(stream)
  end
end
