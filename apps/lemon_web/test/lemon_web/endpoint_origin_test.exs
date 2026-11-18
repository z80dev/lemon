defmodule LemonWeb.EndpointOriginTest do
  @moduledoc """
  The endpoint served on a real loopback listener: with tokenless loopback
  enabled, a foreign `Origin` or `Host` must not reach the `/live` socket or
  any page, while the launcher's loopback origin completes a LiveView join.
  """
  use ExUnit.Case, async: false

  @app :lemon_control_plane

  setup do
    previous = Application.fetch_env(@app, :allow_unauthenticated_loopback_operator)
    previous_token = Application.fetch_env(@app, :operator_token)
    previous_origins = Application.fetch_env(:lemon_web, :trusted_origins)
    Application.put_env(@app, :allow_unauthenticated_loopback_operator, true)
    Application.delete_env(@app, :operator_token)
    env_token = System.get_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN")
    System.delete_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN")

    {:ok, server} =
      Bandit.start_link(plug: LemonWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:lemon_web, :trusted_origins, [
      "http://localhost:#{port}",
      "http://127.0.0.1:#{port}",
      "http://[::1]:#{port}"
    ])

    on_exit(fn ->
      restore(@app, :allow_unauthenticated_loopback_operator, previous)
      restore(@app, :operator_token, previous_token)
      restore(:lemon_web, :trusted_origins, previous_origins)
      if env_token, do: System.put_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN", env_token)
    end)

    %{port: port}
  end

  test "a loopback-origin handshake joins the LiveView", %{port: port} do
    origin = "http://127.0.0.1:#{port}"
    page = http_get(port, "/", "127.0.0.1:#{port}")
    assert page.status == 200

    socket = ws_upgrade(port, "127.0.0.1:#{port}", origin, page.cookie, page.csrf)
    assert {:ok, 101, sock} = socket

    join = [
      "1",
      "1",
      "lv:" <> page.id,
      "phx_join",
      %{
        "url" => origin <> "/",
        "params" => %{"_csrf_token" => page.csrf, "_mounts" => 0},
        "session" => page.session,
        "static" => page.static
      }
    ]

    send_text(sock, Jason.encode!(join))
    assert ["1", "1", "lv:" <> _, "phx_reply", %{"status" => "ok"}] = recv_json(sock)
  end

  test "a foreign Origin cannot open the /live socket", %{port: port} do
    page = http_get(port, "/", "127.0.0.1:#{port}")

    for origin <- [
          "http://evil.example",
          "http://127.0.0.1:#{port + 1}",
          "https://127.0.0.1:#{port}",
          "http://sub.localhost:#{port}",
          "null"
        ] do
      assert {:error, 403} =
               ws_upgrade(port, "127.0.0.1:#{port}", origin, page.cookie, page.csrf),
             "origin #{origin} was accepted"
    end
  end

  test "a foreign Host is refused on pages, exports and the socket", %{port: port} do
    for path <- ["/", "/sessions", "/login"] do
      assert http_get(port, path, "rebind.evil.example:#{port}").status == 421
    end

    assert {:error, 421} =
             ws_upgrade(
               port,
               "rebind.evil.example:#{port}",
               "http://rebind.evil.example:#{port}",
               nil,
               nil
             )
  end

  describe "session cookie Secure flag over a plain-HTTP backend" do
    setup do
      previous = Application.fetch_env(:lemon_web, :secure_cookies)
      on_exit(fn -> restore(:lemon_web, :secure_cookies, previous) end)
    end

    test "direct loopback HTTP keeps a usable non-Secure cookie by default", %{port: port} do
      Application.delete_env(:lemon_web, :secure_cookies)
      cookie = login_set_cookie(port, [])
      refute cookie =~ ~r/;\s*secure/i
    end

    test "LEMON_WEB_SECURE_COOKIES marks it Secure behind TLS termination", %{port: port} do
      Application.put_env(:lemon_web, :secure_cookies, true)
      assert login_set_cookie(port, []) =~ ~r/;\s*secure/i
    end

    test "forwarded headers never decide the Secure flag", %{port: port} do
      Application.put_env(:lemon_web, :secure_cookies, false)
      cookie = login_set_cookie(port, ["X-Forwarded-Proto: https", "Forwarded: proto=https"])
      refute cookie =~ ~r/;\s*secure/i
    end

    defp login_set_cookie(port, extra_headers) do
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      request =
        ["GET / HTTP/1.1", "Host: 127.0.0.1:#{port}", "Connection: close" | extra_headers]

      :ok = :gen_tcp.send(sock, Enum.join(request, "\r\n") <> "\r\n\r\n")
      [head | _] = sock |> recv_all("") |> String.split("\r\n\r\n", parts: 2)

      head
      |> String.split("\r\n")
      |> Enum.find(&String.starts_with?(String.downcase(&1), "set-cookie: _lemon_web_key="))
      |> tap(&assert(is_binary(&1), "no session cookie set"))
    end
  end

  test "the /live socket's origin check cannot be configured off" do
    [{"/live", Phoenix.LiveView.Socket, opts}] = LemonWeb.Endpoint.__sockets__()

    assert opts[:websocket][:check_origin] == {LemonWeb.RequestGuard, :origin_allowed?, []}
  end

  describe "source runtime configuration (MIX_ENV=dev, as bin/lemon runs it)" do
    @root Path.expand("../../../..", __DIR__)

    defp dev_endpoint(runtime_env) do
      static = Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :dev)

      runtime =
        with_env(runtime_env, fn ->
          Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :dev)
        end)

      merged = Config.Reader.merge(static, runtime)

      {get_in(static, [:lemon_web, LemonWeb.Endpoint]),
       get_in(merged, [:lemon_web, LemonWeb.Endpoint])}
    end

    test "commits no secret, salt, reloader, debug page or disabled origin check" do
      {static, endpoint} = dev_endpoint(%{"LEMON_WEB_SECRET_KEY_BASE" => nil})

      refute Keyword.has_key?(static, :secret_key_base)
      refute get_in(static, [:live_view, :signing_salt])
      refute Keyword.get(endpoint, :code_reloader, false)
      refute Keyword.get(endpoint, :debug_errors, false)
      refute Keyword.get(endpoint, :check_origin) == false
      assert byte_size(endpoint[:secret_key_base]) >= 64
      assert byte_size(endpoint[:live_view][:signing_salt]) >= 8
    end

    test "each install gets its own secret and LiveView salt" do
      {_, a} = dev_endpoint(%{"LEMON_WEB_SECRET_KEY_BASE" => nil})
      {_, b} = dev_endpoint(%{"LEMON_WEB_SECRET_KEY_BASE" => nil})
      assert a[:secret_key_base] != b[:secret_key_base]
      assert a[:live_view][:signing_salt] != b[:live_view][:signing_salt]

      key = String.duplicate("k", 64)
      {_, c} = dev_endpoint(%{"LEMON_WEB_SECRET_KEY_BASE" => key})
      {_, d} = dev_endpoint(%{"LEMON_WEB_SECRET_KEY_BASE" => String.duplicate("j", 64)})
      assert c[:secret_key_base] == key
      assert c[:live_view][:signing_salt] != d[:live_view][:signing_salt]
    end
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)
    end
  end

  ## Raw HTTP/WebSocket client

  defp http_get(port, path, host) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(sock, "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")

    raw = recv_all(sock, "")
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | headers] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    cookie =
      Enum.find_value(headers, fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "set-cookie",
              do: value |> String.trim() |> String.split(";") |> hd()

          _ ->
            nil
        end
      end)

    %{
      status: String.to_integer(status),
      cookie: cookie,
      csrf: attr(body, ~r/name="csrf-token" content="([^"]+)"/),
      id: attr(body, ~r/data-phx-main[^>]*id="([^"]+)"|id="([^"]+)"[^>]*data-phx-main/),
      session: attr(body, ~r/data-phx-session="([^"]+)"/),
      static: attr(body, ~r/data-phx-static="([^"]+)"/)
    }
  end

  defp attr(body, regex) do
    case Regex.run(regex, body, capture: :all_but_first) do
      nil -> nil
      captures -> Enum.find(captures, &(&1 != ""))
    end
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp ws_upgrade(port, host, origin, cookie, csrf) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    key = Base.encode64(:crypto.strong_rand_bytes(16))
    query = URI.encode_query(%{"vsn" => "2.0.0", "_csrf_token" => csrf || ""})

    request =
      [
        "GET /live/websocket?#{query} HTTP/1.1",
        "Host: #{host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Key: #{key}",
        "Origin: #{origin}"
      ] ++ if(cookie, do: ["Cookie: #{cookie}"], else: [])

    :ok = :gen_tcp.send(sock, Enum.join(request, "\r\n") <> "\r\n\r\n")
    {head, _rest} = recv_head(sock, "")
    [_, status | _] = head |> String.split("\r\n") |> hd() |> String.split(" ")

    case String.to_integer(status) do
      101 -> {:ok, 101, sock}
      other -> {:error, other}
    end
  end

  defp recv_head(sock, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        recv_head(sock, acc <> data)
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

    :ok = :gen_tcp.send(sock, [<<1::1, 0::3, 1::4>>, len, mask, mask_payload(text, mask)])
  end

  defp mask_payload(text, <<m::binary-size(4)>>) do
    text
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(m, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp recv_json(sock) do
    {:ok, <<_fin::1, _rsv::3, _op::4, 0::1, len7::7>>} = :gen_tcp.recv(sock, 2, 5_000)

    len =
      case len7 do
        126 -> with {:ok, <<n::16>>} <- :gen_tcp.recv(sock, 2, 5_000), do: n
        127 -> with {:ok, <<n::64>>} <- :gen_tcp.recv(sock, 8, 5_000), do: n
        n -> n
      end

    {:ok, payload} = :gen_tcp.recv(sock, len, 5_000)
    Jason.decode!(payload)
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
