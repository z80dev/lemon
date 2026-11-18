defmodule CodingAgent.ExecutionNode.SocketTLSTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.Socket.Transport

  # Real wss:// controllers backed by certificates generated at runtime. When
  # the node accepts a certificate the listener completes the WebSocket upgrade
  # and forwards the node's first frame (the connect request carrying the
  # session token) to the test process.

  @rsa {:rsa, 2048, 65_537}

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "refuses a self-signed wss controller without sending the connect frame" do
    %{cert: cert, key: key} =
      :public_key.pkix_test_root_cert(~c"localhost", key: @rsa, digest: :sha256)

    server_opts = [cert: cert, key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key)}]
    port = listen({127, 0, 0, 1}, server_opts)

    transport = start_transport("wss://localhost:#{port}/ws")
    assert_refused(transport, :bad_certificate)
  end

  test "a bad certificate is refused even with the plaintext override set" do
    %{cert: cert, key: key} =
      :public_key.pkix_test_root_cert(~c"localhost", key: @rsa, digest: :sha256)

    server_opts = [cert: cert, key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key)}]
    port = listen({127, 0, 0, 1}, server_opts)

    transport = start_transport("wss://localhost:#{port}/ws", allow_insecure_ws: true)
    assert_refused(transport, :bad_certificate)
  end

  test "a trusted controller certificate for the dialled DNS name or IPv4 address connects" do
    %{server: server_opts, cacerts: cacerts} =
      chain(dNSName: ~c"localhost", iPAddress: <<127, 0, 0, 1>>)

    for host <- ["localhost", "127.0.0.1"] do
      port = listen({127, 0, 0, 1}, server_opts)
      transport = start_transport("wss://#{host}:#{port}/ws", extra_cacerts: cacerts)
      assert_receive {:server, {:frame, <<129, _::binary>>}}, 5_000
      Process.exit(transport, :kill)
    end
  end

  test "a trusted controller certificate for the IPv6 loopback address connects" do
    %{server: server_opts, cacerts: cacerts} = chain(iPAddress: <<0::112, 1::16>>)
    port = listen({0, 0, 0, 0, 0, 0, 0, 1}, server_opts)

    transport = start_transport("wss://[::1]:#{port}/ws", extra_cacerts: cacerts)

    assert_receive {:server, {:frame, <<129, _::binary>>}}, 5_000
    Process.exit(transport, :kill)
  end

  test "a trusted chain issued for another host is refused" do
    %{server: server_opts, cacerts: cacerts} = chain(dNSName: ~c"controller.example")

    for host <- ["localhost", "127.0.0.1"] do
      port = listen({127, 0, 0, 1}, server_opts)
      transport = start_transport("wss://#{host}:#{port}/ws", extra_cacerts: cacerts)
      assert_refused(transport, nil)
    end
  end

  test "refuses plaintext non-loopback controllers unless the insecure flag is set" do
    opts = [
      owner: self(),
      url: "ws://192.0.2.1:9/ws",
      connect_params: %{},
      reconnect_delay_ms: 60_000
    ]

    assert Transport.start_link(opts) == {:error, :insecure_web_socket_url}

    for url <- ["ws://controller.localhost:9/ws", "ws://127.0.0.1.evil:9/ws"] do
      assert Transport.start_link(Keyword.put(opts, :url, url)) ==
               {:error, :insecure_web_socket_url}
    end

    assert {:ok, pid} = Transport.start_link(Keyword.put(opts, :allow_insecure_ws, true))
    Process.exit(pid, :kill)
  end

  defp start_transport(url, extra \\ []) do
    {:ok, transport} =
      Transport.start_link(
        [
          owner: self(),
          url: url,
          connect_params: %{"auth" => %{"token" => "private-node-token"}},
          reconnect_delay_ms: 60_000
        ] ++ extra
      )

    transport
  end

  defp assert_refused(transport, alert) do
    assert_receive {:server, {:handshake_failed, _reason}}, 5_000
    assert_receive {:EXIT, ^transport, {:error, %WebSockex.ConnError{original: original}}}, 5_000
    assert {:tls_alert, {kind, _}} = original
    if alert, do: assert(kind == alert)
    refute_receive {:server, {:frame, _}}, 300
    refute_received {:server, :handshake_ok}
    refute_received {:execution_node_socket, _, {:connected, _}}
  end

  defp chain(sans) do
    san = {:Extension, {2, 5, 29, 17}, false, sans}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: @rsa, digest: :sha256],
          peer: [key: @rsa, digest: :sha256, extensions: [san]]
        },
        client_chain: %{root: [key: @rsa], peer: [key: @rsa]}
      })

    server = Map.fetch!(data, :server_config)
    %{server: Keyword.take(server, [:cert, :key]), cacerts: Keyword.fetch!(server, :cacerts)}
  end

  defp listen(ip, server_opts) do
    {:ok, listen} =
      :ssl.listen(0, [ip: ip, mode: :binary, active: false, reuseaddr: true] ++ server_opts)

    {:ok, {_, port}} = :ssl.sockname(listen)
    parent = self()
    spawn_link(fn -> serve(listen, parent) end)
    port
  end

  defp serve(listen, parent) do
    {:ok, socket} = :ssl.transport_accept(listen)

    case :ssl.handshake(socket, 5_000) do
      {:ok, socket} ->
        send(parent, {:server, :handshake_ok})
        {:ok, request} = recv_headers(socket, "")
        [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)

        accept =
          :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
          |> Base.encode64()

        :ok =
          :ssl.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" <>
              "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
          )

        {:ok, frame} = :ssl.recv(socket, 0, 5_000)
        send(parent, {:server, {:frame, frame}})
        Process.sleep(:infinity)

      {:error, reason} ->
        send(parent, {:server, {:handshake_failed, reason}})
        serve(listen, parent)
    end
  end

  defp recv_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: recv_headers(socket, acc <> data)
    end
  end
end
