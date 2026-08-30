defmodule LemonCore.Context.URLFetcherTest do
  use ExUnit.Case, async: true

  alias LemonCore.Context.URLFetcher

  test "blocks localhost, private DNS answers, URL credentials, and private redirects" do
    request = fn _url, _headers, _http, _max -> flunk("unsafe request was attempted") end

    assert {:error, :ssrf_blocked} = URLFetcher.fetch("http://localhost/a", request_fun: request)

    assert {:error, :ssrf_blocked} =
             URLFetcher.fetch("https://example.test/a",
               resolve_fun: fn _ -> {:ok, [{127, 0, 0, 1}]} end,
               request_fun: request
             )

    assert {:error, :url_credentials_forbidden} =
             URLFetcher.fetch("https://user:pass@example.test/a",
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: request
             )

    redirect = fn _url, _headers, _http, _max ->
      {:ok, {{~c"HTTP/1.1", 302, ~c"Found"}, [{~c"location", ~c"http://127.0.0.1/secret"}], ""}}
    end

    assert {:error, :ssrf_blocked} =
             URLFetcher.fetch("https://example.test/a",
               resolve_fun: fn host ->
                 if host == "example.test",
                   do: {:ok, [{93, 184, 216, 34}]},
                   else: {:ok, [{127, 0, 0, 1}]}
               end,
               request_fun: redirect
             )
  end

  test "blocks IPv4-mapped IPv6 loopback, RFC1918, link-local, and CGNAT answers" do
    request = fn _url, _headers, _http, _max -> flunk("mapped private request was attempted") end

    mapped_private = [
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0xAC10, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0x0102},
      {0, 0, 0, 0, 0, 0xFFFF, 0x6440, 0x0001}
    ]

    for address <- mapped_private do
      assert {:error, :ssrf_blocked} =
               URLFetcher.fetch("https://example.test/a",
                 resolve_fun: fn _ -> {:ok, [address]} end,
                 request_fun: request
               )
    end
  end

  test "detects A to B to A redirects on the first return to the initial URL" do
    parent = self()

    request = fn url, _headers, _http, _max ->
      send(parent, {:requested, url})

      location =
        if String.ends_with?(url, "/a"),
          do: "https://example.test/b",
          else: "https://example.test/a"

      {:ok, {{~c"HTTP/1.1", 302, ~c"Found"}, [{~c"location", String.to_charlist(location)}], ""}}
    end

    assert {:error, :redirect_loop} =
             URLFetcher.fetch("https://EXAMPLE.test/a#fragment",
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: request
             )

    assert_received {:requested, "https://93.184.216.34/a"}
    assert_received {:requested, "https://93.184.216.34/b"}
    refute_received {:requested, _third}
  end

  test "pins the request IP, retains host header, and strips query metadata" do
    parent = self()

    request = fn url, headers, http, max ->
      send(parent, {:request, url, headers, http, max})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"text/plain"}], "hello"}}
    end

    assert {:ok, "hello", metadata} =
             URLFetcher.fetch("https://example.test/path?token=secret#frag",
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: request,
               max_input_bytes: 10
             )

    assert metadata.final_url == "https://example.test/path"
    assert_received {:request, "https://93.184.216.34/path?token=secret", headers, http, 10}
    assert {~c"host", ~c"example.test"} in headers
    assert get_in(http, [:ssl, :server_name_indication]) == ~c"example.test"
  end

  test "rejects a body over the limit even from an injected transport" do
    assert {:error, {:input_too_large, 6, 5}} =
             URLFetcher.fetch("https://example.test/",
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: fn _, _, _, _ ->
                 {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "123456"}}
               end,
               max_input_bytes: 5
             )
  end

  test "rejects ambiguous request targets before opening a socket" do
    connect = fn _, _, _, _, _ -> flunk("invalid target reached the connector") end
    resolve = fn _ -> {:ok, [{93, 184, 216, 34}]} end

    for url <- ["http://example.test/has space", "http://example.test/bad\tpath"] do
      assert {:error, :invalid_url} =
               URLFetcher.fetch(url, resolve_fun: resolve, connect_fun: connect)
    end
  end

  test "default transport preserves live redirect and error status while bounding streamed bodies" do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    {:ok, server} =
      Task.start_link(fn ->
        for _ <- 1..4 do
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, request} = recv_request(socket, "")

          response =
            case Regex.run(~r/^GET ([^ ]+) HTTP\/1\.1/m, request, capture: :all_but_first) do
              ["/start"] ->
                "HTTP/1.1 302 Found\r\nlocation: /ok\r\ncontent-length: 999999\r\nconnection: close\r\n\r\n"

              ["/ok"] ->
                "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n"

              ["/missing"] ->
                "HTTP/1.1 404 Not Found\r\ncontent-length: 999999\r\nconnection: close\r\n\r\n"

              ["/large"] ->
                "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n6\r\n123456\r\n0\r\n\r\n"
            end

          :ok = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
        end

        :gen_tcp.close(listener)
        send(parent, :server_done)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    connect_fun = fn "http", _address, _requested_port, _ssl, timeout ->
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], timeout) do
        {:ok, socket} -> {:ok, {:tcp, socket}}
        error -> error
      end
    end

    common = [
      resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
      connect_fun: connect_fun
    ]

    assert {:ok, "hello", %{status: 200, redirects: 1}} =
             URLFetcher.fetch("http://example.test:#{port}/start", common)

    assert {:error, {:http_status, 404}} =
             URLFetcher.fetch("http://example.test:#{port}/missing", common)

    assert {:error, :input_too_large} =
             URLFetcher.fetch(
               "http://example.test:#{port}/large",
               common ++ [max_input_bytes: 5]
             )

    assert_receive :server_done
  end

  defp recv_request(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 1_000) do
        recv_request(socket, buffer <> chunk)
      end
    end
  end
end
