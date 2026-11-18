defmodule LemonCore.Net.HTTPTest do
  use ExUnit.Case, async: false

  alias LemonCore.Net.HTTP

  # Serves one canned response per connection, chosen by request path, and
  # reports every request line to the test process.
  defp start_server(routes) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = self()
    pid = spawn_link(fn -> accept_loop(listen, test, port, routes) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp accept_loop(listen, test, port, routes) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, head} = read_head(socket, "")
    [line | _] = String.split(head, "\r\n")
    [_method, path, _] = String.split(line, " ")
    send(test, {:hit, port, line, head})
    :ok = :gen_tcp.send(socket, Map.fetch!(routes, path).(port))
    :gen_tcp.close(socket)
    accept_loop(listen, test, port, routes)
  end

  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 5_000), do: read_head(socket, buffer <> chunk)
    end
  end

  defp ok(body),
    do: fn _ -> "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}" end

  defp redirect(location),
    do: fn _ -> "HTTP/1.1 302 Found\r\nlocation: #{location}\r\ncontent-length: 0\r\n\r\n" end

  test "a 3xx is returned unchanged by default and never followed" do
    target = start_server(%{"/t" => ok("secret")})
    port = start_server(%{"/r" => redirect("http://127.0.0.1:#{target}/t")})

    assert {:ok, %{status: 302, redirects: 0}} =
             HTTP.request(:post, "http://127.0.0.1:#{port}/r", body: "{}", allow_private: true)

    assert_receive {:hit, ^port, "POST /r HTTP/1.1", _}
    refute_receive {:hit, ^target, _, _}, 200
  end

  test "followed redirects are re-authorized: a public origin cannot redirect to a private one" do
    send_fun = fn
      %{address: {93, 184, 216, 34}, path: "/a"} ->
        {:ok, %{status: 302, headers: [{"location", "http://10.0.0.5/admin"}], body: ""}}

      request ->
        flunk("redirect reached #{inspect(request.address)}")
    end

    assert {:error, :destination_not_public} =
             HTTP.request(:get, "https://public.example/a",
               max_redirects: 3,
               resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               send: send_fun
             )

    for location <- [
          "http://169.254.169.254/",
          "http://2852039166/",
          "http://0xA9FEA9FE/",
          "http://[::ffff:169.254.169.254]/",
          "http://[2002:a9fe:a9fe::]/"
        ] do
      send_fun = fn %{address: {93, 184, 216, 34}} ->
        {:ok, %{status: 307, headers: [{"location", location}], body: ""}}
      end

      assert {:error, :metadata_blocked} =
               HTTP.request(:get, "https://public.example/a",
                 max_redirects: 3,
                 allow_private: true,
                 resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
                 send: send_fun
               ),
             location
    end
  end

  test "real redirects are followed over fresh pinned connections with Host preserved" do
    port = start_server(%{"/a" => redirect("/b"), "/b" => ok("done")})

    assert {:ok, %{status: 200, body: "done", redirects: 1, url: url}} =
             HTTP.request(:get, "http://svc.test:#{port}/a",
               max_redirects: 2,
               allow_private: true,
               resolver: fn "svc.test" -> {:ok, [{127, 0, 0, 1}]} end
             )

    assert url == "http://svc.test:#{port}/b"
    assert_receive {:hit, ^port, "GET /a HTTP/1.1", head}
    assert head =~ ~r/\r\nhost: svc\.test:#{port}\r\n/i
    assert_receive {:hit, ^port, "GET /b HTTP/1.1", _}
  end

  test "credentials are dropped across origins and 303 becomes a bodiless GET" do
    parent = self()

    send_fun = fn request ->
      send(parent, {:request, request})

      case request.host do
        "a.example" ->
          {:ok, %{status: 303, headers: [{"location", "https://b.example/x"}], body: ""}}

        "b.example" ->
          {:ok, %{status: 200, headers: [], body: "ok"}}
      end
    end

    assert {:ok, %{status: 200}} =
             HTTP.request(:post, "https://a.example/",
               body: "payload",
               headers: [{"Authorization", "Bearer x"}],
               max_redirects: 1,
               resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               send: send_fun
             )

    assert_receive {:request, %{host: "a.example", method: "POST", headers: first}}
    assert {"authorization", "Bearer x"} in first
    assert_receive {:request, %{host: "b.example", method: "GET", body: nil, headers: second}}
    refute Enum.any?(second, fn {k, _} -> k == "authorization" end)
  end

  test "redirect limit and loops are errors" do
    send_fun = fn %{path: path} ->
      next = if path == "/a", do: "/b", else: "/a"
      {:ok, %{status: 302, headers: [{"location", next}], body: ""}}
    end

    opts = [resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end, send: send_fun]

    assert {:error, :redirect_loop} =
             HTTP.request(:get, "https://x.example/a", [max_redirects: 5] ++ opts)

    assert {:error, :too_many_redirects} =
             HTTP.request(:get, "https://x.example/a", [max_redirects: 1] ++ opts)
  end

  test "response bodies are bounded" do
    port = start_server(%{"/big" => ok(String.duplicate("x", 100))})

    assert {:error, {:body_too_large, 10}} =
             HTTP.request(:get, "http://127.0.0.1:#{port}/big",
               allow_private: true,
               max_body_bytes: 10
             )
  end

  test "DNS failure never reaches the transport" do
    assert {:error, :dns_resolution_failed} =
             HTTP.request(:get, "https://down.example/",
               resolver: fn _ -> {:error, :timeout} end,
               send: fn _ -> flunk("sent") end
             )
  end

  test "requests to N distinct hosts create no atoms" do
    port = start_server(%{"/" => ok("ok")})

    fetch = fn host ->
      HTTP.request(:get, "http://#{host}:#{port}/",
        allow_private: true,
        resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
      )
    end

    assert {:ok, _} = fetch.("warm.example")
    atoms = :erlang.system_info(:atom_count)

    for n <- 1..50, do: assert({:ok, %{status: 200}} = fetch.("h#{n}.example"))

    assert :erlang.system_info(:atom_count) == atoms
  end

  # A listener that accepts and then runs `fun` on the raw socket.
  defp start_raw(fun) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        fun.(socket, test)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  test "repeated 103 responses are bounded and never leak into the final headers" do
    early = "HTTP/1.1 103 Early Hints\r\nlink: </a.css>; rel=preload\r\n\r\n"

    flood =
      start_raw(fn socket, _ ->
        {:ok, _} = read_head(socket, "")
        for _ <- 1..200, do: :gen_tcp.send(socket, early)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        Process.sleep(1_000)
      end)

    assert {:error, :too_many_informational_responses} =
             HTTP.request(:get, "http://127.0.0.1:#{flood}/", allow_private: true)

    one =
      start_raw(fn socket, _ ->
        {:ok, _} = read_head(socket, "")

        :gen_tcp.send(
          socket,
          early <> "HTTP/1.1 200 OK\r\nx-final: 1\r\ncontent-length: 2\r\n\r\nok"
        )

        Process.sleep(1_000)
      end)

    assert {:ok, %{status: 200, headers: headers, body: "ok"}} =
             HTTP.request(:get, "http://127.0.0.1:#{one}/", allow_private: true)

    assert {"x-final", "1"} in headers
    refute Enum.any?(headers, fn {k, _} -> k == "link" end)
  end

  test "cumulative informational header bytes are capped" do
    big = String.duplicate("a", 9_000)

    port =
      start_raw(fn socket, _ ->
        {:ok, _} = read_head(socket, "")
        for _ <- 1..8, do: :gen_tcp.send(socket, "HTTP/1.1 103 Early\r\nx-pad: #{big}\r\n\r\n")
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        Process.sleep(1_000)
      end)

    assert {:error, {:headers_too_large, _}} =
             HTTP.request(:get, "http://127.0.0.1:#{port}/", allow_private: true)
  end

  test "a peer that stops reading cannot stall a large send past the deadline" do
    port =
      start_raw(fn socket, test ->
        send(test, {:accepted, socket})
        Process.sleep(10_000)
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             HTTP.request(:post, "http://127.0.0.1:#{port}/",
               allow_private: true,
               body: :binary.copy("x", 64 * 1024 * 1024),
               timeout_ms: 500
             )

    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  test "DNS resolution counts against the deadline" do
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             HTTP.request(:get, "https://slow-dns.example/",
               timeout_ms: 200,
               resolver: fn _ ->
                 Process.sleep(5_000)
                 {:ok, [{93, 184, 216, 34}]}
               end
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "streams deliver data incrementally" do
    port =
      start_raw(fn socket, test ->
        {:ok, _} = read_head(socket, "")
        send(test, {:server, self()})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
        )

        :gen_tcp.send(socket, "5\r\none\n\n\r\n")
        receive do: (:next -> :ok)
        :gen_tcp.send(socket, "5\r\ntwo\n\n\r\n0\r\n\r\n")
        Process.sleep(1_000)
      end)

    assert {:ok, stream} =
             HTTP.open_stream(:get, "http://127.0.0.1:#{port}/sse", allow_private: true)

    assert stream.status == 200
    assert_receive {:server, server}

    # The first event arrives while the server is still holding the second.
    {stream, first} = drain_until(stream, "one\n\n", "")
    assert first =~ "one"
    refute first =~ "two"

    send(server, :next)
    {stream, rest} = drain_until(stream, "two\n\n", "")
    assert rest =~ "two"
    HTTP.close_stream(stream)
  end

  test "a stream answered with a redirect is returned as-is, not followed" do
    port =
      start_raw(fn socket, _ ->
        {:ok, _} = read_head(socket, "")

        :gen_tcp.send(
          socket,
          "HTTP/1.1 302 Found\r\nlocation: http://169.254.169.254/\r\ncontent-length: 0\r\n\r\n"
        )

        Process.sleep(1_000)
      end)

    assert {:ok, %{status: 302} = stream} =
             HTTP.open_stream(:get, "http://127.0.0.1:#{port}/sse", allow_private: true)

    HTTP.close_stream(stream)
  end

  test "open_stream waits for the complete header section across split writes" do
    port =
      start_raw(fn socket, _ ->
        {:ok, _} = read_head(socket, "")
        :ok = :inet.setopts(socket, nodelay: true)

        for piece <- [
              "HTTP/1.1 200 OK\r\n",
              "content-type: text/event-stream\r\n",
              "x-late: yes\r\n",
              "transfer-encoding: chunked\r\n",
              "\r\n",
              "5\r\nhi\n\n\n\r\n"
            ] do
          :gen_tcp.send(socket, piece)
          Process.sleep(100)
        end

        Process.sleep(1_000)
      end)

    assert {:ok, stream} =
             HTTP.open_stream(:get, "http://127.0.0.1:#{port}/sse", allow_private: true)

    assert stream.status == 200
    assert {"content-type", "text/event-stream"} in stream.headers
    assert {"x-late", "yes"} in stream.headers
    assert {"transfer-encoding", "chunked"} in stream.headers
    HTTP.close_stream(stream)
  end

  test "a stream ready at the deadline is closed by the worker, never leaked to the caller" do
    port =
      start_raw(fn socket, test ->
        {:ok, _} = read_head(socket, "")
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
        # Reports when the client side of the connection goes away.
        send(test, {:closed, :gen_tcp.recv(socket, 0, 5_000)})
      end)

    ports_before = MapSet.new(Port.list())

    # The head is complete, but the worker is held past the deadline before it
    # can report the stream: the caller must time out and the socket must close.
    assert {:error, :timeout} =
             HTTP.open_stream(:get, "http://127.0.0.1:#{port}/sse",
               allow_private: true,
               timeout_ms: 300,
               before_handoff: fn -> Process.sleep(600) end
             )

    assert_receive {:closed, {:error, :closed}}, 2_000

    leaked =
      Port.list()
      |> Enum.reject(&MapSet.member?(ports_before, &1))
      |> Enum.filter(&(Port.info(&1, :connected) == {:connected, self()}))

    assert leaked == []
    refute_received {_, {:ok, %{conn: _}}}
  end

  test "a worker whose caller dies before the handoff closes the connection and exits" do
    test = self()

    port =
      start_raw(fn socket, test ->
        {:ok, _} = read_head(socket, "")
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
        send(test, {:closed, :gen_tcp.recv(socket, 0, 5_000)})
      end)

    caller =
      spawn(fn ->
        HTTP.open_stream(:get, "http://127.0.0.1:#{port}/sse",
          allow_private: true,
          timeout_ms: 30_000,
          before_handoff: fn ->
            send(test, {:worker, self()})
            receive do: (:release -> :ok)
          end
        )
      end)

    assert_receive {:worker, worker}, 2_000
    worker_monitor = Process.monitor(worker)

    Process.exit(caller, :kill)
    send(worker, :release)

    # Well inside the 30 s deadline: only the caller-death path can end it.
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 2_000
    assert_receive {:closed, {:error, :closed}}, 2_000
  end

  test "a stream handed over normally belongs to the caller" do
    port =
      start_raw(fn socket, _ ->
        {:ok, _} = read_head(socket, "")
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
        Process.sleep(2_000)
      end)

    assert {:ok, stream} =
             HTTP.open_stream(:get, "http://127.0.0.1:#{port}/sse", allow_private: true)

    assert Port.info(Mint.HTTP.get_socket(stream.conn), :connected) == {:connected, self()}
    HTTP.close_stream(stream)
  end

  defp drain_until(stream, marker, acc) do
    if String.contains?(acc, marker) do
      {stream, acc}
    else
      case HTTP.stream_next(stream, 2_000) do
        {:ok, stream, chunks} -> drain_until(stream, marker, acc <> Enum.join(chunks))
        {:done, stream, chunks} -> {stream, acc <> Enum.join(chunks)}
      end
    end
  end
end
