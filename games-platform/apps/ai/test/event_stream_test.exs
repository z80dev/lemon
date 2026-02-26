defmodule Ai.EventStreamTest do
  use ExUnit.Case

  alias Ai.EventStream
  alias Ai.Types.{AssistantMessage, TextContent, Usage, Cost}

  defp make_message(opts \\ []) do
    %AssistantMessage{
      content: Keyword.get(opts, :content, []),
      api: :test,
      provider: :test,
      model: "test",
      usage: %Usage{cost: %Cost{}},
      stop_reason: Keyword.get(opts, :stop_reason, :stop),
      timestamp: System.system_time(:millisecond)
    }
  end

  describe "basic operations" do
    test "starts and stops" do
      {:ok, stream} = EventStream.start_link()
      assert is_pid(stream)
      assert Process.alive?(stream)
    end

    test "pushes events and consumes them" do
      {:ok, stream} = EventStream.start_link()

      partial = make_message()

      # Push some events
      EventStream.push(stream, {:text_delta, 0, "Hello", partial})
      EventStream.push(stream, {:text_delta, 0, " world", partial})
      EventStream.complete(stream, make_message(content: [%TextContent{text: "Hello world"}]))

      # Consume events
      events = EventStream.events(stream) |> Enum.to_list()

      assert length(events) == 3
      assert {:text_delta, 0, "Hello", _} = Enum.at(events, 0)
      assert {:text_delta, 0, " world", _} = Enum.at(events, 1)
      assert {:done, :stop, _} = Enum.at(events, 2)
    end
  end

  describe "result/1" do
    test "returns final message after completion" do
      {:ok, stream} = EventStream.start_link()

      final = make_message(content: [%TextContent{text: "Done"}])
      EventStream.complete(stream, final)

      {:ok, result} = EventStream.result(stream)
      assert result.content == [%TextContent{text: "Done"}]
    end

    test "returns error message after error" do
      {:ok, stream} = EventStream.start_link()

      error_msg = make_message(stop_reason: :error, content: [])
      EventStream.error(stream, error_msg)

      {:error, result} = EventStream.result(stream)
      assert result.stop_reason == :error
    end
  end

  describe "collect_text/1" do
    test "collects all text deltas" do
      {:ok, stream} = EventStream.start_link()

      partial = make_message()
      EventStream.push(stream, {:text_delta, 0, "Hello", partial})
      EventStream.push(stream, {:text_delta, 0, " ", partial})
      EventStream.push(stream, {:text_delta, 0, "world!", partial})
      EventStream.complete(stream, make_message())

      text = EventStream.collect_text(stream)
      assert text == "Hello world!"
    end
  end

  describe "concurrent access" do
    test "handles concurrent pushes and reads" do
      {:ok, stream} = EventStream.start_link()

      # Start a reader task
      reader =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Push events from another process
      partial = make_message()

      for i <- 1..10 do
        EventStream.push(stream, {:text_delta, 0, "#{i}", partial})
      end

      EventStream.complete(stream, make_message())

      events = Task.await(reader)
      # 10 deltas + 1 done
      assert length(events) == 11
    end
  end
end
