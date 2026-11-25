defmodule LemonMCP.SSEOriginTest do
  @moduledoc false
  # Real loopback listeners for the legacy HTTP+SSE transport: the server's
  # `endpoint` event and redirects must never move credentialed traffic to
  # another origin, and the stream must stay incremental.
  use ExUnit.Case, async: true

  alias LemonMCP.Client.SSE

  @auth {"authorization", "Bearer sse-secret"}

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "endpoint event naming another origin is refused and that origin receives nothing" do
    other = listen(:other, fn socket, _request -> reply(socket, 202, "") end)
    other_origin = origin(other)

    stream =
      listen(:stream, fn socket, _request ->
        sse_head(socket)
        sse_event(socket, "endpoint", other_origin <> "/messages")
        hold(socket)
      end)

    # Both origins are allowed and approved: refusal must come from the
    # same-origin rule, not from the allowlist.
    policy = %{
      allowed_origins: [origin(stream), other_origin],
      approved_private_origins: [origin(stream), other_origin]
    }

    assert {:error, :sse_endpoint_origin_mismatch} = start(stream, origin_policy: policy)
    assert_received {:stream, %{method: "GET"}}
    refute_receive {:other, _}, 300
  end

  test "endpoint event naming a metadata or private absolute URL is refused" do
    for endpoint <- [
          "http://169.254.169.254/latest/meta-data",
          "http://10.0.0.1/messages",
          "http://localhost:1/messages"
        ] do
      stream =
        listen(:stream, fn socket, _request ->
          sse_head(socket)
          sse_event(socket, "endpoint", endpoint)
          hold(socket)
        end)

      assert {:error, :sse_endpoint_origin_mismatch} =
               start(stream, origin_policy: approved(stream))
    end

    # Without a policy the configured local server stays usable, but the
    # endpoint is still bound to its origin.
    stream =
      listen(:stream, fn socket, _request ->
        sse_head(socket)
        sse_event(socket, "endpoint", "http://169.254.169.254/latest/meta-data")
        hold(socket)
      end)

    assert {:error, :sse_endpoint_origin_mismatch} = start(stream, [])
  end

  test "a POST redirect is not followed and credentials never reach the target" do
    other = listen(:other, fn socket, _request -> reply(socket, 200, "") end)
    location = origin(other) <> "/steal"

    stream =
      listen(:stream, fn socket, request ->
        case request.method do
          "GET" ->
            sse_head(socket)
            sse_event(socket, "endpoint", "/messages")
            hold(socket)

          "POST" ->
            reply(socket, 307, "", [{"location", location}])
        end
      end)

    assert {:error, {:http_error, 307, _body}} =
             start(stream, origin_policy: approved(stream))

    assert_received {:stream, %{method: "POST", headers: headers}}
    assert headers["authorization"] == "Bearer sse-secret"
    refute_receive {:other, _}, 300
  end

  test "a stream redirect is not followed" do
    other =
      listen(:other, fn socket, _request ->
        sse_head(socket)
        sse_event(socket, "endpoint", "/messages")
        hold(socket)
      end)

    stream =
      listen(:stream, fn socket, _request ->
        reply(socket, 302, "", [{"location", origin(other) <> "/sse"}])
      end)

    policy = %{
      allowed_origins: [origin(stream), origin(other)],
      approved_private_origins: [origin(stream), origin(other)]
    }

    assert {:error, {:sse_stream_failed, {:http_status, 302}}} =
             start(stream, origin_policy: policy)

    refute_receive {:other, _}, 300
  end

  test "events are delivered incrementally while the stream stays open" do
    test_pid = self()

    stream =
      listen(:stream, fn socket, request ->
        case request.method do
          "GET" ->
            sse_head(socket)
            sse_event(socket, "endpoint", "/messages")
            send(test_pid, {:stream_socket, self()})
            stream_loop(socket)

          "POST" ->
            message = Jason.decode!(request.body)
            send(test_pid, {:posted, message})
            reply(socket, 202, "")
        end
      end)

    handler = fn notification -> send(test_pid, {:notified, notification}) end

    task =
      Task.async(fn ->
        SSE.start_link(
          url: origin(stream) <> "/sse",
          headers: [@auth],
          origin_policy: approved(stream),
          notification_handler: handler,
          timeout_ms: 5_000
        )
      end)

    assert_receive {:stream_socket, writer}, 2_000
    assert_receive {:posted, %{"method" => "initialize", "id" => id}}, 2_000

    send(writer, {:event, "message", Jason.encode!(init_response(id))})
    assert_receive {:posted, %{"method" => "notifications/initialized"}}, 2_000
    assert {:ok, client} = Task.await(task)

    send(writer, {:event, "message", notification("first")})
    assert_receive {:notified, %{params: %{"n" => "first"}}}, 2_000
    refute_received {:notified, %{params: %{"n" => "second"}}}

    send(writer, {:event, "message", notification("second")})
    assert_receive {:notified, %{params: %{"n" => "second"}}}, 2_000

    assert :ready = SSE.state(client)
    SSE.close(client)
  end

  @over_cap 8 * 1024 * 1024 + 1024

  test "an oversized unterminated line closes the stream with a classified error" do
    stream =
      listen(:stream, fn socket, _request ->
        sse_head(socket)
        sse_raw(socket, "data: " <> :binary.copy("x", @over_cap))
        hold(socket)
      end)

    assert {:error, {:sse_stream_failed, :sse_line_too_long}} =
             start(stream, origin_policy: approved(stream), timeout_ms: 10_000)
  end

  test "an oversized event built from many data lines closes the stream" do
    stream =
      listen(:stream, fn socket, _request ->
        sse_head(socket)
        line = "data: " <> :binary.copy("y", 1_000) <> "\n"
        for _ <- 1..div(@over_cap, 1_000), do: sse_raw(socket, line)
        hold(socket)
      end)

    assert {:error, {:sse_stream_failed, :sse_event_too_large}} =
             start(stream, origin_policy: approved(stream), timeout_ms: 10_000)
  end

  test "a flooding server cannot grow the client's mailbox while it is slow" do
    test_pid = self()

    stream =
      listen(:stream, fn socket, request ->
        case request.method do
          "GET" ->
            sse_head(socket)
            sse_event(socket, "endpoint", "/messages")
            send(test_pid, {:stream_socket, self()})
            stream_loop(socket)

          "POST" ->
            send(test_pid, {:posted, Jason.decode!(request.body)})
            reply(socket, 202, "")
        end
      end)

    handler = fn %{params: %{"n" => n}} -> if n == "last", do: send(test_pid, :last_seen) end

    task =
      Task.async(fn ->
        SSE.start_link(
          url: origin(stream) <> "/sse",
          origin_policy: approved(stream),
          notification_handler: handler,
          timeout_ms: 5_000
        )
      end)

    assert_receive {:stream_socket, writer}, 2_000
    assert_receive {:posted, %{"method" => "initialize", "id" => id}}, 2_000
    send(writer, {:event, "message", Jason.encode!(init_response(id))})
    assert {:ok, client} = Task.await(task)

    reader = :sys.get_state(client).stream_reader
    :ok = :sys.suspend(client)
    send(writer, {:flood, 20_000, notification("flood")})
    send(writer, {:event, "message", notification("last")})

    for _ <- 1..10 do
      Process.sleep(50)
      assert {:message_queue_len, client_len} = Process.info(client, :message_queue_len)
      assert client_len <= 2
      assert {:message_queue_len, reader_len} = Process.info(reader, :message_queue_len)
      assert reader_len <= 2
    end

    :ok = :sys.resume(client)
    assert_receive :last_seen, 20_000
    assert :ready = SSE.state(client)
    SSE.close(client)
  end

  defp start(stream, opts) do
    SSE.start_link([url: origin(stream) <> "/sse", headers: [@auth], timeout_ms: 2_000] ++ opts)
  end

  defp approved(port),
    do: %{allowed_origins: [origin(port)], approved_private_origins: [origin(port)]}

  defp origin(port), do: "http://127.0.0.1:#{port}"

  defp sse_raw(socket, payload) do
    size = Integer.to_string(byte_size(payload), 16)
    :gen_tcp.send(socket, [size, "\r\n", payload, "\r\n"])
  end

  defp init_response(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "sse-origin", "version" => "1"}
      }
    }
  end

  defp notification(n),
    do:
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"n" => n}
      })

  # --- raw HTTP/1.1 loopback listener -------------------------------------

  defp listen(tag, handler) do
    test_pid = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    acceptor =
      spawn_link(fn -> accept_loop(listener, tag, handler, test_pid) end)

    :ok = :gen_tcp.controlling_process(listener, acceptor)
    port
  end

  defp accept_loop(listener, tag, handler, test_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        pid =
          spawn(fn ->
            receive do
              :go -> serve(socket, tag, handler, test_pid)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept_loop(listener, tag, handler, test_pid)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, tag, handler, test_pid) do
    case read_request(socket, "") do
      {:ok, request} ->
        send(test_pid, {tag, request})
        handler.(socket, request)
        serve(socket, tag, handler, test_pid)

      :error ->
        :ok
    end
  end

  defp read_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, path | _] = String.split(request_line, " ")

        headers =
          Map.new(header_lines, fn line ->
            [key, value] = String.split(line, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        length = String.to_integer(Map.get(headers, "content-length", "0"))
        body = read_body(socket, rest, length)
        {:ok, %{method: method, path: path, headers: headers, body: body}}

      [_] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_request(socket, buffer <> data)
          {:error, _} -> :error
        end
    end
  end

  defp read_body(_socket, buffer, length) when byte_size(buffer) >= length,
    do: binary_part(buffer, 0, length)

  defp read_body(socket, buffer, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, buffer <> data, length)
  end

  defp reply(socket, status, body, headers \\ []) do
    head =
      Enum.map_join(
        [{"content-length", Integer.to_string(byte_size(body))} | headers],
        fn {k, v} -> "#{k}: #{v}\r\n" end
      )

    :gen_tcp.send(socket, "HTTP/1.1 #{status} X\r\n#{head}\r\n#{body}")
  end

  defp sse_head(socket) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
    )
  end

  defp sse_event(socket, event, data) do
    payload = "event: #{event}\ndata: #{data}\n\n"
    size = Integer.to_string(byte_size(payload), 16)
    :gen_tcp.send(socket, "#{size}\r\n#{payload}\r\n")
  end

  defp stream_loop(socket) do
    receive do
      {:event, event, data} ->
        sse_event(socket, event, data)
        stream_loop(socket)

      {:flood, count, data} ->
        for _ <- 1..count, do: sse_event(socket, "message", data)
        stream_loop(socket)
    after
      10_000 -> :ok
    end
  end

  defp hold(_socket) do
    receive do
    after
      5_000 -> :ok
    end
  end
end
