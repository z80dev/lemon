defmodule LemonCore.TernTest do
  use ExUnit.Case, async: false
  alias LemonCore.Tern

  setup do
    path = Path.join(System.tmp_dir!(), "lt-#{System.unique_integer([:positive])}.sock")
    keys = ~w(TERN_PANE_SOCKET TERN_DAEMON_SOCKET TERN_CONFIG_DIR TERN_PANE LEMON_BROWSER_TERN)
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)
    System.put_env("TERN_PANE_SOCKET", path)

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm(path)
    end)

    {:ok, path: path}
  end

  test "safe pane ids reject malformed, negative and unsafe integers" do
    for value <- [nil, "", "-1", "1x", "1.0", " 1", 1.5, -1, 9_007_199_254_740_992] do
      assert {:error, :invalid_pane} = Tern.pane(value)
    end

    assert {:ok, 0} = Tern.pane("000")
    assert {:ok, 9_007_199_254_740_991} = Tern.pane("9007199254740991")
  end

  test "socket discovery ignores caller paths and refuses ordinary files", %{path: path} do
    File.write!(path, "not a socket")
    assert {:error, {:connect, _}} = Tern.connect(path: "/tmp/untrusted")
    File.rm!(path)
    System.delete_env("TERN_PANE_SOCKET")
    System.put_env("TERN_CONFIG_DIR", "/tmp/tern-test-config")
    assert Tern.socket_path() == "/tmp/tern-test-config/daemon.sock"
    System.put_env("TERN_DAEMON_SOCKET", "/tmp/daemon.sock")
    assert Tern.socket_path() == "/tmp/daemon.sock"
  end

  test "fragmented frames, unknown members and out-of-order replies correlate concurrent requests",
       %{path: path} do
    daemon(path, fn socket ->
      frame(socket, %{"future" => true})
      bytes = encoded(%{"welcome" => %{"ops" => ["browser", 42], "future" => true}})
      <<first::binary-size(2), rest::binary>> = bytes
      :gen_tcp.send(socket, first)
      :gen_tcp.send(socket, rest)
      a = receive_frame(socket)
      b = receive_frame(socket)
      frame(socket, %{"id" => a["id"], "future" => %{}})
      frame(socket, %{"id" => b["id"], "browser" => %{"ok" => b["browser"]}})
      frame(socket, %{"id" => a["id"], "browser" => %{"ok" => a["browser"]}})
      receive do: (:finish -> :ok)
    end)

    assert {:ok, client} = Tern.connect()
    assert Tern.supports?(client, "browser")
    refute Tern.supports?(client, "fork")
    a = Task.async(fn -> Tern.request(client, "browser", %{"op" => "a"}) end)
    b = Task.async(fn -> Tern.request(client, "browser", %{"op" => "b"}) end)
    assert {:ok, %{"op" => "a"}} = Task.await(a)
    assert {:ok, %{"op" => "b"}} = Task.await(b)
    Tern.close(client)
  end

  test "request timeouts do not poison other requests and daemon errors remain tagged", %{
    path: path
  } do
    daemon(path, fn socket ->
      frame(socket, %{"welcome" => %{"ops" => ["browser"]}})
      expired = receive_frame(socket)
      next = receive_frame(socket)
      frame(socket, %{"id" => expired["id"], "browser" => %{"ok" => "late"}})

      frame(socket, %{
        "id" => next["id"],
        "browser" => %{"error" => %{"kind" => "no_window", "message" => "No window"}}
      })

      receive do: (:finish -> :ok)
    end)

    assert {:ok, client} = Tern.connect()
    assert {:error, {:timeout, _}} = Tern.request(client, "browser", %{"op" => "slow"}, 10)

    assert {:error, {:no_window, "No window"}} =
             Tern.request(client, "browser", %{"op" => "state"})

    Tern.close(client)
  end

  test "provider auto uses the daemon welcome for a bound pane", %{path: path} do
    daemon(path, fn socket ->
      frame(socket, %{"welcome" => %{"ops" => ["browser", "future"]}})
      receive do: (:finish -> :ok)
    end)

    result =
      LemonCore.BrowserProvider.resolve(
        config: %{provider: "auto"},
        tern_pane: 123,
        lcu_probe: fn -> flunk("must not probe a later provider") end
      )

    assert result.provider == "tern"
    assert result.checks["tern"].available
  end

  test "a daemon without browser support is not selected", %{path: path} do
    daemon(path, fn socket ->
      frame(socket, %{"welcome" => %{"ops" => ["fork"]}})
      receive do: (:finish -> :ok)
    end)

    assert %{provider: "lcu"} =
             LemonCore.BrowserProvider.resolve(
               config: %{provider: "auto"},
               tern_pane: 123,
               lcu_probe: fn -> {:ok, "available"} end
             )
  end

  test "connections close when their owner exits", %{path: path} do
    daemon(path, fn socket ->
      frame(socket, %{"welcome" => %{"ops" => ["browser"]}})
      receive do: (:finish -> :ok)
    end)

    parent = self()

    owner =
      spawn(fn ->
        {:ok, client} = Tern.connect()
        send(parent, {:client, client})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:client, client}
    monitor = Process.monitor(client)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  test "daemon error kinds are preserved without creating atoms", %{path: path} do
    kinds = ~w(invalid not_found not_agent no_window window_closed unsupported js failed)

    daemon(path, fn socket ->
      frame(socket, %{"welcome" => %{"ops" => ["browser"]}})

      Enum.each(kinds ++ ["future_kind"], fn kind ->
        request = receive_frame(socket)

        frame(socket, %{
          "id" => request["id"],
          "browser" => %{"error" => %{"kind" => kind, "message" => "failure"}}
        })
      end)
    end)

    assert {:ok, client} = Tern.connect()

    for kind <- kinds do
      assert {:error, {actual, "failure"}} = Tern.request(client, "browser", %{"op" => "state"})
      assert Atom.to_string(actual) == kind
    end

    assert {:error, {:failed, "failure"}} = Tern.request(client, "browser", %{"op" => "state"})
    Tern.close(client)
  end

  test "oversized and non-object frames fail as protocol errors", %{path: path} do
    for bytes <- [<<268_435_457::little-32>>, encoded([])] do
      daemon =
        daemon(path, fn socket ->
          frame(socket, %{"welcome" => %{"ops" => ["browser"]}})
          receive_frame(socket)
          :gen_tcp.send(socket, bytes)
          receive do: (:finish -> :ok)
        end)

      assert {:ok, client} = Tern.connect()
      assert {:error, {:protocol, _}} = Tern.request(client, "browser", %{"op" => "state"})
      Process.exit(daemon, :kill)
      File.rm!(path)
    end
  end

  test "handshake has a bounded deadline", %{path: path} do
    daemon(path, fn _ -> receive do: (:finish -> :ok) end)
    assert {:error, {:timeout, _}} = Tern.connect(timeout_ms: 10)
  end

  test "late successful opens are closed rather than leaked", %{path: path} do
    parent = self()

    pid =
      daemon(path, fn socket ->
        frame(socket, %{"welcome" => %{"ops" => ["browser"]}})
        open = receive_frame(socket)
        receive do: (:late -> :ok)
        frame(socket, %{"id" => open["id"], "browser" => %{"ok" => %{"block" => 88}}})
        close = receive_frame(socket)
        send(parent, {:late_close, close["browser"]})
      end)

    assert {:ok, client} = Tern.connect()
    assert {:error, {:timeout, _}} = Tern.request(client, "browser", %{"op" => "open"}, 10)
    send(pid, :late)
    assert_receive {:late_close, %{"op" => "close", "block" => 88}}
    Tern.close(client)
  end

  test "user page open hands the block to the user", %{path: path} do
    parent = self()
    System.put_env("TERN_PANE", "123")

    daemon(path, fn socket ->
      frame(socket, %{"welcome" => %{"ops" => ["browser"]}})
      open = receive_frame(socket)
      send(parent, {:open, open["browser"]})
      frame(socket, %{"id" => open["id"], "browser" => %{"ok" => %{"block" => 99}}})
      release = receive_frame(socket)
      send(parent, {:release, release["browser"]})
      frame(socket, %{"id" => release["id"], "browser" => %{"ok" => %{}}})
    end)

    assert :ok = Tern.open_user_page("https://example.com/login")

    assert_receive {:open,
                    %{
                      "op" => "open",
                      "owner" => 123,
                      "how" => "beside",
                      "url" => "https://example.com/login"
                    }}

    assert_receive {:release, %{"op" => "release", "block" => 99}}
  end

  test "opt-out config and env precedence" do
    assert Tern.enabled?(provider_config: %{tern: true})
    refute Tern.enabled?(provider_config: %{"tern" => false})
    System.put_env("LEMON_BROWSER_TERN", "0")
    refute Tern.enabled?(provider_config: %{tern: true})
    System.put_env("LEMON_BROWSER_TERN", "1")
    assert Tern.enabled?(provider_config: %{tern: false})
  end

  defp daemon(path, callback) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        assert receive_frame(socket) == %{"hello" => %{}}
        callback.(socket)
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    pid
  end

  defp receive_frame(socket) do
    {:ok, <<size::little-32>>} = :gen_tcp.recv(socket, 4, 5_000)
    {:ok, body} = :gen_tcp.recv(socket, size, 5_000)
    Jason.decode!(body)
  end

  defp frame(socket, message), do: :gen_tcp.send(socket, encoded(message))

  defp encoded(message) do
    body = Jason.encode!(message)
    <<byte_size(body)::little-32, body::binary>>
  end
end
