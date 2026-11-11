defmodule LemonSkills.McpSourceLifecycleTest do
  use ExUnit.Case, async: false
  alias LemonMCP.Client.SSE
  alias LemonSkills.McpSource

  test "legacy SSE loss exits the client so the host observes transport loss" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, id} = Mint.HTTP.request(conn, "GET", "/sse", [], nil)
    socket = Mint.HTTP.get_socket(conn)

    state = %{
      state: :ready,
      stream_request_id: id,
      stream_conn: conn,
      stream_socket: socket
    }

    for event <- [
          {:tcp_closed, socket},
          {:tcp_error, socket, :closed},
          {:mcp_stream_closed, id}
        ] do
      assert {:stop, :normal, %{state: :disconnected, stream_request_id: nil}} =
               SSE.handle_info(event, state)
    end

    {:ok, _conn} = Mint.HTTP.close(conn)
  end

  test "legacy SSE ignores stray messages without exposing their contents" do
    state = %{state: :ready, stream_request_id: make_ref(), stream_socket: make_ref()}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for event <- [
              {:stray, "private message contents"},
              {:tcp_closed, make_ref()},
              {:mcp_stream_closed, make_ref()}
            ] do
          assert {:noreply, ^state} = SSE.handle_info(event, state)
        end
      end)

    assert log =~ "Ignoring unexpected MCP SSE client message"
    refute log =~ "private message contents"
  end

  setup do
    disabled = Application.get_env(:lemon_skills, :mcp_disabled)
    env = System.get_env("LEMON_MCP_DISABLED")
    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.delete_env("LEMON_MCP_DISABLED")
    root = Path.join(System.tmp_dir!(), "mcp-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    script = Path.join(root, "server.exs")
    File.write!(script, fixture())

    # The fixture server is a fresh Erlang VM; its boot is not under test, so
    # keep the product's ready deadline instead of racing boot under load.
    config =
      {:stdio, System.find_executable("elixir"), ["--erl", "+S 1:1", script], name: "lifecycle"}

    source =
      start_supervised!({McpSource, name: nil, configs: [config], refresh_interval_ms: 60_000})

    assert {:ok, _} = McpSource.discover_ready(source)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(disabled),
        do: Application.delete_env(:lemon_skills, :mcp_disabled),
        else: Application.put_env(:lemon_skills, :mcp_disabled, disabled)

      if is_nil(env),
        do: System.delete_env("LEMON_MCP_DISABLED"),
        else: System.put_env("LEMON_MCP_DISABLED", env)
    end)

    %{source: source, script: script}
  end

  test "each real list_changed notification refreshes tools, resources and prompts", %{
    source: source
  } do
    for {kind, generation} <- Enum.with_index(["tools", "resources", "prompts"], 1) do
      echo = Enum.find(McpSource.discover_tools(source, []), &String.contains?(&1.name, "_echo_"))
      assert {:ok, _} = McpSource.call_tool(source, echo.name, %{"kind" => kind}, [])
      eventually(fn -> length(server(source).resources) == generation + 1 end)
      current = server(source)
      assert length(current.prompts) == generation + 1
      assert length(current.tools) == generation + 6
    end
  end

  test "transport loss reconnects after 500 ms and refreshes the cache", %{source: source} do
    old = server(source).client
    GenServer.stop(old, :normal)
    eventually(fn -> not server(source).connected end)
    reconnecting = server(source)
    assert reconnecting.reconnect_attempt == 1
    assert Process.read_timer(reconnecting.reconnect_timer) in 1..500
    eventually(fn -> server(source).connected end)
    assert server(source).client != old
    assert server(source).reconnect_attempt == 0
  end

  test "failed reconnects follow 500/1000/2000/4000 then stop; discovery cannot bypass", %{
    source: source,
    script: script
  } do
    File.rm!(script)
    GenServer.stop(server(source).client, :normal)
    eventually(fn -> server(source).reconnect_timer != nil end)

    for {delay, attempt} <- Enum.with_index([500, 1_000, 2_000, 4_000], 1) do
      current = server(source)
      assert current.reconnect_attempt == attempt
      assert Process.read_timer(current.reconnect_timer) in 1..delay
      McpSource.discover_tools(source, force_refresh: true)
      assert server(source).reconnect_token == current.reconnect_token
      trigger_retry(source)
    end

    current = server(source)
    assert current.unavailable
    assert current.last_error == "server unavailable: reconnect exhausted"
    assert current.reconnect_timer == nil
  end

  test "six crashes within thirty seconds open a redacted breaker; explicit refresh resets it", %{
    source: source
  } do
    for _ <- 1..5 do
      GenServer.stop(server(source).client, :normal)
      eventually(fn -> server(source).reconnect_timer != nil end)
      trigger_retry(source)
      assert server(source).connected
    end

    GenServer.stop(server(source).client, :normal)
    eventually(fn -> server(source).unavailable end)
    assert server(source).last_error == "server unavailable: crash storm"
    assert server(source).reconnect_timer == nil
    McpSource.discover_tools(source, force_refresh: true)
    refute server(source).connected
    assert :ok = McpSource.refresh(source)
    assert server(source).connected
    assert server(source).crashes == []
  end

  test "obsolete connection notifications and reconnect timers cannot revive or refresh servers",
       %{source: source} do
    [{name, before}] = :sys.get_state(source).servers |> Map.to_list()

    send(
      source,
      {:mcp_notification, name, make_ref(), %{method: "notifications/tools/list_changed"}}
    )

    send(source, {:mcp_reconnect, name, make_ref()})
    assert server(source).client == before.client
    assert server(source).notification_token == before.notification_token
  end

  defp trigger_retry(source) do
    [{name, current}] = :sys.get_state(source).servers |> Map.to_list()
    Process.cancel_timer(current.reconnect_timer)
    send(source, {:mcp_reconnect, name, current.reconnect_token})
    :sys.get_state(source)
  end

  defp server(source), do: :sys.get_state(source).servers |> Map.values() |> hd()
  defp eventually(fun, remaining \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    unless fun.() do
      Process.sleep(20)
      eventually(fun, remaining - 1)
    end
  end

  defp fixture do
    ~S'''
    defmodule LifecycleFixture do
      def run, do: IO.stream(:stdio, :line) |> Enum.each(fn line -> handle(:json.decode(String.trim(line))) end)
      defp handle(%{"method" => "initialize", "id" => id}) do
        reply(id, %{"protocolVersion" => "2024-11-05", "capabilities" => %{"tools" => %{}, "resources" => %{}, "prompts" => %{}}, "serverInfo" => %{"name" => "fixture", "version" => "1"}})
      end
      defp handle(%{"method" => "tools/list", "id" => id}) do
        tools = [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}] ++ Enum.map(items(), &%{"name" => "extra#{&1}", "inputSchema" => %{"type" => "object"}})
        reply(id, %{"tools" => tools})
      end
      defp handle(%{"method" => "resources/list", "id" => id}), do: reply(id, %{"resources" => Enum.map(items(), &%{"uri" => "fixture://#{&1}", "name" => "resource#{&1}"})})
      defp handle(%{"method" => "prompts/list", "id" => id}), do: reply(id, %{"prompts" => Enum.map(items(), &%{"name" => "prompt#{&1}"})})
      defp handle(%{"method" => "tools/call", "id" => id, "params" => params}) do
        Process.put(:generation, Process.get(:generation, 0) + 1)
        reply(id, %{"content" => [%{"type" => "text", "text" => "updated"}]})
        kind = get_in(params, ["arguments", "kind"])
        IO.write([:json.encode(%{"jsonrpc" => "2.0", "method" => "notifications/#{kind}/list_changed"}), "\n"])
      end
      defp handle(_), do: :ok
      defp items, do: Enum.to_list(0..Process.get(:generation, 0))
      defp reply(id, result), do: IO.write([:json.encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result}), "\n"])
    end
    LifecycleFixture.run()
    '''
  end
end
