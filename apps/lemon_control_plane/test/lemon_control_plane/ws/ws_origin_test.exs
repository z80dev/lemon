defmodule LemonControlPlane.WS.OriginTest do
  @moduledoc """
  DNS-rebinding / cross-site WebSocket hijacking regression tests: a browser on
  the operator's machine must not be able to reach the loopback control plane.
  Exercised against a real Bandit listener on 127.0.0.1.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.HTTP.Router

  @keys [:operator_token, :allow_unauthenticated_loopback_operator, :allowed_origins, :ip]

  setup do
    old = Map.new(@keys, &{&1, Application.fetch_env(:lemon_control_plane, &1)})
    Application.delete_env(:lemon_control_plane, :operator_token)
    Application.delete_env(:lemon_control_plane, :allowed_origins)
    Application.put_env(:lemon_control_plane, :ip, {127, 0, 0, 1})
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:lemon_control_plane, key, value)
          :error -> Application.delete_env(:lemon_control_plane, key)
        end
      end
    end)

    server =
      start_supervised!({Bandit, plug: Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  for path <- ["/ws", "/acp/ws"] do
    test "#{path} refuses a foreign browser Origin with tokenless loopback enabled", %{port: p} do
      response = upgrade(p, unquote(path), "127.0.0.1:#{p}", origin: "https://evil.example")
      assert response =~ "HTTP/1.1 403"
      refute response =~ "101"
    end

    test "#{path} refuses lookalike and opaque origins", %{port: p} do
      for origin <- [
            "null",
            "http://127.0.0.1.evil.example",
            "http://localhost.evil.example:#{p}",
            "http://evil.example@127.0.0.1"
          ] do
        assert upgrade(p, unquote(path), "127.0.0.1:#{p}", origin: origin) =~ "HTTP/1.1 403",
               origin
      end
    end

    test "#{path} still upgrades a native client without Origin", %{port: p} do
      assert upgrade(p, unquote(path), "127.0.0.1:#{p}") =~ "HTTP/1.1 101"
      assert upgrade(p, unquote(path), "localhost:#{p}") =~ "HTTP/1.1 101"
      assert upgrade(p, unquote(path), "[::1]:#{p}") =~ "HTTP/1.1 101"
    end

    test "#{path} refuses other loopback origins: unrelated ports, subdomains, schemes", %{
      port: p
    } do
      for origin <- [
            "http://localhost:5173",
            "http://127.0.0.1:1",
            "http://localhost",
            "http://evil.localhost:#{p}",
            "http://app.localhost:4082",
            "https://localhost:#{p}"
          ] do
        assert upgrade(p, unquote(path), "localhost:#{p}", origin: origin) =~ "HTTP/1.1 403",
               origin
      end
    end

    test "#{path} accepts its own origin, lemon_web's origin and allowlisted origins", %{
      port: p
    } do
      for origin <- [
            "http://localhost:#{p}",
            "http://127.0.0.1:#{p}",
            "http://[::1]:#{p}",
            "http://localhost:4082",
            "http://127.0.0.1:4082"
          ] do
        assert upgrade(p, unquote(path), "localhost:#{p}", origin: origin) =~ "HTTP/1.1 101",
               origin
      end

      Application.put_env(:lemon_control_plane, :allowed_origins, ["https://ops.example.com"])

      assert upgrade(p, unquote(path), "127.0.0.1:#{p}", origin: "https://ops.example.com") =~
               "HTTP/1.1 101"

      assert upgrade(p, unquote(path), "127.0.0.1:#{p}", origin: "https://ops.example.com.evil") =~
               "HTTP/1.1 403"
    end

    test "#{path} refuses a rebound Host from a loopback peer", %{port: p} do
      assert upgrade(p, unquote(path), "attacker.example:#{p}") =~ "HTTP/1.1 403"
      assert upgrade(p, unquote(path), "evil.localhost:#{p}") =~ "HTTP/1.1 403"
    end
  end

  test "HTTP routes refuse a rebound Host from a loopback peer", %{port: p} do
    assert request(p, "GET /healthz HTTP/1.1\r\nHost: attacker.example:#{p}\r\n\r\n") =~
             "HTTP/1.1 403"

    assert request(p, "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1:#{p}\r\n\r\n") =~
             "HTTP/1.1 200"
  end

  defp upgrade(port, path, host, opts \\ []) do
    origin = if o = opts[:origin], do: "Origin: #{o}\r\n", else: ""

    request(
      port,
      "GET #{path} HTTP/1.1\r\nHost: #{host}\r\n#{origin}Connection: Upgrade\r\nUpgrade: websocket\r\n" <>
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    )
  end

  defp request(port, raw) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    try do
      :ok = :gen_tcp.send(socket, raw)
      {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
      response
    after
      :gen_tcp.close(socket)
    end
  end
end
