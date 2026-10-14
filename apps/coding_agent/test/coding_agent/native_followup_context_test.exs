defmodule CodingAgent.NativeFollowupContextTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Agent, as: AgentTool
  alias CodingAgent.Tools.Task.{Followup, Params}
  alias LemonCore.{InvocationProof, ProfileStore, Secrets, Store}
  alias LemonRouter.{NativeFollowupAdmission, NativeLineage, RunOrchestrator}

  defmodule Coordinator do
    def submit(_key, submission) do
      send(Application.fetch_env!(:lemon_router, :native_context_consumer_pid), {:native_dispatch, submission})
      :ok
    end
  end

  defmodule Issuer do
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"runId" => id} = Jason.decode!(body)
      send(opts.pid, {:native_issuer, id, Jason.decode!(body), NativeLineage.get_pending_lineage(id)})
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"allow" => true, "invocation" => %{
        "invocationContextKey" => "renewed-actor", "memoryContextKey" => "renewed-audience",
        "invocationToolPolicy" => %{"allow" => ["read"]},
        "invocationMcpServers" => CodingAgent.NativeFollowupContextTest.servers(id),
        "invocationProof" => CodingAgent.NativeFollowupContextTest.proof(id),
        "sharedMemoryGrant" => false
      }}))
    end
  end

  defmodule ForbiddenRouter do
    def submit(request) do
      send(Application.fetch_env!(:lemon_router, :native_context_consumer_pid), {:forbidden_legacy_dispatch, request})
      {:ok, request.run_id}
    end
  end
  defmodule ConduitExecutor do
    def start_run(request, opts, _sink) do
      source = %{run_id: request.meta.native_lineage_run_id,
        lineage_handle: request.meta.native_lineage_handle}
      :ok = opts.native_source_floor_fun.(source, request.tool_policy)
      fresh = LemonCore.RunRequest.new(%{run_id: LemonCore.Id.run_id(),
        agent_id: request.meta.profile_id, session_key: request.session_key,
        prompt: "remote returning work", tool_policy: request.tool_policy})
      {:ok, fresh_id} = opts.native_followup_submit.(source, fresh)
      owner = Application.fetch_env!(:lemon_router, :native_context_consumer_pid)
      send(owner, {:remote_native_conduit, request, fresh_id})
      runner = spawn(fn -> receive do :stop -> :ok end end)
      {:ok, make_ref(), %{runner_pid: runner}}
    end
    def cancel(context), do: send(context.runner_pid, :stop)
  end


  setup do
    assert {:ok, _} = Application.ensure_all_started(:lemon_router)
    assert {:ok, _} = Application.ensure_all_started(:lemon_control_plane)
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    prefix = "native-consumer-" <> suffix
    root = Path.join(System.tmp_dir!(), prefix)
    File.mkdir_p!(root)
    keys = [{:lemon_core, :paths}, {:lemon_core, Secrets},
      {:lemon_router, :native_followup_allowed_origins}, {:lemon_router, :session_coordinator},
      {:lemon_router, :native_context_consumer_pid}]
    previous = Map.new(keys, fn {app, key} = pair -> {pair, Application.fetch_env(app, key)} end)
    previous_origin = System.get_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")
    secret_env = "NATIVE_CONTEXT_CONSUMER_KEY_" <> suffix
    System.put_env(secret_env, Base.encode64(:crypto.strong_rand_bytes(32)))
    System.delete_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")
    Application.put_env(:lemon_core, :paths, home_state_dir: root, global_config: Path.join(root, "config.toml"))
    Application.put_env(:lemon_core, Secrets, key_providers: [:env], env_var: secret_env)
    Application.put_env(:lemon_router, :session_coordinator, Coordinator)
    Application.put_env(:lemon_router, :native_context_consumer_pid, self())
    bandit = start_supervised!({Bandit, plug: {Issuer, %{pid: self()}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false})
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    origin = "http://127.0.0.1:#{port}"
    Application.put_env(:lemon_router, :native_followup_allowed_origins, [origin])
    {:ok, owner} = GenServer.start_link(RunOrchestrator, [])
    profile_id = prefix <> "-profile"
    run_id = prefix <> "-root"
    assert {:ok, _} = ProfileStore.create(%{"id" => profile_id,
      "mcpServers" => [%{"name" => "core", "url" => "https://bot.example/mcp", "headers" => %{},
        "allowedOrigins" => ["https://bot.example"], "approvedPrivateOrigins" => []}]})
    assert {:ok, _} = NativeFollowupAdmission.configure(profile_id, origin <> "/admit", "issuer-private-bearer")
    assert {:ok, profile} = ProfileStore.get_for_execution(profile_id)
    policy = %{allow: ["read", "write", "task", "agent"], require_approval: ["write"]}
    assert {:ok, request} = ProfileStore.chat_request(profile, "original source", run_id: run_id, tool_policy: policy)
    assert {:ok, record} = InvocationProof.validate(proof(run_id), run_id, servers(run_id))
    meta = Map.merge(request.meta, %{invocation_context_key: "original-actor",
      memory_context_key: "original-audience", memory_context_verified: true,
      invocation_proof: record, invocation_proof_verified: true, shared_memory_grant: false,
      mcp_servers: servers(run_id)})
    assert {:ok, ^run_id} = RunOrchestrator.submit(owner, %{request | meta: meta})
    assert_receive {:native_dispatch, submission}
    source = %{run_id: run_id, lineage_handle: submission.execution_request.meta.native_lineage_handle}
    assert :ok = RunOrchestrator.register_native_source_floor(source, policy)
    opts = [native_lineage_run_id: run_id, native_lineage_handle: source.lineage_handle,
      invocation_context_key: "original-actor", memory_context_key: "original-audience",
      memory_context_verified: true, shared_memory_grant: false, tool_policy: policy,
      invocation_mcp_servers: servers(run_id), session_key: request.session_key,
      agent_id: profile_id, run_orchestrator: ForbiddenRouter,
      native_followup_submit: fn captured, fresh -> RunOrchestrator.submit_native_followup(owner, captured, fresh) end]

    on_exit(fn ->
      if Process.alive?(owner), do: GenServer.stop(owner)
      {:ok, entries} = Secrets.list()
      for entry <- entries, String.starts_with?(entry.name, "native_followup/" <> profile_id <> "/"), do: Secrets.delete(entry.name)
      Store.delete(:native_followup_admission_configs, profile_id)
      for {id, _} <- Store.list(RunOrchestrator.admission_table()), is_binary(id) and String.starts_with?(id, prefix),
        do: Store.delete(RunOrchestrator.admission_table(), id)
      for {{app, key}, value} <- previous do
        case value do
          {:ok, prior} -> Application.put_env(app, key, prior)
          :error -> Application.delete_env(app, key)
        end
      end
      if previous_origin, do: System.put_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS", previous_origin),
        else: System.delete_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")
      System.delete_env(secret_env)
      File.rm_rf!(root)
    end)
    %{opts: opts, root: root, source: source, profile: profile_id}
  end

  test "Agent dispatch renews F through configured issuer and never copies old proof", ctx do
    result = AgentTool.execute("native-agent", %{"agent_id" => ctx.profile,
      "prompt" => "delegated work", "async" => true, "auto_followup" => false,
      "meta" => %{"nativeLineageHandle" => "forged", "sharedMemoryGrant" => true}},
      nil, nil, ctx.root, ctx.opts)
    assert %LemonAgent.Types.AgentToolResult{} = result
    id = result.details.run_id
    assert_receive {:native_issuer, ^id, %{"runId" => ^id}, {:ok, lineage}}, 2000
    assert lineage["sourceRootRunId"] == ctx.source.run_id
    assert_receive {:native_dispatch, admitted}
    assert admitted.execution_request.run_id == id
    assert admitted.execution_request.meta.invocation_context_key == "renewed-actor"
    assert admitted.execution_request.meta.memory_context_key == "renewed-audience"
    assert admitted.execution_request.meta.invocation_proof.run_id == id
    assert admitted.execution_request.tool_policy.allow == ["read"]
    assert admitted.queue_mode == :collect
    refute inspect(result) =~ ctx.source.lineage_handle
    refute inspect(CodingAgent.TaskStore.get(result.details.task_id)) =~ ctx.source.lineage_handle
    refute_receive {:forbidden_legacy_dispatch, _}
    :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(id),
      LemonCore.Event.new(:run_completed, LemonPlatformTest.EventsFixtures.run_completed(answer: "done")))
  end

  test "Task returning followup renews source authority instead of steering old session", ctx do
    context = Params.inherited_execution_context(ctx.opts)
    context = Map.merge(context, %{auto_followup: true, parent_session_key: ctx.opts[:session_key],
      parent_agent_id: ctx.profile, queue_mode: :steer, cwd: ctx.root, run_orchestrator: ForbiddenRouter})
    assert :ok = Followup.maybe_send_async_followup(context, nil, "child-complete", %{ok: true, answer: "child answer"})
    assert_receive {:native_issuer, id, %{"runId" => id}, {:ok, lineage}}, 2000
    assert lineage["sourceRootRunId"] == ctx.source.run_id
    assert_receive {:native_dispatch, admitted}
    assert admitted.execution_request.run_id == id
    assert admitted.execution_request.meta.invocation_context_key == "renewed-actor"
    assert admitted.execution_request.meta.invocation_proof.run_id == id
    assert admitted.queue_mode == :collect
    refute_receive {:forbidden_legacy_dispatch, _}
  end

  test "background session retains immutable root ownership for nested fresh F", ctx do
    owner = self()
    opts = Keyword.merge(ctx.opts, cwd: ctx.root, runner: fn session_opts, _prompt, _signal, _timeout ->
      inherited = Params.inherited_execution_context(session_opts)
      result = AgentTool.execute("background-agent", %{"agent_id" => ctx.profile,
        "prompt" => "nested background work", "async" => true, "auto_followup" => false},
        nil, nil, ctx.root, Map.to_list(inherited) ++ [session_key: ctx.opts[:session_key], agent_id: ctx.profile])
      send(owner, {:background_nested_result, result, inherited})
      {:ok, "background done"}
    end)
    assert {:ok, %{id: background_id}} = CodingAgent.BackgroundRun.start("background work", opts)
    assert_receive {:native_issuer, id, %{"runId" => id}, {:ok, lineage}}, 2000
    assert lineage["sourceRootRunId"] == ctx.source.run_id
    assert_receive {:native_dispatch, admitted}
    assert admitted.execution_request.run_id == id
    assert admitted.execution_request.meta.invocation_context_key == "renewed-actor"
    assert_receive {:background_nested_result, result, inherited}
    assert inherited.native_lineage_run_id == ctx.source.run_id
    assert inherited.native_lineage_handle == ctx.source.lineage_handle
    assert inherited.memory_context_key == "original-audience"
    refute inspect(CodingAgent.BackgroundRun.status(background_id)) =~ ctx.source.lineage_handle
    refute inspect(CodingAgent.TaskStore.get(background_id)) =~ ctx.source.lineage_handle
    :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(result.details.run_id),
      LemonCore.Event.new(:run_completed, LemonPlatformTest.EventsFixtures.run_completed(answer: "done")))
  end

  test "actual authenticated Worker socket publishes floor and submits F only to controller", ctx do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    node_id = "native-conduit-" <> suffix
    node_name = "Native Conduit " <> suffix
    token = "native-conduit-token-" <> suffix
    assert :ok = LemonControlPlane.NodeStore.put_node(node_id,
      %{id: node_id, name: node_name, type: "coding_agent", capabilities: %{}, status: :offline})
    assert {:ok, credential} = LemonControlPlane.Auth.TokenStore.replace_node_session(token,
      %{"type" => "node", "nodeId" => node_id})
    bandit = start_supervised!(Supervisor.child_spec({Bandit,
      plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
      id: {:native_conduit_ws, suffix}))
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    worker = start_supervised!(%{id: {:native_conduit_worker, suffix}, restart: :temporary,
      start: {CodingAgent.ExecutionNode.Worker, :start_link, [[node_name: node_name,
        controller: "ws://127.0.0.1:#{port}/ws", cwd: ctx.root, token: token,
        notify_pid: self(), executor_module: ConduitExecutor, socket_opts: [reconnect_delay_ms: 10]]]}})
    assert_receive {:execution_node_worker, ^worker, {:status, :online, ^node_id}}, 3000
    assert {:ok, destination} = LemonCore.NodeRegistry.resolve_id(node_id)
    assert destination.generation == credential.identity["sessionGeneration"]
    refute destination.pid == worker
    assert {:ok, _} = ProfileStore.update(ctx.profile, %{"node" => node_id})
    assert {:ok, profile} = ProfileStore.get_for_execution(ctx.profile)
    id = "remote-root-" <> suffix
    assert {:ok, root} = ProfileStore.chat_request(profile, "actual remote source", run_id: id,
      tool_policy: %{allow: ["read", "agent"]})
    assert {:ok, proof_record} = InvocationProof.validate(proof(id), id, servers(id))
    root = %{root | meta: Map.merge(root.meta, %{invocation_context_key: "remote-actor",
      memory_context_key: "remote-audience", memory_context_verified: true, shared_memory_grant: false,
      invocation_proof: proof_record, invocation_proof_verified: true, mcp_servers: servers(id)})}
    assert {:ok, ^id} = RunOrchestrator.submit(root)
    assert_receive {:native_dispatch, sealed}
    source = %{run_id: id, lineage_handle: sealed.execution_request.meta.native_lineage_handle}
    assert {:error, :invalid_native_lineage} = NativeLineage.register_source_floor(source, %{allow: ["read"]},
      %{node_id: node_id, connection_pid: destination.pid, generation: destination.generation + 1})
    request = LemonGateway.ExecutionRequest.from_command(sealed.execution_request)
    assert {:ok, _ref, remote} = CodingAgent.Executor.start_run(request, %{}, self())
    assert_receive {:native_issuer, fresh_id, %{"runId" => fresh_id}, {:ok, lineage}}, 3000
    assert lineage["sourceRootRunId"] == id
    assert_receive {:native_dispatch, admitted}
    assert admitted.execution_request.meta.invocation_proof.run_id == fresh_id
    assert admitted.execution_request.meta.invocation_context_key == "renewed-actor"
    assert_receive {:remote_native_conduit, received_root, ^fresh_id}, 3000
    assert received_root.meta.invocation_context_key == "remote-actor"
    assert {:ok, actual_source} = NativeLineage.authenticate(source,
      %{node_id: node_id, connection_pid: destination.pid, generation: destination.generation})
    assert actual_source.native_floor_verified
    refute_receive {:forbidden_legacy_dispatch, _}
    :ok = CodingAgent.Executor.cancel(remote)
    on_exit(fn ->
      LemonCore.NodeRegistry.unregister(node_id, destination.pid)
      LemonCore.Store.delete(:session_tokens, token)
      LemonCore.Store.delete(:session_token_heads, {"node", node_id})
      LemonControlPlane.NodeStore.release_node_name(node_name, node_id)
      LemonCore.Store.delete(:nodes_registry, node_id)
      Store.delete(RunOrchestrator.admission_table(), id)
      Store.delete(RunOrchestrator.admission_table(), fresh_id)
    end)
  end

  test "explicit negative, malformed, and paired private claims cannot use legacy dispatch", ctx do
    for claim <- [[memory_context_key: nil], [memory_context_verified: false],
                   [shared_memory_grant: false], [invocation_proof: %{}],
                   [native_lineage_run_id: nil], [memory_context_key: "unproven-audience"],
                   [invocation_mcp_servers: servers("stale-run")]] do
      result = AgentTool.execute("denied", %{"agent_id" => ctx.profile, "prompt" => "must not dispatch",
        "async" => true}, nil, nil, ctx.root,
        [invocation_context_key: "standalone", run_orchestrator: ForbiddenRouter] ++ claim)
      assert {:error, _} = result
      refute_receive {:forbidden_legacy_dispatch, _}
      refute_receive {:native_issuer, _, _, _}
      refute_receive {:native_dispatch, _}
    end
  end

  def servers(id), do: [%{"name" => "core", "url" => "https://bot.example/mcp",
    "headers" => %{"X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{id}}"},
    "allowedOrigins" => ["https://bot.example"], "approvedPrivateOrigins" => []}]
  def proof(id), do: %{"runId" => id, "serverName" => "core", "serverUrl" => "https://bot.example/mcp",
    "headerName" => "X-Lemon-Bot-Invocation", "secretName" => "lemon_bot/invocations/" <> id}
end
