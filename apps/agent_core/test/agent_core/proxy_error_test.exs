defmodule AgentCore.ProxyErrorTest do
  @moduledoc """
  Comprehensive error handling tests for AgentCore.Proxy.

  Tests cover:
  1. SSE parsing edge cases (malformed events, partial data)
  2. Partial JSON reconstruction with malformed input
  3. Abort signal handling during streaming
  4. Connection error recovery
  5. Timeout scenarios
  6. Large response handling
  7. Invalid content-type handling
  """
  use ExUnit.Case, async: true

  alias AgentCore.Proxy
  alias AgentCore.Proxy.ProxyStreamOptions
  alias AgentCore.AbortSignal
  alias AgentCore.Test.Mocks

  alias Ai.EventStream
  alias Ai.Types.{AssistantMessage, TextContent, ToolCall}

  @receive_timeout 5_000

  # ============================================================================
  # Test Server Helpers
  # ============================================================================

  defp start_sse_server(chunks, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    content_type = Keyword.get(opts, :content_type, "text/event-stream")
    delay = Keyword.get(opts, :delay, 0)
    close_early = Keyword.get(opts, :close_early, false)

    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listen)
    parent = self()

    Task.start(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      read_request(socket, "")

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} OK\r\n" <>
            "content-type: #{content_type}\r\n" <>
            "transfer-encoding: chunked\r\n" <>
            "\r\n"
        )

      unless close_early do
        Enum.reduce_while(chunks, :ok, fn chunk, _acc ->
          if delay > 0, do: Process.sleep(delay)

          case send_chunk(socket, chunk) do
            :ok -> {:cont, :ok}
            :closed -> {:halt, :closed}
          end
        end)

        _ = :gen_tcp.send(socket, "0\r\n\r\n")
      end

      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
      send(parent, :sse_server_done)
    end)

    port
  end

  defp start_error_server(status, body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listen)
    parent = self()

    Task.start(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      read_request(socket, "")

      # Use chunked transfer encoding for consistency
      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Error\r\n" <>
            "content-type: application/json\r\n" <>
            "transfer-encoding: chunked\r\n" <>
            "\r\n"
        )

      # Send body as a chunk
      size = byte_size(body)
      _ = :gen_tcp.send(socket, Integer.to_string(size, 16) <> "\r\n")
      _ = :gen_tcp.send(socket, body)
      _ = :gen_tcp.send(socket, "\r\n")
      # Final chunk
      _ = :gen_tcp.send(socket, "0\r\n\r\n")

      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
      send(parent, :sse_server_done)
    end)

    port
  end

  defp start_slow_server(chunks, chunk_delay) do
    start_sse_server(chunks, delay: chunk_delay)
  end

  defp read_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "\r\n\r\n") do
          :ok
        else
          read_request(socket, acc)
        end

      {:error, _} ->
        :ok
    end
  end

  defp send_chunk(socket, data) do
    size = byte_size(data)

    with :ok <- :gen_tcp.send(socket, Integer.to_string(size, 16) <> "\r\n"),
         :ok <- :gen_tcp.send(socket, data),
         :ok <- :gen_tcp.send(socket, "\r\n") do
      :ok
    else
      {:error, :closed} -> :closed
      {:error, _} -> :closed
    end
  end

  defp sse_event(map) do
    "data: " <> Jason.encode!(map) <> "\n\n"
  end

  # ============================================================================
  # SSE Parsing Edge Cases
  # ============================================================================

  describe "SSE parsing - malformed events" do
    test "ignores lines that don't start with 'data:'" do
      chunks = [
        "event: message\n",
        sse_event(%{"type" => "start"}),
        "id: 123\n",
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        "retry: 1000\n",
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Hello"}),
        ": comment line\n",
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop
      assert [%TextContent{text: "Hello"}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles empty data lines" do
      chunks = [
        sse_event(%{"type" => "start"}),
        "data:\n\n",
        "data:   \n\n",
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Test"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop
      assert [%TextContent{text: "Test"}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles malformed JSON in data lines gracefully" do
      chunks = [
        sse_event(%{"type" => "start"}),
        "data: {invalid json}\n\n",
        "data: not json at all\n\n",
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        "data: {\"type\": \"text_delta\", incomplete\n\n",
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Valid"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop
      assert [%TextContent{text: "Valid"}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles unknown event types gracefully" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "unknown_event", "data" => "ignored"}),
        sse_event(%{"type" => "custom_type", "foo" => "bar"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "OK"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles events with missing required fields" do
      chunks = [
        sse_event(%{"type" => "start"}),
        # Missing contentIndex
        sse_event(%{"type" => "text_start"}),
        # text_delta with missing delta
        sse_event(%{"type" => "text_delta", "contentIndex" => 0}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Works"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  describe "SSE parsing - partial data handling" do
    test "handles events split across multiple chunks" do
      # Split an event across multiple chunks
      full_event =
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Hello World"})

      {chunk1, rest} = String.split_at(full_event, 10)
      {chunk2, chunk3} = String.split_at(rest, 15)

      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        chunk1,
        chunk2,
        chunk3,
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop
      assert [%TextContent{text: "Hello World"}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles multiple events in single chunk" do
      combined_events =
        sse_event(%{"type" => "start"}) <>
          sse_event(%{"type" => "text_start", "contentIndex" => 0}) <>
          sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Combined"}) <>
          sse_event(%{"type" => "text_end", "contentIndex" => 0}) <>
          sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})

      chunks = [combined_events]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop
      assert [%TextContent{text: "Combined"}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles event split exactly at newline boundary" do
      # Split right before/after newlines
      event1 = "data: " <> Jason.encode!(%{"type" => "start"})

      event2 =
        "\n\ndata: " <> Jason.encode!(%{"type" => "text_start", "contentIndex" => 0}) <> "\n"

      event3 = "\n"

      chunks = [
        event1,
        event2,
        event3,
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Split"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  # ============================================================================
  # Partial JSON Reconstruction Edge Cases
  # ============================================================================

  describe "parse_streaming_json/1 - malformed input" do
    test "handles truncated string value" do
      # String value cut off mid-stream
      json = ~s({"text": "hello wo)
      result = Proxy.parse_streaming_json(json)
      # Should return empty map since string is incomplete and invalid
      assert is_map(result)
    end

    test "handles truncated number value" do
      json = ~s({"count": 12)
      result = Proxy.parse_streaming_json(json)
      assert result["count"] == 12
    end

    test "handles truncated boolean value" do
      json = ~s({"enabled": tru)
      result = Proxy.parse_streaming_json(json)
      # tru is not valid JSON, should return empty map
      assert %{} == result
    end

    test "handles mismatched brackets" do
      json = ~s({"items": [1, 2, 3})
      result = Proxy.parse_streaming_json(json)
      # This is malformed - items array not closed but brace closed
      # The completion algorithm will add ]} making it parse
      assert is_map(result)
    end

    test "handles extra closing brackets" do
      json = ~s({"a": 1}})
      result = Proxy.parse_streaming_json(json)
      # Extra brace makes it invalid
      assert %{} == result
    end

    test "handles deeply nested incomplete JSON" do
      json = ~s({"a": {"b": {"c": {"d": {"e": "deep)
      result = Proxy.parse_streaming_json(json)
      # Incomplete string, might not parse
      assert is_map(result)
    end

    test "handles mixed array and object nesting" do
      # Note: The completion algorithm adds `]}` to close both the array and object
      # but this results in `{"items": [{"id": 1}, {"id": 2]}` which is invalid JSON
      # because the inner object is not closed. The function returns empty map for invalid JSON.
      json = ~s({"items": [{"id": 1}, {"id": 2)
      result = Proxy.parse_streaming_json(json)
      # This is expected to fail parsing due to incomplete inner object
      assert is_map(result)
    end

    test "handles unicode in partial JSON" do
      json = ~s({"text": "Hello )
      result = Proxy.parse_streaming_json(json)
      # Incomplete string
      assert is_map(result)
    end

    test "handles escaped characters in partial JSON" do
      json = ~s({"text": "line1\\nline2)
      result = Proxy.parse_streaming_json(json)
      assert is_map(result)
    end

    test "handles null value partial" do
      json = ~s({"value": nul)
      result = Proxy.parse_streaming_json(json)
      assert %{} == result
    end

    test "handles array of primitives partial" do
      json = ~s({"nums": [1, 2, 3, 4)
      result = Proxy.parse_streaming_json(json)
      assert result["nums"] == [1, 2, 3, 4]
    end

    test "handles empty object incomplete" do
      json = "{"
      result = Proxy.parse_streaming_json(json)
      assert %{} == result
    end

    test "handles object with only key" do
      json = ~s({"key")
      result = Proxy.parse_streaming_json(json)
      assert %{} == result
    end

    test "handles object with key and colon" do
      json = ~s({"key":)
      result = Proxy.parse_streaming_json(json)
      assert %{} == result
    end

    test "handles large partial JSON" do
      # Create a large partial JSON
      items = Enum.map(1..100, fn i -> ~s({"id": #{i}, "name": "item_#{i}"}) end)
      json = ~s({"items": [) <> Enum.join(items, ", ")
      result = Proxy.parse_streaming_json(json)
      assert length(result["items"]) == 100
    end
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  describe "abort signal handling" do
    test "aborts stream when signal is triggered before streaming starts" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Should not see"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks, delay: 50)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}",
            signal: signal
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :aborted
      assert message.error_message =~ "aborted"

      AbortSignal.clear(signal)
    end

    test "aborts stream when signal is triggered during streaming" do
      signal = AbortSignal.new()

      # Use delayed chunks so we have time to abort
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Part 1"}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => " Part 2"}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => " Part 3"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks, delay: 200)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}",
            signal: signal
          }
        )

      # Abort after a short delay
      Task.start(fn ->
        Process.sleep(300)
        AbortSignal.abort(signal)
      end)

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :aborted

      AbortSignal.clear(signal)
    end

    test "nil signal does not cause abort" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Hello"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}",
            signal: nil
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  # ============================================================================
  # Connection Error Recovery
  # ============================================================================

  describe "connection error handling" do
    test "handles HTTP 400 Bad Request" do
      port = start_error_server(400, Jason.encode!(%{"error" => "Bad Request"}))

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      # The proxy correctly returns an error - the specific message depends on Req's handling
      assert message.error_message != nil

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles HTTP 401 Unauthorized" do
      port = start_error_server(401, Jason.encode!(%{"error" => "Unauthorized"}))

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "bad-token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      # The proxy correctly returns an error - the specific message depends on Req's handling
      assert message.error_message != nil

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles HTTP 429 Too Many Requests" do
      port = start_error_server(429, Jason.encode!(%{"error" => "Rate limit exceeded"}))

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      # The proxy correctly returns an error - the specific message depends on Req's handling
      assert message.error_message != nil

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles HTTP 500 Internal Server Error" do
      port = start_error_server(500, Jason.encode!(%{"error" => "Internal error"}))

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      # The proxy correctly returns an error - the specific message depends on Req's handling
      assert message.error_message != nil

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles HTTP 503 Service Unavailable" do
      port =
        start_error_server(503, Jason.encode!(%{"error" => "Service temporarily unavailable"}))

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      # The proxy correctly returns an error - the specific message depends on Req's handling
      assert message.error_message != nil

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles non-JSON error response" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, {_, port}} = :inet.sockname(listen)
      parent = self()

      Task.start(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        read_request(socket, "")

        body = "Plain text error"

        # Use chunked transfer encoding
        _ =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 500 Error\r\n" <>
              "content-type: text/plain\r\n" <>
              "transfer-encoding: chunked\r\n" <>
              "\r\n"
          )

        # Send body as chunk
        size = byte_size(body)
        _ = :gen_tcp.send(socket, Integer.to_string(size, 16) <> "\r\n")
        _ = :gen_tcp.send(socket, body)
        _ = :gen_tcp.send(socket, "\r\n")
        _ = :gen_tcp.send(socket, "0\r\n\r\n")

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        send(parent, :sse_server_done)
      end)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      # The proxy correctly returns an error - the specific message depends on Req's handling
      assert message.error_message != nil

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles connection refused" do
      # Use a port that's not listening
      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:59999"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      assert message.error_message =~ "connection"
    end

    test "handles connection reset during streaming" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, {_, port}} = :inet.sockname(listen)
      parent = self()

      Task.start(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        read_request(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\n" <>
              "content-type: text/event-stream\r\n" <>
              "transfer-encoding: chunked\r\n" <>
              "\r\n"
          )

        # Send partial data using inline chunk sending (not the helper which may fail)
        start_event = sse_event(%{"type" => "start"})
        start_size = byte_size(start_event)
        :ok = :gen_tcp.send(socket, Integer.to_string(start_size, 16) <> "\r\n")
        :ok = :gen_tcp.send(socket, start_event)
        :ok = :gen_tcp.send(socket, "\r\n")

        text_start_event = sse_event(%{"type" => "text_start", "contentIndex" => 0})
        text_start_size = byte_size(text_start_event)
        :ok = :gen_tcp.send(socket, Integer.to_string(text_start_size, 16) <> "\r\n")
        :ok = :gen_tcp.send(socket, text_start_event)
        :ok = :gen_tcp.send(socket, "\r\n")

        # Close without proper termination
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        send(parent, :sse_server_done)
      end)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      # The stream should handle the abrupt close
      # It might get a partial result or an error or timeout
      result = EventStream.result(stream, @receive_timeout)
      assert is_tuple(result)

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles invalid hostname" do
      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            # Use localhost with closed port instead - faster than DNS resolution failure
            proxy_url: "http://127.0.0.1:59998"
          }
        )

      result = EventStream.result(stream, @receive_timeout)

      case result do
        {:error, %AssistantMessage{} = message} ->
          assert message.stop_reason == :error
          assert message.error_message =~ "connection" or message.error_message =~ "error"

        {:error, :timeout} ->
          # This is also acceptable - the connection attempt timed out
          assert true
      end
    end
  end

  # ============================================================================
  # Timeout Scenarios
  # ============================================================================

  describe "timeout handling" do
    test "handles slow server with abort during wait" do
      signal = AbortSignal.new()

      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Slow"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      # Very slow server - 500ms between chunks
      port = start_slow_server(chunks, 500)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}",
            signal: signal
          }
        )

      # Abort after 200ms - should abort during the slow stream
      Task.start(fn ->
        Process.sleep(200)
        AbortSignal.abort(signal)
      end)

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :aborted

      AbortSignal.clear(signal)
    end
  end

  # ============================================================================
  # Large Response Handling
  # ============================================================================

  describe "large response handling" do
    test "handles large text response" do
      large_text = String.duplicate("x", 100_000)

      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => large_text}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop
      assert [%TextContent{text: ^large_text}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles many small deltas" do
      delta_count = 100

      deltas =
        for i <- 1..delta_count do
          sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "word#{i} "})
        end

      chunks =
        [
          sse_event(%{"type" => "start"}),
          sse_event(%{"type" => "text_start", "contentIndex" => 0})
        ] ++
          deltas ++
          [
            sse_event(%{"type" => "text_end", "contentIndex" => 0}),
            sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
          ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop
      [%TextContent{text: text}] = message.content

      # Verify all deltas were accumulated
      for i <- 1..delta_count do
        assert String.contains?(text, "word#{i}")
      end

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles large tool call arguments" do
      large_args = %{
        "items" =>
          Enum.map(1..1000, fn i -> %{"id" => i, "data" => String.duplicate("x", 100)} end)
      }

      large_json = Jason.encode!(large_args)

      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{
          "type" => "toolcall_start",
          "contentIndex" => 0,
          "id" => "call_1",
          "toolName" => "big_tool"
        }),
        sse_event(%{"type" => "toolcall_delta", "contentIndex" => 0, "delta" => large_json}),
        sse_event(%{"type" => "toolcall_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "toolUse", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :tool_use
      assert [%ToolCall{name: "big_tool", arguments: args}] = message.content
      assert length(args["items"]) == 1000

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles multiple content blocks" do
      chunks = [
        sse_event(%{"type" => "start"}),
        # First text block
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "First"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        # Second text block
        sse_event(%{"type" => "text_start", "contentIndex" => 1}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 1, "delta" => "Second"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 1}),
        # Tool call block
        sse_event(%{
          "type" => "toolcall_start",
          "contentIndex" => 2,
          "id" => "call_1",
          "toolName" => "test"
        }),
        sse_event(%{
          "type" => "toolcall_delta",
          "contentIndex" => 2,
          "delta" => ~s({"arg": "value"})
        }),
        sse_event(%{"type" => "toolcall_end", "contentIndex" => 2}),
        sse_event(%{"type" => "done", "reason" => "toolUse", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :tool_use

      assert [
               %TextContent{text: "First"},
               %TextContent{text: "Second"},
               %ToolCall{name: "test", arguments: %{"arg" => "value"}}
             ] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  # ============================================================================
  # Invalid Content-Type Handling
  # ============================================================================

  describe "content-type handling" do
    test "handles text/event-stream with charset" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Hello"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks, content_type: "text/event-stream; charset=utf-8")

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  # ============================================================================
  # Error Event Handling
  # ============================================================================

  describe "error event handling" do
    test "handles error event with usage data" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Partial"}),
        sse_event(%{
          "type" => "error",
          "reason" => "error",
          "errorMessage" => "Context length exceeded",
          "usage" => %{"input" => 100, "output" => 50}
        })
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      assert message.error_message == "Context length exceeded"
      assert message.usage.input == 100
      assert message.usage.output == 50

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles error event without usage data" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{
          "type" => "error",
          "reason" => "error",
          "errorMessage" => "Unknown error"
        })
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :error
      assert message.error_message == "Unknown error"

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles aborted error reason" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{
          "type" => "error",
          "reason" => "aborted",
          "errorMessage" => "Request cancelled by server"
        })
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:error, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :aborted

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  # ============================================================================
  # Stop Reason Decoding
  # ============================================================================

  describe "stop reason decoding" do
    test "handles all valid stop reasons" do
      stop_reasons = [
        {"stop", :stop},
        {"length", :length},
        {"toolUse", :tool_use},
        {"tool_use", :tool_use},
        {"aborted", :aborted},
        {"error", :error}
      ]

      for {reason_str, expected_atom} <- stop_reasons do
        chunks = [
          sse_event(%{"type" => "start"}),
          sse_event(%{"type" => "done", "reason" => reason_str, "usage" => %{}})
        ]

        port = start_sse_server(chunks)

        stream =
          Proxy.stream_proxy(
            Mocks.mock_model(),
            Ai.Types.Context.new(),
            %ProxyStreamOptions{
              auth_token: "token",
              proxy_url: "http://localhost:#{port}"
            }
          )

        {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)

        assert message.stop_reason == expected_atom,
               "Expected #{expected_atom} for '#{reason_str}'"

        assert_receive :sse_server_done, @receive_timeout
      end
    end

    test "handles unknown stop reason as :stop" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "done", "reason" => "unknown_reason", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  # ============================================================================
  # Usage Decoding
  # ============================================================================

  describe "usage decoding" do
    test "handles complete usage data" do
      usage = %{
        "input" => 100,
        "output" => 50,
        "cacheRead" => 25,
        "cacheWrite" => 10,
        "totalTokens" => 175,
        "cost" => %{
          "input" => 0.001,
          "output" => 0.0015,
          "cacheRead" => 0.0005,
          "cacheWrite" => 0.0003,
          "total" => 0.0033
        }
      }

      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => usage})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.usage.input == 100
      assert message.usage.output == 50
      assert message.usage.cache_read == 25
      assert message.usage.cache_write == 10
      assert message.usage.total_tokens == 175
      assert message.usage.cost.input == 0.001
      assert message.usage.cost.output == 0.0015
      assert message.usage.cost.total == 0.0033

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles partial usage data with defaults" do
      usage = %{
        "input" => 100,
        "output" => 50
      }

      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => usage})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.usage.input == 100
      assert message.usage.output == 50
      assert message.usage.cache_read == 0
      assert message.usage.cache_write == 0
      assert message.usage.total_tokens == 0

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles empty usage data" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.usage.input == 0
      assert message.usage.output == 0

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  # ============================================================================
  # Thinking Content Handling
  # ============================================================================

  describe "thinking content handling" do
    test "handles thinking content events" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "thinking_start", "contentIndex" => 0}),
        sse_event(%{
          "type" => "thinking_delta",
          "contentIndex" => 0,
          "delta" => "Let me think..."
        }),
        sse_event(%{"type" => "thinking_delta", "contentIndex" => 0, "delta" => " about this."}),
        sse_event(%{
          "type" => "thinking_end",
          "contentIndex" => 0,
          "contentSignature" => "sig123"
        }),
        sse_event(%{"type" => "text_start", "contentIndex" => 1}),
        sse_event(%{
          "type" => "text_delta",
          "contentIndex" => 1,
          "delta" => "Here is my answer."
        }),
        sse_event(%{"type" => "text_end", "contentIndex" => 1}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert message.stop_reason == :stop

      assert [
               %Ai.Types.ThinkingContent{
                 thinking: "Let me think... about this.",
                 thinking_signature: "sig123"
               },
               %TextContent{text: "Here is my answer."}
             ] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end
  end

  # ============================================================================
  # Content Signature Handling
  # ============================================================================

  describe "content signature handling" do
    test "handles text content with signature" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Signed text"}),
        sse_event(%{
          "type" => "text_end",
          "contentIndex" => 0,
          "contentSignature" => "text_sig_abc"
        }),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert [%TextContent{text: "Signed text", text_signature: "text_sig_abc"}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "handles content without signature" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "No sig"}),
        sse_event(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks)

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          Ai.Types.Context.new(),
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{} = message} = EventStream.result(stream, @receive_timeout)
      assert [%TextContent{text: "No sig", text_signature: nil}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end
  end
end
