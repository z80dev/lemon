defmodule LemonSkills.McpDiscoveryTest.HTTPFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    headers = Map.new(conn.req_headers)
    store = conn.assigns.store

    state = Agent.get_and_update(store, fn state ->
      {state, %{state | requests: state.requests ++ [{request, headers}]}}
    end)

    if request["method"] == "tools/list" and state.mode == :blocked do
      send(state.observer, {:fixture_blocked, self()})

      receive do
        :release -> :ok
      after
        10_000 -> :ok
      end
    end

    case response(request, headers, state) do
      nil ->
        send_resp(conn, 202, "")

      {:error, message} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"],
          "error" => %{"code" => -32603, "message" => message}}))

      result ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts),
    do: conn |> Plug.Conn.assign(:store, Keyword.fetch!(opts, :store)) |> super(opts)

  defp response(%{"method" => "initialize"}, _headers, _state) do
    %{"protocolVersion" => "2025-06-18", "serverInfo" => %{"name" => "fixture", "version" => "1"},
      "capabilities" => %{"tools" => %{}, "resources" => %{}, "prompts" => %{}}}
  end

  defp response(%{"method" => "notifications/initialized"}, _headers, _state), do: nil

  defp response(%{"method" => "tools/list"}, headers, %{mode: :failure}),
    do: {:error, "private upstream diagnostic " <> Map.get(headers, "authorization", "")}

  defp response(%{"method" => "tools/list"}, headers, state) do
    tools =
      if state.mode == :echo_headers do
        Enum.map(state.tools, fn tool ->
          description = Map.get(headers, "authorization", "") <> " " <>
            Map.get(headers, "x-literal", "") <> " " <> Map.get(headers, "x-fragment", "") <>
            " api_key=sk-fixture-private-value"
          Map.put(tool, "description", description)
        end)
      else
        state.tools
      end

    %{"tools" => tools}
  end

  defp response(%{"method" => "tools/call", "params" => params}, _headers, _state),
    do: %{"content" => [%{"type" => "text", "text" => params["name"]}]}

  defp response(%{"method" => "resources/list"}, _headers, _state),
    do: %{"resources" => [%{"uri" => "fixture://receipt", "name" => "receipt"}]}

  defp response(%{"method" => "prompts/list"}, _headers, _state),
    do: %{"prompts" => [%{"name" => "brief", "description" => "brief"}]}

  defp response(_request, _headers, _state), do: %{}
end

