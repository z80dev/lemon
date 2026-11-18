defmodule LemonCli.WebSocketTLSTest do
  use ExUnit.Case, async: false

  alias LemonCli.{AcpCommand, ControlPlaneClient}

  @remote "ws://192.0.2.1:9/ws"

  test "ControlPlaneClient refuses remote plaintext before connecting" do
    assert ControlPlaneClient.open(url: @remote, token: "secret") ==
             {:error, :insecure_web_socket_url}

    assert ControlPlaneClient.request("health", %{}, url: @remote, token: "secret") ==
             {:error, {:control_plane_unavailable, :insecure_web_socket_url}}

    assert ControlPlaneClient.request("health", %{},
             url: "ws://controller.localhost:9/ws",
             token: "secret"
           ) == {:error, {:control_plane_unavailable, :insecure_web_socket_url}}
  end

  test "AcpCommand refuses remote plaintext before connecting" do
    assert AcpCommand.connect("ws://192.0.2.1:9/acp/ws", [{"authorization", "Bearer secret"}]) ==
             {:error, :insecure_web_socket_url}
  end

  test "ControlPlaneClient.request still reaches a pinned localhost listener" do
    port = listen()

    task =
      Task.async(fn ->
        ControlPlaneClient.request("health", %{},
          url: "ws://localhost:#{port}/ws",
          token: "secret",
          timeout_ms: 2_000
        )
      end)

    assert_receive {:upgrade, request}, 5_000
    assert request =~ ~r/^host: 127\.0\.0\.1:#{port}\r$/im
    assert_receive {:frame, <<129, _::binary>>}, 5_000
    Task.shutdown(task, :brutal_kill)
  end

  test "ControlPlaneClient.open reaches a loopback listener" do
    port = listen()

    task =
      Task.async(fn -> ControlPlaneClient.open(url: "ws://127.0.0.1:#{port}/ws", token: "t") end)

    assert_receive {:upgrade, _request}, 5_000
    assert_receive {:frame, <<129, _::binary>>}, 5_000
    Task.shutdown(task, :brutal_kill)
  end

  test "AcpCommand.connect reaches a loopback listener with its headers" do
    port = listen()

    assert {:ok, socket} =
             AcpCommand.connect("ws://localhost:#{port}/acp/ws", [
               {"authorization", "Bearer secret"}
             ])

    assert_receive {:upgrade, request}, 5_000
    assert request =~ ~r/^authorization: Bearer secret\r$/im
    assert request =~ ~r/^host: 127\.0\.0\.1:#{port}\r$/im
    Process.exit(socket, :kill)
  end

  defp listen do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, request} = recv_headers(socket, "")
      send(parent, {:upgrade, request})
      [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)
      accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" <>
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
        )

      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, frame} -> send(parent, {:frame, frame})
        _ -> :ok
      end

      Process.sleep(:infinity)
    end)

    port
  end

  defp recv_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000), do: recv_headers(socket, acc <> data)
    end
  end
end
