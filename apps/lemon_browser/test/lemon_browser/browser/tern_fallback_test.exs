defmodule LemonBrowser.TernFallbackTest do
  use ExUnit.Case, async: false

  defmodule LocalRecorder do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:request, method, args, _, _}, _, parent) do
      send(parent, {:local, method, args})
      {:reply, {:ok, %{"method" => method}}, parent}
    end
  end

  setup do
    path = Path.join(System.tmp_dir!(), "lf-#{System.unique_integer([:positive])}.sock")
    keys = ~w(TERN_PANE_SOCKET LEMON_BROWSER_TERN)
    old = Map.new(keys, &{&1, System.get_env(&1)})
    System.put_env("TERN_PANE_SOCKET", path)
    System.delete_env("LEMON_BROWSER_TERN")

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm(path)
    end)

    server = start_supervised!({LocalRecorder, self()})

    opts = [
      server: server,
      tern_pane: 123,
      session_id: "fallback-#{System.unique_integer([:positive])}",
      run_id: "run",
      provider_config: %{tern: true},
      provider_resolution: %{provider: "tern", requested: "auto", reason: "test"},
      probe: fn
        "local" -> {:ok, "available"}
        _ -> {:error, "unavailable"}
      end
    ]

    {:ok, path: path, opts: opts}
  end

  test "auto unavailable opens fall back with a note and retain the provider for later methods",
       %{path: path, opts: opts} do
    daemon(path, "no_window")

    assert {:ok, result} =
             LemonBrowser.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               opts
             )

    assert result["providerNote"] =~ "local"
    assert_receive {:local, "browser.navigate", _}
    assert {:ok, result} = LemonBrowser.request("browser.snapshot", %{}, 1_000, opts)
    assert result["providerNote"] =~ "local"
    assert_receive {:local, "browser.snapshot", %{}}
    LemonBrowser.TernSession.close(opts)
  end

  test "explicit Tern never switches providers", %{path: path, opts: opts} do
    daemon(path, "unsupported")

    opts =
      Keyword.put(opts, :provider_resolution, %{
        provider: "tern",
        requested: "tern",
        reason: "test"
      })

    assert {:error, {:unsupported, _}} =
             LemonBrowser.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               opts
             )

    refute_received {:local, _, _}
    LemonBrowser.TernSession.close(opts)
  end

  test "adopting a user target never falls back to a different browser", %{path: path, opts: opts} do
    daemon(path, "no_window")

    assert {:error, _} =
             LemonBrowser.request(
               "browser.navigate",
               %{"url" => "https://example.com", "targetId" => "99"},
               1_000,
               opts
             )

    refute_received {:local, _, _}
    LemonBrowser.TernSession.close(opts)
  end

  test "non-unavailable errors never fall back", %{path: path, opts: opts} do
    daemon(path, "failed")

    assert {:error, {:failed, _}} =
             LemonBrowser.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               opts
             )

    refute_received {:local, _, _}
    LemonBrowser.TernSession.close(opts)
  end

  defp daemon(path, kind) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    pid = spawn(fn -> accept(listener, kind) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)
  end

  defp accept(listener, kind) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, kind) end)
        accept(listener, kind)

      _ ->
        :ok
    end
  end

  defp serve(socket, kind) do
    case receive_frame(socket) do
      {:ok, %{"hello" => _}} ->
        frame(socket, %{"welcome" => %{"ops" => ["browser"]}})
        serve(socket, kind)

      {:ok, %{"id" => id}} ->
        frame(socket, %{
          "id" => id,
          "browser" => %{"error" => %{"kind" => kind, "message" => "Unavailable"}}
        })

        serve(socket, kind)

      _ ->
        :gen_tcp.close(socket)
    end
  end

  defp receive_frame(socket) do
    with {:ok, <<size::little-32>>} <- :gen_tcp.recv(socket, 4, 5_000),
         {:ok, json} <- :gen_tcp.recv(socket, size, 5_000),
         do: Jason.decode(json)
  end

  defp frame(socket, message) do
    json = Jason.encode!(message)
    :gen_tcp.send(socket, <<byte_size(json)::little-32, json::binary>>)
  end
end
