defmodule AgentCore.ProxyStreamIntegrationTest do
  use ExUnit.Case, async: true

  alias AgentCore.Proxy
  alias AgentCore.Proxy.ProxyStreamOptions
  alias AgentCore.Test.Mocks

  alias Ai.EventStream
  alias Ai.Types.{AssistantMessage, TextContent, ToolCall}

  @receive_timeout 2_000

  defp start_sse_server(chunks) do
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

      Enum.each(chunks, fn chunk ->
        send_chunk(socket, chunk)
      end)

      :ok = :gen_tcp.send(socket, "0\r\n\r\n")
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
      send(parent, :sse_server_done)
    end)

    port
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
    :ok = :gen_tcp.send(socket, Integer.to_string(size, 16) <> "\r\n")
    :ok = :gen_tcp.send(socket, data)
    :ok = :gen_tcp.send(socket, "\r\n")
  end

  defp sse_event(map) do
    "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defp sse_event_no_space(map) do
    "data:" <> Jason.encode!(map) <> "\n\n"
  end

  describe "stream_proxy/3" do
    test "reconstructs text content from SSE stream" do
      text_delta_line = sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Hello"})
      {chunk1, chunk2} = String.split_at(text_delta_line, 15)

      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "text_start", "contentIndex" => 0}),
        chunk1,
        chunk2,
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

    test "accepts SSE data lines without a space after the colon" do
      chunks = [
        sse_event_no_space(%{"type" => "start"}),
        sse_event_no_space(%{"type" => "text_start", "contentIndex" => 0}),
        sse_event_no_space(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Hi"}),
        sse_event_no_space(%{"type" => "text_end", "contentIndex" => 0}),
        sse_event_no_space(%{"type" => "done", "reason" => "stop", "usage" => %{}})
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
      assert [%TextContent{text: "Hi"}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "reconstructs tool call arguments from streaming JSON" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "toolcall_start", "contentIndex" => 0, "id" => "call_1", "toolName" => "echo"}),
        sse_event(%{"type" => "toolcall_delta", "contentIndex" => 0, "delta" => "{\"text\":\"hi"}),
        sse_event(%{"type" => "toolcall_delta", "contentIndex" => 0, "delta" => "\"}"}),
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
      assert [%ToolCall{name: "echo", arguments: %{"text" => "hi"}}] = message.content

      assert_receive :sse_server_done, @receive_timeout
    end

    test "propagates proxy error events" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "error", "reason" => "error", "errorMessage" => "boom", "usage" => %{}})
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
      assert message.error_message == "boom"

      assert_receive :sse_server_done, @receive_timeout
    end
  end
end
