# LemonWeb LiveView smoke: performs a real /live WebSocket upgrade and LiveView
# join at the launcher URL (http://127.0.0.1:$LEMON_WEB_PORT/), and checks that a
# foreign Origin is refused.
#
#   LEMON_WEB_PORT=4080 [LEMON_CONTROL_PLANE_OPERATOR_TOKEN=...] elixir scripts/web_liveview_smoke.exs
#
# With an operator token the script signs in through /login first; without one
# the runtime must allow tokenless loopback access. Standard library only.

defmodule WebLiveViewSmoke do
  def run do
    port = String.to_integer(System.get_env("LEMON_WEB_PORT") || "4080")
    host = "127.0.0.1:#{port}"
    origin = "http://#{host}"
    cookie = login(port, host, System.get_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN"))

    page = request(port, host, "GET", "/", cookie, nil)
    page.status == 200 || fail!("GET / returned #{page.status}")
    cookie = page.cookie || cookie
    csrf = attr!(page.body, ~r/name="csrf-token" content="([^"]+)"/, "csrf-token")
    id = attr!(page.body, ~r/<div[^>]*id="(phx-[^"]+)"[^>]*data-phx-main/, "LiveView id")
    session = attr!(page.body, ~r/data-phx-session="([^"]+)"/, "data-phx-session")
    static = attr!(page.body, ~r/data-phx-static="([^"]+)"/, "data-phx-static")

    case upgrade(port, host, "http://evil.example", cookie, csrf) do
      {:error, 403} -> :ok
      other -> fail!("foreign Origin was not refused: #{inspect(other)}")
    end

    {:ok, sock} =
      case upgrade(port, host, origin, cookie, csrf) do
        {:ok, sock} -> {:ok, sock}
        other -> fail!("/live/websocket upgrade from #{origin} failed: #{inspect(other)}")
      end

    join = [
      "1",
      "1",
      "lv:" <> id,
      "phx_join",
      %{
        "url" => origin <> "/",
        "params" => %{"_csrf_token" => csrf, "_mounts" => 0},
        "session" => session,
        "static" => static
      }
    ]

    send_text(sock, JSON.encode!(join))

    case recv_json(sock) do
      ["1", "1", "lv:" <> _, "phx_reply", %{"status" => "ok"}] ->
        IO.puts("web LiveView smoke ok: 101 upgrade and join reply from #{origin}")

      reply ->
        fail!("unexpected LiveView join reply: #{inspect(reply, limit: 5, printable_limit: 200)}")
    end
  end

  defp login(_port, _host, token) when token in [nil, ""], do: nil

  defp login(port, host, token) do
    form = request(port, host, "GET", "/login", nil, nil)
    form.status == 200 || fail!("GET /login returned #{form.status}")
    csrf = attr!(form.body, ~r/name="_csrf_token"[^>]*value="([^"]+)"/, "login csrf")
    body = URI.encode_query(%{"_csrf_token" => csrf, "token" => token, "return_to" => "/"})
    signed_in = request(port, host, "POST", "/login", form.cookie, body)
    signed_in.status == 302 || fail!("POST /login returned #{signed_in.status}")
    signed_in.cookie || fail!("POST /login set no session cookie")
  end

  defp request(port, host, method, path, cookie, body) do
    sock = connect(port)

    headers =
      ["#{method} #{path} HTTP/1.1", "Host: #{host}", "Connection: close"] ++
        if(cookie, do: ["Cookie: #{cookie}"], else: []) ++
        if(body,
          do: [
            "Content-Type: application/x-www-form-urlencoded",
            "Content-Length: #{byte_size(body)}"
          ],
          else: []
        )

    :ok = :gen_tcp.send(sock, Enum.join(headers, "\r\n") <> "\r\n\r\n" <> (body || ""))
    [head, resp_body] = sock |> recv_all("") |> String.split("\r\n\r\n", parts: 2)
    [status_line | lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    set_cookie =
      Enum.find_value(lines, fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "set-cookie",
              do: value |> String.trim() |> String.split(";") |> hd()

          _ ->
            nil
        end
      end)

    %{status: String.to_integer(status), cookie: set_cookie, body: resp_body}
  end

  defp upgrade(port, host, origin, cookie, csrf) do
    sock = connect(port)
    query = URI.encode_query(%{"vsn" => "2.0.0", "_csrf_token" => csrf})

    headers =
      [
        "GET /live/websocket?#{query} HTTP/1.1",
        "Host: #{host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Key: #{Base.encode64(:crypto.strong_rand_bytes(16))}",
        "Origin: #{origin}"
      ] ++ if(cookie, do: ["Cookie: #{cookie}"], else: [])

    :ok = :gen_tcp.send(sock, Enum.join(headers, "\r\n") <> "\r\n\r\n")
    status = sock |> recv_head("") |> String.split(" ") |> Enum.at(1) |> String.to_integer()
    if status == 101, do: {:ok, sock}, else: {:error, status}
  end

  defp connect(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000) do
      {:ok, sock} -> sock
      {:error, reason} -> fail!("cannot connect to 127.0.0.1:#{port}: #{inspect(reason)}")
    end
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> fail!("HTTP read failed: #{inspect(reason)}")
    end
  end

  # Reads the response head byte by byte so no WebSocket frame is consumed.
  defp recv_head(sock, acc) do
    if String.ends_with?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(sock, 1, 10_000) do
        {:ok, byte} -> recv_head(sock, acc <> byte)
        {:error, reason} -> fail!("upgrade read failed: #{inspect(reason)}")
      end
    end
  end

  defp send_text(sock, text) do
    mask = :crypto.strong_rand_bytes(4)
    size = byte_size(text)

    len =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    masked =
      for {byte, i} <- Enum.with_index(:binary.bin_to_list(text)),
          into: <<>>,
          do: <<Bitwise.bxor(byte, :binary.at(mask, rem(i, 4)))>>

    :ok = :gen_tcp.send(sock, [<<1::1, 0::3, 1::4>>, len, mask, masked])
  end

  defp recv_json(sock) do
    {:ok, <<_::4, _op::4, 0::1, len7::7>>} = :gen_tcp.recv(sock, 2, 10_000)

    len =
      case len7 do
        126 -> with {:ok, <<n::16>>} <- :gen_tcp.recv(sock, 2, 10_000), do: n
        127 -> with {:ok, <<n::64>>} <- :gen_tcp.recv(sock, 8, 10_000), do: n
        n -> n
      end

    {:ok, payload} = :gen_tcp.recv(sock, len, 10_000)
    JSON.decode!(payload)
  end

  defp attr!(body, regex, what) do
    case Regex.run(regex, body, capture: :all_but_first) do
      [value] -> value
      _ -> fail!("page has no #{what}")
    end
  end

  defp fail!(message) do
    IO.puts(:stderr, "web LiveView smoke FAILED: " <> message)
    System.halt(1)
  end
end

WebLiveViewSmoke.run()
