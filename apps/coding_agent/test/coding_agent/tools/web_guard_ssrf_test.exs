defmodule CodingAgent.Tools.WebGuardSsrfTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.WebGuard

  defp start_listener do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp accept_loop(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)

    spawn(fn ->
      _ = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
      :gen_tcp.close(socket)
    end)

    accept_loop(listen)
  end

  test "metadata aliases, IPv4-mapped and 6to4 targets are rejected before any request" do
    for url <- [
          "http://2852039166/latest/meta-data/",
          "http://0xA9FEA9FE/latest/meta-data/",
          "http://[::ffff:169.254.169.254]/latest/meta-data/",
          "http://[64:ff9b::a9fe:a9fe]/",
          "http://[2002:a9fe:a9fe::]/",
          "http://[2002:7f00:0001::]/"
        ] do
      assert {:error, {:ssrf_blocked, _}} =
               WebGuard.guarded_get(url, resolve_host: fn _ -> flunk("literal reached DNS") end),
             url
    end

    for url <- ["http://169.254.169.254/", "http://[2002:a9fe:a9fe::]/"] do
      assert {:error, {:ssrf_blocked, _}} =
               WebGuard.guarded_get(url, allow_private_network: true),
             url
    end
  end

  test "repeated fetches to distinct hosts create no new atoms or connection pools" do
    port = start_listener()
    resolver = fn _host -> {:ok, [{127, 0, 0, 1}]} end

    # HTTPS carries a per-host TLS identity, which is what used to key a pool.
    # The listener speaks plain HTTP, so each fetch fails after connecting.
    fetch = fn host ->
      WebGuard.guarded_get("https://#{host}:#{port}/",
        allow_private_network: true,
        resolve_host: resolver,
        timeout_ms: 1_000
      )
    end

    # Warm up code paths once.
    assert {:error, _} = fetch.("warmup.example")

    atoms = :erlang.system_info(:atom_count)
    processes = :erlang.system_info(:process_count)

    for n <- 1..40 do
      assert {:error, _} = fetch.("host-#{n}-#{System.unique_integer([:positive])}.example")
    end

    # 40 distinct hosts would intern >= 40 atoms if per-host atoms leaked;
    # allow a handful of incidental atoms from concurrent OTP/umbrella workers.
    assert :erlang.system_info(:atom_count) - atoms < 5

    # Allow short-lived per-request processes to exit before counting.
    Process.sleep(200)
    assert :erlang.system_info(:process_count) - processes < 10
  end
end
