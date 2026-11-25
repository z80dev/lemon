defmodule CodingAgent.Executor.ProfileExecutionTest.HttpFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn |> Plug.Conn.assign(:owner, Keyword.fetch!(opts, :owner)) |> super(opts)
  end

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    send(conn.assigns.owner, {:mcp_request, request["method"], Map.new(conn.req_headers)})

    if Map.has_key?(request, "id") do
      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "Profile Fixture", "version" => "1.0"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "echo",
                  "description" => "Profile echo",
                  "inputSchema" => %{"type" => "object"}
                }
              ]
            }

          "tools/call" ->
            %{"content" => [%{"type" => "text", "text" => "profile-tool-result"}]}
        end

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("mcp-session-id", "profile-fixture")
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
end

defmodule CodingAgent.Executor.ProfileExecutionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.Executor
  alias CodingAgent.Session
  alias LemonAi.Types.{AssistantMessage, Cost, TextContent, Usage}
  alias LemonCore.ExecutionCommand
  alias LemonSkills.{McpSession, McpSource}

  defmodule PaneBackend do
    @behaviour LemonBrowser.Backend
    def id, do: :native_pane_binding_test
    def available?, do: true
    def status(_opts), do: %{available: true}

    def request("browser.tabs", _args, _timeout_ms, opts) do
      send(self(), {:native_browser_binding, Keyword.get(opts, :tern_pane)})
      {:ok, %{"tabs" => []}}
    end
  end

  setup do
    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_disabled = Application.get_env(:lemon_skills, :mcp_disabled)
    previous_env = System.get_env("LEMON_MCP_DISABLED")
    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.delete_env("LEMON_MCP_DISABLED")

    on_exit(fn ->
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_skills, :mcp_disabled, previous_disabled)

      if previous_env,
        do: System.put_env("LEMON_MCP_DISABLED", previous_env),
        else: System.delete_env("LEMON_MCP_DISABLED")
    end)

    :ok
  end

  @tag :tmp_dir
  test "native runs thread the pane to browser requests and do not inherit it on resume", %{
    tmp_dir: root
  } do
    config = Path.join(root, "pane-config.toml")
    File.write!(config, "")

    Application.put_env(
      :lemon_core,
      :paths,
      global_config: config,
      home_state_dir: Path.join(root, "state")
    )

    assert :ok = LemonBrowser.BackendRegistry.register(:native_pane_binding_test, PaneBackend)
    on_exit(fn -> LemonBrowser.BackendRegistry.unregister(:native_pane_binding_test) end)
    parent = self()
    session_key = "agent:pane-binding:main"

    Enum.reduce([42, nil], nil, fn pane, resume ->
      run_id = "pane-binding-#{System.unique_integer([:positive])}"
      meta = %{model: "openai:gpt-4o", resume_source: :explicit}
      meta = if is_nil(pane), do: meta, else: Map.put(meta, :tern_pane, pane)

      request = %ExecutionCommand{
        run_id: run_id,
        session_key: session_key,
        cwd: root,
        prompt: "Inspect this browser.",
        resume: resume,
        meta: meta
      }

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = LemonAi.EventStream.start_link()
        send(parent, {:pane_stream, run_id, stream})
        {:ok, stream}
      end

      assert {:ok, run_ref, %{runner_pid: runner}} =
               Executor.start_run(request, %{stream_fn: stream_fn}, self())

      on_exit(fn -> CodingAgent.Session.Presentation.safe_stop_session(runner) end)
      assert_receive {:pane_stream, ^run_id, stream}, 5_000
      session = :sys.get_state(runner).session
      on_exit(fn -> CodingAgent.Session.Presentation.safe_stop_session(session) end)
      state = Session.get_state(session)
      assert Keyword.get(state.tool_opts, :tern_pane) == pane
      session_id = state.session_manager.header.id

      assert {:error, :already_streaming} = Session.reload_extensions(session)
      state = Session.get_state(session)
      assert Keyword.get(state.tool_opts, :tern_pane) == pane

      tool =
        CodingAgent.Tools.BrowserTabs.tool(
          root,
          Keyword.put(state.tool_opts, :browser_backend, :native_pane_binding_test)
        )

      assert %LemonAgent.Types.AgentToolResult{} = tool.execute.("tabs", %{}, nil, nil)
      assert_received {:native_browser_binding, ^pane}

      runner_ref = Process.monitor(runner)
      response = response()
      LemonAi.EventStream.push(stream, {:done, :stop, response})
      LemonAi.EventStream.complete(stream, response)
      collect_completed(run_ref)
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 5_000
      LemonCore.ResumeToken.new("lemon", session_id)
    end)
  end

  @tag :tmp_dir
  test "HTTP profile tools transmit headers, redact inventory and close with their owner", %{
    tmp_dir: root
  } do
    url = fixture_url(self())

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    id = "http-profile-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      McpSession.close(id)
      send(owner, :stop)
    end)

    headers = %{"Authorization" => "Bearer profile-only-secret", "X-Bot" => "writer"}

    log =
      capture_log(fn ->
        assert :ok =
                 McpSession.open_http(
                   id,
                   root,
                   [%{name: "profile", url: url, headers: headers}],
                   owner
                 )
      end)

    refute log =~ "profile-only-secret"

    assert_receive {:mcp_request, "initialize",
                    %{"authorization" => "Bearer profile-only-secret"}},
                   5_000

    assert_receive {:mcp_request, "tools/list", %{"x-bot" => "writer"}}, 5_000
    [tool] = McpSession.tools(id)
    assert {:ok, result} = tool.execute.("echo", %{}, nil, nil)
    assert Enum.map_join(result.content, "", & &1.text) == "profile-tool-result"

    assert_receive {:mcp_request, "tools/call",
                    %{"authorization" => "Bearer profile-only-secret"}},
                   5_000

    source = :sys.get_state(McpSession)[id].source
    inventory = McpSource.inventory(source, [])
    assert %{loaded: true, servers: [%{connected: true}]} = inventory
    refute inspect(inventory) =~ "profile-only-secret"
    refute inspect(GenServer.call(source, :status)) =~ "profile-only-secret"

    session =
      start_supervised!(
        {Session,
         cwd: root,
         workspace_dir: Path.join(root, "workspace"),
         model: "openai:gpt-4o",
         mcp_session_id: id,
         tool_disclosure: [enabled: false]}
      )

    assert Enum.any?(Session.get_state(session).tools, &(&1.name == tool.name))
    assert {:ok, _report} = Session.reload_extensions(session)
    assert Session.get_state(session).mcp_session_id == id
    assert Enum.any?(Session.get_state(session).tools, &(&1.name == tool.name))
    clients = :sys.get_state(source).servers |> Map.values() |> Enum.map(& &1.client)
    refs = Enum.map([source | clients], &{Process.monitor(&1), &1})
    send(owner, :stop)
    Enum.each(refs, fn {ref, pid} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000 end)
    assert McpSession.tools(id) == []
    assert {:error, :not_connected} = tool.execute.("stale", %{}, nil, nil)
  end

  @tag :tmp_dir
  test "malformed profile HTTP definitions return classified errors without secrets", %{
    tmp_dir: root
  } do
    id = "bad-profile-#{System.unique_integer([:positive])}"

    assert {:error, :invalid_config} =
             McpSession.open_http(
               id,
               root,
               [
                 %{
                   "name" => "bad",
                   "url" => "ftp://invalid",
                   "headers" => %{"Authorization" => "secret"}
                 }
               ],
               self()
             )

    assert McpSession.tools(id) == []
  end

  @tag :tmp_dir
  test "missing native history never opens profile connections", %{tmp_dir: root} do
    url = fixture_url(self())
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)
    before = :sys.get_state(McpSession) |> Map.keys() |> Enum.sort()

    request = %ExecutionCommand{
      run_id: "profile-startup-failure",
      session_key: "agent:writer:task-failure",
      prompt: "This turn must not start.",
      cwd: root,
      resume: LemonCore.ResumeToken.new("lemon", "missing-profile-session"),
      meta: %{
        resume_source: :explicit,
        mcp_servers: [
          %{name: "profile", url: url, headers: %{"Authorization" => "Bearer failure-secret"}}
        ]
      }
    }

    assert {:error, {:resume_session_missing, "missing-profile-session"}} =
             CodingAgent.Executor.SessionRunner.start_link(
               request: request,
               sink_pid: self(),
               run_ref: make_ref()
             )

    refute_received {:mcp_request, "initialize", _headers}

    assert :sys.get_state(McpSession) |> Map.keys() |> Enum.sort() == before
    Process.flag(:trap_exit, previous_trap_exit)
  end

  @tag :tmp_dir
  test "missing destination secret never falls back to environment or attaches clients", %{
    tmp_dir: root
  } do
    name = prepare_secret_store()
    System.put_env(name, "environment-is-not-the-store")
    on_exit(fn -> System.delete_env(name) end)
    url = fixture_url(self())
    id = "missing-secret-#{System.unique_integer([:positive])}"

    definition = %{
      "name" => "profile",
      "url" => url,
      "headers" => %{"Authorization" => "${LEMON_SECRET:#{name}}"}
    }

    before = :sys.get_state(McpSession)

    assert {:error, :not_found} = LemonCore.Secrets.get(name)

    log =
      capture_log(fn ->
        assert {:error, :secret_resolution_failed} =
                 McpSession.open_http(id, root, [definition], self())
      end)

    assert :sys.get_state(McpSession) == before
    assert McpSession.tools(id) == []
    refute_receive {:mcp_request, _, _}, 50
    refute log =~ "environment-is-not-the-store"
    refute log =~ name
  end

  @tag :tmp_dir
  test "failing encrypted destination read and malformed references fail closed", %{tmp_dir: root} do
    name = prepare_secret_store()
    assert {:ok, _} = LemonCore.Secrets.set(name, "never-expose-this-value")
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    assert {:error, _} = LemonCore.Secrets.get(name)
    url = fixture_url(self())
    id = "failed-secret-#{System.unique_integer([:positive])}"
    before = :sys.get_state(McpSession)

    for header <- ["${LEMON_SECRET:#{name}}", "${LEMON_SECRET:}", "${LEMON_SECRET:unterminated"] do
      definition = %{name: "profile", url: url, headers: %{"Authorization" => header}}

      log =
        capture_log(fn ->
          assert {:error, :secret_resolution_failed} =
                   McpSession.open_http(id, root, [definition], self())
        end)

      refute log =~ "never-expose-this-value"
      refute log =~ name
    end

    assert :sys.get_state(McpSession) == before
    assert McpSession.tools(id) == []
    refute_receive {:mcp_request, _, _}, 50
  end

  @tag :tmp_dir
  test "profile sessions never inherit machine-global MCP credentials, including after reload", %{
    tmp_dir: root
  } do
    url = fixture_url(self())
    previous_servers = Application.get_env(:lemon_skills, :mcp_servers)
    previous_env = System.get_env("LEMON_MCP_SERVERS")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    previous_source_disabled = :sys.get_state(McpSource).disabled
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "isolated-agent"))
    :sys.replace_state(McpSource, &%{&1 | disabled: false})
    System.delete_env("LEMON_MCP_SERVERS")

    Application.put_env(:lemon_skills, :mcp_servers, [
      {:http, url,
       [name: "ambient-owner", headers: [{"Authorization", "Bearer ambient-owner-token"}]]}
    ])

    Application.put_env(:lemon_core, :paths, home_state_dir: Path.join(root, "destination-state"))

    on_exit(fn ->
      restore_env(:lemon_skills, :mcp_servers, previous_servers)

      if previous_env,
        do: System.put_env("LEMON_MCP_SERVERS", previous_env),
        else: System.delete_env("LEMON_MCP_SERVERS")

      if previous_agent_dir,
        do: System.put_env("LEMON_AGENT_DIR", previous_agent_dir),
        else: System.delete_env("LEMON_AGENT_DIR")

      :sys.replace_state(McpSource, fn state ->
        %{state | scopes: Map.delete(state.scopes, Path.expand(root)), disabled: false}
      end)

      McpSource.refresh()
      :sys.replace_state(McpSource, &%{&1 | disabled: previous_source_disabled})
    end)

    McpSource.refresh()
    [ambient] = McpSource.discover_tools(cwd: root)

    assert_receive {:mcp_request, "initialize",
                    %{"authorization" => "Bearer ambient-owner-token"}},
                   5_000

    assert {:ok, _} =
             CodingAgent.ToolRegistry.get_tool(root, ambient.name, include_extensions: false)

    {:ok, %{"workspace" => workspace}} = LemonCore.ProfileStore.paths("principal")

    no_connectors =
      start_supervised!(
        {Session,
         cwd: root,
         workspace_dir: workspace,
         agent_id: "principal",
         model: "openai:gpt-4o",
         tool_disclosure: [enabled: false]},
        id: :profile_without_connectors
      )

    refute Enum.any?(Session.get_state(no_connectors).tools, &(&1.name == ambient.name))
    assert {:ok, _} = Session.reload_extensions(no_connectors)
    refute Enum.any?(Session.get_state(no_connectors).tools, &(&1.name == ambient.name))

    assert {:error, :not_found} =
             CodingAgent.ToolRegistry.get_tool(root, ambient.name,
               include_extensions: false,
               workspace_dir: workspace,
               agent_id: "principal"
             )

    id = "principal-mcp-#{System.unique_integer([:positive])}"
    on_exit(fn -> McpSession.close(id) end)

    assert :ok =
             McpSession.open_http(
               id,
               root,
               [
                 %{
                   name: "principal",
                   url: url,
                   headers: %{"Authorization" => "Bearer caller-only-token"}
                 }
               ],
               self()
             )

    [caller] = McpSession.tools(id)

    replacement =
      start_supervised!(
        {Session,
         cwd: root,
         workspace_dir: workspace,
         agent_id: "principal",
         model: "openai:gpt-4o",
         mcp_session_id: id,
         tool_disclosure: [enabled: false]},
        id: :profile_with_caller_connectors
      )

    names = Enum.map(Session.get_state(replacement).tools, & &1.name)
    assert caller.name in names
    refute ambient.name in names
    assert {:ok, _} = Session.reload_extensions(replacement)
    names = Enum.map(Session.get_state(replacement).tools, & &1.name)
    assert caller.name in names
    refute ambient.name in names
  end

  defp prepare_secret_store do
    previous_config = Application.get_env(:lemon_core, :secrets)
    previous_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    name = "profile-mcp-secret-#{System.unique_integer([:positive])}"
    Application.put_env(:lemon_core, :secrets, key_providers: [:env])
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    # A fresh master key: the store's key verifier and records from earlier
    # tests belong to other keys and correctly refuse writes.
    for {ref, _} <- LemonCore.Store.list(LemonCore.Secrets.table()),
        do: LemonCore.Store.delete(LemonCore.Secrets.table(), ref)

    on_exit(fn ->
      LemonCore.Secrets.delete(name)
      restore_env(:lemon_core, :secrets, previous_config)

      if previous_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", previous_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")
    end)

    name
  end

  defp fixture_url(owner) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.HttpFixture, owner: owner}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp response do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: "profile execution complete"}],
      api: :openai_completions,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{input: 1, output: 1, total_tokens: 2, cost: %Cost{total: 0.0}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp collect_completed(run_ref, events \\ []) do
    receive do
      {:engine_event, ^run_ref, %{__event__: :completed} = event} ->
        Enum.reverse([event | events])

      {:engine_event, ^run_ref, event} ->
        collect_completed(run_ref, [event | events])

      {:engine_delta, ^run_ref, _text} ->
        collect_completed(run_ref, events)
    after
      5_000 -> flunk("profile execution did not complete")
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
