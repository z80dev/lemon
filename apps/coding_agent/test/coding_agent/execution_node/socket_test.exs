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

  test "sends application health keepalives below the controller idle timeout" do
    state = %Socket{
      owner: self(),
      connect_params: %{},
      reconnect_delay_ms: 0,
      ping_interval_ms: 1,
      max_payload_bytes: 1_048_576
    }

    assert {:ok, connected_state} = Socket.handle_connect(:ignored, state)
    token = connected_state.ping_token
    assert_receive {:execution_node_ping, ^token}, 2_000

    assert {:reply, {:text, frame}, keepalive_state} =
             Socket.handle_info({:execution_node_ping, token}, connected_state)

    decoded = Jason.decode!(frame)
    assert decoded["method"] == "health"
    assert decoded["params"] == %{}
    assert Map.has_key?(keepalive_state.pending, decoded["id"])
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

  test "transient connect failures accumulate across TCP connections and reset on hello" do
    state = %Socket{owner: self(), connect_id: "connect", connect_params: %{}}
    error = ~s({"type":"res","id":"connect","ok":false,"error":{"code":"UNAVAILABLE"}})

    assert {:close, {1013, _}, failed} = Socket.handle_frame({:text, error}, state)
    assert_receive {:execution_node_socket, _, {:connect_retry, "UNAVAILABLE"}}
    refute failed.stopping
    assert failed.connect_failures == 1
    assert {:ok, connecting} = Socket.handle_connect(:ignored, failed)
    assert connecting.connect_failures == 1
    error =
      Jason.encode!(%{
        type: "res",
        id: connecting.connect_id,
        ok: false,
        error: %{code: "INTERNAL_ERROR"}
      })
    assert {:close, {1013, _}, failed_again} = Socket.handle_frame({:text, error}, connecting)
    assert failed_again.connect_failures == 2
    assert {:ok, ready} = Socket.handle_frame({:text, ~s({"type":"hello-ok"})}, failed_again)
    assert ready.connect_failures == 0
  end

  test "rejected credentials stop instead of retrying" do
    state = %Socket{owner: self(), connect_id: "connect"}
    error = ~s({"type":"res","id":"connect","ok":false,"error":{"code":"UNAUTHORIZED"}})
    assert {:close, {1008, _}, failed} = Socket.handle_frame({:text, error}, state)
    assert_receive {:execution_node_socket, _, {:authentication_error, %{"code" => "UNAUTHORIZED"}}}
    assert failed.stopping
    assert {:ok, _} = Socket.handle_disconnect(%{}, failed)
    refute_receive {:execution_node_socket, _, {:connect_retry, _}}
  end

  test "connect retry backoff grows exponentially and never exceeds sixty seconds" do
    for failures <- 1..100 do
      base = min(1_000 * Integer.pow(2, min(failures - 1, 6)), 60_000)
      delay = Socket.reconnect_delay(%Socket{connect_failures: failures}, 1)
      assert delay >= round(base * 0.8)
      assert delay <= min(round(base * 1.2), 60_000)
    end
  end
end
