defmodule LemonCore.NetTest do
  use ExUnit.Case, async: true

  alias LemonCore.Net

  test "wss URLs always verify the peer certificate and hostname" do
    url = "wss://api.deepgram.com/v1/listen"
    assert {:ok, ^url, opts} = Net.web_socket_options(url, extra_headers: [{"a", "b"}])

    assert opts[:extra_headers] == [{"a", "b"}]
    assert opts[:insecure] == false
    ssl = Keyword.fetch!(opts, :ssl_options)
    assert ssl[:verify] == :verify_peer
    assert ssl[:cacerts] == :public_key.cacerts_get()
    assert ssl[:server_name_indication] == ~c"api.deepgram.com"
    assert [match_fun: fun] = ssl[:customize_hostname_check]
    assert is_function(fun, 2)
  end

  test "caller-supplied TLS options cannot downgrade verification" do
    assert {:ok, _url, opts} =
             Net.web_socket_options("wss://controller.example/ws",
               insecure: true,
               ssl_options: [verify: :verify_none],
               cacerts: [],
               allow_insecure_ws: true
             )

    assert opts[:insecure] == false
    refute Keyword.has_key?(opts, :cacerts)
    refute Keyword.has_key?(opts, :allow_insecure_ws)
    ssl = Keyword.fetch!(opts, :ssl_options)
    assert ssl[:verify] == :verify_peer
    assert [match_fun: _] = ssl[:customize_hostname_check]
  end

  test "extra_cacerts appends to the OS store and keeps verification" do
    extra = <<1, 2, 3>>

    assert {:ok, _url, opts} =
             Net.web_socket_options("wss://127.0.0.1:4044/ws", extra_cacerts: [extra])

    refute Keyword.has_key?(opts, :extra_cacerts)
    ssl = Keyword.fetch!(opts, :ssl_options)
    assert ssl[:cacerts] == :public_key.cacerts_get() ++ [extra]
    assert ssl[:verify] == :verify_peer
    assert [match_fun: _] = ssl[:customize_hostname_check]
    refute Keyword.has_key?(ssl, :server_name_indication)
  end

  test "plaintext ws is allowed to literal loopback IPs" do
    for url <- [
          "ws://127.0.0.1:4040/ws",
          "ws://127.8.9.10:4040/ws",
          "ws://[::1]:4040/ws",
          "ws://[::ffff:127.0.0.1]:4040/ws"
        ] do
      assert {:ok, ^url, opts} = Net.web_socket_options(url)
      refute Keyword.has_key?(opts, :ssl_options)
    end
  end

  test "plaintext localhost is pinned to 127.0.0.1 instead of resolved" do
    assert {:ok, "ws://127.0.0.1:4040/ws", _} = Net.web_socket_options("ws://localhost:4040/ws")
    assert {:ok, "ws://127.0.0.1:4040/ws", _} = Net.web_socket_options("WS://LocalHost:4040/ws")
  end

  test "spoofed loopback hosts are refused for plaintext" do
    for url <- [
          "ws://127.0.0.1.evil/ws",
          "ws://localhost.evil.com/ws",
          "ws://x.localhost/ws",
          "ws://controller.example/ws",
          "ws://192.168.1.2:4040/ws",
          "ws://[::ffff:10.0.0.1]/ws"
        ] do
      assert Net.web_socket_options(url) == {:error, :insecure_web_socket_url}, url
    end

    assert {:ok, _, _} =
             Net.web_socket_options("ws://192.168.1.2:4040/ws", allow_insecure_ws: true)
  end

  test "userinfo, malformed and non-websocket URLs are refused" do
    for url <- [
          "ws://127.0.0.1@evil/ws",
          "wss://user:pass@controller.example/ws",
          "https://example.com",
          "wss://",
          "not a url",
          nil
        ] do
      assert Net.web_socket_options(url) == {:error, :invalid_web_socket_url}, inspect(url)
    end
  end

  test "upper-case schemes are normalized and still verified" do
    assert {:ok, "wss://controller.example/ws", opts} =
             Net.web_socket_options("WSS://controller.example/ws")

    assert Keyword.fetch!(opts, :ssl_options)[:verify] == :verify_peer
  end
end
