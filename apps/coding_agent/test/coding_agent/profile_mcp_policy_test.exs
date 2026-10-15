defmodule CodingAgent.ProfileMcpPolicyTest.HTTPFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    Agent.update(conn.assigns.store, &[request | &1])

    result =
      case request["method"] do
        "initialize" ->
          %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "native-policy-fixture", "version" => "1"}
          }

        "tools/list" ->
          %{
            "tools" => [
              %{
                "name" => "lookup",
                "description" => "Lookup fixture",
                "inputSchema" => %{"type" => "object", "properties" => %{}},
                "annotations" => %{"readOnlyHint" => true, "approval" => "never"}
              }
            ]
          }

        "tools/call" ->
          %{"content" => [%{"type" => "text", "text" => "real-http-call"}]}

        _ ->
          nil
      end

    if result do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    else
      send_resp(conn, 202, "")
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
end

defmodule CodingAgent.ProfileMcpPolicyTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Executor.SessionRunner
  alias CodingAgent.{Session, SettingsManager, ToolPolicy, ToolRegistry}
  alias LemonCore.ProfileStore
  alias LemonGateway.ExecutionRequest
  alias LemonSkills.{McpDiscovery, McpSession, McpSource}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_disabled = Application.get_env(:lemon_skills, :mcp_disabled)
    previous_env = System.get_env("LEMON_MCP_DISABLED")

    Application.put_env(:lemon_core, :paths,
      home_state_dir: root,
      global_config: Path.join(root, "config.toml")
    )

    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.delete_env("LEMON_MCP_DISABLED")
    store = start_supervised!({Agent, fn -> [] end})

    bandit =
      start_supervised!(
        {Bandit,
         plug: {CodingAgent.ProfileMcpPolicyTest.HTTPFixture, store: store},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    origin = "http://127.0.0.1:#{port}"

    server = %{
      "name" => "policy-fixture",
      "url" => origin <> "/mcp",
      "headers" => %{},
      "enabledTools" => ["lookup"],
      "allowedOrigins" => [origin],
      "approvedPrivateOrigins" => [origin]
    }

    id = "native-mcp-policy-#{System.unique_integer([:positive])}"
    profile_id = "mcp-policy-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      McpSession.close(id)
      McpSession.close(id <> "-acp")
      restore_app(:lemon_core, :paths, previous_paths)
      restore_app(:lemon_skills, :mcp_disabled, previous_disabled)

      if is_nil(previous_env),
        do: System.delete_env("LEMON_MCP_DISABLED"),
        else: System.put_env("LEMON_MCP_DISABLED", previous_env)
    end)

    assert {:ok, _} = ProfileStore.create(%{id: profile_id, mcpServers: [server]})
    assert {:ok, discovery} = McpDiscovery.discover(server, root)
    [discovered] = discovery["tools"]
    assert discovered["readOnly"]
    assert :ok = McpSession.open_http(id, root, [server], self())
    [tool] = McpSession.tools(id)
    assert tool.name == discovered["executionName"]
    assert McpSession.approvals(id) == %{tool.name => :never}

    %{root: root, id: id, profile_id: profile_id, server: server, name: tool.name, store: store}
  end

  test "native stored deny removes discovered read-only tools from actual registry and Session",
       ctx do
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{toolPolicy: %{"deny" => [ctx.name]}})
    policy = execution_policy(ctx, %{allow: :all, approvals: %{ctx.name => :never}})
    refute ToolPolicy.allowed?(policy, ctx.name)
    opts = registry_opts(ctx, policy, fn _ -> flunk("denied tool cannot request approval") end)
    assert {:error, :not_found} = ToolRegistry.get_tool(ctx.root, ctx.name, opts)
    refute Enum.any?(ToolRegistry.get_tools(ctx.root, opts), &(&1.name == ctx.name))
    session = session(ctx, opts)
    refute Enum.any?(Session.get_state(session).tools, &(&1.name == ctx.name))
    assert calls(ctx) == []
  end

  test "stored require_approval survives incoming never and denied execution makes no HTTP call",
       ctx do
    assert {:ok, _} =
             ProfileStore.update(
               ctx.profile_id,
               %{toolPolicy: %{"require_approval" => [ctx.name]}}
             )

    policy = execution_policy(ctx, %{allow: :all, approvals: %{ctx.name => :never}})
    assert ToolPolicy.requires_approval?(policy, ctx.name)
    observer = self()

    opts =
      registry_opts(ctx, policy, fn request ->
        send(observer, {:approval_checked, request.tool})
        {:ok, :denied}
      end)

    assert {:ok, tool} = ToolRegistry.get_tool(ctx.root, ctx.name, opts)
    result = tool.execute.("registry-denied", %{}, nil, nil)
    assert result.is_error
    assert_receive {:approval_checked, name} when name == ctx.name
    assert calls(ctx) == []

    session = session(ctx, opts)
    tool = Enum.find(Session.get_state(session).tools, &(&1.name == ctx.name))
    assert tool
    result = tool.execute.("session-denied", %{}, nil, nil)
    assert result.is_error
    assert_receive {:approval_checked, name} when name == ctx.name
    assert calls(ctx) == []
  end

  test "explicit stored approvals always require successful approval before a real HTTP execution",
       ctx do
    assert {:ok, _} =
             ProfileStore.update(
               ctx.profile_id,
               %{toolPolicy: %{"approvals" => %{ctx.name => "always"}}}
             )

    policy = execution_policy(ctx, %{allow: :all, approvals: %{ctx.name => :never}})
    assert ToolPolicy.requires_approval?(policy, ctx.name)
    observer = self()

    opts =
      registry_opts(ctx, policy, fn request ->
        send(observer, {:approval_checked, request.tool})
        assert calls(ctx) == []
        {:ok, :approved, :once}
      end)

    session = session(ctx, opts)
    tool = Enum.find(Session.get_state(session).tools, &(&1.name == ctx.name))
    assert {:ok, result} = tool.execute.("session-approved", %{}, nil, nil)
    assert text(result) == "real-http-call"
    assert_receive {:approval_checked, name} when name == ctx.name
    assert length(calls(ctx)) == 1
    assert hd(calls(ctx))["params"]["name"] == "lookup"
  end

  test "explicit native allow and never approval execute real MCP without a blanket profile approval",
       ctx do
    assert {:ok, _} =
             ProfileStore.update(
               ctx.profile_id,
               %{toolPolicy: %{"allow" => [ctx.name], "approvals" => %{ctx.name => "never"}}}
             )

    policy = execution_policy(ctx, %{allow: :all})
    assert ToolPolicy.allowed?(policy, ctx.name)
    refute ToolPolicy.requires_approval?(policy, ctx.name)

    opts =
      registry_opts(ctx, policy, fn _ ->
        flunk("explicitly allowed tool needs no extra MCP approval")
      end)

    assert {:ok, tool} = ToolRegistry.get_tool(ctx.root, ctx.name, opts)
    assert {:ok, result} = tool.execute.("registry-allowed", %{}, nil, nil)
    assert text(result) == "real-http-call"
    session = session(ctx, opts)
    tool = Enum.find(Session.get_state(session).tools, &(&1.name == ctx.name))
    assert {:ok, result} = tool.execute.("session-allowed", %{}, nil, nil)
    assert text(result) == "real-http-call"
    assert length(calls(ctx)) == 2
  end

  test "generic ACP source retains local always approval instead of profile-owned deferral",
       ctx do
    raw = Map.put(ctx.server, "type", "http")
    assert :ok = McpSession.open(ctx.id <> "-acp", ctx.root, [raw], self())
    [legacy] = McpSession.tools(ctx.id <> "-acp")
    assert McpSession.approvals(ctx.id <> "-acp") == %{legacy.name => :always}

    refute legacy.name ==
             McpSource.execution_name(ctx.server["name"], ctx.server["url"], "lookup")

    opts = [
      include_extensions: false,
      acp_mcp_session_id: ctx.id <> "-acp",
      tool_policy: ToolPolicy.custom(allow: [legacy.name], approvals: %{legacy.name => :never}),
      approval_context: %{
        run_id: ctx.id,
        session_key: "agent:test:main",
        approval_request_fun: fn _ -> {:ok, :denied} end
      }
    ]

    assert {:ok, tool} = ToolRegistry.get_tool(ctx.root, legacy.name, opts)
    result = tool.execute.("legacy-denied", %{}, nil, nil)
    assert result.is_error
    assert calls(ctx) == []
  end

  defp execution_policy(ctx, incoming) do
    request = %ExecutionRequest{
      run_id: ctx.id,
      prompt: "Check destination MCP policy",
      session_key: "agent:#{ctx.profile_id}:main",
      tool_policy: incoming,
      meta: %{profile_id: ctx.profile_id, agent_id: ctx.profile_id}
    }

    SessionRunner.execution_tool_policy(request, ctx.root)
  end

  defp registry_opts(ctx, policy, approval_fun),
    do: [
      include_extensions: false,
      mcp_session_id: ctx.id,
      tool_policy: policy,
      approval_context: %{
        run_id: ctx.id,
        session_key: "agent:#{ctx.profile_id}:main",
        approval_request_fun: approval_fun
      }
    ]

  defp session(ctx, opts) do
    model = %LemonAi.Types.Model{
      id: "policy-model",
      name: "Policy model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      context_window: 32_000,
      max_tokens: 1024
    }

    opts =
      Keyword.merge(opts,
        cwd: ctx.root,
        model: model,
        settings_manager: %SettingsManager{},
        agent_id: ctx.profile_id,
        system_prompt: "Policy fixture",
        tool_disclosure: [enabled: false],
        stream_fn: fn _, _, _ -> flunk("tool policy regression must not call a model") end
      )

    start_supervised!(Supervisor.child_spec({Session, opts}, id: make_ref()))
  end

  defp calls(ctx),
    do:
      Agent.get(ctx.store, &Enum.filter(&1, fn request -> request["method"] == "tools/call" end))

  defp text(result), do: Enum.map_join(result.content, "", & &1.text)
  defp restore_app(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app(app, key, value), do: Application.put_env(app, key, value)
end
