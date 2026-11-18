defmodule LemonAi.Providers.OpenAIResponsesWebSocketLifecycleTest do
  use ExUnit.Case, async: true

  alias LemonAi.Providers.OpenAIResponsesWebSocket, as: Transport
  alias LemonAi.Providers.OpenAIResponsesShared

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    Model,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    UserMessage
  }

  @url "ws://127.0.0.1/responses"
  @headers [{"authorization", "Bearer test"}]
  @body %{"model" => "test-model", "input" => [%{"role" => "user", "content" => "first"}]}

  test "completion arms a real 30-second timer and its token closes the socket" do
    {transport, socket} = transport_with_socket(self())
    socket_monitor = Process.monitor(socket)
    before = System.monotonic_time(:millisecond)
    {:ok, events} = Transport.request(transport, @url, @headers, @body)
    send(socket, {:events, [completed("resp_first")]})
    assert [%{"type" => "response.completed"}] = Enum.to_list(events)

    state = :sys.get_state(transport)
    remaining = Process.read_timer(state.idle_timer)
    elapsed = System.monotonic_time(:millisecond) - before
    assert is_integer(remaining) and remaining > 0 and remaining <= 30_000
    assert remaining + elapsed >= 30_000
    assert state.baseline.id == "resp_first"

    # Deliver the exact scheduled message instead of sleeping for 30 seconds.
    send(transport, {:idle_expired, state.idle_token})
    expired = :sys.get_state(transport)
    assert expired.socket == nil
    assert expired.baseline == nil
    assert expired.idle_timer == nil
    assert Process.read_timer(state.idle_timer) == false
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :killed}
  end

  test "an obsolete idle timer cannot close a reused active connection" do
    {transport, socket} = transport_with_socket(self())
    {:ok, events} = Transport.request(transport, @url, @headers, @body)
    send(socket, {:events, [completed("resp_first")]})
    Enum.to_list(events)
    idle = :sys.get_state(transport)

    {:ok, events} = Transport.request(transport, @url, @headers, @body)
    send(transport, {:idle_expired, idle.idle_token})
    active = :sys.get_state(transport)
    assert active.socket == socket
    assert active.idle_timer == nil
    assert Process.read_timer(idle.idle_timer) == false
    assert Process.alive?(socket)

    send(socket, {:events, [completed("resp_second")]})
    assert [%{"type" => "response.completed"}] = Enum.to_list(events)
  end

  test "halting enumeration closes a demand-blocked socket and drops the anchor" do
    {transport, socket} = transport_with_socket(self())
    monitor = Process.monitor(socket)
    {:ok, events} = Transport.request(transport, @url, @headers, @body)
    created = %{"type" => "response.created", "response" => %{"id" => "resp_started"}}
    send(socket, {:events, [created, completed("resp_started")]})
    assert [^created] = Enum.take(events, 1)
    assert_receive {:DOWN, ^monitor, :process, ^socket, :killed}
    state = :sys.get_state(transport)
    assert state.active == nil
    assert state.socket == nil
    assert state.baseline == nil
  end

  test "request owner death cleans up even when enumeration has not started" do
    {transport, socket} = transport_with_socket(self())
    test = self()
    socket_monitor = Process.monitor(socket)

    caller =
      spawn(fn ->
        {:ok, _events} = Transport.request(transport, @url, @headers, @body)
        send(test, {:request_started, self()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)

    assert_receive {:request_started, ^caller}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :killed}
    state = :sys.get_state(transport)
    assert state.active == nil
    assert state.baseline == nil
    assert Process.alive?(transport)
  end

  test "logical session death stops the transport and socket" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    {transport, socket} = transport_with_socket(owner)
    transport_monitor = Process.monitor(transport)
    socket_monitor = Process.monitor(socket)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^transport_monitor, :process, ^transport, :normal}
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket, :killed}
  end

  test "reset closes the connection without erasing logical-session rejection strikes" do
    {transport, socket} = transport_with_socket(self())
    monitor = Process.monitor(socket)
    :sys.replace_state(transport, &%{&1 | rejection_strikes: 3})
    assert :ok = Transport.reset(transport)
    state = :sys.get_state(transport)
    assert state.rejection_strikes == 3
    assert state.socket == nil
    assert state.baseline == nil
    assert state.identity == nil
    assert_receive {:DOWN, ^monitor, :process, ^socket, :killed}
  end

  test "nested terminal errors are exposed as shared stream error events" do
    {transport, socket} = transport_with_socket(self())
    {:ok, events} = Transport.request(transport, @url, @headers, @body)

    send(
      socket,
      {:events,
       [
         %{
           "type" => "error",
           "error" => %{"code" => "invalid_request_error", "message" => "Invalid tool schema"}
         }
       ]}
    )

    assert [
             %{
               "type" => "error",
               "code" => "invalid_request_error",
               "message" => "Invalid tool schema"
             }
           ] =
             Enum.to_list(events)

    assert :sys.get_state(transport).socket == nil
  end

  test "raw output anchors match shared text, reasoning and function-call replay" do
    {transport, socket} = transport_with_socket(self())
    providers = MapSet.new([:openai])
    model = %Model{id: @body["model"], provider: :openai, api: :openai_responses, input: [:text]}
    context = Context.new(messages: [%UserMessage{content: "first"}])
    input = OpenAIResponsesShared.convert_messages(model, context, providers)
    body = Map.put(@body, "input", input)
    {:ok, events} = Transport.request(transport, @url, @headers, body)
    assert_receive {:request_frame, _first}

    reasoning = %{
      "type" => "reasoning",
      "id" => "rs_first",
      "status" => "completed",
      "summary" => [%{"type" => "summary_text", "text" => "Reasoning"}],
      "encrypted_content" => "opaque-signature"
    }

    message = %{
      "type" => "message",
      "id" => "msg_" <> String.duplicate("x", 70),
      "role" => "assistant",
      "status" => "completed",
      "content" => [
        %{
          "type" => "output_text",
          "text" => "Answer",
          "annotations" => [%{"type" => "citation"}]
        },
        %{"type" => "refusal", "refusal" => " with refusal"}
      ]
    }

    call = %{
      "type" => "function_call",
      "id" => "fc_first",
      "call_id" => "call_first",
      "name" => "lookup",
      "status" => "completed",
      "arguments" => ~s({"z":{"b":2,"a":1},"a":3})
    }

    terminal = put_in(completed("resp_first"), ["response", "output"], [reasoning, message, call])
    send(socket, {:events, [terminal]})
    Enum.to_list(events)

    assistant = %AssistantMessage{
      provider: model.provider,
      api: model.api,
      model: model.id,
      content: [
        %ThinkingContent{thinking: "Reasoning", thinking_signature: Jason.encode!(reasoning)},
        %TextContent{text: "Answer with refusal", text_signature: message["id"]},
        %ToolCall{
          id: "call_first|fc_first",
          name: "lookup",
          arguments: %{"a" => 3, "z" => %{"a" => 1, "b" => 2}}
        }
      ]
    }

    result = %ToolResultMessage{
      tool_call_id: "call_first|fc_first",
      tool_name: "lookup",
      content: [%TextContent{text: "found"}]
    }

    context = %{context | messages: context.messages ++ [assistant, result]}

    body =
      Map.put(body, "input", OpenAIResponsesShared.convert_messages(model, context, providers))

    {:ok, events} = Transport.request(transport, @url, @headers, body)
    assert_receive {:request_frame, continuation}
    assert continuation["previous_response_id"] == "resp_first"

    assert [%{"type" => "function_call_output", "call_id" => "call_first", "output" => "found"}] =
             continuation["input"]

    send(socket, {:events, [completed("resp_second")]})
    Enum.to_list(events)
  end

  # These are transport lifecycle tests, not wire tests. A linked process speaks
  # the internal demand/ack protocol so no scheduler sleeps or network timing
  # are needed. The sibling wire suite exercises actual WebSockex TCP sockets.
  defp transport_with_socket(owner) do
    transport = start_supervised!({Transport, owner: owner})
    observer = self()
    socket = spawn(fn -> socket_loop(transport, observer) end)

    identity =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({@url, @headers, @body["model"]}, [:deterministic])
      )

    :sys.replace_state(transport, fn state ->
      Process.link(socket)
      %{state | socket: socket, connected: true, identity: identity}
    end)

    {transport, socket}
  end

  defp socket_loop(transport, observer) do
    receive do
      {:"$websockex_cast", {:request, frame}} ->
        send(observer, {:request_frame, Jason.decode!(frame)})
        socket_loop(transport, observer)

      {:events, events} ->
        Enum.each(events, &GenServer.call(transport, {:frame, self(), &1}, :infinity))
        socket_loop(transport, observer)
    end
  end

  defp completed(id) do
    %{
      "type" => "response.completed",
      "response" => %{"id" => id, "status" => "completed", "output" => []}
    }
  end
end
