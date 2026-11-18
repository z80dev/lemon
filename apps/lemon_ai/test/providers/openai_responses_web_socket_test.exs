defmodule LemonAi.Providers.OpenAIResponsesWebSocketTest do
  use ExUnit.Case, async: false

  alias LemonAi.EventStream
  alias LemonAi.Providers.{OpenAICodexResponses, OpenAIResponses, OpenAIResponsesWebSocket}
  alias LemonAi.Types.{Context, Model, StreamOptions, TextContent, ToolResultMessage, UserMessage}

  defmodule WireServer do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def port(server), do: GenServer.call(server, :port)

    @impl true
    def init(opts) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)
      owner = Keyword.fetch!(opts, :owner)
      acceptor = spawn_link(fn -> accept(listener, owner) end)
      {:ok, %{listener: listener, acceptor: acceptor, port: port}}
    end

    @impl true
    def handle_call(:port, _from, state), do: {:reply, state.port, state}

    @impl true
    def terminate(_reason, state) do
      Process.exit(state.acceptor, :shutdown)
      :gen_tcp.close(state.listener)
    end

    defp accept(listener, owner) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          handler = spawn_link(fn -> await_socket(owner) end)
          :ok = :gen_tcp.controlling_process(socket, handler)
          send(handler, {:socket, socket})
          accept(listener, owner)

        {:error, :closed} ->
          :ok
      end
    end

    defp await_socket(owner) do
      receive do
        {:socket, socket} ->
          {:ok, headers} = handshake(socket)
          send(owner, {:ws_connected, self(), headers})
          frames(socket, owner)
      end
    end

    defp handshake(socket) do
      :ok = :inet.setopts(socket, packet: :http_bin)
      {:ok, {:http_request, :GET, path, _version}} = :gen_tcp.recv(socket, 0, 5_000)
      {:ok, headers} = headers(socket, %{"path" => path})
      key = Map.fetch!(headers, "sec-websocket-key")
      accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 101 Switching Protocols\r\n",
          "Upgrade: websocket\r\nConnection: Upgrade\r\n",
          "Sec-WebSocket-Accept: ",
          accept,
          "\r\n\r\n"
        ])

      :ok = :inet.setopts(socket, packet: :raw)
      {:ok, headers}
    end

    defp headers(socket, acc) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, {:http_header, _index, key, _reserved, value}} ->
          headers(socket, Map.put(acc, String.downcase(to_string(key)), value))

        {:ok, :http_eoh} ->
          {:ok, acc}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp frames(socket, owner) do
      case read_frame(socket) do
        {:ok, 1, payload} ->
          send(owner, {:ws_request, self(), Jason.decode!(payload)})
          respond(socket, owner)

        {:ok, 9, payload} ->
          send_frame(socket, 10, payload)
          frames(socket, owner)

        {:ok, 8, _payload} ->
          send_frame(socket, 8, <<1000::16>>)
          :gen_tcp.close(socket)
          send(owner, {:ws_closed, self()})

        {:error, _reason} ->
          :gen_tcp.close(socket)
          send(owner, {:ws_closed, self()})
      end
    end

    defp respond(socket, owner) do
      receive do
        {:events, events} ->
          Enum.each(events, &send_frame(socket, 1, Jason.encode!(&1)))
          frames(socket, owner)

        :close ->
          :gen_tcp.close(socket)
          send(owner, {:ws_closed, self()})
      end
    end

    defp read_frame(socket) do
      with {:ok, <<_fin::1, _reserved::3, opcode::4, masked::1, size::7>>} <-
             :gen_tcp.recv(socket, 2, 5_000),
           {:ok, size} <- frame_size(socket, size),
           {:ok, mask} <- read_bytes(socket, masked * 4),
           {:ok, payload} <- read_bytes(socket, size) do
        {:ok, opcode, unmask(payload, mask)}
      end
    end

    defp frame_size(socket, 126) do
      case :gen_tcp.recv(socket, 2, 5_000) do
        {:ok, <<size::16>>} -> {:ok, size}
        error -> error
      end
    end

    defp frame_size(socket, 127) do
      case :gen_tcp.recv(socket, 8, 5_000) do
        {:ok, <<size::64>>} -> {:ok, size}
        error -> error
      end
    end

    defp frame_size(_socket, size), do: {:ok, size}
    defp read_bytes(_socket, 0), do: {:ok, <<>>}
    defp read_bytes(socket, size), do: :gen_tcp.recv(socket, size, 5_000)
    defp unmask(payload, <<>>), do: payload

    defp unmask(payload, mask) do
      payload
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(mask, rem(index, 4))) end)
      |> :binary.list_to_bin()
    end

    defp send_frame(socket, opcode, payload) do
      size = byte_size(payload)

      header =
        cond do
          size < 126 -> <<1::1, 0::3, opcode::4, 0::1, size::7>>
          size <= 65_535 -> <<1::1, 0::3, opcode::4, 0::1, 126::7, size::16>>
          true -> <<1::1, 0::3, opcode::4, 0::1, 127::7, size::64>>
        end

      :gen_tcp.send(socket, [header, payload])
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    server = start_supervised!({WireServer, owner: self()})
    transport = start_supervised!({OpenAIResponsesWebSocket, owner: self()})
    base_url = "http://127.0.0.1:#{WireServer.port(server)}"
    %{transport: transport, base_url: base_url}
  end

  test "second turn sends only new input on the same connection", state do
    for provider <- [OpenAIResponses, OpenAICodexResponses] do
      OpenAIResponsesWebSocket.reset(state.transport)
      model = model(provider, state.base_url)
      opts = options(provider, state.transport)
      context = context("first")
      {:ok, stream} = provider.stream(model, context, opts)
      assert_receive {:ws_connected, socket, headers}, 2_000
      assert String.starts_with?(headers["authorization"], "Bearer ")

      if provider == OpenAICodexResponses do
        assert headers["openai-beta"] == "responses_websockets=2026-02-06"
      end

      assert_receive {:ws_request, ^socket, first}, 2_000
      assert first["type"] == "response.create"
      refute Map.has_key?(first, "stream")
      refute Map.has_key?(first, "previous_response_id")
      send(socket, {:events, completed("resp_first")})
      assert {:ok, assistant} = EventStream.result(stream, 2_000)

      context = next_context(context, assistant, "second")
      {:ok, stream} = provider.stream(model, context, opts)
      assert_receive {:ws_request, ^socket, second}, 2_000
      assert second["previous_response_id"] == "resp_first"
      assert [%{"role" => "user", "content" => [%{"text" => "second"}]}] = second["input"]
      send(socket, {:events, completed("resp_second")})
      assert {:ok, _} = EventStream.result(stream, 2_000)
    end
  end

  test "context helpers preserve the anchored prefix on a second turn", state do
    for provider <- [OpenAIResponses, OpenAICodexResponses] do
      OpenAIResponsesWebSocket.reset(state.transport)
      model = model(provider, state.base_url)
      opts = options(provider, state.transport)

      context =
        Context.new(system_prompt: "Stable instructions")
        |> Context.add_user_message("first")

      {:ok, stream} = provider.stream(model, context, opts)
      assert_receive {:ws_request, socket, first}, 2_000
      refute Map.has_key?(first, "previous_response_id")
      send(socket, {:events, completed("resp_helper_first")})

      assistant =
        stream
        |> EventStream.events()
        |> Enum.find_value(fn
          {:done, _, message} -> message
          _ -> nil
        end)

      assert [%TextContent{text_signature: "msg_resp_helper_first"}] = assistant.content
      assert :sys.get_state(state.transport).baseline != nil

      context =
        context
        |> Context.add_assistant_message(assistant)
        |> Context.add_user_message("second")

      {:ok, stream} = provider.stream(model, context, opts)
      assert_receive {:ws_request, next_socket, second}, 2_000
      assert second["previous_response_id"] == "resp_helper_first"
      assert next_socket == socket
      assert [%{"role" => "user", "content" => [%{"text" => "second"}]}] = second["input"]
      send(next_socket, {:events, completed("resp_helper_second")})
      assert {:ok, _} = EventStream.result(stream, 2_000)
    end
  end

  test "tool-result continuation sends only the new result", state do
    for provider <- [OpenAIResponses, OpenAICodexResponses] do
      OpenAIResponsesWebSocket.reset(state.transport)
      model = model(provider, state.base_url)
      opts = options(provider, state.transport)
      context = context("call a tool")
      {:ok, stream} = provider.stream(model, context, opts)
      assert_receive {:ws_request, socket, _body}, 2_000

      item = %{
        "type" => "function_call",
        "id" => "fc_wire",
        "call_id" => "call_wire",
        "name" => "lookup",
        "arguments" => ~s({"z":1,"a":2}),
        "status" => "completed"
      }

      send(
        socket,
        {:events,
         [
           %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
           %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_tool",
               "status" => "completed",
               "output" => [item]
             }
           }
         ]}
      )

      assert {:ok, assistant} = EventStream.result(stream, 2_000)
      assert assistant.stop_reason == :tool_use
      [call] = assistant.content

      result = %ToolResultMessage{
        tool_call_id: call.id,
        tool_name: "lookup",
        content: [%TextContent{text: "found"}]
      }

      context =
        context
        |> Context.add_assistant_message(assistant)
        |> Context.add_tool_result(result)

      {:ok, stream} = provider.stream(model, context, opts)
      assert_receive {:ws_request, ^socket, body}, 2_000
      assert body["previous_response_id"] == "resp_tool"

      assert [%{"type" => "function_call_output", "call_id" => "call_wire", "output" => "found"}] =
               body["input"]

      send(socket, {:events, completed("resp_tool_done")})
      assert {:ok, _} = EventStream.result(stream, 2_000)
    end
  end

  test "changed history cannot reuse an otherwise live anchor", state do
    model = model(OpenAIResponses, state.base_url)
    opts = options(OpenAIResponses, state.transport)
    {:ok, stream} = OpenAIResponses.stream(model, context("first"), opts)
    assert_receive {:ws_request, socket, _body}, 2_000
    send(socket, {:events, completed("resp_first")})
    assert {:ok, _} = EventStream.result(stream, 2_000)

    {:ok, stream} = OpenAIResponses.stream(model, context("replacement summary"), opts)
    assert_receive {:ws_request, replacement_socket, body}, 2_000
    assert replacement_socket != socket
    assert_receive {:ws_closed, ^socket}, 2_000
    refute Map.has_key?(body, "previous_response_id")
    assert length(body["input"]) == 2
    send(replacement_socket, {:events, completed("resp_replaced")})
    assert {:ok, _} = EventStream.result(stream, 2_000)
  end

  test "three rejected anchors replay full context then disable chaining", state do
    model = model(OpenAIResponses, state.base_url)
    opts = options(OpenAIResponses, state.transport)
    context = context("first")
    {:ok, stream} = OpenAIResponses.stream(model, context, opts)
    assert_receive {:ws_request, socket, _body}, 2_000
    send(socket, {:events, completed("resp_0")})
    assert {:ok, assistant} = EventStream.result(stream, 2_000)

    {context, assistant} =
      Enum.reduce(1..3, {context, assistant}, fn strike, {history, previous} ->
        history = next_context(history, previous, "turn #{strike}")
        {:ok, stream} = OpenAIResponses.stream(model, history, opts)
        assert_receive {:ws_request, ^socket, chained}, 2_000
        assert chained["previous_response_id"] == "resp_#{strike - 1}"

        rejection =
          if strike == 2 do
            %{
              "type" => "response.failed",
              "response" => %{"status" => "failed", "error" => anchor_rejection()["error"]}
            }
          else
            anchor_rejection()
          end

        send(socket, {:events, [rejection]})
        assert_receive {:ws_request, ^socket, replay}, 2_000
        refute Map.has_key?(replay, "previous_response_id")
        assert length(replay["input"]) == 2 * strike + 2
        send(socket, {:events, completed("resp_#{strike}")})
        assert {:ok, response} = EventStream.result(stream, 2_000)
        {history, response}
      end)

    context = next_context(context, assistant, "after strikes")
    {:ok, stream} = OpenAIResponses.stream(model, context, opts)
    assert_receive {:ws_request, ^socket, full}, 2_000
    refute Map.has_key?(full, "previous_response_id")
    assert length(full["input"]) == length(context.messages) + 1
    send(socket, {:events, completed("resp_final")})
    assert {:ok, _} = EventStream.result(stream, 2_000)
  end

  test "credential rotation closes the old socket and drops the anchor", state do
    for provider <- [OpenAIResponses, OpenAICodexResponses] do
      OpenAIResponsesWebSocket.reset(state.transport)
      model = model(provider, state.base_url)
      opts = options(provider, state.transport)
      context = context("first")
      {:ok, stream} = provider.stream(model, context, opts)
      authorization = "Bearer #{opts.api_key}"
      assert_receive {:ws_connected, old_socket, %{"authorization" => ^authorization}}, 2_000
      assert_receive {:ws_request, ^old_socket, _body}, 2_000
      send(old_socket, {:events, completed("resp_first")})
      assert {:ok, assistant} = EventStream.result(stream, 2_000)

      # Rotating the Codex signature keeps the same account claim: even a
      # same-account token refresh must replace the authenticated connection.
      rotated = %{opts | api_key: opts.api_key <> "-rotated"}
      {:ok, stream} = provider.stream(model, next_context(context, assistant, "second"), rotated)
      authorization = "Bearer #{rotated.api_key}"
      assert_receive {:ws_connected, new_socket, %{"authorization" => ^authorization}}, 2_000
      assert new_socket != old_socket
      assert_receive {:ws_request, ^new_socket, body}, 2_000
      refute Map.has_key?(body, "previous_response_id")
      assert length(body["input"]) == if(provider == OpenAICodexResponses, do: 3, else: 4)
      send(new_socket, {:events, completed("resp_second")})
      assert {:ok, _} = EventStream.result(stream, 2_000)
      assert_receive {:ws_closed, ^old_socket}, 2_000
    end
  end

  test "model changes and compaction reset both socket and baseline", state do
    model = model(OpenAIResponses, state.base_url)
    opts = options(OpenAIResponses, state.transport)
    context = context("first")
    {:ok, stream} = OpenAIResponses.stream(model, context, opts)
    assert_receive {:ws_request, first_socket, _body}, 2_000
    send(first_socket, {:events, completed("resp_first")})
    assert {:ok, assistant} = EventStream.result(stream, 2_000)
    history = next_context(context, assistant, "second")

    {:ok, stream} = OpenAIResponses.stream(%{model | id: "other-model"}, history, opts)
    assert_receive {:ws_request, second_socket, switched}, 2_000
    assert second_socket != first_socket
    refute Map.has_key?(switched, "previous_response_id")
    send(second_socket, {:events, completed("resp_second")})
    assert {:ok, _} = EventStream.result(stream, 2_000)

    :ok = OpenAIResponsesWebSocket.reset(state.transport)
    {:ok, stream} = OpenAIResponses.stream(%{model | id: "other-model"}, context("summary"), opts)
    assert_receive {:ws_request, third_socket, compacted}, 2_000
    assert third_socket != second_socket
    refute Map.has_key?(compacted, "previous_response_id")
    assert length(compacted["input"]) == 2
    send(third_socket, {:events, completed("resp_compacted")})
    assert {:ok, _} = EventStream.result(stream, 2_000)
  end

  test "a rejected anchor after generation evidence is not replayed", state do
    model = model(OpenAIResponses, state.base_url)
    opts = options(OpenAIResponses, state.transport)
    context = context("first")
    {:ok, stream} = OpenAIResponses.stream(model, context, opts)
    assert_receive {:ws_request, socket, _body}, 2_000
    send(socket, {:events, completed("resp_first")})
    assert {:ok, assistant} = EventStream.result(stream, 2_000)

    {:ok, stream} =
      OpenAIResponses.stream(model, next_context(context, assistant, "second"), opts)

    assert_receive {:ws_request, ^socket, _body}, 2_000

    send(
      socket,
      {:events,
       [
         %{"type" => "response.created", "response" => %{"id" => "resp_started"}},
         anchor_rejection()
       ]}
    )

    assert {:error, _} = EventStream.result(stream, 2_000)
    refute_receive {:ws_request, ^socket, _body}, 50
  end

  test "a failed first frame containing output is not a safe anchor rejection", state do
    model = model(OpenAIResponses, state.base_url)
    opts = options(OpenAIResponses, state.transport)
    history = context("first")
    {:ok, stream} = OpenAIResponses.stream(model, history, opts)
    assert_receive {:ws_request, socket, _body}, 2_000
    send(socket, {:events, completed("resp_first")})
    assert {:ok, assistant} = EventStream.result(stream, 2_000)

    {:ok, stream} =
      OpenAIResponses.stream(model, next_context(history, assistant, "second"), opts)

    assert_receive {:ws_request, ^socket, _body}, 2_000

    send(
      socket,
      {:events,
       [
         %{
           "type" => "response.failed",
           "response" => %{
             "status" => "failed",
             "error" => anchor_rejection()["error"],
             "output" => [%{"type" => "function_call", "id" => "fc_started", "name" => "lookup"}]
           }
         }
       ]}
    )

    assert {:error, _} = EventStream.result(stream, 2_000)
    refute_receive {:ws_request, ^socket, _body}, 50
  end

  test "connection loss after send fails without uncertain replay", state do
    opts = options(OpenAIResponses, state.transport)

    {:ok, stream} =
      OpenAIResponses.stream(model(OpenAIResponses, state.base_url), context("first"), opts)

    assert_receive {:ws_request, socket, _body}, 2_000
    send(socket, :close)
    assert {:error, _} = EventStream.result(stream, 2_000)
    refute_receive {:ws_request, _socket, _body}, 50
  end

  test "remote plaintext endpoints are refused before any bearer token is sent", state do
    body = %{"model" => "m", "input" => []}

    for url <- [
          "http://192.0.2.1:9/v1/responses",
          "ws://api.example.com/v1/responses",
          "http://x.localhost:9/v1/responses",
          "http://127.0.0.1.evil:9/v1/responses"
        ] do
      assert {:error, "Refusing plaintext Responses WebSocket to a non-loopback host", nil} =
               OpenAIResponsesWebSocket.request(
                 state.transport,
                 url,
                 [{"authorization", "Bearer secret"}],
                 body
               )
    end

    refute_receive {:ws_connected, _, _}, 100
  end

  test "plaintext localhost is pinned to the loopback address", state do
    port = String.split(state.base_url, ":") |> List.last()

    assert {:ok, _events} =
             OpenAIResponsesWebSocket.request(
               state.transport,
               "http://localhost:#{port}/v1/responses",
               [{"authorization", "Bearer secret"}],
               %{"model" => "m", "input" => []}
             )

    assert_receive {:ws_connected, _socket, headers}, 2_000
    assert headers["authorization"] == "Bearer secret"
    assert headers["host"] == "127.0.0.1:#{port}"
  end

  test "disabled transport uses the unchanged SSE request path", state do
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
    end)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sse_request, conn.request_path, conn.req_headers, Jason.decode!(raw)})
      body = Enum.map_join(completed("resp_sse"), "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      Plug.Conn.send_resp(conn, 200, body)
    end)

    for provider <- [OpenAIResponses, OpenAICodexResponses] do
      opts = options(provider, state.transport)

      opts = %{
        opts
        | provider_options: %{responses_websocket: false, responses_transport: state.transport}
      }

      context =
        Context.new(system_prompt: "Stable instructions")
        |> Context.add_user_message("first")

      {:ok, stream} = provider.stream(model(provider, state.base_url), context, opts)
      assert {:ok, assistant} = EventStream.result(stream, 2_000)
      assert_receive {:sse_request, _path, headers, %{"stream" => true} = body}

      if provider == OpenAICodexResponses do
        assert {"openai-beta", "responses=experimental"} in headers
      end

      refute Map.has_key?(body, "previous_response_id")
      refute Map.has_key?(body, "type")

      context =
        context
        |> Context.add_assistant_message(assistant)
        |> Context.add_user_message("second")

      {:ok, stream} = provider.stream(model(provider, state.base_url), context, opts)
      assert {:ok, _} = EventStream.result(stream, 2_000)
      assert_receive {:sse_request, _path, _headers, body}
      refute Map.has_key?(body, "previous_response_id")

      assert [
               %{"role" => "user", "content" => [%{"text" => "first"}]},
               %{"role" => "assistant", "content" => [%{"text" => "Answer"}]},
               %{"role" => "user", "content" => [%{"text" => "second"}]}
             ] = Enum.filter(body["input"], &(&1["role"] in ["user", "assistant"]))
    end

    refute_receive {:ws_connected, _socket, _headers}, 50
  end

  defp model(provider, base_url) do
    codex? = provider == OpenAICodexResponses

    %Model{
      id: "wire-model",
      name: "Wire model",
      provider: if(codex?, do: :openai_codex, else: :openai),
      api: if(codex?, do: :openai_codex_responses, else: :openai_responses),
      base_url: base_url
    }
  end

  defp options(provider, transport) do
    token =
      if provider == OpenAICodexResponses do
        claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "wire-account"}}
        "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".signature"
      else
        "test-key"
      end

    %StreamOptions{
      api_key: token,
      session_id: "wire-session",
      provider_options: %{responses_websocket: true, responses_transport: transport}
    }
  end

  defp context(text) do
    Context.new(system_prompt: "Stable instructions", messages: [%UserMessage{content: text}])
  end

  defp next_context(context, assistant, text) do
    %{context | messages: context.messages ++ [assistant, %UserMessage{content: text}]}
  end

  defp anchor_rejection do
    %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "code" => "previous_response_not_found",
        "param" => "previous_response_id",
        "message" => "Previous response not found"
      }
    }
  end

  defp completed(id) do
    item = %{
      "type" => "message",
      "id" => "msg_#{id}",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => "Answer", "annotations" => []}]
    }

    [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "message",
          "id" => item["id"],
          "role" => "assistant",
          "content" => []
        }
      },
      %{"type" => "response.output_text.delta", "output_index" => 0, "delta" => "Answer"},
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => id,
          "status" => "completed",
          "output" => [item],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 1, "total_tokens" => 11}
        }
      }
    ]
  end
end