defmodule LemonSkills.McpDiscoveryTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Secrets, Store}
  alias LemonSkills.{McpDiscovery, McpSession, McpSource}

  setup do
    previous_app = Application.get_env(:lemon_skills, :mcp_disabled)
    previous_env = System.get_env("LEMON_MCP_DISABLED")
    previous_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.delete_env("LEMON_MCP_DISABLED")
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env("LEMON_SECRETS_MASTER_KEY", key)
    secret_name = "MCP_DISCOVERY_#{System.unique_integer([:positive])}"
    id = "mcp-http-test-#{System.unique_integer([:positive])}"
    cwd = System.tmp_dir!()

    store = start_supervised!({Agent, fn ->
      %{tools: inventory(), requests: [], mode: :normal, observer: self()}
    end})

    bandit = start_supervised!({Bandit,
      plug: {LemonSkills.McpDiscoveryTest.HTTPFixture, store: store},
      scheme: :http, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    server = %{"name" => "fixture", "url" => "http://127.0.0.1:#{port}/mcp", "headers" => %{}}

    on_exit(fn ->
      McpSession.close(id)
      McpSession.close(id <> "-other")
      Secrets.delete(secret_name)
      System.delete_env(secret_name)
      restore_env("LEMON_MCP_DISABLED", previous_env)
      restore_env("LEMON_SECRETS_MASTER_KEY", previous_key)

      if is_nil(previous_app),
        do: Application.delete_env(:lemon_skills, :mcp_disabled),
        else: Application.put_env(:lemon_skills, :mcp_disabled, previous_app)
    end)

    %{id: id, cwd: cwd, server: server, store: store, secret_name: secret_name, key: key}
  end

  test "discovers raw native names and explicit advisory annotations, closing its temporary session", ctx do
    before = children()
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result == %{
      "connected" => true,
      "server" => %{"name" => "fixture", "status" => "connected"},
      "tools" => [
        projected("echo", true, ctx.server), projected("erase", false, ctx.server),
        projected("literal*", false, ctx.server), projected("resources_list", false, ctx.server)
      ],
      "count" => 4,
      "truncated" => false
    }
    assert children() == before
    assert Jason.decode!(Jason.encode!(result)) == result
    methods = Enum.map(requests(ctx), fn {request, _} -> request["method"] end)
    refute "resources/list" in methods
    refute "prompts/list" in methods
    refute "tools/call" in methods
  end

  test "discovery inventory does not hide tools selected out of executable exposure", ctx do
    for enabled <- [[], ["echo"]] do
      assert {:ok, result} = McpDiscovery.discover(Map.put(ctx.server, "enabledTools", enabled), ctx.cwd)
      assert Enum.map(result["tools"], & &1["name"]) == ["echo", "erase", "literal*", "resources_list"]
    end
  end

  test "discovery execution names exactly match profile runtime names and native policy owns approval", ctx do
    server = Map.put(ctx.server, "enabledTools", ["echo", "erase"])
    assert {:ok, discovery} = McpDiscovery.discover(server, ctx.cwd)
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [server], self())
    tools = McpSession.tools(ctx.id)
    expected = discovery["tools"] |> Enum.filter(&(&1["name"] in ["echo", "erase"]))
      |> Enum.map(& &1["executionName"]) |> Enum.sort()
    assert Enum.map(tools, & &1.name) |> Enum.sort() == expected
    assert McpSession.approvals(ctx.id) == Map.new(tools, &{&1.name, :never})
    assert Enum.all?(expected, &(byte_size(&1) <= 64 and Regex.match?(~r/^[a-z0-9_]+$/, &1)))
  end

  test "profile aliases survive encrypted header rotation and internal destination pin changes", ctx do
    assert {:ok, _} = Secrets.set(ctx.secret_name, "first-private-header")
    server = secret_server(ctx) |> Map.put("enabledTools", ["echo"])
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [server], self())
    [first] = McpSession.tools(ctx.id)
    assert {:ok, _} = Secrets.set(ctx.secret_name, "second-private-header")
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [server], self())
    [second] = McpSession.tools(ctx.id)
    assert second.name == first.name
    assert {:ok, result} = second.execute.("rotated", %{}, nil, nil)
    assert text(result) == "echo"

    source = source(ctx.id)
    # Internal connection identity changes must not change public policy keys.
    # The already-connected owning client remains on its actual fixture socket.
    :sys.replace_state(source, fn state ->
      servers = Map.new(state.servers, fn {name, connected} ->
        {:http, url, opts} = connected.config
        opts = Keyword.put(opts, :destination_pin, %{address: {203, 0, 113, 7}})
        {name, %{connected | config: {:http, url, opts}}}
      end)
      %{state | servers: servers}
    end)
    assert :ok = McpSource.refresh(source)
    [refreshed] = McpSource.discover_tools(source, [])
    assert refreshed.name == first.name
    assert {:ok, discovery} = McpDiscovery.discover(server, ctx.cwd)
    assert Enum.find(discovery["tools"], &(&1["name"] == "echo"))["executionName"] == first.name
  end

  test "public aliases canonicalize origins but distinguish endpoints and exact raw names", ctx do
    name = McpSource.execution_name("fixture", "HTTPS://EXAMPLE.TEST:443/mcp?tenant=one", "echo")
    assert name == McpSource.execution_name("fixture", "https://example.test/mcp?tenant=one", "echo")
    assert name != McpSource.execution_name("fixture", "https://example.test/mcp?tenant=two", "echo")
    assert name != McpSource.execution_name("fixture", "https://example.test/other?tenant=one", "echo")
    assert name != McpSource.execution_name("other", "https://example.test/mcp?tenant=one", "echo")
    assert McpSource.execution_name("fixture", ctx.server["url"], "raw-name") !=
      McpSource.execution_name("fixture", ctx.server["url"], "raw_name")
    assert byte_size(McpSource.execution_name(String.duplicate("s", 128), ctx.server["url"],
      String.duplicate("r", 128))) <= 64
  end

  test "generic ACP-style HTTP attachment retains legacy alias and local always approval", ctx do
    raw = Map.put(ctx.server, "type", "http")
    assert :ok = McpSession.open(ctx.id, ctx.cwd, [raw], self())
    tools = McpSession.tools(ctx.id)
    assert McpSession.approvals(ctx.id) == Map.new(tools, &{&1.name, :always})
    [echo] = Enum.filter(tools, &String.starts_with?(&1.name, "mcp_fixture_echo_"))
    refute echo.name == McpSource.execution_name("fixture", ctx.server["url"], "echo")
    assert {:ok, result} = echo.execute.("legacy", %{}, nil, nil)
    assert text(result) == "echo"
  end

  test "omitted allowlist exposes native tools and existing resource/prompt utilities", ctx do
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [ctx.server], self())
    tools = McpSession.tools(ctx.id)
    assert length(tools) == 8
    assert McpSession.approvals(ctx.id) == Map.new(tools, &{&1.name, :never})
    [echo] = Enum.filter(tools, &String.starts_with?(&1.name, "mcp_fixture_echo_"))
    assert {:ok, result} = echo.execute.("echo", %{}, nil, nil)
    assert text(result) == "echo"
  end

  test "explicit empty allows no tools and direct known published names cannot execute", ctx do
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [ctx.server], self())
    published = McpSession.tools(ctx.id)
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [Map.put(ctx.server, "enabledTools", [])], self())
    source = source(ctx.id)
    assert McpSession.tools(ctx.id) == []
    assert McpSession.approvals(ctx.id) == %{}
    assert :ok = McpSource.refresh(source)
    assert McpSource.discover_tools(source, force_refresh: true) == []

    for tool <- published do
      assert {:error, :not_found} = McpSource.call_tool(source, tool.name, %{}, [])
    end

    refute Enum.any?(requests(ctx), fn {request, _} -> request["method"] == "tools/call" end)
  end

  test "specific allowlist is exact, keeps only native names, and survives registry refresh", ctx do
    server = Map.put(ctx.server, "enabledTools", ["echo", "literal*", "resources_list"])
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [server], self())
    source = source(ctx.id)
    tools = McpSession.tools(ctx.id)
    assert length(tools) == 3
    assert {:ok, raw} = McpSource.remote_tools(source)
    assert length(raw) == 4

    for tool <- tools do
      assert {:ok, result} = McpSource.call_tool(source, tool.name, %{}, [])
      assert text(result) in ["echo", "literal*", "resources_list"]
    end

    for _ <- 1..2 do
      assert :ok = McpSource.refresh(source)
      assert Enum.map(McpSource.discover_tools(source, force_refresh: true), & &1.name) == Enum.map(tools, & &1.name)
    end

    assert :ok = McpSession.open_http(ctx.id <> "-other", ctx.cwd,
      [Map.put(ctx.server, "enabledTools", ["*"])], self())
    assert McpSession.tools(ctx.id <> "-other") == []
  end

  test "cached disabled native and utility entries are rejected at the execution boundary", ctx do
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [ctx.server], self())
    source = source(ctx.id)
    names = Enum.map(McpSession.tools(ctx.id), & &1.name)

    # Exercise the second authorization check, not just removal from listings.
    :sys.replace_state(source, fn state ->
      servers = Map.new(state.servers, fn {name, server} ->
        {:http, url, opts} = server.config
        {name, %{server | config: {:http, url, Keyword.put(opts, :enabled_tools, [])}}}
      end)
      %{state | servers: servers}
    end)

    for name <- names do
      assert {:error, :not_found} = McpSource.call_tool(source, name, %{}, [])
    end

    refute Enum.any?(requests(ctx), fn {request, _} -> request["method"] == "tools/call" end)
  end

  test "encrypted destination secrets reach HTTP but all echoed values are scrubbed", ctx do
    secret = "unlabelled-private-credential-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Secrets.set(ctx.secret_name, secret)
    entry = Store.get(Secrets.table(), {"default", ctx.secret_name})
    refute inspect(entry) =~ secret
    Agent.update(ctx.store, &%{&1 | mode: :echo_headers})
    server = Map.put(ctx.server, "headers", %{
      "Authorization" => "Bearer ${LEMON_SECRET:#{ctx.secret_name}}",
      "X-Literal" => "literal-credential-874",
      "X-Fragment" => "${LEMON_SECRET:#{ctx.secret_name}}"
    })

    assert {:ok, result} = McpDiscovery.discover(server, ctx.cwd)
    assert Enum.any?(requests(ctx), fn {_request, headers} -> headers["authorization"] == "Bearer " <> secret end)
    json = Jason.encode!(result)
    refute json =~ secret
    refute json =~ ctx.secret_name
    refute json =~ "literal-credential-874"
    refute json =~ "sk-fixture-private-value"
    assert json =~ "[REDACTED]"
    assert result["count"] == 4
  end

  test "missing encrypted secret never falls back to the environment or starts clients", ctx do
    System.put_env(ctx.secret_name, "environment-must-not-be-used")
    server = secret_server(ctx)
    before = children()
    assert {:error, :secret_resolution_failed} = McpDiscovery.discover(server, ctx.cwd)
    assert requests(ctx) == []
    assert children() == before
  end

  test "decryption failure fails closed before any HTTP request", ctx do
    assert {:ok, _} = Secrets.set(ctx.secret_name, "encrypted-fixture-value")
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    before = children()
    assert {:error, :secret_resolution_failed} = McpDiscovery.discover(secret_server(ctx), ctx.cwd)
    assert requests(ctx) == []
    assert children() == before
  end

  test "destination policy rejects unapproved private addresses before secret resolution", ctx do
    origin = ctx.server["url"] |> URI.parse() |> Map.put(:path, nil) |> URI.to_string()
    server = secret_server(ctx) |> Map.put("allowedOrigins", [origin])
    before = children()
    assert {:error, :destination_not_public} = McpDiscovery.discover(server, ctx.cwd)
    assert requests(ctx) == []
    assert children() == before
  end

  test "approved private origin and pin reach the destination with encrypted headers", ctx do
    assert {:ok, _} = Secrets.set(ctx.secret_name, "pinned-local-credential")
    origin = ctx.server["url"] |> URI.parse() |> Map.put(:path, nil) |> URI.to_string()
    server = secret_server(ctx)
      |> Map.put("allowedOrigins", [origin])
      |> Map.put("approvedPrivateOrigins", [origin])

    assert {:ok, result} = McpDiscovery.discover(server, ctx.cwd)
    assert result["count"] == 4
    assert Enum.any?(requests(ctx), fn {_request, headers} ->
      headers["authorization"] == "Bearer pinned-local-credential"
    end)
  end

  test "atom-keyed invocation configs preserve an explicit empty allowlist and origin policy", ctx do
    origin = ctx.server["url"] |> URI.parse() |> Map.put(:path, nil) |> URI.to_string()
    server = %{name: "fixture", url: ctx.server["url"], headers: %{}, enabledTools: [],
      allowedOrigins: [origin], approvedPrivateOrigins: [origin]}
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [server], self())
    assert McpSession.tools(ctx.id) == []
    assert {:ok, tools} = McpSession.remote_tools(ctx.id)
    assert length(tools) == 4
  end

  test "invalid definitions and discovery failures return only static classified errors", ctx do
    assert {:error, :invalid_config} = McpDiscovery.discover(Map.put(ctx.server, "url", "file:///private"), ctx.cwd)
    assert {:error, :invalid_config} = McpDiscovery.discover(Map.put(ctx.server, "enabledTools", nil), ctx.cwd)
    assert {:error, :invalid_cwd} = McpDiscovery.discover(ctx.server, "")
    Agent.update(ctx.store, &%{&1 | mode: :failure})
    assert {:ok, _} = Secrets.set(ctx.secret_name, "upstream-private-credential")
    before = children()
    assert {:error, :discovery_failed} = McpDiscovery.discover(secret_server(ctx), ctx.cwd)
    assert children() == before
    Application.put_env(:lemon_skills, :mcp_disabled, true)
    assert {:error, :mcp_disabled} = McpDiscovery.discover(ctx.server, ctx.cwd)
  end

  test "HTTP owner death and close release source and client processes", ctx do
    owner = spawn(fn -> receive do :stop -> :ok end end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [ctx.server], owner)
    refs = monitor_session(ctx.id)
    send(owner, :stop)
    assert_down(refs)
    assert McpSession.tools(ctx.id) == []

    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [ctx.server], self())
    [tool | _] = McpSession.tools(ctx.id)
    refs = monitor_session(ctx.id)
    assert :ok = McpSession.close(ctx.id)
    assert_down(refs)
    assert {:error, :not_connected} = tool.execute.("closed", %{}, nil, nil)
  end

  test "killing a discovery owner during discovery releases its temporary clients", ctx do
    observer = self()
    Agent.update(ctx.store, &%{&1 | mode: :blocked, observer: observer})
    before = children()
    task = Task.async(fn -> McpDiscovery.discover(ctx.server, ctx.cwd) end)
    Process.unlink(task.pid)
    assert_receive {:fixture_blocked, fixture}, 5_000
    [source] = children() -- before
    {:links, links} = Process.info(source, :links)
    pids = [source | Enum.filter(links, &(is_pid(&1) and &1 != Process.whereis(LemonSkills.McpSession.Supervisor)))]
    refs = Enum.map(pids, fn pid -> {Process.monitor(pid), pid} end)
    Process.exit(task.pid, :kill)
    send(fixture, :release)
    assert_down(refs)
    assert children() == before
  end

  test "invalid or oversized schemas and names are skipped without schema modification", ctx do
    schema = %{"type" => "object", "properties" => %{"message" => %{"type" => "string"}}, "required" => ["message"]}
    valid = tool("valid", true) |> Map.put("inputSchema", schema)
    long_desc = tool("description", false) |> Map.put("description", String.duplicate("é", 3000))
    tools = [valid, long_desc,
      tool(String.duplicate("n", 129), false),
      tool("unselectable name", false), tool("unselectable\tname", false),
      tool("unselectable" <> <<127>>, false),
      tool("bad-schema", false) |> Map.put("inputSchema", "not-a-schema"),
      tool("bad-properties", false) |> Map.put("inputSchema", %{"type" => "object", "properties" => []}),
      tool("bad-property-schema", false) |> Map.put("inputSchema", %{"type" => "object", "properties" => %{"x" => 42}}),
      tool("large-schema", false) |> Map.put("inputSchema", %{"type" => "object", "description" => String.duplicate("x", 33_000)})]
    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["count"] == 2
    assert result["truncated"]
    assert hd(result["tools"])["inputSchema"] == schema
    description = Enum.at(result["tools"], 1)["description"]
    assert byte_size(description) <= 4096
    assert String.valid?(description)
  end

  test "credential-bearing raw names are rejected before execution aliases are projected", ctx do
    secret = "raw-name-private-credential"
    assert {:ok, _} = Secrets.set(ctx.secret_name, secret)
    tools = [tool(secret, false), tool("safe", false)]
    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(secret_server(ctx), ctx.cwd)
    assert result["count"] == 1
    assert result["truncated"]
    assert hd(result["tools"])["name"] == "safe"
    refute Jason.encode!(result) =~ secret
  end

  test "credential-bearing configured server labels fail with no secret-bearing DTO or error", ctx do
    secret = "server-label-private-credential"
    assert {:ok, _} = Secrets.set(ctx.secret_name, secret)
    server = secret_server(ctx) |> Map.put("name", secret)
    before = children()
    assert {:error, :discovery_failed} = McpDiscovery.discover(server, ctx.cwd)
    assert children() == before
  end

  test "schema credentials skip the tool rather than corrupt its input schema", ctx do
    secret = "schema-private-credential"
    assert {:ok, _} = Secrets.set(ctx.secret_name, secret)
    tools = [tool("unsafe", false) |> Map.put("inputSchema", %{"type" => "object", "const" => secret}), tool("safe", false)]
    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(secret_server(ctx), ctx.cwd)
    assert result["count"] == 1
    assert result["truncated"]
    assert hd(result["tools"])["name"] == "safe"
    refute Jason.encode!(result) =~ secret
  end

  test "bounds tool count and encoded aggregate without slicing complete schemas", ctx do
    Agent.update(ctx.store, &%{&1 | tools: Enum.map(1..300, fn n -> tool("tool-#{n}", false) end)})
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["count"] == 256
    assert result["truncated"]

    schema = %{"type" => "object", "description" => String.duplicate("s", 24_000)}
    tools = Enum.map(1..70, fn n -> tool("large-#{n}", false) |> Map.put("inputSchema", schema) end)
    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["count"] > 0 and result["count"] < 70
    assert result["truncated"]
    assert byte_size(Jason.encode!(result)) <= 1_048_576
    assert Enum.all?(result["tools"], &(&1["inputSchema"] == schema))
  end

  test "aggregate JSON item budget skips whole tools before transport overflow", ctx do
    schema = %{"type" => "object", "default" => List.duplicate(0, 16_000)}
    tools = Enum.map(1..12, fn n -> tool("dense-#{n}", false) |> Map.put("inputSchema", schema) end)
    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["truncated"]
    assert result["count"] > 0 and result["count"] < 12
    assert Enum.all?(result["tools"], &(&1["inputSchema"] == schema))
    assert byte_size(Jason.encode!(result)) < 1_048_576
    assert {:ok, stats} = LemonCore.JSONPayload.validate(result,
      max_items: 131_072, max_bytes: 1_048_576, max_depth: 32)
    assert stats.item_count <= 131_072

    envelope = %{"jsonrpc" => "2.0", "id" => "discovery", "result" => %{"payload" => result}}
    assert {:ok, _} = LemonCore.JSONPayload.validate(envelope,
      max_items: 131_072, max_bytes: 1_048_640, max_depth: 32)
  end

  test "schema depth leaves room for worker and WebSocket result envelopes", ctx do
    allowed = %{"type" => "object",
      "default" => Enum.reduce(1..23, 0, fn _, nested -> [nested] end)}
    too_deep = %{"type" => "object",
      "default" => Enum.reduce(1..24, 0, fn _, nested -> [nested] end)}
    tools = [tool("within-depth", false) |> Map.put("inputSchema", allowed),
      tool("over-depth", false) |> Map.put("inputSchema", too_deep)]
    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["truncated"]
    assert result["count"] == 1
    assert hd(result["tools"])["name"] == "within-depth"
    assert hd(result["tools"])["inputSchema"] == allowed
    assert {:ok, schema_stats} = LemonCore.JSONPayload.validate(allowed,
      max_depth: 24, max_bytes: 32_768, max_items: 131_072)
    assert schema_stats.depth == 24
    envelope = %{"jsonrpc" => "2.0", "id" => "discovery",
      "result" => %{"payload" => %{"data" => result}}}
    assert {:ok, _} = LemonCore.JSONPayload.validate(envelope,
      max_items: 131_072, max_bytes: 1_048_640, max_depth: 32)
  end

  defp inventory, do: [tool("echo", true), tool("erase", "true"), tool("literal*", false), tool("resources_list", nil)]

  defp tool(name, read_only), do: %{"name" => name, "description" => "Fixture tool",
    "inputSchema" => %{"type" => "object", "properties" => %{}},
    "annotations" => %{"readOnlyHint" => read_only, "approval" => "never"}}

  defp projected(name, read_only, server), do: %{"name" => name, "description" => "Fixture tool",
    "inputSchema" => %{"type" => "object", "properties" => %{}}, "readOnly" => read_only,
    "executionName" => McpSource.execution_name(server["name"], server["url"], name)}

  defp secret_server(ctx), do: Map.put(ctx.server, "headers", %{"Authorization" => "Bearer ${LEMON_SECRET:#{ctx.secret_name}}"})
  defp requests(ctx), do: Agent.get(ctx.store, & &1.requests)
  defp text(result), do: Enum.map_join(result.content, "", & &1.text)
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp children do
    DynamicSupervisor.which_children(LemonSkills.McpSession.Supervisor)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
  end

  defp source(id), do: :sys.get_state(McpSession)[id].source
  defp monitor_session(id), do: monitor_source(source(id))

  defp monitor_source(source) do
    clients = :sys.get_state(source).servers |> Map.values() |> Enum.map(& &1.client) |> Enum.filter(&is_pid/1)
    Enum.map([source | clients], fn pid -> {Process.monitor(pid), pid} end)
  end

  defp assert_down(refs),
    do: Enum.each(refs, fn {ref, pid} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000 end)
end
