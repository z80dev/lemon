defmodule LemonSkills.McpSourceScopesTest do
  # Project scopes are held by the sessions that discovered them and capped;
  # loading one scope never invalidates another's cache; discovery serves the
  # committed snapshot within a bound, and failing servers back off.
  use ExUnit.Case, async: false

  alias LemonSkills.McpSource

  setup do
    previous = %{
      disabled: Application.fetch_env(:lemon_skills, :mcp_disabled),
      servers: Application.fetch_env(:lemon_skills, :mcp_servers),
      env: System.get_env("LEMON_MCP_DISABLED"),
      servers_env: System.get_env("LEMON_MCP_SERVERS")
    }

    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.delete_env("LEMON_MCP_DISABLED")
    System.delete_env("LEMON_MCP_SERVERS")
    root = Path.join(System.tmp_dir!(), "mcp-scopes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    script = Path.join(root, "server.exs")
    File.write!(script, fixture())

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env(:mcp_disabled, previous.disabled)
      restore_env(:mcp_servers, previous.servers)

      if previous.env,
        do: System.put_env("LEMON_MCP_DISABLED", previous.env),
        else: System.delete_env("LEMON_MCP_DISABLED")

      if previous.servers_env,
        do: System.put_env("LEMON_MCP_SERVERS", previous.servers_env),
        else: System.delete_env("LEMON_MCP_SERVERS")
    end)

    %{root: root, script: script}
  end

  test "ten session cwds keep at most the configured stdio clients and return to baseline",
       ctx do
    configure_stdio_server(ctx)
    baseline = stdio_processes()

    source =
      start_supervised!(
        {McpSource, name: nil, max_project_scopes: 3, refresh_interval_ms: 60_000}
      )

    sessions =
      for n <- 1..10 do
        cwd = project(ctx, "project-#{n}")
        session = start_session(source, cwd)
        assert [%{label: "MCP echo"}] = session_tools(session)
        # At most three project scopes, each with its own stdio client.
        eventually(fn -> length(stdio_clients(source)) <= 3 end)
        session
      end

    # The global scope plus the three most recently used projects.
    assert map_size(:sys.get_state(source).scopes) == 4
    Enum.each(sessions, &send(&1, :close))

    eventually(fn -> map_size(:sys.get_state(source).scopes) == 1 end)
    eventually(fn -> stdio_clients(source) == [] end)
    eventually(fn -> stdio_processes() == baseline end)
  end

  test "a second session opening elsewhere keeps the first session's tool cache", ctx do
    configure_stdio_server(ctx)
    source = start_supervised!({McpSource, name: nil, refresh_interval_ms: 60_000})
    first = project(ctx, "first")
    second = project(ctx, "second")

    session = start_session(source, first)
    assert [%{name: name}] = session_tools(session)
    cached = :sys.get_state(source).tool_cache[name]
    assert lists(ctx, first) == 1

    other = start_session(source, second)
    assert [%{name: other_name}] = session_tools(other)
    assert other_name != name

    state = :sys.get_state(source)
    assert state.tool_cache[name] == cached
    assert lists(ctx, first) == 1
    assert {:ok, _} = McpSource.call_tool(source, name, %{}, [])
    assert lists(ctx, first) == 1
  end

  test "an unreachable server cannot delay discovery past its bound; failures back off" do
    {hanging, _hold} = listener(:hold)
    {failing, attempts} = listener(:fail)

    configs = [
      {:http, "http://127.0.0.1:#{hanging}/mcp", ready_timeout_ms: 30_000, timeout_ms: 30_000},
      {:http, "http://127.0.0.1:#{failing}/mcp", ready_timeout_ms: 2_000, timeout_ms: 2_000}
    ]

    source =
      start_supervised!(
        {McpSource, name: nil, configs: configs, discovery_wait_ms: 300, refresh_interval_ms: 20}
      )

    started = System.monotonic_time(:millisecond)
    assert [] = McpSource.discover_tools(source, [])
    assert System.monotonic_time(:millisecond) - started < 2_000

    # Ticks fire every 20 ms (about 75 in this window) and every discovery
    # re-checks the scope, yet the failing server retries only on its jittered
    # backoff (at least 0.25 s, 0.5 s, then 1 s apart).
    for _ <- 1..10 do
      Process.sleep(150)
      assert [] = McpSource.discover_tools(source, [])
    end

    assert Agent.get(attempts, & &1) in 1..4

    failed =
      :sys.get_state(source).servers
      |> Map.values()
      |> Enum.find(&(&1.config |> elem(1) |> String.contains?("#{failing}")))

    assert failed.reconnect_attempt >= 1
    assert failed.last_error == "connection failed"
    assert failed.reconnect_timer || failed.unavailable
  end

  defp configure_stdio_server(ctx) do
    Application.put_env(:lemon_skills, :mcp_servers, [
      {:stdio, System.find_executable("elixir"), ["--erl", "+S 1:1", ctx.script],
       name: "scoped", env: [{"MCP_SCOPES_LOG", Path.join(ctx.root, "lists.log")}]}
    ])
  end

  defp project(ctx, name) do
    dir = Path.join(ctx.root, name)
    File.mkdir_p!(dir)
    dir
  end

  # A session process holds its scope until it exits.
  defp start_session(source, cwd) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:tools, self(), McpSource.discover_tools(source, cwd: cwd)})

        receive do
          :close -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp session_tools(session) do
    assert_receive {:tools, ^session, tools}, 30_000
    tools
  end

  defp stdio_clients(source) do
    {:links, links} = Process.info(source, :links)
    Enum.filter(links, &(initial_call(&1) == {LemonMCP.Client, :init, 1}))
  end

  defp stdio_processes do
    Enum.count(Process.list(), fn pid ->
      initial_call(pid) in [{LemonMCP.Client, :init, 1}, {LemonMCP.Transport.Stdio, :init, 1}]
    end)
  end

  defp initial_call(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$initial_call")
      nil -> nil
    end
  end

  defp lists(ctx, cwd) do
    case File.read(Path.join(ctx.root, "lists.log")) do
      {:ok, log} -> log |> String.split("\n") |> Enum.count(&(&1 == Path.basename(cwd)))
      {:error, :enoent} -> 0
    end
  end

  # `:hold` accepts and never answers; `:fail` answers every request with 500
  # and counts connections.
  defp listener(mode) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    attempts = start_supervised!({Agent, fn -> 0 end}, id: {:attempts, mode})
    acceptor = spawn(fn -> accept(socket, mode, attempts) end)
    :ok = :gen_tcp.controlling_process(socket, acceptor)
    on_exit(fn -> Process.exit(acceptor, :kill) end)
    {port, attempts}
  end

  defp accept(socket, mode, attempts) do
    case :gen_tcp.accept(socket) do
      {:ok, conn} ->
        Agent.update(attempts, &(&1 + 1))

        if mode == :fail do
          _ = :gen_tcp.recv(conn, 0, 1_000)
          :gen_tcp.send(conn, "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 0\r\n\r\n")
          :gen_tcp.close(conn)
        end

        accept(socket, mode, attempts)

      {:error, _} ->
        :ok
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:lemon_skills, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:lemon_skills, key)

  defp eventually(fun, attempts \\ 250)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp fixture do
    ~S'''
    defmodule ScopesFixture do
      def run, do: IO.stream(:stdio, :line) |> Enum.each(fn line -> handle(:json.decode(String.trim(line))) end)
      defp handle(%{"method" => "initialize", "id" => id}) do
        reply(id, %{"protocolVersion" => "2024-11-05", "capabilities" => %{"tools" => %{}}, "serverInfo" => %{"name" => "scopes", "version" => "1"}})
      end
      defp handle(%{"method" => "tools/list", "id" => id}) do
        File.write!(System.fetch_env!("MCP_SCOPES_LOG"), Path.basename(File.cwd!()) <> "\n", [:append])
        reply(id, %{"tools" => [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}]})
      end
      defp handle(%{"method" => "tools/call", "id" => id}), do: reply(id, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      defp handle(_), do: :ok
      defp reply(id, result), do: IO.write([:json.encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result}), "\n"])
    end
    ScopesFixture.run()
    '''
  end
end
