defmodule LemonRouter.ProfileExecutionTest.HttpFixture do
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

defmodule LemonRouter.ProfileExecutionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.Worker
  alias CodingAgent.Executor
  alias CodingAgent.Executor.RemoteRequestCodec
  alias CodingAgent.Session
  alias LemonAi.Types.{AssistantMessage, Cost, TextContent, Usage}
  alias LemonCore.{InvocationProof, ProfileStore, Secrets, Store}
  alias LemonRouter.RunOrchestrator
  alias LemonSkills.McpSession

  defmodule Coordinator do
    def submit(_key, submission) do
      send(
        Application.fetch_env!(:lemon_router, :profile_execution_consumer_pid),
        {:profile_dispatch, submission.execution_request}
      )

      :ok
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

  test "local and JSON-decoded execution attach persona and MCP without management metadata leaks" do
    root = Path.join(System.tmp_dir!(), "profile-native-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:lemon_core, :paths,
      home_state_dir: Path.join(root, "destination-state"),
      global_config: Path.join(root, "config.toml")
    )

    prepare_admission()
    url = fixture_url(self())
    origin = url |> URI.parse() |> Map.put(:path, nil) |> URI.to_string()
    parent = self()
    secret_name = prepare_secret_store()
    assert {:ok, _} = Secrets.set(secret_name, "runtime-secret")
    literal_name = "LEMON_MCP_LITERAL_#{System.unique_integer([:positive])}"
    literal_secret = secret_name <> "-literal"
    System.put_env(literal_name, "must-not-expand")
    assert {:ok, _} = Secrets.set(literal_secret, "${#{literal_name}}")

    on_exit(fn ->
      Secrets.delete(literal_secret)
      System.delete_env(literal_name)
    end)

    for transport <- [:local, :json] do
      profile_id = "writer-#{transport}-#{System.unique_integer([:positive])}"
      run_id = "profile-execution-#{transport}-#{System.unique_integer([:positive])}"
      proof_secret = "lemon_bot/invocations/" <> run_id
      assert {:ok, _} = Secrets.set(proof_secret, "runtime-secret")

      on_exit(fn ->
        Store.delete(RunOrchestrator.admission_table(), run_id)
        Secrets.delete(proof_secret)
      end)

      template = %{
        "name" => "profile",
        "url" => url,
        "headers" => %{},
        "allowedOrigins" => [origin],
        "approvedPrivateOrigins" => [origin]
      }

      assert {:ok, _} =
               ProfileStore.create(%{
                 "id" => profile_id,
                 "model" => "openai:gpt-4o",
                 "systemPrompt" => "private-profile-system-prompt",
                 "mcpServers" => [template]
               })

      assert {:ok, profile} = ProfileStore.get_for_execution(profile_id)
      workspace = profile["paths"]["workspace"]
      File.write!(Path.join(workspace, "SOUL.md"), "private-profile-soul")
      File.write!(Path.join(workspace, "README.md"), "private-profile-job")

      servers = [
        %{
          template
          | "headers" => %{
              "Authorization" => "Bearer ${LEMON_SECRET:#{secret_name}}",
              "X-Literal" => "${LEMON_SECRET:#{literal_secret}}",
              "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:#{proof_secret}}"
            }
        }
      ]

      assert {:ok, request} =
               ProfileStore.chat_request(
                 profile,
                 "Exercise the profile execution contract.",
                 run_id: run_id,
                 invocation_mcp_servers: servers
               )

      assert {:ok, request} =
               InvocationProof.attach_execution_context(request, %{
                 "runId" => run_id,
                 "invocationContextKey" => "profile-client-#{transport}",
                 "memoryContextKey" => "profile-memory-#{transport}",
                 "sharedMemoryGrant" => false,
                 "invocationProof" => %{
                   "runId" => run_id,
                   "serverName" => "profile",
                   "serverUrl" => url,
                   "headerName" => "X-Lemon-Bot-Invocation",
                   "secretName" => proof_secret
                 }
               })

      assert {:ok, ^run_id} = RunOrchestrator.submit(request)
      assert_receive {:profile_dispatch, command}
      request = command

      context_result =
        case request.execution_context do
          nil ->
            LemonCore.ExecutionContext.new(
              run_id: request.run_id,
              cwd: request.cwd,
              tool_policy: request.tool_policy
            )

          context ->
            LemonCore.ExecutionContext.validate(context)
        end

      assert {:ok, execution_context} = context_result

      request = %{request | execution_context: execution_context}
      meta = request.meta
      refute inspect(meta) =~ "runtime-secret"
      assert {:ok, outbound} = RemoteRequestCodec.encode(request)
      refute inspect(outbound) =~ "runtime-secret"

      assert hd(outbound["meta"]["mcp_servers"])["headers"]["Authorization"] ==
               "Bearer ${LEMON_SECRET:#{secret_name}}"

      request =
        case transport do
          :local ->
            request

          :json ->
            assert {:ok, decoded, _opts} =
                     Worker.execution_request(
                       outbound,
                       %Worker{default_cwd: root, name: "profile-fixture"},
                       run_id
                     )

            decoded
        end

      stream_fn = fn model, context, _options ->
        {:ok, stream} = LemonAi.EventStream.start_link()

        send(
          parent,
          {:profile_context, model.id, LemonAi.SystemPrompt.text(context.system_prompt), stream}
        )

        {:ok, stream}
      end

      assert {:ok, run_ref, %{runner_pid: runner}} =
               Executor.start_run(request, %{stream_fn: stream_fn}, self())

      on_exit(fn -> CodingAgent.Session.Presentation.safe_stop_session(runner) end)
      assert_receive {:profile_context, "gpt-4o", prompt, stream}, 5_000
      assert prompt =~ "private-profile-system-prompt"
      assert prompt =~ "private-profile-soul"
      assert prompt =~ "private-profile-job"
      runner_state = :sys.get_state(runner)
      session_state = Session.get_state(runner_state.session)
      assert session_state.tool_opts[:session_mode] == :chat

      assert session_state.workspace_dir ==
               Path.join([root, "destination-state", "profiles", profile_id, "workspace"])

      assert is_binary(session_state.mcp_session_id)

      assert session_state.profile_instructions ==
               RemoteRequestCodec.normalize_meta(meta).profile_instructions

      [tool] = McpSession.tools(session_state.mcp_session_id)
      hidden_names = session_state.extension_status_report.tool_disclosure.hidden_names

      assert Enum.any?(session_state.base_tools, &(&1.name == tool.name)) or
               tool.name in hidden_names

      assert {:ok, _} = tool.execute.("profile-tool", %{}, nil, nil)

      assert_receive {:mcp_request, "tools/call", %{"authorization" => "Bearer runtime-secret"}},
                     5_000

      assert_receive {:mcp_request, "initialize", %{"x-literal" => literal_header}}, 5_000
      assert literal_header == "${#{literal_name}}"

      # Native task children use the same unresolved invocation definitions and
      # trusted local connection, not machine-global MCP configuration. The
      # child's agent identity comes from the launching session's opts, never
      # from task arguments.
      child_opts =
        CodingAgent.Tools.Task.Params.build_session_opts(
          root,
          [
            parent_session: runner_state.session,
            model: session_state.model,
            agent_id: "mcp-child-writer"
          ],
          %{
            tool_policy:
              CodingAgent.ToolPolicy.custom(allow: [tool.name], require_approval: [tool.name])
          }
        )
        |> Keyword.put(:approval_context, %{
          approval_request_fun: fn approval ->
            send(parent, {:child_mcp_approval, approval})
            {:ok, :approved, :once}
          end
        })

      {:ok, child} = Session.start_link(child_opts)

      try do
        child_state = Session.get_state(child)
        assert child_state.tool_opts[:session_mode] == :chat
        child_tool = Enum.find(child_state.base_tools, &(&1.name == tool.name))
        assert {:ok, child_result} = child_tool.execute.("child-profile-tool", %{}, nil, nil)
        assert Enum.map_join(child_result.content, "", & &1.text) == "profile-tool-result"
        assert_receive {:child_mcp_approval, approval}
        assert approval.invocation_context_key == "profile-client-#{transport}"
        assert approval.agent_id == "mcp-child-writer"

        assert_receive {:mcp_request, "tools/call",
                        %{"authorization" => "Bearer runtime-secret"}},
                       5_000

        refute inspect(child_state.approval_context.invocation_mcp_servers) =~ "runtime-secret"
        assert child_state.approval_context.memory_context_key == "profile-memory-#{transport}"
        assert child_state.approval_context.memory_context_verified == true
      after
        GenServer.stop(child)
      end

      # Rebuilding the registry preserves the owner-bound session connection.
      assert {:ok, _tool} =
               CodingAgent.ToolRegistry.get_tool(root, tool.name,
                 include_extensions: false,
                 mcp_session_id: session_state.mcp_session_id
               )

      session_ref = Process.monitor(runner_state.session)
      runner_ref = Process.monitor(runner)
      response = response()
      LemonAi.EventStream.push(stream, {:done, :stop, response})
      LemonAi.EventStream.complete(stream, response)
      events = collect_completed(run_ref)
      assert Process.alive?(runner_state.session)
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 5_000
      GenServer.stop(runner_state.session)
      assert_receive {:DOWN, ^session_ref, :process, _, _}, 5_000
      assert McpSession.tools(session_state.mcp_session_id) == []
      refute inspect(events) =~ "runtime-secret"
      refute inspect(events) =~ "private-profile-system-prompt"
      refute inspect(events) =~ "private-profile-soul"
      refute inspect(events) =~ "mcp_servers"
    end
  end

  defp prepare_admission do
    for app <- [:lemon_router, :coding_agent] do
      assert {:ok, started} = Application.ensure_all_started(app)
      on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)
    end

    previous_coordinator = Application.get_env(:lemon_router, :session_coordinator)
    previous_consumer = Application.get_env(:lemon_router, :profile_execution_consumer_pid)
    Application.put_env(:lemon_router, :session_coordinator, Coordinator)
    Application.put_env(:lemon_router, :profile_execution_consumer_pid, self())

    on_exit(fn ->
      restore_env(:lemon_router, :session_coordinator, previous_coordinator)
      restore_env(:lemon_router, :profile_execution_consumer_pid, previous_consumer)
    end)
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
