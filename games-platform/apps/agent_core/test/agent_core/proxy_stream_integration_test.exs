defmodule AgentCore.ProxyStreamIntegrationTest do
  use ExUnit.Case, async: true

  alias AgentCore.Proxy
  alias AgentCore.Proxy.ProxyStreamOptions
  alias AgentCore.Test.Mocks

  alias Ai.EventStream
  alias Ai.Types.{AssistantMessage, TextContent, ToolCall, ToolResultMessage}

  @receive_timeout 2_000

  defp start_sse_server(chunks, opts \\ []) do
    capture_request = Keyword.get(opts, :capture_request, false)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listen)
    parent = self()

    Task.start(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      request = read_request(socket, "")

      if capture_request do
        send(parent, {:sse_server_request, request})
      end

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
          [headers, body_so_far] = String.split(acc, "\r\n\r\n", parts: 2)
          content_length = parse_content_length(headers)
          remaining = max(content_length - byte_size(body_so_far), 0)
          body = body_so_far <> recv_exact(socket, remaining)
          headers <> "\r\n\r\n" <> body
        else
          read_request(socket, acc)
        end

      {:error, _} ->
        acc
    end
  end

  defp parse_content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            case Integer.parse(String.trim(value)) do
              {length, _} -> length
              :error -> 0
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp recv_exact(_socket, 0), do: ""

  defp recv_exact(socket, bytes) do
    case :gen_tcp.recv(socket, bytes, 1_000) do
      {:ok, data} ->
        read = byte_size(data)

        if read >= bytes do
          binary_part(data, 0, bytes)
        else
          data <> recv_exact(socket, bytes - read)
        end

      {:error, _} ->
        ""
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
      text_delta_line =
        sse_event(%{"type" => "text_delta", "contentIndex" => 0, "delta" => "Hello"})

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
        sse_event(%{
          "type" => "toolcall_start",
          "contentIndex" => 0,
          "id" => "call_1",
          "toolName" => "echo"
        }),
        sse_event(%{
          "type" => "toolcall_delta",
          "contentIndex" => 0,
          "delta" => "{\"text\":\"hi"
        }),
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
        sse_event(%{
          "type" => "error",
          "reason" => "error",
          "errorMessage" => "boom",
          "usage" => %{}
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
      assert message.error_message == "boom"

      assert_receive :sse_server_done, @receive_timeout
    end

    test "encodes tool result trust in proxy request context" do
      chunks = [
        sse_event(%{"type" => "start"}),
        sse_event(%{"type" => "done", "reason" => "stop", "usage" => %{}})
      ]

      port = start_sse_server(chunks, capture_request: true)

      context =
        Ai.Types.Context.new(
          messages: [
            %ToolResultMessage{
              role: :tool_result,
              tool_call_id: "call_1",
              tool_name: "webfetch",
              content: [%TextContent{type: :text, text: "<html>"}],
              trust: :untrusted,
              is_error: false,
              timestamp: 1
            }
          ]
        )

      stream =
        Proxy.stream_proxy(
          Mocks.mock_model(),
          context,
          %ProxyStreamOptions{
            auth_token: "token",
            proxy_url: "http://localhost:#{port}"
          }
        )

      {:ok, %AssistantMessage{}} = EventStream.result(stream, @receive_timeout)

      assert_receive {:sse_server_request, request}, @receive_timeout
      assert request =~ "\"role\":\"tool_result\""
      assert request =~ "\"trust\":\"untrusted\""

      assert_receive :sse_server_done, @receive_timeout
    end
  end
end
