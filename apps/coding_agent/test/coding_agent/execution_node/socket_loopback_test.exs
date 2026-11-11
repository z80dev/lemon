defmodule CodingAgent.ExecutionNode.SocketLoopbackTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.Socket

  setup do
    original = Application.fetch_env(:lemon_core, :require_owned_loopback)
    Application.put_env(:lemon_core, :require_owned_loopback, true)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:lemon_core, :require_owned_loopback, value)
        :error -> Application.delete_env(:lemon_core, :require_owned_loopback)
      end
    end)
  end

  test "all non-owned results close before encoding credentials and reconnect normally" do
    for ownership <- [:foreign, :absent, :unverifiable] do
      state = state("ws://127.0.0.1:4044/ws", fn 4044 -> ownership end)

      assert {:close, blocked} =
               Socket.handle_info({:execution_node_send_connect, "connect"}, state)

      assert_receive {:execution_node_socket, _, {:connect_retry, :loopback_listener_not_owned}}
      refute blocked.stopping

      assert {:reconnect, retrying} = Socket.handle_disconnect(%{reason: :closed}, blocked)
      refute_receive {:execution_node_socket, _, {:disconnected, _}}
      assert {:ok, connected} = Socket.handle_connect(:ignored, retrying)
      assert connected.connect_blocked_reason == nil
      assert_receive {:execution_node_send_connect, _}
    end
  end

  test "owned IPv4 and IPv6 listeners may receive the connect frame" do
    for host <- ["127.0.0.1", "[::1]", "[::ffff:127.0.0.1]"] do
      state = state("ws://#{host}:4044/ws", fn 4044 -> :owned end)

      assert {:reply, {:text, frame}, ^state} =
               Socket.handle_info({:execution_node_send_connect, "connect"}, state)

      assert Jason.decode!(frame)["params"]["auth"]["token"] == "private-node-token"
    end
  end

  test "checks the listener again on every handshake" do
    parent = self()

    check = fn _ ->
      send(parent, :checked)
      :owned
    end

    state = state("ws://127.0.0.1:4044/ws", check)

    for _ <- 1..2 do
      assert {:reply, _, _} = Socket.handle_info({:execution_node_send_connect, "connect"}, state)
      assert_receive :checked
    end
  end

  test "routable and DNS hosts do not invoke the literal-loopback guard" do
    for url <- [
          "wss://controller.example/ws",
          "ws://localhost:4044/ws",
          "ws://192.168.1.2:4044/ws"
        ] do
      state = state(url, fn _ -> flunk("not a literal loopback host") end)
      assert {:reply, _, _} = Socket.handle_info({:execution_node_send_connect, "connect"}, state)
    end
  end

  test "explicit opt-out preserves trusted cross-uid loopback controllers" do
    Application.put_env(:lemon_core, :require_owned_loopback, false)
    state = state("ws://127.0.0.1:4044/ws", fn _ -> flunk("guard is disabled") end)
    assert {:reply, _, _} = Socket.handle_info({:execution_node_send_connect, "connect"}, state)
  end

  test "a real WebSocket listener receives no connect frame when ownership is refused" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      Task.async(fn ->
        {:ok, client} = :gen_tcp.accept(listener, 2_000)
        request = receive_headers(client, "")
        [_, key] = Regex.run(~r/sec-websocket-key:\s*([^\r\n]+)/i, request)

        accept =
          :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

        :ok =
          :gen_tcp.send(
            client,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
          )

        observed = :gen_tcp.recv(client, 0, 1_000)
        :gen_tcp.close(client)
        observed
      end)

    {:ok, socket} =
      Socket.start_link(
        owner: self(),
        url: "ws://127.0.0.1:#{port}/ws",
        connect_params: %{"auth" => %{"token" => "private-node-token"}},
        listener_owner: fn ^port -> :foreign end,
        reconnect_delay_ms: 5_000,
        ping_interval_ms: 0
      )

    Process.unlink(socket)
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)

    assert_receive {:execution_node_socket, ^socket,
                    {:connect_retry, :loopback_listener_not_owned}},
                   2_000

    case Task.await(server, 3_000) do
      {:ok, <<first, _::binary>>} -> assert Bitwise.band(first, 0x0F) == 8
      {:error, reason} -> assert reason in [:closed, :timeout]
    end
  end

  defp state(url, check) do
    %Socket{
      owner: self(),
      url: url,
      connect_id: "connect",
      connect_params: %{"auth" => %{"token" => "private-node-token"}},
      listener_owner: check,
      reconnect_delay_ms: 0,
      ping_interval_ms: 0
    }
  end

  defp receive_headers(socket, accumulated) do
    if String.contains?(accumulated, "\r\n\r\n") do
      accumulated
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      receive_headers(socket, accumulated <> data)
    end
  end
end
