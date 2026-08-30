defmodule CodingAgent.ExecutionNode.SocketTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.Socket

  test "authenticates every connection and routes responses and targeted events" do
    state = %Socket{
      owner: self(),
      url: "ws://controller:4040/ws",
      connect_params: %{"auth" => %{"token" => "secret"}},
      reconnect_delay_ms: 0
    }

    assert {:ok, connected_state} = Socket.handle_connect(:ignored, state)
    connect_id = connected_state.connect_id
    assert_receive {:execution_node_send_connect, ^connect_id}

    assert {:reply, {:text, connect_frame}, ^connected_state} =
             Socket.handle_info({:execution_node_send_connect, connect_id}, connected_state)

    decoded_connect = Jason.decode!(connect_frame)
    assert decoded_connect["method"] == "connect"
    assert decoded_connect["params"]["auth"]["token"] == "secret"

    hello = ~s({"type":"hello-ok","auth":{"role":"node","clientId":"node-1"}})
    assert {:ok, ready_state} = Socket.handle_frame({:text, hello}, connected_state)
    assert_receive {:execution_node_socket, _pid, {:connected, %{"auth" => auth}}}
    assert auth["clientId"] == "node-1"

    assert {:reply, {:text, request_frame}, pending_state} =
             Socket.handle_cast(
               {:request, "req-1", "node.invoke.result", %{"invokeId" => "invoke-1"}, :result,
                1_000},
               ready_state
             )

    assert Jason.decode!(request_frame)["method"] == "node.invoke.result"

    response = ~s({"type":"res","id":"req-1","ok":true,"payload":{"received":true}})
    assert {:ok, response_state} = Socket.handle_frame({:text, response}, pending_state)

    assert_receive {:execution_node_socket, _pid,
                    {:response, :result, {:ok, %{"received" => true}}}}

    event =
      ~s({"type":"event","event":"node.invoke.request","payload":{"nodeId":"node-1"}})

    assert {:ok, _state} = Socket.handle_frame({:text, event}, response_state)

    assert_receive {:execution_node_socket, _pid,
                    {:event, "node.invoke.request", %{"nodeId" => "node-1"}}}
  end

  test "reports disconnects and requests an authenticated reconnect" do
    state = %Socket{
      owner: self(),
      url: "ws://controller:4040/ws",
      connect_params: %{"auth" => %{"token" => "secret"}},
      reconnect_delay_ms: 0
    }

    assert {:reconnect, reconnecting} =
             Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, state)

    assert reconnecting.connect_id == nil
    assert_receive {:execution_node_socket, _pid, {:disconnected, :closed}}

    assert {:ok, connected_state} = Socket.handle_connect(:ignored, reconnecting)
    connect_id = connected_state.connect_id
    assert_receive {:execution_node_send_connect, ^connect_id}

    assert {:reply, {:text, frame}, ^connected_state} =
             Socket.handle_info({:execution_node_send_connect, connect_id}, connected_state)

    assert Jason.decode!(frame)["params"]["auth"]["token"] == "secret"
  end

  test "redacts authentication material from status output" do
    state = %Socket{
      connect_params: %{"auth" => %{"token" => "secret"}},
      pending: %{"id" => %{tag: :tag, timer: make_ref()}}
    }

    formatted = Socket.format_status(:normal, [[], state])
    assert formatted.connect_params["auth"] == "[REDACTED]"
    refute inspect(formatted) =~ "secret"
  end
end
