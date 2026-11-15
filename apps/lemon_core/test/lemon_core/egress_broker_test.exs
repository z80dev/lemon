defmodule LemonCore.EgressBrokerTest do
  use ExUnit.Case, async: false

  alias LemonCore.EgressBroker
  alias LemonCore.EgressBroker.Certificates

  @timeout 5_000
  @reference "egress-broker-test-key"

  setup_all do
    {:ok, started} = Application.ensure_all_started(:ssl)
    on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)
    ca = Certificates.create()
    %{ca: ca, leaf: Certificates.leaf(ca, "localhost")}
  end

  setup do
    %{secret: "fixture-token-" <> Base.encode16(:crypto.strong_rand_bytes(12))}
  end

  test "default deny and exact allowlist reject CONNECT before upstream access", context do
    upstream = upstream(context)
    broker = broker(context, upstream, allowlist: [], bindings: %{})
    assert connect_response(broker, "localhost", upstream.port) =~ "403"

    broker = broker(context, upstream)
    assert connect_response(broker, "localhost.example", upstream.port) =~ "403"
    assert connect_response(broker, "localhost", different_port(upstream.port)) =~ "403"
    assert connect_response(broker, "127.0.0.1", upstream.port) =~ "400"
    refute_received {:upstream_request, _, _}
    refute_received {:secret_resolved, _}
  end

  test "plaintext forward HTTP and ambiguous CONNECT authority are refused", context do
    upstream = upstream(context)
    broker = broker(context, upstream)

    for request <- [
          "GET https://localhost/ HTTP/1.1\r\nHost: localhost\r\n\r\n",
          "CONNECT localhost:#{upstream.port} HTTP/1.1\r\nHost: other.example\r\n\r\n",
          "CONNECT localhost:#{upstream.port} HTTP/1.1\r\nHost: localhost:#{upstream.port}\r\nHost: localhost:#{upstream.port}\r\n\r\n"
        ] do
      socket = unix_connect(broker)
      :ok = :gen_tcp.send(socket, request)
      assert receive_all(:gen_tcp, socket) =~ "400"
    end

    refute_received {:upstream_request, _, _}
    refute_received {:secret_resolved, _}
  end

  test "bound requests replace every client credential and redact headers and body", context do
    upstream = upstream(context)
    broker = broker(context, upstream)
    client = tls_connect(broker, upstream.port, broker.ca)

    :ok =
      :ssl.send(
        client,
        request(
          upstream.port,
          "Authorization: client-one\r\naUtHoRiZaTiOn: client-two\r\nAccept-Encoding: gzip\r\n"
        )
      )

    assert_receive {:secret_resolved, @reference}, @timeout
    assert_receive {:upstream_request, server, sent}, @timeout
    assert sent =~ "authorization: Bearer #{context.secret}\r\n"
    assert length(Regex.scan(~r/authorization:/i, sent)) == 1
    refute sent =~ "client-one"
    refute sent =~ "client-two"
    assert sent =~ "accept-encoding: identity\r\n"
    assert sent =~ "connection: close\r\n"

    body = "before #{context.secret} after #{context.secret}"

    send(
      server,
      {:respond,
       [
         "HTTP/1.1 200 #{context.secret}\r\nX-Echo: #{context.secret}\r\n",
         "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
         body
       ]}
    )

    response = receive_all(:ssl, client)
    refute response =~ context.secret
    assert response =~ "x-echo: [REDACTED]\r\n"
    assert_response_body(response, "before [REDACTED] after [REDACTED]")
    assert Map.keys(EgressBroker.info(broker.pid)) |> Enum.sort() == [:ca_path, :socket_path]
    refute inspect(:sys.get_status(broker.pid)) =~ context.secret
    refute inspect(:sys.get_status(broker.pid)) =~ "RSAPrivateKey"
    assert Enum.sort(File.ls!(broker.directory)) == ["adapter.py", "ca.pem", "proxy.sock"]
    refute File.read!(broker.info.ca_path) =~ "PRIVATE KEY"
  end

  test "chunk decoding catches secrets across chunks and TLS records", context do
    upstream = upstream(context)
    broker = broker(context, upstream)
    client = tls_connect(broker, upstream.port, broker.ca)

    :ok =
      :ssl.send(
        client,
        request(
          upstream.port,
          "Transfer-Encoding: chunked\r\n",
          "2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n"
        )
      )

    assert_receive {:upstream_request, server, sent}, @timeout
    assert sent =~ "content-length: 4\r\n"
    assert String.ends_with?(sent, "\r\n\r\nabcd")
    refute sent =~ "transfer-encoding"

    <<first::binary-size(7), rest::binary>> = context.secret
    <<second::binary-size(9), third::binary>> = rest
    chunks = Enum.map(["start ", first, second, third, " end"], &chunk/1)

    send(
      server,
      {:respond,
       [
         "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Echo: ",
         first,
         second,
         third,
         "\r\n\r\n",
         chunks,
         "0\r\n\r\n"
       ]}
    )

    response = receive_all(:ssl, client)
    refute response =~ context.secret
    refute response =~ "transfer-encoding"
    assert response =~ "x-echo: [REDACTED]"
    assert_response_body(response, "start [REDACTED] end")
  end

  test "close-delimited responses redact secrets across upstream writes", context do
    upstream = upstream(context)
    broker = broker(context, upstream)
    client = tls_connect(broker, upstream.port, broker.ca)
    :ok = :ssl.send(client, request(upstream.port))
    assert_receive {:upstream_request, server, _}, @timeout
    <<first::binary-size(10), rest::binary>> = context.secret
    send(server, {:respond, ["HTTP/1.1 200 OK\r\n\r\n", "left ", first, rest, " right"]})
    response = receive_all(:ssl, client)
    refute response =~ context.secret
    assert_response_body(response, "left [REDACTED] right")
  end

  test "generated status and framing cannot reproduce the secret", context do
    for secret <- ["200", "content-length", "[REDACTED]"] do
      context = %{context | secret: secret}
      upstream = upstream(context)
      broker = broker(context, upstream)
      client = tls_connect(broker, upstream.port, broker.ca)
      :ok = :ssl.send(client, request(upstream.port))
      assert_receive {:upstream_request, server, _}, @timeout

      send(
        server,
        {:respond, ["HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(secret)}\r\n\r\n", secret]}
      )

      assert receive_all(:ssl, client) == ""
    end
  end

  test "unbound TLS retains the upstream certificate and bytes without resolving secrets",
       context do
    upstream = upstream(context)
    broker = broker(context, upstream, bindings: %{})
    client = tls_connect(broker, upstream.port, context.ca.cert)
    assert {:ok, certificate} = :ssl.peercert(client)
    assert certificate == context.leaf.cert
    :ok = :ssl.send(client, request(upstream.port, "Authorization: client-owned\r\n"))
    assert_receive {:upstream_request, server, sent}, @timeout
    assert sent =~ "Authorization: client-owned\r\n"
    refute_received {:secret_resolved, _}

    response =
      "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(context.secret)}\r\n\r\n#{context.secret}"

    send(server, {:respond, [response]})
    assert receive_all(:ssl, client) == response
  end

  test "bound TLS rejects another HTTP authority and absolute request targets", context do
    upstream = upstream(context)
    broker = broker(context, upstream)

    for request <- [
          "GET / HTTP/1.1\r\nHost: other.example:#{upstream.port}\r\n\r\n",
          "GET / HTTP/1.1\r\nHost: localhost:#{different_port(upstream.port)}\r\n\r\n",
          "GET https://localhost:#{upstream.port}/ HTTP/1.1\r\nHost: localhost:#{upstream.port}\r\n\r\n",
          request(upstream.port, "Host: localhost:#{upstream.port}\r\n")
        ] do
      client = tls_connect(broker, upstream.port, broker.ca)
      :ok = :ssl.send(client, request)
      assert receive_all(:ssl, client) == ""
    end

    refute_received {:secret_resolved, _}
    refute_received {:upstream_request, _, _}
  end

  test "request bounds and secret-resolution failures close before upstream access", context do
    upstream = upstream(context)

    for {opts, request} <- [
          {[body_bytes: 4], request(upstream.port, "Content-Length: 5\r\n", "12345")},
          {[header_bytes: 512],
           request(upstream.port, "X-Large: #{String.duplicate("a", 512)}\r\n")},
          {[secrets_opts: [prefer_env: true, env_getter: fn _ -> raise context.secret end]],
           request(upstream.port)}
        ] do
      broker = broker(context, upstream, opts)
      client = tls_connect(broker, upstream.port, broker.ca)
      :ok = :ssl.send(client, request)
      assert receive_all(:ssl, client) == ""
    end

    refute_received {:secret_resolved, _}
    refute_received {:upstream_request, _, _}
  end

  test "binary response bodies are redacted without text decoding", context do
    upstream = upstream(context)
    broker = broker(context, upstream)
    client = tls_connect(broker, upstream.port, broker.ca)
    :ok = :ssl.send(client, request(upstream.port))
    assert_receive {:upstream_request, server, _}, @timeout
    body = <<0, 255>> <> context.secret <> <<128, 0>>

    send(
      server,
      {:respond, ["HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n", body]}
    )

    assert_response_body(receive_all(:ssl, client), <<0, 255>> <> "[REDACTED]" <> <<128, 0>>)
  end

  test "ambiguous requests and protocol upgrades never reach the upstream", context do
    upstream = upstream(context)
    broker = broker(context, upstream)

    for headers <- [
          "Content-Length: 0\r\nContent-Length: 0\r\n",
          "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n",
          "Transfer-Encoding: gzip, chunked\r\n",
          "Content-Encoding: gzip\r\n",
          "Connection: upgrade\r\nUpgrade: websocket\r\n",
          "Connection: authorization\r\n",
          "Expect: 100-continue\r\n"
        ] do
      client = tls_connect(broker, upstream.port, broker.ca)
      :ok = :ssl.send(client, request(upstream.port, headers))
      assert receive_all(:ssl, client) == ""
    end

    refute_received {:secret_resolved, _}
    refute_received {:upstream_request, _, _}
  end

  test "unsupported response framing and compression fail closed without reflecting credentials",
       context do
    for header <- [
          "Content-Encoding: gzip\r\n",
          "Content-Length: 1\r\nContent-Length: 1\r\n",
          "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n",
          "Transfer-Encoding: gzip, chunked\r\n",
          "Upgrade: websocket\r\n",
          "Connection: x-echo\r\n",
          "Trailer: x-echo\r\n"
        ] do
      upstream = upstream(context)
      broker = broker(context, upstream)
      client = tls_connect(broker, upstream.port, broker.ca)
      :ok = :ssl.send(client, request(upstream.port))
      assert_receive {:upstream_request, server, _}, @timeout

      send(
        server,
        {:respond,
         ["HTTP/1.1 200 OK\r\n#{header}X-Echo: #{context.secret}\r\n\r\n#{context.secret}"]}
      )

      response = receive_all(:ssl, client)
      assert response =~ "502"
      refute response =~ context.secret
    end
  end

  test "chunk extensions, trailers, truncation, and informational responses are not forwarded",
       context do
    for response <- [
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;foo=bar\r\nx\r\n0\r\n\r\n",
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Echo: #{context.secret}\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\n#{context.secret}",
          "HTTP/1.1 100 Continue\r\nX-Echo: #{context.secret}\r\n\r\n",
          "HTTP/1.1 101 Switching Protocols\r\n\r\n#{context.secret}"
        ] do
      upstream = upstream(context)
      broker = broker(context, upstream)
      client = tls_connect(broker, upstream.port, broker.ca)
      :ok = :ssl.send(client, request(upstream.port))
      assert_receive {:upstream_request, server, _}, @timeout
      send(server, {:respond, [response]})
      received = receive_all(:ssl, client)
      assert received =~ "502"
      refute received =~ context.secret
    end
  end

  test "upstream certificates must chain to the configured CA", context do
    upstream = upstream(context)
    other_ca = Certificates.create()
    broker = broker(context, upstream, upstream_tls: [cacerts: [other_ca.cert]])
    client = tls_connect(broker, upstream.port, broker.ca)
    :ok = :ssl.send(client, request(upstream.port))
    response = receive_all(:ssl, client)
    assert response =~ "502"
    refute response =~ context.secret
    refute_received {:upstream_request, _, _}
  end

  test "upstream hostname verification is not replaced by CA trust", context do
    upstream = upstream(%{context | leaf: Certificates.leaf(context.ca, "other.example")})
    broker = broker(context, upstream)
    client = tls_connect(broker, upstream.port, broker.ca)
    :ok = :ssl.send(client, request(upstream.port))
    assert receive_all(:ssl, client) =~ "502"
    refute_received {:upstream_request, _, _}
  end

  test "configured body and header bounds reject responses before releasing any upstream bytes",
       context do
    for {opts, response} <- [
          {[body_bytes: 8], "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n123456789"},
          {[body_bytes: 8], "HTTP/1.1 200 OK\r\n\r\n123456789"},
          {[header_bytes: 512],
           "HTTP/1.1 200 OK\r\nX-Large: #{String.duplicate("a", 512)}\r\n\r\n"}
        ] do
      upstream = upstream(context)
      broker = broker(context, upstream, opts)
      client = tls_connect(broker, upstream.port, broker.ca)
      :ok = :ssl.send(client, request(upstream.port))
      assert_receive {:upstream_request, server, _}, @timeout
      send(server, {:respond, [response]})

      assert receive_all(:ssl, client) ==
               "HTTP/1.1 502 \r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    end
  end

  test "owner termination synchronously closes active connections and removes public resources",
       context do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    upstream = upstream(context)
    broker = broker(context, upstream, owner: owner)
    client = tls_connect(broker, upstream.port, broker.ca)
    :ok = :ssl.send(client, request(upstream.port))
    assert_receive {:upstream_request, _, _}, @timeout
    monitor = Process.monitor(broker.pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, @timeout
    assert receive_all(:ssl, client) == ""
    refute File.exists?(broker.directory)
  end

  test "forced broker death kills its workers and the reaper removes its directory", context do
    upstream = upstream(context)
    broker = broker(context, upstream)
    client = tls_connect(broker, upstream.port, broker.ca)
    :ok = :ssl.send(client, request(upstream.port))
    assert_receive {:upstream_request, _, _}, @timeout
    state = :sys.get_state(broker.pid)

    monitors =
      Enum.map([state.acceptor, state.reaper | Map.keys(state.workers)], &Process.monitor/1)

    Process.exit(broker.pid, :kill)
    for ref <- monitors, do: assert_receive({:DOWN, ^ref, :process, _, _}, @timeout)
    assert receive_all(:ssl, client) == ""
    refute File.exists?(broker.directory)
  end

  test "connection admission is bounded and idle connections have a deadline", context do
    upstream = upstream(context)
    broker = broker(context, upstream, bindings: %{}, max_connections: 1)
    first = unix_connect(broker)
    :ok = :gen_tcp.send(first, connect_request("localhost", upstream.port))

    assert {:ok, "HTTP/1.1 200 Connection Established\r\n\r\n"} =
             :gen_tcp.recv(first, 0, @timeout)

    second = unix_connect(broker)
    assert {:error, :closed} = :gen_tcp.recv(second, 0, @timeout)

    bounded = broker(context, upstream, timeout: 100)
    idle = unix_connect(bounded)
    assert {:error, :closed} = :gen_tcp.recv(idle, 0, @timeout)
  end

  defp broker(context, upstream, overrides \\ []) do
    # Keep the AF_UNIX pathname below macOS's 104-byte sockaddr_un limit.
    directory =
      "/tmp/lemon-egress-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    File.mkdir!(directory)
    File.write!(Path.join(directory, "adapter.py"), "# public adapter fixture\n")
    test = self()
    secret = context.secret

    opts =
      Keyword.merge(
        [
          directory: directory,
          allowlist: [{"localhost", upstream.port}],
          bindings: %{
            "localhost" => %{secret: @reference, header: "authorization", prefix: "Bearer "}
          },
          secrets_opts: [
            prefer_env: true,
            env_getter: fn reference ->
              send(test, {:secret_resolved, reference})
              secret
            end
          ],
          upstream_tls: [cacerts: [context.ca.cert]],
          timeout: @timeout
        ],
        overrides
      )

    {:ok, pid} = EgressBroker.start_link(opts)
    Process.unlink(pid)
    info = EgressBroker.info(pid)

    [{:Certificate, ca, :not_encrypted}] =
      info.ca_path |> File.read!() |> :public_key.pem_decode()

    reaper = :sys.get_state(pid).reaper

    on_exit(fn ->
      reaper_ref = Process.monitor(reaper)
      if Process.alive?(pid), do: GenServer.stop(pid)
      assert_receive {:DOWN, ^reaper_ref, :process, ^reaper, _}, @timeout
      File.rm_rf(directory)
    end)

    %{pid: pid, info: info, directory: directory, ca: ca}
  end

  defp upstream(context) do
    {:ok, listener} =
      :ssl.listen(0,
        ip: {127, 0, 0, 1},
        cert: context.leaf.cert,
        key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, context.leaf.key)},
        active: false,
        mode: :binary,
        reuseaddr: true,
        log_level: :none
      )

    {:ok, {_, port}} = :ssl.sockname(listener)
    parent = self()

    pid =
      spawn(fn ->
        case :ssl.transport_accept(listener, @timeout) do
          {:ok, transport} ->
            case :ssl.handshake(transport, @timeout) do
              {:ok, socket} ->
                case read_request(socket, "") do
                  {:ok, request} ->
                    send(parent, {:upstream_request, self(), request})

                    receive do
                      {:respond, parts} -> Enum.each(parts, &:ssl.send(socket, &1))
                    after
                      @timeout -> :ok
                    end

                  _ ->
                    :ok
                end

                :ssl.close(socket)

              {:error, _reason} ->
                send(parent, {:upstream_tls_error, self()})
            end

          _ ->
            :ok
        end
      end)

    on_exit(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      :ssl.close(listener)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, @timeout
    end)

    %{pid: pid, port: port}
  end

  defp read_request(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {head_size, 4} ->
        head = binary_part(buffer, 0, head_size)

        length =
          case Regex.run(~r/\r\ncontent-length: ([0-9]+)/i, head) do
            [_, value] -> String.to_integer(value)
            nil -> 0
          end

        if byte_size(buffer) >= head_size + 4 + length,
          do: {:ok, buffer},
          else: receive_request(socket, buffer)

      :nomatch ->
        receive_request(socket, buffer)
    end
  end

  defp receive_request(socket, buffer) do
    case :ssl.recv(socket, 0, @timeout) do
      {:ok, data} -> read_request(socket, buffer <> data)
      error -> error
    end
  end

  defp unix_connect(broker) do
    {:ok, socket} =
      :gen_tcp.connect(
        {:local, String.to_charlist(broker.info.socket_path)},
        0,
        [:binary, active: false, packet: :raw],
        @timeout
      )

    socket
  end

  defp connect_request(host, port),
    do: "CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n\r\n"

  defp connect_response(broker, host, port) do
    socket = unix_connect(broker)
    :ok = :gen_tcp.send(socket, connect_request(host, port))
    receive_all(:gen_tcp, socket)
  end

  defp tls_connect(broker, port, ca) do
    socket = unix_connect(broker)
    :ok = :gen_tcp.send(socket, connect_request("localhost", port))

    assert {:ok, "HTTP/1.1 200 Connection Established\r\n\r\n"} =
             :gen_tcp.recv(socket, 0, @timeout)

    {:ok, tls} =
      :ssl.connect(
        socket,
        [
          verify: :verify_peer,
          cacerts: [ca],
          server_name_indication: ~c"localhost",
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          active: false,
          mode: :binary,
          log_level: :none
        ],
        @timeout
      )

    tls
  end

  defp request(port, headers \\ "", body \\ ""),
    do: "GET /fixture HTTP/1.1\r\nHost: localhost:#{port}\r\n#{headers}\r\n#{body}"

  defp receive_all(transport, socket, chunks \\ []) do
    case transport.recv(socket, 0, @timeout) do
      {:ok, data} -> receive_all(transport, socket, [data | chunks])
      {:error, :closed} -> IO.iodata_to_binary(Enum.reverse(chunks))
      error -> flunk("unexpected local transport result: #{inspect(error)}")
    end
  end

  defp chunk(data), do: [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"]
  defp different_port(65_535), do: 65_534
  defp different_port(port), do: port + 1

  defp assert_response_body(response, expected) do
    [head, body] = :binary.split(response, "\r\n\r\n")
    assert body == expected
    assert head =~ "content-length: #{byte_size(body)}\r\n"
  end
end
