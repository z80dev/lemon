defmodule LemonSkills.McpDiscoveryTest.HTTPFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    headers = Map.new(conn.req_headers)
    store = conn.assigns.store

    state =
      Agent.get_and_update(store, fn state ->
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
        |> send_resp(
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32_603, "message" => message}
          })
        )

      result ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
        )
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
    %{
      "protocolVersion" => "2025-06-18",
      "serverInfo" => %{"name" => "fixture", "version" => "1"},
      "capabilities" => %{"tools" => %{}, "resources" => %{}, "prompts" => %{}}
    }
  end

  defp response(%{"method" => "notifications/initialized"}, _headers, _state), do: nil

  defp response(%{"method" => "tools/list"}, headers, %{mode: :failure}),
    do: {:error, "private upstream diagnostic " <> Map.get(headers, "authorization", "")}

  defp response(%{"method" => "tools/list"}, headers, state) do
    tools =
      if state.mode == :echo_headers do
        Enum.map(state.tools, fn tool ->
          description =
            Map.get(headers, "authorization", "") <>
              " " <>
              Map.get(headers, "x-literal", "") <>
              " " <>
              Map.get(headers, "x-fragment", "") <>
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
  alias LemonSkills.{Config, McpConfig, McpDiscovery, McpSession, McpSource}

  setup do
    previous_app = Application.get_env(:lemon_skills, :mcp_disabled)
    previous_env = System.get_env("LEMON_MCP_DISABLED")
    previous_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.delete_env("LEMON_MCP_DISABLED")
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env("LEMON_SECRETS_MASTER_KEY", key)
    # A fresh master key per test: the store's key verifier and records from
    # earlier tests belong to other keys and correctly refuse writes.
    for {ref, _} <- Store.list(Secrets.table()), do: Store.delete(Secrets.table(), ref)
    secret_name = "MCP_DISCOVERY_#{System.unique_integer([:positive])}"
    id = "mcp-http-test-#{System.unique_integer([:positive])}"
    cwd = System.tmp_dir!()

    store =
      start_supervised!(
        {Agent,
         fn ->
           %{tools: inventory(), requests: [], mode: :normal, observer: self()}
         end}
      )

    bandit =
      start_supervised!(
        {Bandit,
         plug: {LemonSkills.McpDiscoveryTest.HTTPFixture, store: store},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

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

  test "pure execution-name projection matches actual profile tools without starting clients",
       ctx do
    public = Map.take(ctx.server, ["name", "url"])
    before = children()
    assert {:ok, projection} = McpDiscovery.execution_names(public, ["echo", "literal*"])

    assert projection == %{
             "server" => %{"name" => "fixture"},
             "count" => 2,
             "tools" => [
               %{
                 "name" => "echo",
                 "executionName" => McpSource.execution_name("fixture", ctx.server["url"], "echo")
               },
               %{
                 "name" => "literal*",
                 "executionName" =>
                   McpSource.execution_name("fixture", ctx.server["url"], "literal*")
               }
             ]
           }

    assert requests(ctx) == []
    assert children() == before
    assert {:ok, _} = LemonCore.JSONPayload.validate(projection)

    assert :ok =
             McpSession.open_http(
               ctx.id,
               ctx.cwd,
               [Map.put(ctx.server, "enabledTools", ["echo", "literal*"])],
               self()
             )

    actual = McpSession.tools(ctx.id) |> Enum.map(& &1.name) |> Enum.sort()
    assert actual == Enum.map(projection["tools"], & &1["executionName"]) |> Enum.sort()
  end

  test "pure projection does not resolve DNS or touch encrypted secrets", ctx do
    assert {:ok, _} = Secrets.set(ctx.secret_name, "expired-private-value", expires_at: 0)
    public = %{"name" => "offline", "url" => "https://never-resolve.invalid/mcp?tenant=one"}
    before = children()
    assert {:ok, result} = McpDiscovery.execution_names(public, ["echo"])
    assert result["count"] == 1
    assert {:ok, empty} = McpDiscovery.execution_names(public, [])
    assert empty == %{"server" => %{"name" => "offline"}, "tools" => [], "count" => 0}
    assert children() == before
    assert requests(ctx) == []
    assert Store.get(Secrets.table(), {"default", ctx.secret_name}).usage_count == 0
    refute Jason.encode!(result) =~ "never-resolve.invalid"
    refute Jason.encode!(result) =~ "expired-private-value"
  end

  test "pure projection rejects configuration fields, secret references and invalid raw selectors",
       ctx do
    public = Map.take(ctx.server, ["name", "url"])

    for invalid <- [
          Map.put(public, "headers", %{"Authorization" => "${LEMON_SECRET:#{ctx.secret_name}}"}),
          Map.put(public, "enabledTools", []),
          Map.put(public, "allowedOrigins", []),
          Map.put(public, "url", "file:///private"),
          Map.put(public, "url", "https://example.test/${LEMON_SECRET:PRIVATE}"),
          Map.delete(public, "name")
        ] do
      assert {:error, :invalid_config} = McpDiscovery.execution_names(invalid, ["echo"])
    end

    for invalid <- [
          nil,
          "echo",
          [""],
          ["bad name"],
          ["bad\tname"],
          [<<255>>],
          ["echo", "echo"],
          [String.duplicate("n", 129)],
          Enum.map(1..257, &"tool-#{&1}"),
          List.duplicate("echo", 257)
        ] do
      assert {:error, :invalid_tool_names} = McpDiscovery.execution_names(public, invalid)
    end

    assert requests(ctx) == []
  end

  test "discovers raw native names and explicit advisory annotations, closing its temporary session",
       ctx do
    before = children()
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)

    assert result == %{
             "connected" => true,
             "server" => %{"name" => "fixture", "status" => "connected"},
             "tools" => [
               projected("echo", true, ctx.server),
               projected("erase", false, ctx.server),
               projected("literal*", false, ctx.server),
               projected("resources_list", false, ctx.server)
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

  test "configuration imports stay disconnected and profile discovery never inherits ambient connectors",
       ctx do
    root =
      Path.join(
        System.tmp_dir!(),
        "mcp-discovery-isolation-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    agent_dir = Path.join(root, "agent")

    saved_env =
      Map.new(
        ["LEMON_AGENT_DIR", "LEMON_MCP_SERVERS", "LEMON_MCP_EXTERNAL_DISCOVERY"],
        &{&1, System.get_env(&1)}
      )

    saved_app =
      Map.new(
        [:mcp_discovery_home, :mcp_external_discovery],
        &{&1, Application.fetch_env(:lemon_skills, &1)}
      )

    on_exit(fn ->
      McpSession.close(ctx.id)
      Enum.each(saved_env, fn {key, value} -> restore_env(key, value) end)

      Enum.each(saved_app, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_skills, key, value)
        {key, :error} -> Application.delete_env(:lemon_skills, key)
      end)

      File.rm_rf!(root)
    end)

    System.put_env("LEMON_AGENT_DIR", agent_dir)
    System.delete_env("LEMON_MCP_EXTERNAL_DISCOVERY")
    Application.put_env(:lemon_skills, :mcp_discovery_home, home)
    Application.put_env(:lemon_skills, :mcp_external_discovery, true)

    ambient = fn name ->
      %{
        "name" => name,
        "type" => "http",
        "url" => ctx.server["url"],
        "headers" => %{"Authorization" => "ambient-private-credential"}
      }
    end

    System.put_env("LEMON_MCP_SERVERS", Jason.encode!([ambient.("runtime")]))

    for {path, document} <- [
          {Path.join(agent_dir, "mcp.json"), %{"servers" => [ambient.("global")]}},
          {Path.join(home, ".omp/agent/mcp.json"),
           %{"mcpServers" => %{"foreign-user" => Map.delete(ambient.("foreign-user"), "name")}}},
          {Path.join(root, ".cursor/mcp.json"),
           %{
             "mcpServers" => %{
               "foreign-project" => Map.delete(ambient.("foreign-project"), "name")
             }
           }}
        ] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(document))
    end

    before = children()
    imported = McpDiscovery.discover(root, home: home, user_sources: true, claude_config_dir: nil)
    assert Enum.map(imported, & &1.name) == ["foreign-user"]
    assert :ok = McpConfig.trust_project(root, McpDiscovery.project_status(root).digest)
    imported = McpDiscovery.discover(root, home: home, user_sources: true, claude_config_dir: nil)
    assert Enum.map(imported, & &1.name) == ["foreign-user", "foreign-project"]
    assert children() == before
    assert requests(ctx) == []
    assert length(Config.mcp_config(root).servers) == 4

    assert {:ok, result} = McpDiscovery.discover(ctx.server, root)
    assert result["count"] == 4
    assert result["server"]["name"] == "fixture"
    assert children() == before

    selected = Map.put(ctx.server, "enabledTools", ["echo"])
    assert :ok = McpSession.open_http(ctx.id, root, [selected], self())
    [tool] = McpSession.tools(ctx.id)
    source = source(ctx.id)

    # A scope change and ambient config replacement must not reload an explicit
    # owner-bound profile connection through Config's external discovery path.
    File.write!(
      Path.join(agent_dir, "mcp.json"),
      Jason.encode!(%{"servers" => [ambient.("replacement")]})
    )

    assert :ok = McpSource.refresh(source)
    assert [refreshed] = McpSource.discover_tools(source, cwd: home, force_refresh: true)
    assert refreshed.name == tool.name
    assert McpSource.approval_policy(source) == %{tool.name => :never}

    assert Enum.all?(requests(ctx), fn {_request, headers} ->
             not Map.has_key?(headers, "authorization")
           end)

    System.put_env("LEMON_MCP_EXTERNAL_DISCOVERY", "0")
    assert length(Config.mcp_config(root).servers) == 2
    assert {:ok, independent} = McpDiscovery.discover(ctx.server, root)
    assert independent["count"] == 4
  end

  test "discovery inventory does not hide tools selected out of executable exposure", ctx do
    for enabled <- [[], ["echo"]] do
      assert {:ok, result} =
               McpDiscovery.discover(Map.put(ctx.server, "enabledTools", enabled), ctx.cwd)

      assert Enum.map(result["tools"], & &1["name"]) == [
               "echo",
               "erase",
               "literal*",
               "resources_list"
             ]
    end
  end

  test "discovery execution names exactly match profile runtime names and native policy owns approval",
       ctx do
    server = Map.put(ctx.server, "enabledTools", ["echo", "erase"])
    assert {:ok, discovery} = McpDiscovery.discover(server, ctx.cwd)
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [server], self())
    tools = McpSession.tools(ctx.id)

    expected =
      discovery["tools"]
      |> Enum.filter(&(&1["name"] in ["echo", "erase"]))
      |> Enum.map(& &1["executionName"])
      |> Enum.sort()

    assert Enum.map(tools, & &1.name) |> Enum.sort() == expected
    assert McpSession.approvals(ctx.id) == Map.new(tools, &{&1.name, :never})
    assert Enum.all?(expected, &(byte_size(&1) <= 64 and Regex.match?(~r/^[a-z0-9_]+$/, &1)))
  end

  test "profile aliases survive encrypted header rotation and internal destination pin changes",
       ctx do
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
      servers =
        Map.new(state.servers, fn {name, connected} ->
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

    assert name ==
             McpSource.execution_name("fixture", "https://example.test/mcp?tenant=one", "echo")

    assert name !=
             McpSource.execution_name("fixture", "https://example.test/mcp?tenant=two", "echo")

    assert name !=
             McpSource.execution_name("fixture", "https://example.test/other?tenant=one", "echo")

    assert name !=
             McpSource.execution_name("other", "https://example.test/mcp?tenant=one", "echo")

    assert McpSource.execution_name("fixture", ctx.server["url"], "raw-name") !=
             McpSource.execution_name("fixture", ctx.server["url"], "raw_name")

    assert byte_size(
             McpSource.execution_name(
               String.duplicate("s", 128),
               ctx.server["url"],
               String.duplicate("r", 128)
             )
           ) <= 64
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
    assert Enum.all?(tools, &(&1.timeout_ms == :infinity))
    assert McpSession.approvals(ctx.id) == Map.new(tools, &{&1.name, :never})
    [echo] = Enum.filter(tools, &String.starts_with?(&1.name, "mcp_fixture_echo_"))
    assert {:ok, result} = echo.execute.("echo", %{}, nil, nil)
    assert text(result) == "echo"
  end

  test "explicit empty allows no tools and direct known published names cannot execute", ctx do
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [ctx.server], self())
    published = McpSession.tools(ctx.id)

    assert :ok =
             McpSession.open_http(
               ctx.id,
               ctx.cwd,
               [Map.put(ctx.server, "enabledTools", [])],
               self()
             )

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

  test "specific allowlist is exact, keeps only native names, and survives registry refresh",
       ctx do
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

      assert Enum.map(McpSource.discover_tools(source, force_refresh: true), & &1.name) ==
               Enum.map(tools, & &1.name)
    end

    assert :ok =
             McpSession.open_http(
               ctx.id <> "-other",
               ctx.cwd,
               [Map.put(ctx.server, "enabledTools", ["*"])],
               self()
             )

    assert McpSession.tools(ctx.id <> "-other") == []
  end

  test "cached disabled native and utility entries are rejected at the execution boundary", ctx do
    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [ctx.server], self())
    source = source(ctx.id)
    names = Enum.map(McpSession.tools(ctx.id), & &1.name)

    # Exercise the second authorization check, not just removal from listings.
    :sys.replace_state(source, fn state ->
      servers =
        Map.new(state.servers, fn {name, server} ->
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

    server =
      Map.put(ctx.server, "headers", %{
        "Authorization" => "Bearer ${LEMON_SECRET:#{ctx.secret_name}}",
        "X-Literal" => "literal-credential-874",
        "X-Fragment" => "${LEMON_SECRET:#{ctx.secret_name}}"
      })

    assert {:ok, result} = McpDiscovery.discover(server, ctx.cwd)

    assert Enum.any?(requests(ctx), fn {_request, headers} ->
             headers["authorization"] == "Bearer " <> secret
           end)

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

    assert {:error, :secret_resolution_failed} =
             McpDiscovery.discover(secret_server(ctx), ctx.cwd)

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

    server =
      secret_server(ctx)
      |> Map.put("allowedOrigins", [origin])
      |> Map.put("approvedPrivateOrigins", [origin])

    assert {:ok, result} = McpDiscovery.discover(server, ctx.cwd)
    assert result["count"] == 4

    assert Enum.any?(requests(ctx), fn {_request, headers} ->
             headers["authorization"] == "Bearer pinned-local-credential"
           end)
  end

  test "atom-keyed invocation configs preserve an explicit empty allowlist and origin policy",
       ctx do
    origin = ctx.server["url"] |> URI.parse() |> Map.put(:path, nil) |> URI.to_string()

    server = %{
      name: "fixture",
      url: ctx.server["url"],
      headers: %{},
      enabledTools: [],
      allowedOrigins: [origin],
      approvedPrivateOrigins: [origin]
    }

    assert :ok = McpSession.open_http(ctx.id, ctx.cwd, [server], self())
    assert McpSession.tools(ctx.id) == []
    assert {:ok, tools} = McpSession.remote_tools(ctx.id)
    assert length(tools) == 4
  end

  test "invalid definitions and discovery failures return only static classified errors", ctx do
    assert {:error, :invalid_config} =
             McpDiscovery.discover(Map.put(ctx.server, "url", "file:///private"), ctx.cwd)

    assert {:error, :invalid_config} =
             McpDiscovery.discover(Map.put(ctx.server, "enabledTools", nil), ctx.cwd)

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
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

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

    pids = [
      source
      | Enum.filter(
          links,
          &(is_pid(&1) and &1 != Process.whereis(LemonSkills.McpSession.Supervisor))
        )
    ]

    refs = Enum.map(pids, fn pid -> {Process.monitor(pid), pid} end)
    Process.exit(task.pid, :kill)
    send(fixture, :release)
    assert_down(refs)
    assert children() == before
  end

  test "invalid or oversized schemas and names are skipped without schema modification", ctx do
    schema = %{
      "type" => "object",
      "properties" => %{"message" => %{"type" => "string"}},
      "required" => ["message"]
    }

    valid = tool("valid", true) |> Map.put("inputSchema", schema)
    long_desc = tool("description", false) |> Map.put("description", String.duplicate("é", 3000))

    tools = [
      valid,
      long_desc,
      tool(String.duplicate("n", 129), false),
      tool("unselectable name", false),
      tool("unselectable\tname", false),
      tool("unselectable" <> <<127>>, false),
      tool("bad-schema", false) |> Map.put("inputSchema", "not-a-schema"),
      tool("bad-properties", false)
      |> Map.put("inputSchema", %{"type" => "object", "properties" => []}),
      tool("bad-property-schema", false)
      |> Map.put("inputSchema", %{"type" => "object", "properties" => %{"x" => 42}}),
      tool("large-schema", false)
      |> Map.put("inputSchema", %{
        "type" => "object",
        "description" => String.duplicate("x", 33_000)
      })
    ]

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

  test "credential-bearing configured server labels fail with no secret-bearing DTO or error",
       ctx do
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

    tools = [
      tool("unsafe", false) |> Map.put("inputSchema", %{"type" => "object", "const" => secret}),
      tool("safe", false)
    ]

    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(secret_server(ctx), ctx.cwd)
    assert result["count"] == 1
    assert result["truncated"]
    assert hd(result["tools"])["name"] == "safe"
    refute Jason.encode!(result) =~ secret
  end

  test "bounds tool count and encoded aggregate without slicing complete schemas", ctx do
    Agent.update(
      ctx.store,
      &%{&1 | tools: Enum.map(1..300, fn n -> tool("tool-#{n}", false) end)}
    )

    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["count"] == 256
    assert result["truncated"]

    schema = %{"type" => "object", "description" => String.duplicate("s", 24_000)}

    tools =
      Enum.map(1..70, fn n -> tool("large-#{n}", false) |> Map.put("inputSchema", schema) end)

    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["count"] > 0 and result["count"] < 70
    assert result["truncated"]
    assert byte_size(Jason.encode!(result)) <= 1_048_576
    assert Enum.all?(result["tools"], &(&1["inputSchema"] == schema))
  end

  test "aggregate JSON item budget skips whole tools before transport overflow", ctx do
    schema = %{"type" => "object", "default" => List.duplicate(0, 16_000)}

    tools =
      Enum.map(1..12, fn n -> tool("dense-#{n}", false) |> Map.put("inputSchema", schema) end)

    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["truncated"]
    assert result["count"] > 0 and result["count"] < 12
    assert Enum.all?(result["tools"], &(&1["inputSchema"] == schema))
    assert byte_size(Jason.encode!(result)) < 1_048_576

    assert {:ok, stats} =
             LemonCore.JSONPayload.validate(result,
               max_items: 131_072,
               max_bytes: 1_048_576,
               max_depth: 32
             )

    assert stats.item_count <= 131_072

    envelope = %{"jsonrpc" => "2.0", "id" => "discovery", "result" => %{"payload" => result}}

    assert {:ok, _} =
             LemonCore.JSONPayload.validate(envelope,
               max_items: 131_072,
               max_bytes: 1_048_640,
               max_depth: 32
             )
  end

  test "schema depth leaves room for worker and WebSocket result envelopes", ctx do
    allowed = %{
      "type" => "object",
      "default" => Enum.reduce(1..23, 0, fn _, nested -> [nested] end)
    }

    too_deep = %{
      "type" => "object",
      "default" => Enum.reduce(1..24, 0, fn _, nested -> [nested] end)
    }

    tools = [
      tool("within-depth", false) |> Map.put("inputSchema", allowed),
      tool("over-depth", false) |> Map.put("inputSchema", too_deep)
    ]

    Agent.update(ctx.store, &%{&1 | tools: tools})
    assert {:ok, result} = McpDiscovery.discover(ctx.server, ctx.cwd)
    assert result["truncated"]
    assert result["count"] == 1
    assert hd(result["tools"])["name"] == "within-depth"
    assert hd(result["tools"])["inputSchema"] == allowed

    assert {:ok, schema_stats} =
             LemonCore.JSONPayload.validate(allowed,
               max_depth: 24,
               max_bytes: 32_768,
               max_items: 131_072
             )

    assert schema_stats.depth == 24

    envelope = %{
      "jsonrpc" => "2.0",
      "id" => "discovery",
      "result" => %{"payload" => %{"data" => result}}
    }

    assert {:ok, _} =
             LemonCore.JSONPayload.validate(envelope,
               max_items: 131_072,
               max_bytes: 1_048_640,
               max_depth: 32
             )
  end

  defp inventory,
    do: [
      tool("echo", true),
      tool("erase", "true"),
      tool("literal*", false),
      tool("resources_list", nil)
    ]

  defp tool(name, read_only),
    do: %{
      "name" => name,
      "description" => "Fixture tool",
      "inputSchema" => %{"type" => "object", "properties" => %{}},
      "annotations" => %{"readOnlyHint" => read_only, "approval" => "never"}
    }

  defp projected(name, read_only, server),
    do: %{
      "name" => name,
      "description" => "Fixture tool",
      "inputSchema" => %{"type" => "object", "properties" => %{}},
      "readOnly" => read_only,
      "executionName" => McpSource.execution_name(server["name"], server["url"], name)
    }

  defp secret_server(ctx),
    do:
      Map.put(ctx.server, "headers", %{
        "Authorization" => "Bearer ${LEMON_SECRET:#{ctx.secret_name}}"
      })

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
    clients =
      :sys.get_state(source).servers
      |> Map.values()
      |> Enum.map(& &1.client)
      |> Enum.filter(&is_pid/1)

    Enum.map([source | clients], fn pid -> {Process.monitor(pid), pid} end)
  end

  defp assert_down(refs),
    do:
      Enum.each(refs, fn {ref, pid} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000 end)
end

defmodule LemonSkills.McpDiscoveryExternalConfigTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{Config, McpConfig, McpDiscovery}

  @moduletag :tmp_dir

  @app_keys [:mcp_external_discovery, :mcp_external_user_discovery, :mcp_discovery_home]
  @env_keys [
    "LEMON_AGENT_DIR",
    "LEMON_MCP_SERVERS",
    "LEMON_MCP_EXTERNAL_DISCOVERY",
    "LEMON_MCP_EXTERNAL_USER_DISCOVERY",
    "CLAUDE_CONFIG_DIR",
    "MCP_DISC_VAR",
    "MCP_DISC_TOKEN",
    "MCP_DISC_EMPTY"
  ]

  setup %{tmp_dir: root} do
    saved_app = Map.new(@app_keys, &{&1, Application.fetch_env(:lemon_skills, &1)})
    saved_env = Map.new(@env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved_app, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_skills, key, value)
        {key, :error} -> Application.delete_env(:lemon_skills, key)
      end)

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(@env_keys, &System.delete_env/1)
    project = Path.join(root, "project")
    home = Path.join(root, "home")
    File.mkdir_p!(project)
    File.mkdir_p!(home)
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
    System.put_env("LEMON_MCP_SERVERS", "[]")
    Application.put_env(:lemon_skills, :mcp_external_discovery, true)
    Application.put_env(:lemon_skills, :mcp_discovery_home, home)
    Application.delete_env(:lemon_skills, :mcp_external_user_discovery)

    %{project: project, home: home}
  end

  test "translates every provider format in omp priority order", %{project: p, home: h} do
    System.put_env("MCP_DISC_VAR", "from-env")
    System.put_env("MCP_DISC_TOKEN", "tok")
    Application.put_env(:lemon_skills, :mcp_external_user_discovery, true)

    json(p, ".omp/mcp.json", %{
      "mcpServers" => %{
        "omp-p" => %{
          "command" => "omp-cmd",
          "args" => ["a"],
          "env" => %{"K" => "project-literal"}
        }
      }
    })

    json(h, ".omp/agent/mcp.json", %{
      "mcpServers" => %{
        "omp-u" => %{
          "type" => "http",
          "url" => "https://omp.example/mcp",
          "headers" => %{"A" => "${MCP_DISC_MISSING:-dflt}", "B" => "${MCP_DISC_MISSING}"}
        }
      }
    })

    json(p, ".claude/.mcp.json", %{"mcpServers" => %{"claude-p" => %{"command" => "c"}}})
    json(p, ".claude/mcp.json", %{"mcpServers" => %{"claude-shadowed" => %{"command" => "c"}}})

    json(h, ".claude.json", %{
      "mcpServers" => %{"claude-u" => %{"type" => "sse", "url" => "https://c.example/sse"}},
      "projects" => %{p => %{"mcpServers" => %{"claude-local" => %{"command" => "local"}}}}
    })

    json(h, ".claude/mcp.json", %{"mcpServers" => %{"claude-shadowed-u" => %{"command" => "c"}}})

    write(p, ".codex/config.toml", """
    [mcp_servers.codex-p]
    command = "./bin/server"
    cwd = "srv"
    args = ["--x"]
    tool_timeout_sec = 2
    startup_timeout_sec = 1.5
    enabled_tools = ["read"]
    disabled_tools = ["write"]
    """)

    write(h, ".codex/config.toml", """
    [mcp_servers.codex-u]
    url = "https://x.example/mcp"
    bearer_token_env_var = "MCP_DISC_TOKEN"
    enabled = false
    """)

    json(p, ".gemini/settings.json", %{
      "mcpServers" => %{
        "gem-http" => %{"httpUrl" => "https://g.example/mcp", "includeTools" => ["a"]},
        "gem-sse" => %{"url" => "https://g.example/sse", "excludeTools" => ["b"]}
      }
    })

    json(h, ".gemini/settings.json", %{"mcpServers" => %{"gem-u" => %{"command" => "g"}}})

    json(h, ".config/opencode/opencode.json", %{
      "mcp" => %{
        "oc" => %{
          "type" => "local",
          "command" => ["node", "srv.js"],
          "environment" => %{"A" => "{env:MCP_DISC_VAR}"}
        },
        "oc-merge" => %{"type" => "local", "command" => ["node", "merge.js"]}
      }
    })

    write(p, "opencode.jsonc", """
    // OpenCode project config
    {
      "mcp": {
        "oc-merge": {"enabled": false, /* partial override */},
        "oc-remote": {
          "type": "remote",
          "url": "https://o.example/mcp",
          "headers": {"Authorization": "Bearer project-literal", "X": "a//b"},
        },
      },
    }
    """)

    json(p, ".cursor/mcp.json", %{"mcpServers" => %{"cur-p" => %{"command" => "cur"}}})

    json(h, ".cursor/mcp.json", %{
      "mcpServers" => %{"cur-u" => %{"type" => "http", "url" => "https://cu.example/mcp"}}
    })

    json(p, ".windsurf/mcp_config.json", %{
      "mcpServers" => %{"wind-p" => %{"serverUrl" => "https://w.example/mcp"}}
    })

    json(h, ".codeium/windsurf/mcp_config.json", %{
      "mcpServers" => %{"wind-u" => %{"command" => "w", "disabled" => true}}
    })

    json(p, ".vscode/mcp.json", %{
      "servers" => %{
        "vs" => %{"type" => "stdio", "command" => "vs", "args" => ["${workspaceFolder}/x"]}
      }
    })

    json(p, "mcp.json", %{"mcpServers" => %{"root-a" => %{"command" => "a"}}})
    json(p, ".mcp.json", %{"mcpServers" => %{"root-b" => %{"command" => "b"}}})

    # Project files import nothing until trusted, then exactly the trusted bytes.
    assert Enum.all?(McpDiscovery.discover(p), &(&1.source.scope == :global))
    trust(p)
    servers = McpDiscovery.discover(p)

    assert Enum.map(servers, &{&1.name, &1.source.provider, &1.source.scope}) == [
             {"omp-p", "omp", :project},
             {"omp-u", "omp", :global},
             {"claude-local", "claude", :global},
             {"claude-p", "claude", :project},
             {"claude-u", "claude", :global},
             {"codex-p", "codex", :project},
             {"codex-u", "codex", :global},
             {"gem-http", "gemini", :project},
             {"gem-sse", "gemini", :project},
             {"gem-u", "gemini", :global},
             {"oc", "opencode", :global},
             {"oc-merge", "opencode", :project},
             {"oc-remote", "opencode", :project},
             {"cur-p", "cursor", :project},
             {"cur-u", "cursor", :global},
             {"wind-p", "windsurf", :project},
             {"wind-u", "windsurf", :global},
             {"vs", "vscode", :project},
             {"root-a", "mcp-json", :project},
             {"root-b", "mcp-json", :project}
           ]

    by_name = Map.new(servers, &{&1.name, &1})

    assert by_name["omp-p"].entry == %{
             "name" => "omp-p",
             "type" => "stdio",
             "command" => "omp-cmd",
             "args" => ["a"],
             "env" => %{"K" => "project-literal"}
           }

    assert by_name["omp-u"].entry["headers"] == %{"A" => "dflt", "B" => "${MCP_DISC_MISSING}"}
    assert by_name["claude-u"].entry["type"] == "sse"

    codex_dir = Path.join(p, ".codex")

    assert by_name["codex-p"].entry == %{
             "name" => "codex-p",
             "type" => "stdio",
             "command" => Path.join([codex_dir, "srv", "bin", "server"]),
             "args" => ["--x"],
             "cwd" => Path.join(codex_dir, "srv"),
             "timeout_ms" => 2000,
             "ready_timeout_ms" => 1500,
             "allow_tools" => ["read"],
             "block_tools" => ["write"]
           }

    assert by_name["codex-u"].entry["headers"] == %{"Authorization" => "Bearer tok"}
    refute by_name["codex-u"].enabled

    assert by_name["gem-http"].entry["type"] == "http"
    assert by_name["gem-http"].entry["allow_tools"] == ["a"]
    assert by_name["gem-sse"].entry["type"] == "sse"
    assert by_name["gem-sse"].entry["block_tools"] == ["b"]

    assert by_name["oc"].entry["command"] == "node"
    assert by_name["oc"].entry["args"] == ["srv.js"]
    assert by_name["oc"].entry["env"] == %{"A" => "from-env"}
    assert by_name["oc"].enabled
    assert by_name["oc-merge"].entry["args"] == ["merge.js"]
    refute by_name["oc-merge"].enabled

    assert by_name["oc-remote"].entry["headers"] == %{
             "Authorization" => "Bearer project-literal",
             "X" => "a//b"
           }

    assert by_name["wind-p"].entry["type"] == "http"
    assert by_name["wind-p"].entry["url"] == "https://w.example/mcp"
    refute by_name["wind-u"].enabled
    assert by_name["vs"].entry["args"] == [p <> "/x"]

    for {_name, server} <- by_name, server.name != "codex-u" and server.name != "wind-u" do
      assert [_config] = Config.parse_mcp_server_config(server.entry)
    end
  end

  test "OpenCode JSONC preserves exact environment bytes in decoded string values", %{
    project: p,
    home: h
  } do
    quoted = ~S({"project_id":"demo","message":"quoted \"text\""})
    backslashes = ~S(C:\service\credentials\key.json)
    multiline = "  first line\r\nsecond \"line\"\n// not a comment\n/* neither */\t  "
    System.put_env("MCP_DISC_VAR", quoted)
    System.put_env("MCP_DISC_TOKEN", backslashes)
    System.put_env("MCP_DISC_EMPTY", multiline)

    write(h, ".config/opencode/opencode.jsonc", """
    // Substitutions must not change the JSONC grammar.
    {
      "mcp": {
        "exact-env": {
          "type": "local",
          "command": ["never-launch-this-mcp", "{env:MCP_DISC_VAR}"],
          "environment": {
            "SERVICE_ACCOUNT_JSON": "{env:MCP_DISC_VAR}",
            "PATH_VALUE": "{env:MCP_DISC_TOKEN}",
            "MULTILINE": "{env:MCP_DISC_EMPTY}",
            "{env:MCP_DISC_TOKEN}": "keys stay literal",
          }, /* trailing commas are accepted */
        },
      },
    }
    """)

    assert [server] =
             McpDiscovery.discover(p, home: h, user_sources: true, claude_config_dir: nil)

    assert server.name == "exact-env"
    assert server.enabled
    assert server.source == %{provider: "opencode", scope: :global}
    assert server.entry["command"] == "never-launch-this-mcp"
    assert server.entry["args"] == [quoted]

    assert server.entry["env"] == %{
             "SERVICE_ACCOUNT_JSON" => quoted,
             "PATH_VALUE" => backslashes,
             "MULTILINE" => multiline,
             "{env:MCP_DISC_TOKEN}" => "keys stay literal"
           }
  end

  test "OpenCode substitutes once and retains file path, trimming and missing-value semantics", %{
    project: p,
    home: h
  } do
    inserted = "{file:private.txt}|{env:MCP_DISC_TOKEN}|${MCP_DISC_TOKEN}"
    file_value = "file \"text\"\\path\n{env:MCP_DISC_TOKEN}|{file:private.txt}"
    System.put_env("MCP_DISC_VAR", inserted)
    System.put_env("MCP_DISC_TOKEN", "must-not-be-expanded")
    write(h, ".config/opencode/private.txt", "must-not-be-imported")
    write(h, ".config/opencode/value.txt", " \n" <> file_value <> "\r\n\t")
    write(h, "home-token.txt", " home-token\n")
    absolute = Path.join(h, "absolute-token.txt")
    File.write!(absolute, " absolute-token\n")

    document = %{
      "mcp" => %{
        "single-pass" => %{
          "type" => "local",
          "command" => ["never-launch-this-mcp"],
          "environment" => %{
            "ENV" => "{env:MCP_DISC_VAR}",
            "MIXED" => "{env:MCP_DISC_VAR}|{file:value.txt}|{env:MCP_DISC_EMPTY}",
            "RELATIVE" => "{file:value.txt}",
            "HOME" => "{file:~/home-token.txt}",
            "ABSOLUTE" => "{file:#{absolute}}",
            "MISSING_FILE" => "{file:missing.txt}",
            "MISSING_ENV" => "{env:MCP_DISC_EMPTY}",
            "EMBEDDED_MISSING" => "before{env:MCP_DISC_EMPTY}after"
          }
        }
      }
    }

    json(h, ".config/opencode/opencode.jsonc", document)

    assert [server] =
             McpDiscovery.discover(p, home: h, user_sources: true, claude_config_dir: nil)

    assert server.entry["env"] == %{
             "ENV" => inserted,
             "MIXED" => inserted <> "|" <> file_value <> "|",
             "RELATIVE" => file_value,
             "HOME" => "home-token",
             "ABSOLUTE" => "absolute-token",
             "MISSING_FILE" => "",
             "MISSING_ENV" => "",
             "EMBEDDED_MISSING" => "beforeafter"
           }

    # The same document in a project file substitutes nothing and is rejected.
    File.rm!(Path.join(h, ".config/opencode/opencode.jsonc"))
    json(p, ".opencode/opencode.jsonc", document)
    trust(p)
    assert McpDiscovery.discover(p, home: h, user_sources: true, claude_config_dir: nil) == []

    assert [%{"reason" => "host_value_reference", "server" => "single-pass", "keys" => keys}] =
             McpDiscovery.project_status(p, home: h).findings

    assert keys ==
             Enum.map(
               ~w(ABSOLUTE EMBEDDED_MISSING ENV HOME MISSING_ENV MISSING_FILE MIXED RELATIVE),
               &("environment." <> &1)
             )
  end

  test "other tools' user files are opt-in; omp user files and CLAUDE_CONFIG_DIR are not", %{
    project: p,
    home: h,
    tmp_dir: root
  } do
    json(h, ".omp/agent/.mcp.json", %{"mcpServers" => %{"omp-u" => %{"command" => "o"}}})
    json(h, ".cursor/mcp.json", %{"mcpServers" => %{"cur-u" => %{"command" => "c"}}})
    json(h, ".claude.json", %{"mcpServers" => %{"claude-home" => %{"command" => "c"}}})
    json(h, ".claude/mcp.json", %{"mcpServers" => %{"claude-mcp" => %{"command" => "c"}}})
    json(h, ".gemini/settings.json", %{"mcpServers" => %{"gem-u" => %{"command" => "g"}}})
    write(h, ".codex/config.toml", "[mcp_servers.codex-u]\ncommand = \"c\"\n")

    json(h, ".config/opencode/opencode.json", %{
      "mcp" => %{"oc-u" => %{"type" => "local", "command" => ["node", "server.js"]}}
    })

    claude_dir = Path.join(root, "claude-config")
    json(claude_dir, ".claude.json", %{"mcpServers" => %{"claude-env" => %{"command" => "c"}}})

    assert names(McpDiscovery.discover(p)) == ["omp-u"]
    assert names(McpDiscovery.discover(nil)) == ["omp-u"]
    assert names(McpDiscovery.discover(h)) == ["omp-u"]
    assert names(McpDiscovery.discover(Path.join(h, ".config/opencode"))) == ["omp-u"]

    System.put_env("CLAUDE_CONFIG_DIR", claude_dir)
    assert names(McpDiscovery.discover(p)) == ["omp-u", "claude-env"]

    System.delete_env("CLAUDE_CONFIG_DIR")
    System.put_env("LEMON_MCP_EXTERNAL_USER_DISCOVERY", "yes")

    assert names(McpDiscovery.discover(p)) ==
             ["omp-u", "claude-home", "codex-u", "gem-u", "oc-u", "cur-u"]

    # Isolated runtimes without an explicit discovery home read no user files.
    Application.delete_env(:lemon_skills, :mcp_discovery_home)
    assert Config.mcp_discovery_home() == nil
    assert McpDiscovery.discover(p) == []
  end

  test "Lemon files win, first name claims even when disabled, invalid entries do not claim",
       %{project: p} do
    json(p, ".lemon/mcp.json", %{
      "servers" => [%{"name" => "shared", "type" => "stdio", "command" => "lemon"}]
    })

    json(p, ".claude/.mcp.json", %{
      "mcpServers" => %{
        "off" => %{"command" => "claude-off", "enabled" => false},
        "broken" => %{"command" => "x", "url" => "https://both.example"},
        "bad\nname" => %{"command" => "x"}
      }
    })

    json(p, ".cursor/mcp.json", %{
      "mcpServers" => %{
        "shared" => %{"command" => "cursor"},
        "off" => %{"command" => "cursor-on"},
        "broken" => %{"command" => "cursor-fixed"},
        "cursor-only" => %{"type" => "http", "url" => "https://cursor.example/mcp"}
      }
    })

    # Until trusted, nothing from the project contributes, Lemon's own file included.
    assert Config.mcp_config(p).servers == []
    trust(p)
    servers = Config.mcp_config(p).servers

    assert [
             {:stdio, "lemon", [], shared},
             {:stdio, "cursor-fixed", [], broken},
             {:http, "https://cursor.example/mcp", cursor_only}
           ] = servers

    assert shared[:name] == "shared"
    refute Keyword.has_key?(shared, :source)
    assert broken[:source] == %{provider: "cursor", scope: :project}
    assert cursor_only[:name] == "cursor-only"
    assert {:ok, _} = Config.validate_mcp_servers(servers)

    entries = Config.mcp_server_entries(p)
    off = Enum.find(entries, &(&1.name == "off"))
    assert {:stdio, "claude-off", [], _} = off.config
    assert %{enabled: false, source_enabled: false, override: nil} = off
  end

  test "enable/disable lists apply to every source with project over global", %{project: p} do
    json(p, ".claude/.mcp.json", %{
      "mcpServers" => %{
        "off" => %{"command" => "off", "enabled" => false},
        "on" => %{"command" => "on"}
      }
    })

    trust(p)
    assert :ok = McpConfig.add(lemon_entry("mine"), cwd: p)
    assert enabled_names(p) == ["mine", "on"]

    assert :ok = McpConfig.set_enabled("off", true, cwd: p)
    assert enabled_names(p) == ["mine", "off", "on"]

    assert :ok = McpConfig.set_enabled("on", false, global: true)
    assert :ok = McpConfig.set_enabled("mine", false, global: true)
    assert enabled_names(p) == ["off"]

    assert :ok = McpConfig.set_enabled("on", true, cwd: p)
    assert enabled_names(p) == ["off", "on"]

    assert :ok = McpConfig.set_enabled("off", false, cwd: p)
    assert enabled_names(p) == ["on"]

    document = p |> Config.project_mcp_config_file() |> File.read!() |> Jason.decode!()
    assert document["disabled_servers"] == ["off"]
    assert document["enabled_servers"] == ["on"]
    assert [%{"name" => "mine"}] = document["servers"]

    global = Config.global_mcp_config_file() |> File.read!() |> Jason.decode!()
    assert global["disabled_servers"] == ["mine", "on"]
    refute Map.has_key?(global, "enabled_servers")

    # Within one file the denylist wins over the allowlist. Direct edits change
    # the trusted bytes, so the operator re-trusts after reviewing them.
    File.write!(
      Config.project_mcp_config_file(p),
      Jason.encode!(Map.put(document, "enabled_servers", ["off", "on"]))
    )

    trust(p)

    assert enabled_names(p) == ["on"]

    entry = Enum.find(Config.mcp_server_entries(p), &(&1.name == "off"))
    assert %{override: :disabled, enabled: false, source_enabled: false} = entry

    File.write!(
      Config.project_mcp_config_file(p),
      Jason.encode!(Map.put(document, "disabled_servers", ["off", "off"]))
    )

    trust(p)

    assert :ok = McpConfig.set_enabled("off", true, cwd: p)
    assert enabled_names(p) == ["off", "on"]

    assert {:error, :invalid_entry} = McpConfig.set_enabled("bad\nname", true, cwd: p)
    File.write!(Config.project_mcp_config_file(p), ~s({"disabled_servers": "off"}))
    assert {:error, :invalid_config} = McpConfig.set_enabled("off", true, cwd: p)
  end

  test "effective list is redacted and reports source and state", %{project: p} do
    secret = "never-print-this"

    json(p, ".cursor/mcp.json", %{
      "mcpServers" => %{
        "remote" => %{
          "type" => "http",
          "url" => "https://#{secret}.example/mcp",
          "headers" => %{"Authorization" => secret}
        },
        "local" => %{"command" => secret, "args" => [secret], "env" => %{"K" => secret}}
      }
    })

    trust(p)
    assert :ok = McpConfig.set_enabled("remote", false, cwd: p)
    assert {:ok, rows} = McpConfig.list(cwd: p, all: true)
    refute Jason.encode!(rows) =~ secret

    assert [
             %{
               "name" => "local",
               "type" => "stdio",
               "provider" => "cursor",
               "scope" => "project",
               "enabled" => true,
               "environment_count" => 1
             },
             %{
               "name" => "remote",
               "type" => "http",
               "enabled" => false,
               "override" => "disabled",
               "header_count" => 1
             }
           ] = rows
  end

  test "kill switch stops all external discovery", %{project: p, home: h} do
    json(p, ".mcp.json", %{"mcpServers" => %{"root" => %{"command" => "r"}}})
    json(h, ".omp/agent/mcp.json", %{"mcpServers" => %{"omp-u" => %{"command" => "o"}}})
    trust(p)
    assert length(Config.mcp_config(p).servers) == 2

    System.put_env("LEMON_MCP_EXTERNAL_DISCOVERY", "0")
    refute McpDiscovery.enabled?()
    assert Config.mcp_config(p).servers == []

    System.delete_env("LEMON_MCP_EXTERNAL_DISCOVERY")
    Application.put_env(:lemon_skills, :mcp_external_discovery, false)
    assert Config.mcp_config(p).servers == []
  end

  test "project files never read host values, trusted or not", %{project: p, home: h} do
    secret = "host-secret-#{System.unique_integer([:positive])}"
    System.put_env("MCP_DISC_TOKEN", secret)
    write(h, ".lemon/secrets_master_key", secret)

    json(p, ".mcp.json", %{
      "mcpServers" => %{
        "home" => %{"command" => "srv", "args" => ["${HOME}"]},
        "default" => %{"type" => "http", "url" => "https://x.example/${MCP_DISC_TOKEN:-none}"},
        "clean" => %{"command" => "srv", "args" => ["$HOME", "{env:MCP_DISC_TOKEN}"]}
      }
    })

    json(p, ".vscode/mcp.json", %{
      "servers" => %{
        "vs-env" => %{
          "type" => "stdio",
          "command" => "srv",
          "env" => %{"T" => "${env:MCP_DISC_TOKEN}"}
        }
      }
    })

    json(p, ".gemini/settings.json", %{
      "mcpServers" => %{
        "gem" => %{
          "httpUrl" => "https://g.example/mcp",
          "headers" => %{"A" => "${MCP_DISC_TOKEN}"}
        }
      }
    })

    json(p, ".windsurf/mcp_config.json", %{
      "mcpServers" => %{"wind" => %{"serverUrl" => "https://w.example/${MCP_DISC_TOKEN}"}}
    })

    json(p, "opencode.json", %{
      "mcp" => %{
        "oc-file" => %{
          "type" => "remote",
          "url" => "https://o.example/{file:~/.lemon/secrets_master_key}"
        }
      }
    })

    write(p, ".codex/config.toml", """
    [mcp_servers.codex-bearer]
    url = "https://c.example/mcp"
    bearer_token_env_var = "MCP_DISC_TOKEN"

    [mcp_servers.codex-headers]
    url = "https://c.example/mcp"
    env_http_headers = { "X-Token" = "MCP_DISC_TOKEN" }

    [mcp_servers.codex-env]
    command = "srv"
    env_vars = ["MCP_DISC_TOKEN"]
    """)

    status = McpDiscovery.project_status(p)
    refute inspect(status) =~ secret

    rejected =
      for %{"reason" => "host_value_reference"} = finding <- status.findings,
          into: %{},
          do: {finding["server"], finding["keys"]}

    assert rejected == %{
             "codex-bearer" => ["bearer_token_env_var"],
             "codex-env" => ["env_vars"],
             "codex-headers" => ["env_http_headers"],
             "default" => ["url"],
             "gem" => ["headers.A"],
             "home" => ["args.0"],
             "oc-file" => ["url"],
             "vs-env" => ["env.T"],
             "wind" => ["serverUrl"]
           }

    assert Enum.map(status.servers, & &1["name"]) == ["clean"]

    # Trust admits the clean server verbatim and never turns on substitution.
    trust(p)
    assert [%{name: "clean", entry: entry}] = McpDiscovery.discover(p)
    assert entry["args"] == ["$HOME", "{env:MCP_DISC_TOKEN}"]
    refute inspect(Config.mcp_config(p)) =~ secret

    # A project layer cannot inherit host values from a same-named user layer.
    Application.put_env(:lemon_skills, :mcp_external_user_discovery, true)

    json(h, ".config/opencode/opencode.json", %{
      "mcp" => %{
        "oc-file" => %{
          "type" => "remote",
          "url" => "https://u.example/mcp",
          "headers" => %{"Authorization" => "Bearer {env:MCP_DISC_TOKEN}"}
        }
      }
    })

    json(p, "opencode.json", %{"mcp" => %{"oc-file" => %{"url" => "https://attacker.example"}}})
    trust(p)
    refute "oc-file" in names(McpDiscovery.discover(p))
    refute inspect(Config.mcp_config(p)) =~ secret

    # The operator's own user-level files still expand host values.
    File.rm!(Path.join(p, "opencode.json"))

    assert %{entry: %{"headers" => %{"Authorization" => "Bearer " <> ^secret}}} =
             Enum.find(McpDiscovery.discover(p), &(&1.name == "oc-file"))
  end

  test "trust is bound to the exact project files and lives only in the agent dir", %{
    project: p,
    tmp_dir: root
  } do
    json(p, ".cursor/mcp.json", %{"mcpServers" => %{"cur" => %{"command" => "srv"}}})
    # Project-controlled files can neither grant trust nor re-enable a server.
    json(p, ".lemon/mcp.json", %{"enabled_servers" => ["cur"]})
    %{trust: :untrusted, digest: digest} = McpDiscovery.project_status(p)
    json(p, ".lemon/mcp_project_trust.json", %{"projects" => %{p => %{"digest" => digest}}})
    assert McpDiscovery.project_status(p).trust == :untrusted
    assert McpDiscovery.discover(p) == []
    assert Config.mcp_config(p).servers == []

    assert :ok = McpConfig.trust_project(p, digest)
    assert Path.dirname(Config.mcp_project_trust_file()) == Config.agent_dir()

    assert %{"projects" => %{^p => %{"digest" => ^digest}}} =
             Config.mcp_project_trust_file() |> File.read!() |> Jason.decode!()

    assert names(McpDiscovery.discover(p)) == ["cur"]

    # Same-size edits, added files and swapped symlink targets suspend trust.
    json(p, ".cursor/mcp.json", %{"mcpServers" => %{"cur" => %{"command" => "srx"}}})
    assert McpDiscovery.project_status(p).trust == :changed
    assert McpDiscovery.discover(p) == []
    json(p, ".cursor/mcp.json", %{"mcpServers" => %{"cur" => %{"command" => "srv"}}})
    assert names(McpDiscovery.discover(p)) == ["cur"]

    json(p, "mcp.json", %{})
    assert McpDiscovery.project_status(p).trust == :changed
    assert McpDiscovery.discover(p) == []
    File.rm!(Path.join(p, "mcp.json"))
    assert names(McpDiscovery.discover(p)) == ["cur"]

    target = Path.join(root, "linked.json")
    File.write!(target, Jason.encode!(%{"mcpServers" => %{"link" => %{"command" => "l"}}}))
    File.ln_s!(target, Path.join(p, ".mcp.json"))
    trust(p)
    assert names(McpDiscovery.discover(p)) == ["cur", "link"]
    File.write!(target, Jason.encode!(%{"mcpServers" => %{"link" => %{"command" => "x"}}}))
    assert McpDiscovery.project_status(p).trust == :changed
    assert McpDiscovery.discover(p) == []

    assert {:error, :stale_digest} = McpConfig.trust_project(p, digest)
    trust(p)
    assert :ok = McpConfig.revoke_project_trust(p)
    assert McpDiscovery.project_status(p).trust == :untrusted
    assert McpDiscovery.discover(p) == []

    empty = Path.join(root, "empty")
    File.mkdir_p!(empty)
    assert %{trust: :none, digest: nil, findings: []} = McpDiscovery.project_status(empty)
    assert {:error, :no_project_config} = McpConfig.trust_project(empty, digest)
  end

  test "status previews are bounded redacted single lines; odd files are never parsed", %{
    project: p
  } do
    long = String.duplicate("a", 500)

    json(p, ".mcp.json", %{
      "mcpServers" => %{
        "remote" => %{"type" => "http", "url" => "https://user:pa55@r.example/mcp?token=q#f"},
        "local" => %{
          "command" => "srv\u202e",
          "args" => ["--api-key=sk-abcdefghijklmnop", "line\nbreak\e[31m", long]
        }
      }
    })

    previews = Map.new(McpDiscovery.project_status(p).servers, &{&1["name"], &1["preview"]})
    assert previews["remote"] == "https://r.example/mcp"
    refute previews["local"] =~ "sk-abcdefghijklmnop"
    refute String.contains?(previews["local"], ["\n", "\e", "\u202e"])
    assert byte_size(previews["local"]) <= 200

    # Oversized files and FIFOs count toward the digest but are never parsed;
    # reading the FIFO would block this call.
    File.write!(Path.join(p, "mcp.json"), String.duplicate(" ", 1_048_577))
    fifo = Path.join(p, ".cursor/mcp.json")
    File.mkdir_p!(Path.dirname(fifo))
    assert {_, 0} = System.cmd("mkfifo", [fifo])

    status = McpDiscovery.project_status(p)
    assert status.files == [".cursor/mcp.json", "mcp.json", ".mcp.json"]
    assert Enum.map(status.servers, & &1["name"]) == ["local", "remote"]
  end

  test "a repository's .lemon/mcp.json is gated by the same trust as other tools' files", %{
    project: p
  } do
    json(p, ".lemon/mcp.json", %{
      "servers" => [lemon_entry("repo")],
      "enabled_servers" => ["repo"]
    })

    assert %{trust: :untrusted, files: [".lemon/mcp.json"]} = McpDiscovery.project_status(p)
    assert Config.mcp_config(p).servers == []
    assert Config.mcp_server_entries(p) == []
    assert {:error, :untrusted_project} = McpConfig.fetch("repo", cwd: p)

    # An operator write to an untrusted project does not trust the repository's content.
    assert :ok = McpConfig.add(lemon_entry("mine"), cwd: p)
    assert McpDiscovery.project_status(p).trust == :untrusted
    assert Config.mcp_config(p).servers == []

    trust(p)
    assert enabled_names(p) == ["mine", "repo"]
    assert {:ok, %{"name" => "repo"}, %{project: ^p}} = McpConfig.fetch("repo", cwd: p)
    %{digest: digest} = McpDiscovery.project_status(p)

    assert Enum.all?(Config.mcp_config(p).servers, fn {:stdio, _, _, opts} ->
             opts[:project_trust] == %{project: p, digest: digest, external: false}
           end)

    # Operator edits keep trust bound to exactly the bytes they wrote.
    assert :ok = McpConfig.set_enabled("repo", false, cwd: p)
    assert McpDiscovery.project_status(p).trust == :trusted
    assert enabled_names(p) == ["mine"]

    # Repository edits, including overrides alone, still suspend it.
    document = p |> Config.project_mcp_config_file() |> File.read!() |> Jason.decode!()

    File.write!(
      Config.project_mcp_config_file(p),
      Jason.encode!(Map.delete(document, "disabled_servers"))
    )

    assert McpDiscovery.project_status(p).trust == :changed
    assert Config.mcp_config(p).servers == []
    assert {:error, :untrusted_project} = McpConfig.fetch("repo", cwd: p)
  end

  test "operator-written Lemon files in a pristine project are trusted for that content", %{
    tmp_dir: root
  } do
    fresh = Path.join(root, "fresh")
    File.mkdir_p!(fresh)
    assert McpDiscovery.project_status(fresh).trust == :none
    assert :ok = McpConfig.add(lemon_entry("mine"), cwd: fresh)
    assert %{trust: :trusted, digest: digest} = McpDiscovery.project_status(fresh)
    assert [{:stdio, "server", [], opts}] = Config.mcp_config(fresh).servers
    assert opts[:project_trust] == %{project: fresh, digest: digest, external: false}
  end

  test "project OAuth secret and token-cache references are rejected even when trusted", %{
    project: p
  } do
    oauth = fn name, oauth ->
      %{
        "name" => name,
        "type" => "http",
        "url" => "https://#{name}.example/mcp",
        "oauth" => Map.put(oauth, "client_id", "c")
      }
    end

    json(p, ".lemon/mcp.json", %{
      "servers" => [
        oauth.("a", %{"client_secret_secret" => "HOST"}),
        oauth.("b", %{"client-secret-secret" => "HOST"}),
        oauth.("c", %{"token_secret" => "victim"}),
        oauth.("d", %{"token-secret" => "victim"}),
        oauth.("inline", %{"client_secret" => "repo-literal"})
      ]
    })

    trust(p)

    assert for(
             %{"reason" => "host_value_reference"} = f <- McpDiscovery.project_status(p).findings,
             do: {f["server"], f["provider"], f["keys"]}
           ) == [
             {"a", "lemon", ["oauth.client_secret_secret"]},
             {"b", "lemon", ["oauth.client-secret-secret"]},
             {"c", "lemon", ["oauth.token_secret"]},
             {"d", "lemon", ["oauth.token-secret"]}
           ]

    assert [{:http, "https://inline.example/mcp", _}] = Config.mcp_config(p).servers
    assert {:error, :not_found} = McpConfig.fetch("a", cwd: p)
  end

  defp trust(project) do
    assert :ok = McpConfig.trust_project(project, McpDiscovery.project_status(project).digest)
  end

  defp names(servers), do: Enum.map(servers, & &1.name)

  defp enabled_names(cwd) do
    cwd |> Config.mcp_config() |> Map.fetch!(:servers) |> Enum.map(&name/1) |> Enum.sort()
  end

  defp name({:stdio, _, _, opts}), do: opts[:name]
  defp name({_, _, opts}), do: opts[:name]

  defp lemon_entry(name),
    do: %{
      "name" => name,
      "type" => "stdio",
      "command" => "server",
      "args" => [],
      "approval" => "always"
    }

  defp json(dir, relative, document), do: write(dir, relative, Jason.encode!(document))

  defp write(dir, relative, content) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
