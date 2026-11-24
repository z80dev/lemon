defmodule LemonSkills.McpSessionTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{McpSession, McpSource}

  setup do
    disabled = Application.get_env(:lemon_skills, :mcp_disabled)
    disabled_env = System.get_env("LEMON_MCP_DISABLED")
    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.delete_env("LEMON_MCP_DISABLED")
    root = Path.join(System.tmp_dir!(), "mcp-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {physical_root, 0} = System.cmd("pwd", ["-P"], cd: root)
    root = String.trim(physical_root)
    script = Path.join(root, "server.exs")
    File.write!(script, fixture_script())
    id = "mcp-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      McpSession.close(id)
      McpSession.close(id <> "-other")
      File.rm_rf!(root)

      if is_nil(disabled),
        do: Application.delete_env(:lemon_skills, :mcp_disabled),
        else: Application.put_env(:lemon_skills, :mcp_disabled, disabled)

      if is_nil(disabled_env),
        do: System.delete_env("LEMON_MCP_DISABLED"),
        else: System.put_env("LEMON_MCP_DISABLED", disabled_env)
    end)

    %{id: id, root: root, script: script}
  end

  test "missing sessions are empty and close is idempotent", %{id: id} do
    assert McpSession.tools(id) == []
    assert McpSession.approvals(id) == %{}
    assert McpSession.close(id) == :ok
    assert McpSession.close(id) == :ok
  end

  test "validates all definitions before starting or replacing clients", context do
    config = config(context, "first")
    assert :ok = McpSession.open(context.id, context.root, [config], self())
    [tool] = McpSession.tools(context.id)
    children = children()

    for invalid <- [
          %{"name" => "bad", "command" => ""},
          Map.put(config, "args", [1]),
          Map.put(config, "env", [%{"name" => "TOKEN", "value" => 3}]),
          Map.put(config, "headers", [%{"name" => "Authorization"}]),
          Map.put(config, "approval", "maybe"),
          Map.put(config, "tool_approvals", %{"echo" => "maybe"}),
          Map.put(config, "cwd", 42),
          Map.put(config, "sampling", "invalid"),
          Map.put(config, "sampling", %{"mode" => "invalid"}),
          %{
            "type" => "http",
            "name" => "http",
            "url" => "http://127.0.0.1:1",
            "oauth" => %{"client_id" => "missing-secret"}
          },
          %{"type" => "http", "name" => "http", "url" => "ftp://invalid"}
        ] do
      invalid = Map.put(invalid, "name", "invalid")

      assert {:error, :invalid_config} =
               McpSession.open(context.id, context.root, [config, invalid], self())

      assert children() == children
    end

    assert {:ok, result} = tool.execute.("call", %{}, nil, nil)
    assert result.trust == :untrusted
    assert text(result) == "first|#{context.root}"
    assert {:error, :invalid_id} = McpSession.open(nil, context.root, [], self())
    assert {:error, :invalid_owner} = McpSession.open(context.id, context.root, [], nil)
  end

  test "closures and policies stay isolated across sessions and replacement", context do
    first = config(context, "first")

    second =
      config(context, "second")
      |> Map.put("env", %{"MCP_SESSION_VALUE" => "second"})
      |> Map.put("approval", "never")
      |> Map.put("tool_approvals", %{"echo" => "always"})

    assert :ok = McpSession.open(context.id, context.root, [first], self())
    assert :ok = McpSession.open(context.id <> "-other", context.root, [second], self())
    [first_tool] = McpSession.tools(context.id)
    [second_tool] = McpSession.tools(context.id <> "-other")
    assert String.starts_with?(first_tool.name, "mcp_fixture_echo_")
    assert McpSession.approvals(context.id) == %{first_tool.name => :always}
    assert McpSession.approvals(context.id <> "-other") == %{second_tool.name => :always}
    assert {:ok, first_result} = first_tool.execute.("call", %{}, nil, nil)
    assert {:ok, second_result} = second_tool.execute.("call", %{}, nil, nil)
    assert text(first_result) == "first|#{context.root}"
    assert text(second_result) == "second|#{context.root}"

    old_source = source(context.id)
    refs = monitor_source(old_source)
    assert :ok = McpSession.open(context.id, context.root, [second], self())
    assert_down(refs)
    assert {:error, :not_connected} = first_tool.execute.("stale", %{}, nil, nil)
    assert {:ok, result} = second_tool.execute.("other-session", %{}, nil, nil)
    assert text(result) == "second|#{context.root}"
  end

  test "owner death closes every supervised source client", context do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = McpSession.open(context.id, context.root, [config(context, "owner")], owner)
    refs = monitor_source(source(context.id))
    send(owner, :stop)
    assert_down(refs)
    assert McpSession.tools(context.id) == []
    assert McpSession.approvals(context.id) == %{}
  end

  test "close terminates clients and invalidates captured closures", context do
    assert :ok = McpSession.open(context.id, context.root, [config(context, "close")], self())
    [tool] = McpSession.tools(context.id)
    refs = monitor_source(source(context.id))
    assert :ok = McpSession.close(context.id)
    assert_down(refs)
    assert {:error, :not_connected} = tool.execute.("closed", %{}, nil, nil)
  end

  test "unavailable handshakes and failed discovery roll back the entire session", context do
    before = children()
    good = config(context, "good")

    unavailable = %{
      "name" => "missing",
      "command" => Path.join(context.root, "missing"),
      "args" => [],
      "ready_timeout_ms" => 100
    }

    assert {:error, :connection_failed} =
             McpSession.open(context.id, context.root, [good, unavailable], self())

    assert children() == before
    assert McpSession.tools(context.id) == []

    failure = config(context, "discovery-error") |> Map.put("name", "failure")

    assert {:error, :discovery_failed} =
             McpSession.open(context.id, context.root, [good, failure], self())

    assert children() == before
    assert McpSession.tools(context.id) == []
  end

  test "preserves configured working directory and sampling policy", context do
    cwd = Path.join(context.root, "workspace")
    File.mkdir_p!(cwd)

    config =
      config(context, "configured")
      |> Map.put("cwd", "workspace")
      |> Map.put("sampling", %{"mode" => "deny"})

    assert :ok = McpSession.open(context.id, context.root, [config], self())
    [tool] = McpSession.tools(context.id)
    assert {:ok, result} = tool.execute.("cwd", %{}, nil, nil)
    assert text(result) == "configured|#{cwd}"
    [server] = source(context.id) |> :sys.get_state() |> Map.fetch!(:servers) |> Map.values()
    assert {:stdio, _, _, opts} = server.config
    assert opts[:sampling_policy] == [mode: "deny"]
  end

  test "explicit source configurations do not load global servers", context do
    tuple =
      {:stdio, System.find_executable("elixir"), ["--erl", "+S 1:1", context.script],
       name: "isolated", env: [{"MCP_SESSION_VALUE", "direct"}], approval: :never}

    source = start_supervised!({McpSource, name: nil, configs: [tuple], cwd: context.root})
    assert {:ok, [tool]} = McpSource.discover_ready(source)
    assert [^tool] = McpSource.discover_tools(source, [])
    assert McpSource.approval_policy(source) == %{tool.name => :never}
    assert {:ok, result} = McpSource.call_tool(source, tool.name, %{}, [])
    assert text(result) == "direct|#{context.root}"
  end

  test "resource-only servers expose utilities without requesting unsupported tools", context do
    assert :ok =
             McpSession.open(
               context.id,
               context.root,
               [config(context, "resources-only")],
               self()
             )

    tools = McpSession.tools(context.id)
    assert length(tools) == 2
    list = Enum.find(tools, &String.contains?(&1.name, "_resources_list_"))
    assert list
    assert {:ok, result} = list.execute.("resources", %{}, nil, nil)
    assert text(result) =~ "fixture://receipt"
  end

  test "session lookups and source status respond during blocked handshake and discovery",
       context do
    for method <- ["initialize", "tools/list"] do
      {listener, port} = gate_listener()
      config = gated_config(context, port, method)
      owner = self()
      opening = Task.async(fn -> McpSession.open(context.id, context.root, [config], owner) end)
      socket = await_gate(listener, method)
      source = source(context.id)

      assert %{disabled: false, cached_tools: 0} = GenServer.call(source, :status, 1_000)
      assert %{loaded: true} = GenServer.call(source, {:inventory, []}, 1_000)
      assert [] = GenServer.call(McpSession, {:lookup, context.id, :tools}, 1_000)
      assert %{} = GenServer.call(McpSession, {:lookup, context.id, :approvals}, 1_000)
      assert Task.yield(opening, 0) == nil

      assert :ok = :gen_tcp.send(socket, "release\n")
      assert :ok = Task.await(opening, 5_000)
      assert [_] = McpSession.tools(context.id)
      assert :ok = McpSession.close(context.id)
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end
  end

  test "close cancels a blocked attachment and stops its worker and provisional clients",
       context do
    {listener, port} = gate_listener()
    config = gated_config(context, port, "initialize")
    owner = self()
    opening = Task.async(fn -> McpSession.open(context.id, context.root, [config], owner) end)
    socket = await_gate(listener, "initialize")
    source = source(context.id)
    refs = monitor_pending(source)

    assert :ok = McpSession.close(context.id)
    assert {:error, :session_closed} = Task.await(opening, 1_000)
    assert_down(refs)
    assert McpSession.tools(context.id) == []
    :gen_tcp.close(socket)
  end

  test "owner loss during blocked discovery releases the entire pending attachment", context do
    {listener, port} = gate_listener()
    config = gated_config(context, port, "tools/list")

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    opening = Task.async(fn -> McpSession.open(context.id, context.root, [config], owner) end)
    socket = await_gate(listener, "tools/list")
    refs = monitor_pending(source(context.id))

    send(owner, :stop)
    assert {:error, :owner_unavailable} = Task.await(opening, 1_000)
    assert_down(refs)
    assert McpSession.approvals(context.id) == %{}
    :gen_tcp.close(socket)
  end

  test "a discovery deadline answers its caller; status stays responsive and the refresh commits",
       context do
    {listener, port} = gate_listener()

    configs =
      gated_config(context, port, "tools/list")
      |> Map.put("type", "stdio")
      |> LemonSkills.Config.parse_mcp_server_config()

    source = start_supervised!({McpSource, name: nil, configs: configs})
    discovery = Task.async(fn -> McpSource.discover_ready(source) end)
    socket = await_gate(listener, "tools/list")
    [waiter] = :sys.get_state(source).waiters |> Map.keys()

    send(source, {:waiter_timeout, waiter})
    assert {:error, :timeout} = Task.await(discovery, 1_000)
    # Repeated deadlines and stray worker replies are ignored.
    send(source, {:waiter_timeout, waiter})
    send(source, {make_ref(), {:refreshed, {:ok, %{}, %{}}}})
    assert %{cached_tools: 0} = GenServer.call(source, :status, 1_000)
    assert :sys.get_state(source).waiters == %{}

    # The server's own refresh is not tied to the caller and still commits.
    assert :ok = :gen_tcp.send(socket, "release\n")
    eventually(fn -> match?(%{cached_tools: 1}, GenServer.call(source, :status, 1_000)) end)
    :gen_tcp.close(socket)
  end

  test "raw remote discovery cannot block session management or cached source reads", context do
    {listener, port} = gate_listener()
    config = gated_config(context, port, "tools/list", "1")
    assert :ok = McpSession.open(context.id, context.root, [config], self())
    source = source(context.id)
    remote = Task.async(fn -> McpSession.remote_tools(context.id) end)
    socket = await_gate(listener, "tools/list")

    assert [_] = GenServer.call(McpSession, {:lookup, context.id, :tools}, 1_000)
    assert %{cached_tools: 1} = GenServer.call(source, :status, 1_000)
    assert map_size(GenServer.call(source, :approval_policy, 1_000)) == 1
    assert Task.yield(remote, 0) == nil
    assert :ok = :gen_tcp.send(socket, "release\n")
    assert {:ok, [_]} = Task.await(remote, 1_000)
    :gen_tcp.close(socket)
  end

  test "replacement fences a blocked attachment and its late result", context do
    {listener, port} = gate_listener()
    config = gated_config(context, port, "tools/list")
    owner = self()
    opening = Task.async(fn -> McpSession.open(context.id, context.root, [config], owner) end)
    socket = await_gate(listener, "tools/list")
    pending = :sys.get_state(McpSession)[context.id]
    refs = monitor_pending(pending.source)

    assert :ok =
             McpSession.open(context.id, context.root, [config(context, "replacement")], owner)

    assert {:error, :session_closed} = Task.await(opening, 1_000)
    assert_down(refs)
    send(McpSession, {pending.task.ref, {:ok, [:stale], %{}}})
    [tool] = McpSession.tools(context.id)
    assert {:ok, result} = tool.execute.("current", %{}, nil, nil)
    assert text(result) == "replacement|#{context.root}"
    :gen_tcp.close(socket)
  end

  test "abandoning a blocked open cancels the source even while its owner lives", context do
    {listener, port} = gate_listener()
    config = gated_config(context, port, "tools/list")
    owner = self()
    caller = spawn(fn -> McpSession.open(context.id, context.root, [config], owner) end)
    socket = await_gate(listener, "tools/list")
    refs = monitor_pending(source(context.id))

    Process.exit(caller, :kill)
    assert_down(refs)
    assert McpSession.tools(context.id) == []
    :gen_tcp.close(socket)
  end

  test "a dispatched tool deadline is an unknown outcome and leaves status responsive", context do
    {listener, port} = gate_listener()
    config = gated_config(context, port, "tools/call")
    assert :ok = McpSession.open(context.id, context.root, [config], self())
    [tool] = McpSession.tools(context.id)
    source = source(context.id)
    call = Task.async(fn -> McpSource.call_tool(source, tool.name, %{}, timeout_ms: 500) end)
    socket = await_gate(listener, "tools/call")

    assert %{cached_tools: 1} = GenServer.call(source, :status, 1_000)
    assert {:error, :outcome_unknown} = Task.await(call, 2_000)
    assert :sys.get_state(source).invocations == %{}
    assert :ok = :gen_tcp.send(socket, "release\n")
    :gen_tcp.close(socket)
  end

  defp gated_config(context, port, method, after_count \\ "0") do
    config(context, "gated")
    |> Map.put("env", %{
      "MCP_SESSION_VALUE" => "gated",
      "MCP_GATE_PORT" => Integer.to_string(port),
      "MCP_GATE_METHOD" => method,
      "MCP_GATE_AFTER" => after_count
    })
  end

  defp gate_listener do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  defp await_gate(listener, method) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    assert {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    assert data == method <> "\n"
    socket
  end

  defp monitor_pending(source) do
    workers = :sys.get_state(source).workers |> Map.values()
    pids = [source | Enum.flat_map(workers, &[&1.task.pid | Map.keys(&1.clients)])]
    Enum.map(pids, fn pid -> {Process.monitor(pid), pid} end)
  end

  defp eventually(fun, attempts \\ 150) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end

  defp config(context, value) do
    %{
      "name" => "fixture",
      "command" => System.find_executable("elixir"),
      "args" => ["--erl", "+S 1:1", context.script],
      "env" => [%{"name" => "MCP_SESSION_VALUE", "value" => value}]
    }
  end

  defp children do
    DynamicSupervisor.which_children(LemonSkills.McpSession.Supervisor)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
  end

  defp source(id), do: :sys.get_state(McpSession)[id].source

  defp monitor_source(source) do
    clients = :sys.get_state(source).servers |> Map.values() |> Enum.map(& &1.client)
    Enum.map([source | clients], fn pid -> {Process.monitor(pid), pid} end)
  end

  defp assert_down(refs) do
    Enum.each(refs, fn {ref, pid} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000 end)
  end

  defp text(result), do: Enum.map_join(result.content, "", & &1.text)

  defp fixture_script do
    ~S'''
    defmodule SessionFixture do
      def run do
        IO.stream(:stdio, :line)
        |> Enum.each(fn line -> handle(:json.decode(String.trim(line))) end)
      end

      defp handle(%{"method" => "initialize", "id" => id}) do
        pause("initialize")
        capability = if System.get_env("MCP_SESSION_VALUE") == "resources-only", do: "resources", else: "tools"
        respond(id, %{"protocolVersion" => "2024-11-05", "capabilities" => %{capability => %{}},
          "serverInfo" => %{"name" => "session-fixture", "version" => "1.0"}})
      end

      defp handle(%{"method" => "tools/list", "id" => id}) do
        pause("tools/list")
        if System.get_env("MCP_SESSION_VALUE") == "discovery-error" do
          IO.write([:json.encode(%{"jsonrpc" => "2.0", "id" => id,
            "error" => %{"code" => -32603, "message" => "private diagnostic"}}), "\n"])
        else
          respond(id, %{"tools" => [%{"name" => "echo", "description" => "Session echo",
            "inputSchema" => %{"type" => "object"},
            "annotations" => %{"readOnlyHint" => true, "approval" => "never"}}]})
        end
      end

      defp handle(%{"method" => "resources/list", "id" => id}) do
        respond(id, %{"resources" => [%{"uri" => "fixture://receipt", "name" => "receipt"}]})
      end

      defp handle(%{"method" => "tools/call", "id" => id}) do
        pause("tools/call")
        respond(id, %{"content" => [%{"type" => "text",
          "text" => System.get_env("MCP_SESSION_VALUE", "") <> "|" <> File.cwd!()}]})
      end

      defp handle(%{"id" => id}), do: respond(id, %{})
      defp handle(_), do: :ok
      defp pause(method) do
        count = Process.get({:calls, method}, 0)
        Process.put({:calls, method}, count + 1)
        if System.get_env("MCP_GATE_METHOD") == method and
             count == String.to_integer(System.get_env("MCP_GATE_AFTER", "0")) do
          port = String.to_integer(System.fetch_env!("MCP_GATE_PORT"))
          {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
          :ok = :gen_tcp.send(socket, method <> "\n")
          {:ok, _} = :gen_tcp.recv(socket, 0)
          :gen_tcp.close(socket)
        end
      end
      defp respond(id, result), do: IO.write([:json.encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result}), "\n"])
    end
    SessionFixture.run()
    '''
  end
end
