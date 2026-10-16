defmodule LemonRouter.NativeLineageTest do
  use ExUnit.Case, async: false

  alias LemonCore.{
    InvocationProof,
    NodeRegistry,
    ProfileStore,
    RunRequest,
    RunStore,
    Secrets,
    Store
  }

  alias LemonRouter.{NativeFollowupAdmission, NativeLineage, RunOrchestrator}

  defmodule Coordinator do
    def submit(_key, submission) do
      send(
        Application.fetch_env!(:lemon_router, :native_lineage_test_pid),
        {:native_dispatch, submission}
      )

      case Application.get_env(:lemon_router, :native_lineage_test_dispatch, :ok) do
        :crash -> exit(:lost_dispatch_reply)
        result -> result
      end
    end
  end

  defmodule RuntimeObserver do
    def available?, do: true

    def submit_execution(command) do
      send(
        Application.fetch_env!(:lemon_router, :native_lineage_test_pid),
        {:native_runtime_payload, command}
      )

      :ok
    end
  end

  defmodule Issuer do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"runId" => run_id} = Jason.decode!(body)
      lineage = NativeLineage.get_pending_lineage(run_id)
      cp = LemonControlPlane.Methods.RunsFollowupLineageGet.handle(%{"runId" => run_id}, %{})

      extra =
        LemonControlPlane.Methods.RunsFollowupLineageGet.handle(
          %{"runId" => run_id, "parentRunId" => "forged"},
          %{}
        )

      send(
        opts.pid,
        {:issuer_pending, self(), run_id, body, conn.req_headers, lineage, cp, extra}
      )

      receive do
        {:issuer_reply, ^run_id, status, response} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, response)
      after
        4000 -> Plug.Conn.send_resp(conn, 503, "unavailable")
      end
    end
  end

  setup do
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    prefix = "lineage-" <> suffix
    root = Path.join(System.tmp_dir!(), prefix)
    File.mkdir_p!(root)

    env_keys = [
      {:lemon_core, :paths},
      {:lemon_core, Secrets},
      {:lemon_router, :native_followup_allowed_origins},
      {:lemon_router, :session_coordinator},
      {:lemon_router, :native_lineage_test_pid},
      {:lemon_router, :native_lineage_test_dispatch}
    ]

    previous =
      Map.new(env_keys, fn {app, key} = pair -> {pair, Application.fetch_env(app, key)} end)

    origin_env = System.get_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")
    key_env = "NATIVE_LINEAGE_TEST_KEY_" <> suffix
    System.put_env(key_env, Base.encode64(:crypto.strong_rand_bytes(32)))
    System.delete_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")

    Application.put_env(:lemon_core, :paths,
      home_state_dir: root,
      global_config: Path.join(root, "config.toml")
    )

    Application.put_env(:lemon_core, Secrets, key_providers: [:env], env_var: key_env)
    Application.put_env(:lemon_router, :session_coordinator, Coordinator)
    Application.put_env(:lemon_router, :native_lineage_test_pid, self())
    Application.put_env(:lemon_router, :native_lineage_test_dispatch, :ok)

    bandit =
      start_supervised!(
        {Bandit, plug: {Issuer, %{pid: self()}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    origin = "http://127.0.0.1:#{port}"
    Application.put_env(:lemon_router, :native_followup_allowed_origins, [origin])
    {:ok, server} = GenServer.start_link(RunOrchestrator, [])
    profile_id = prefix <> "-profile"
    run_id = prefix <> "-root"
    assert {:ok, _} = ProfileStore.create(%{"id" => profile_id, "mcpServers" => templates()})

    assert {:ok, _} =
             NativeFollowupAdmission.configure(
               profile_id,
               origin <> "/check",
               "private-issuer-bearer"
             )

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      {:ok, secrets} = Secrets.list()

      for secret <- secrets,
          String.starts_with?(secret.name, "native_followup/" <> profile_id <> "/"),
          do: Secrets.delete(secret.name)

      Store.delete(:native_followup_admission_configs, profile_id)

      for {id, _} <- Store.list(RunOrchestrator.admission_table()),
          is_binary(id) and String.starts_with?(id, prefix),
          do: Store.delete(RunOrchestrator.admission_table(), id)

      for {{app, key}, value} <- previous, do: restore_env(app, key, value)

      if origin_env,
        do: System.put_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS", origin_env),
        else: System.delete_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")

      System.delete_env(key_env)
      File.rm_rf!(root)
    end)

    %{server: server, profile_id: profile_id, run_id: run_id, prefix: prefix, origin: origin}
  end

  test "actual factory admission seals original context before dispatch and keeps handle private",
       ctx do
    assert {:error, :not_found} = NativeLineage.pending_destination(ctx.run_id, "local")
    {source, submission} = admit_root(ctx)
    assert source.root_run_id == ctx.run_id
    assert source.profile_id == ctx.profile_id
    assert source.invocation_context_key == "original-actor"
    assert source.memory_context_key == "original-private-audience"
    assert {:error, :not_pending} = NativeLineage.pending_destination(ctx.run_id, "local")
    assert {:ok, row} = Store.fetch(RunOrchestrator.admission_table(), ctx.run_id)
    handle = submission.execution_request.meta.native_lineage_handle
    assert is_binary(row.native_source.handle_hash)
    refute inspect(row) =~ handle
    refute inspect(row) =~ "private-static-header"
    refute inspect(submission.meta) =~ handle

    refute inspect(RunStore.execution_projection(%{nested: [%{native_lineage_handle: handle}]})) =~
             handle

    assert {:error, :invalid_native_lineage} =
             NativeLineage.authenticate(
               %{run_id: ctx.run_id, lineage_handle: String.duplicate("x", 43)},
               :local
             )

    assert {:error, :invalid_native_lineage} =
             NativeLineage.authenticate(
               %{run_id: ctx.prefix <> "-fake", lineage_handle: handle},
               :local
             )
  end

  test "continuation profile preparation preserves request model provenance", ctx do
    {source, _root} = admit_root(ctx)

    for explicit <- [nil, false, true] do
      request = %{
        fresh_request(ctx, "model-provenance-#{inspect(explicit)}")
        | model: "@fast",
          model_explicit: explicit
      }

      assert {:ok, prepared, _destination} = NativeLineage.prepare_request(source, request)
      assert prepared.model == "@fast"
      assert prepared.model_explicit == (explicit != false)
    end
  end

  @tag :tmp_dir
  test "model-less managed continuation retains automatic zero-cap enforcement", ctx do
    {source, _root} = admit_root(ctx)

    assert {:ok, _} =
             ProfileStore.update(ctx.profile_id, %{"model" => "openai:gpt-4o"})

    assert {:ok, prepared, _destination} =
             NativeLineage.prepare_request(source, fresh_request(ctx, "automatic-model"))

    assert prepared.model == "openai:gpt-4o"
    assert prepared.model_explicit == false
    assert_zero_cap(prepared, ctx.tmp_dir)
  end

  test "unknown executing-host floor cannot admit F and runtime receipts only restrict authority",
       ctx do
    {unverified, root} = admit_root(ctx, register_floor: false)
    refute unverified.native_floor_verified
    denied = fresh_request(ctx, "unverified-floor")

    assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), denied) ==
             {:error, :admission_unavailable}

    assert {:ok, %{terminal: true, native_failure: :admission_unavailable}} =
             Store.fetch(RunOrchestrator.admission_table(), denied.run_id)

    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50

    assert :ok =
             RunOrchestrator.register_native_source_floor(
               captured(root),
               %{allow: ["read"], require_approval: ["read"]}
             )

    assert {:ok, actual} = NativeLineage.authenticate(captured(root), :local)
    assert actual.native_floor_verified
    assert actual.tool_policy.allow == ["read"]
    assert :ok = RunOrchestrator.register_native_source_floor(captured(root), %{allow: :all})
    assert {:ok, still_restricted} = NativeLineage.authenticate(captured(root), :local)
    assert still_restricted.tool_policy.allow == ["read"]
    assert "read" in still_restricted.tool_policy.require_approval
    assert "write" in still_restricted.tool_policy.require_approval

    assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), denied) ==
             {:error, :admission_unavailable}

    assert {:ok, prepared, _} =
             NativeLineage.prepare_request(still_restricted, fresh_request(ctx, "verified-floor"))

    assert {:ok, admitted} =
             NativeLineage.apply_invocation(
               still_restricted,
               prepared,
               invocation(prepared.run_id)
             )

    assert admitted.tool_policy.allow == ["read"]
    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
    refute_receive {:native_dispatch, _}, 50
  end

  test "concurrent protected root floor receipts atomically retain both restrictions", ctx do
    {_source, root} = admit_root(ctx, register_floor: false)
    private = captured(root)
    parent = self()

    first =
      Task.async(fn ->
        send(parent, {:floor_ready, self()})

        receive do
          :register ->
            RunOrchestrator.register_native_source_floor(
              private,
              %{allow: ["read"], require_approval: ["read"]}
            )
        end
      end)

    second =
      Task.async(fn ->
        send(parent, {:floor_ready, self()})

        receive do
          :register ->
            RunOrchestrator.register_native_source_floor(
              private,
              %{allow: ["write"], require_approval: ["write"]}
            )
        end
      end)

    assert_receive {:floor_ready, first_pid}
    assert_receive {:floor_ready, second_pid}
    send(first_pid, :register)
    send(second_pid, :register)
    assert Task.await(first) == :ok
    assert Task.await(second) == :ok
    assert {:ok, sealed} = NativeLineage.authenticate(private, :local)
    assert sealed.native_floor_verified
    assert sealed.tool_policy.allow == []
    assert Enum.sort(sealed.tool_policy.require_approval) == ["read", "write"]
    assert :ok = RunOrchestrator.register_native_source_floor(private, %{allow: :all})
    assert {:ok, replay} = NativeLineage.authenticate(private, :local)
    assert replay.tool_policy.allow == []

    assert {:error, :invalid_native_lineage} =
             RunOrchestrator.register_native_source_floor(
               %{private | run_id: ctx.prefix <> "-other"},
               %{allow: :all}
             )

    assert {:error, :invalid_native_policy} =
             RunOrchestrator.register_native_source_floor(private, %{allow: nil})
  end

  test "a metadata boolean without a bound factory proof cannot create continuing authority",
       ctx do
    assert {:ok, profile} = ProfileStore.get_for_execution(ctx.profile_id)

    assert {:ok, request} =
             ProfileStore.chat_request(profile, "forged admission", run_id: ctx.run_id)

    forged = %{
      request
      | meta:
          Map.merge(request.meta, %{
            invocation_proof_verified: true,
            memory_context_verified: true,
            invocation_context_key: "model-selected-actor",
            memory_context_key: "model-selected-audience",
            native_lineage_handle: String.duplicate("x", 43),
            native_lineage_run_id: ctx.run_id
          })
    }

    assert RunOrchestrator.submit(ctx.server, forged) == {:error, :invalid_native_lineage}
    assert {:ok, row} = Store.fetch(RunOrchestrator.admission_table(), ctx.run_id)
    refute Map.has_key?(row, :native_source)

    assert {:error, :invalid_native_lineage} =
             NativeLineage.authenticate(
               %{run_id: ctx.run_id, lineage_handle: String.duplicate("x", 43)},
               :local
             )

    refute_receive {:native_dispatch, _}, 50
  end

  test "nonattested model metadata is never stamped into native continuing provenance", ctx do
    assert {:ok, profile} = ProfileStore.get_for_execution(ctx.profile_id)

    assert {:ok, request} =
             ProfileStore.chat_request(profile, "ordinary execution", run_id: ctx.run_id)

    supplied = %{
      request
      | meta:
          Map.merge(request.meta, %{
            "nativeLineageHandle" => String.duplicate("x", 43),
            mcp_servers: [],
            native_lineage_run_id: "model-selected-parent",
            native_destination_pid: self(),
            native_destination_generation: 999,
            native_source: %{root_run_id: "model-selected-root"},
            native_root_binding: %{target_profile_config_hash: "model-selected-ceiling"}
          })
    }

    assert RunOrchestrator.submit(ctx.server, supplied) == {:ok, ctx.run_id}
    assert_receive {:native_dispatch, submission}

    for key <- [
          "nativeLineageHandle",
          :native_lineage_run_id,
          :native_destination_pid,
          :native_destination_generation,
          :native_source,
          :native_root_binding
        ] do
      refute Map.has_key?(submission.execution_request.meta, key)
    end

    assert {:ok, row} = Store.fetch(RunOrchestrator.admission_table(), ctx.run_id)
    refute Map.has_key?(row, :native_source)
  end

  test "managed initial proof root must fit current operator templates", ctx do
    candidates = [
      {"root-url", fn server -> Map.put(server, "url", "https://arbitrary.example/mcp") end},
      {"root-origins",
       fn server ->
         Map.put(server, "allowedOrigins", ["https://bot.example", "https://arbitrary.example"])
       end},
      {"root-tools", fn server -> Map.put(server, "enabledTools", ["read", "write"]) end}
    ]

    for {suffix, change} <- candidates do
      id = ctx.prefix <> "-" <> suffix
      [server] = servers(id)
      candidate = change.(server)
      request = root_request(ctx, id, [candidate])
      assert RunOrchestrator.submit(ctx.server, request) == {:error, :admission_unavailable}
      assert {:ok, row} = Store.fetch(RunOrchestrator.admission_table(), id)
      refute Map.has_key?(row, :native_source)
      refute Map.has_key?(row, :native_root_binding)
    end

    refute_receive {:native_dispatch, _}, 50
  end

  test "managed memory-only initial root requires exact empty MCP replacement", ctx do
    assert {:ok, profile} = ProfileStore.get_for_execution(ctx.profile_id)
    request = memory_request(ctx, ctx.run_id, profile["mcpServers"])
    assert RunOrchestrator.submit(ctx.server, request) == {:error, :admission_unavailable}
    id = ctx.prefix <> "-memory-only"
    request = memory_request(ctx, id)
    assert RunOrchestrator.submit(ctx.server, request) == {:ok, id}
    assert_receive {:native_dispatch, submission}
    assert submission.execution_request.meta.mcp_servers == []
    assert submission.execution_request.meta[:invocation_proof] == nil
    refute Map.has_key?(submission.execution_request.meta, :native_lineage_handle)
    assert :ok = NativeLineage.register_source_floor(%{run_id: id}, %{allow: ["read"]}, :local)
    assert :ok = NativeLineage.register_source_floor(%{run_id: id}, %{allow: :all}, :local)
    assert :ok = NativeLineage.validate_activation(submission.execution_request)

    assert {:error, :invalid_native_lineage} =
             NativeLineage.authenticate(
               %{run_id: id, lineage_handle: String.duplicate("x", 43)},
               :local
             )

    assert {:error, :invalid_native_lineage} =
             NativeLineage.register_source_floor(
               %{run_id: id, lineage_handle: nil},
               %{allow: :all},
               :local
             )
  end

  test "initial proof root fences changed templates at immutable native startup receipt", ctx do
    {_source, root} = admit_root(ctx, register_floor: false)

    assert {:error, :invalid_native_lineage} =
             NativeLineage.register_source_floor(%{run_id: ctx.run_id}, %{allow: :all}, :local)

    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"mcpServers" => []})

    assert {:error, :admission_unavailable} =
             NativeLineage.register_source_floor(
               captured(root),
               root.execution_request.tool_policy,
               :local
             )

    assert {:ok, source} = NativeLineage.authenticate(captured(root), :local)
    refute source.native_floor_verified

    assert NativeLineage.validate_activation(root.execution_request) ==
             {:error, :admission_unavailable}

    assert {:ok, %{terminal: true, native_failure: :admission_unavailable}} =
             Store.fetch(RunOrchestrator.admission_table(), ctx.run_id)
  end

  test "proofless managed root cannot acknowledge native startup after current ceiling rotation",
       ctx do
    request = memory_request(ctx, ctx.run_id)
    assert RunOrchestrator.submit(ctx.server, request) == {:ok, ctx.run_id}
    assert_receive {:native_dispatch, submission}
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"mcpServers" => []})

    assert {:error, :admission_unavailable} =
             NativeLineage.register_source_floor(
               %{run_id: ctx.run_id},
               %{allow: ["read"]},
               :local
             )

    assert {:error, :admission_unavailable} =
             NativeLineage.validate_activation(submission.execution_request)
  end

  test "proofless startup receipt binds exact authenticated node and never creates continuation authority",
       ctx do
    node = ctx.prefix <> "-proofless-node"
    node_pid = self()

    assert :ok =
             NodeRegistry.register_session(node, node, node_pid, 7, %{
               capabilities: %{
                 "coding_agent.run" => %{
                   "version" => 2,
                   "executionContext" => %{"version" => 1},
                   "nativePrivacyContext" => %{"version" => 1}
                 }
               }
             })

    on_exit(fn -> NodeRegistry.unregister(node, node_pid) end)
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"node" => node})
    request = memory_request(ctx, ctx.run_id)
    assert RunOrchestrator.submit(ctx.server, request) == {:ok, ctx.run_id}
    assert_receive {:native_dispatch, _submission}
    receipt = %{run_id: ctx.run_id}

    assert {:error, :invalid_native_lineage} =
             RunOrchestrator.register_native_source_floor(receipt, %{allow: ["read"]})

    assert {:error, :invalid_native_lineage} =
             RunOrchestrator.register_native_source_floor_from_node(
               receipt,
               %{allow: ["read"]},
               %{node_id: node, connection_pid: node_pid, generation: 6}
             )

    assert :ok =
             RunOrchestrator.register_native_source_floor_from_node(
               receipt,
               %{allow: ["read"]},
               %{node_id: node, connection_pid: node_pid, generation: 7}
             )

    assert {:error, :invalid_native_lineage} =
             NativeLineage.authenticate(
               %{run_id: ctx.run_id, lineage_handle: String.duplicate("x", 43)},
               %{node_id: node, connection_pid: node_pid, generation: 7}
             )
  end

  test "configured issuer renews exactly F with reserved lineage and restrictive authority",
       ctx do
    {_source, root} = admit_root(ctx)
    captured = captured(root)
    fresh = fresh_request(ctx, "fresh")

    task =
      Task.async(fn -> RunOrchestrator.submit_native_followup(ctx.server, captured, fresh) end)

    assert_receive {:issuer_pending, issuer, id, body, headers, {:ok, lineage}, cp, extra}, 2000
    assert id == fresh.run_id
    assert Jason.decode!(body) == %{"runId" => fresh.run_id}
    assert {"authorization", "Bearer private-issuer-bearer"} in headers
    assert lineage["sourceRootRunId"] == ctx.run_id
    assert lineage["parentRunId"] == ctx.run_id
    assert lineage["sourceInvocationContextKey"] == "original-actor"
    assert lineage["sourceMemoryContextKey"] == "original-private-audience"
    assert lineage["targetNodeId"] == "local"

    assert {:ok, %{node_id: "local", pid: nil, generation: nil}} =
             NativeLineage.pending_destination(id, "local")

    assert {:error, :destination_mismatch} = NativeLineage.pending_destination(id, "wrong-node")
    assert cp == {:ok, lineage}
    assert {:error, _} = extra
    refute inspect(lineage) =~ "private-static-header"
    refute inspect(lineage) =~ captured.lineage_handle
    send(issuer, {:issuer_reply, id, 200, approved(id)})
    assert Task.await(task) == {:ok, id}
    assert_receive {:native_dispatch, admitted}
    assert admitted.run_id == id
    assert admitted.queue_mode == :collect
    meta = admitted.execution_request.meta
    assert meta.invocation_proof.run_id == id
    assert meta.invocation_proof_verified
    assert meta.memory_context_verified
    assert meta.invocation_context_key == "fresh-current-actor"
    assert meta.memory_context_key == "fresh-private-target-audience"
    refute meta.shared_memory_grant
    assert meta.mcp_servers == servers(id)
    assert admitted.execution_request.tool_policy.allow == ["read"]
    assert "write" in admitted.execution_request.tool_policy.require_approval

    assert :ok =
             RunOrchestrator.register_native_source_floor(
               captured(admitted),
               admitted.execution_request.tool_policy
             )

    assert {:ok, renewed_source} = NativeLineage.authenticate(captured(admitted), :local)
    assert renewed_source.root_run_id == ctx.run_id
    assert renewed_source.invocation_context_key == "original-actor"
    assert renewed_source.execution_invocation_context_key == "fresh-current-actor"
    assert {:error, :not_found} = NativeLineage.get_pending_lineage(id)
    assert {:error, :not_pending} = NativeLineage.pending_destination(id, "local")
    assert RunOrchestrator.submit_native_followup(ctx.server, captured, fresh) == {:ok, id}
    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
    refute_receive {:native_dispatch, _}, 50
  end

  test "derived executions retain source-profile dependencies while pending, active and queued",
       ctx do
    {_source, root} = admit_root(ctx)
    target_profile = ctx.prefix <> "-execution-profile"
    unrelated_profile = ctx.prefix <> "-unrelated-profile"
    session_key = "agent:#{target_profile}:derived-#{ctx.prefix}"
    assert {:ok, _} = ProfileStore.create(%{"id" => target_profile, "mcpServers" => templates()})
    complete_presence_run(root.execution_request, true)

    original_coordinator = Application.fetch_env!(:lemon_router, :session_coordinator)
    Application.put_env(:lemon_router, :session_coordinator, LemonRouter.SessionCoordinator)

    :sys.replace_state(ctx.server, fn state ->
      %{state | run_process_opts: Map.put(state.run_process_opts, :submit_to_gateway?, false)}
    end)

    fresh_ids = Enum.map(["dependent-active", "dependent-queued"], &(ctx.prefix <> "-" <> &1))
    conversation = {:session, session_key}

    on_exit(fn ->
      Application.put_env(:lemon_router, :session_coordinator, original_coordinator)

      for {pid, _} <- Registry.lookup(LemonRouter.ConversationRegistry, conversation),
          do: DynamicSupervisor.terminate_child(LemonRouter.SessionCoordinatorSupervisor, pid)

      for id <- fresh_ids do
        for {pid, _} <- Registry.lookup(LemonRouter.RunRegistry, id),
            do: DynamicSupervisor.terminate_child(LemonRouter.RunSupervisor, pid)

        Store.delete(:run_receipts, id)
        Store.delete(:runs, id)
        Store.delete(:native_resume_contexts, {:run, id})
      end

      Store.delete(:runs, ctx.run_id)
      Store.delete(:sessions_index, root.session_key)
      Store.delete(:sessions_index, session_key)
    end)

    filters = %{"sessionKey" => session_key, "agentId" => target_profile, "limit" => 1}

    query = fn profile ->
      assert {:ok, result} =
               LemonControlPlane.Methods.RunsActiveList.handle(
                 Map.put(filters, "profileId", profile),
                 %{}
               )

      result
    end

    # Exact session/agent filters exclude attributed work from other fixtures.
    # Legacy rows lacking both fields must still remain conservatively unknown.
    baseline =
      Map.new([ctx.profile_id, target_profile, unrelated_profile], fn profile ->
        assert %{"presence" => %{"active" => 0, "queued" => 0} = presence} = query.(profile)
        {profile, presence}
      end)

    for {id, index} <- Enum.with_index(fresh_ids) do
      fresh = %{
        fresh_request(ctx, "unused")
        | run_id: id,
          agent_id: target_profile,
          session_key: session_key,
          cwd: root.execution_request.cwd,
          meta: %{dependent_profile_ids: [unrelated_profile], parent_run_id: "forged-parent"}
      }

      task =
        Task.async(fn ->
          RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
        end)

      assert_receive {:issuer_pending, issuer, ^id, _, _, {:ok, _}, _, _}, 2000

      for profile <- [ctx.profile_id, target_profile] do
        expected =
          Map.merge(baseline[profile], %{
            "active" => index,
            "unknown" => baseline[profile]["unknown"] + 1,
            "idle" => false
          })

        assert query.(profile)["presence"] == expected
      end

      assert query.(unrelated_profile)["presence"] == baseline[unrelated_profile]
      send(issuer, {:issuer_reply, id, 200, approved(id)})
      assert Task.await(task) == {:ok, id}

      for profile <- [ctx.profile_id, target_profile] do
        expected =
          Map.merge(baseline[profile], %{"active" => 1, "queued" => index, "idle" => false})

        assert query.(profile)["presence"] == expected
      end

      assert query.(unrelated_profile)["presence"] == baseline[unrelated_profile]
    end

    [active_id, queued_id] = fresh_ids
    [{active, _}] = Registry.lookup(LemonRouter.RunRegistry, active_id)
    :ok = :sys.suspend(active)

    try do
      expected =
        Map.merge(baseline[ctx.profile_id], %{"active" => 1, "queued" => 1, "idle" => false})

      assert query.(ctx.profile_id)["presence"] == expected
    after
      :sys.resume(active)
    end

    assert %{
             "runs" => [
               %{
                 "runId" => ^active_id,
                 "profileId" => ^target_profile,
                 "agentId" => ^target_profile,
                 "sessionKey" => ^session_key
               }
             ]
           } = query.(ctx.profile_id)

    assert query.(unrelated_profile)["presence"] == baseline[unrelated_profile]

    active_command = :sys.get_state(active).execution_request
    ref = Process.monitor(active)
    complete_presence_run(active_command, true)
    assert_receive {:DOWN, ^ref, :process, ^active, :normal}, 2000

    assert eventually(fn ->
             LemonRouter.SessionCoordinator.active_run(conversation) == {:ok, queued_id}
           end)

    for profile <- [ctx.profile_id, target_profile] do
      expected = Map.merge(baseline[profile], %{"active" => 1, "idle" => false})
      assert query.(profile)["presence"] == expected
    end

    assert %{"runs" => [%{"runId" => ^queued_id, "profileId" => ^target_profile}]} =
             query.(ctx.profile_id)

    assert query.(unrelated_profile)["presence"] == baseline[unrelated_profile]

    [{queued, _}] = Registry.lookup(LemonRouter.RunRegistry, queued_id)
    queued_ref = Process.monitor(queued)
    complete_presence_run(:sys.get_state(queued).execution_request, false)
    assert_receive {:DOWN, ^queued_ref, :process, ^queued, :normal}, 2000
    assert eventually(fn -> LemonRouter.SessionCoordinator.active_run(conversation) == :none end)
    for id <- fresh_ids, do: Store.delete(:runs, id)

    for profile <- [ctx.profile_id, target_profile, unrelated_profile] do
      assert query.(profile)["presence"] == baseline[profile]
    end
  end

  test "concurrent same-F callers callback and dispatch once; conflicting content is rejected",
       ctx do
    {_source, root} = admit_root(ctx)
    captured = captured(root)
    fresh = fresh_request(ctx, "race")

    first =
      Task.async(fn -> RunOrchestrator.submit_native_followup(ctx.server, captured, fresh) end)

    assert_receive {:issuer_pending, issuer, id, _, _, _, _, _}, 2000

    second =
      Task.async(fn -> RunOrchestrator.submit_native_followup(ctx.server, captured, fresh) end)

    send(issuer, {:issuer_reply, id, 200, approved(id)})
    assert Task.await(first) == {:ok, id}
    assert Task.await(second) == {:ok, id}
    assert_receive {:native_dispatch, %{run_id: ^id}}

    assert RunOrchestrator.submit_native_followup(ctx.server, captured, %{
             fresh
             | prompt: "conflicting content"
           }) == {:error, :run_id_conflict}

    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
    refute_receive {:native_dispatch, _}, 50
  end

  test "denial and unavailable callbacks retain F without dispatch or another callback", ctx do
    {_source, root} = admit_root(ctx)

    for {suffix, status, body, outcome} <- [
          {"denied", 200, Jason.encode!(%{"allow" => false}), :denied},
          {"unavailable", 503, "private-backend-error", :admission_unavailable}
        ] do
      fresh = fresh_request(ctx, suffix)

      task =
        Task.async(fn ->
          RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
        end)

      assert_receive {:issuer_pending, issuer, id, _, _, _, _, _}, 2000
      send(issuer, {:issuer_reply, id, status, body})
      assert Task.await(task) == {:error, outcome}

      assert {:ok, %{terminal: true, native_followup: %{status: ^outcome}}} =
               Store.fetch(RunOrchestrator.admission_table(), id)

      assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh) ==
               {:error, outcome}
    end

    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
    refute_receive {:native_dispatch, _}, 50
  end

  test "ambiguous dispatch retains F across owner restart and never reissues or redispatches",
       ctx do
    {_source, root} = admit_root(ctx)
    fresh = fresh_request(ctx, "unknown")
    Application.put_env(:lemon_router, :native_lineage_test_dispatch, :crash)

    task =
      Task.async(fn ->
        RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
      end)

    assert_receive {:issuer_pending, issuer, id, _, _, _, _, _}, 2000
    send(issuer, {:issuer_reply, id, 200, approved(id)})
    assert Task.await(task) == {:error, :outcome_unknown}
    assert_receive {:native_dispatch, %{run_id: ^id}}
    GenServer.stop(ctx.server)
    {:ok, replacement} = GenServer.start_link(RunOrchestrator, [])
    on_exit(fn -> if Process.alive?(replacement), do: GenServer.stop(replacement) end)

    assert RunOrchestrator.submit_native_followup(replacement, captured(root), fresh) ==
             {:error, :outcome_unknown}

    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
    refute_receive {:native_dispatch, _}, 50
  end

  test "issuer rejects unauthorized origins, raw credentials, stale proof and shared privilege synthesis",
       ctx do
    {source, _root} = admit_root(ctx)
    fresh = fresh_request(ctx, "invalid")
    assert {:ok, prepared, _} = NativeLineage.prepare_request(source, fresh)
    valid = invocation(fresh.run_id)

    changed_header =
      put_in(
        valid,
        ["invocationMcpServers", Access.at(0), "headers", "Authorization"],
        "expanded-auth"
      )

    extra =
      Map.update!(
        valid,
        "invocationMcpServers",
        &(&1 ++ [%{"name" => "ambient", "url" => "https://ambient.example/mcp", "headers" => %{}}])
      )

    unauthorized =
      valid
      |> put_in(["invocationMcpServers", Access.at(0), "url"], "https://arbitrary.example/mcp")
      |> put_in(["invocationProof", "serverUrl"], "https://arbitrary.example/mcp")

    stale = invocation(ctx.run_id)

    widened_origins =
      put_in(valid, ["invocationMcpServers", Access.at(0), "allowedOrigins"], [
        "https://bot.example",
        "https://arbitrary.example"
      ])

    widened_tools =
      put_in(valid, ["invocationMcpServers", Access.at(0), "enabledTools"], ["read", "write"])

    widened_private =
      put_in(valid, ["invocationMcpServers", Access.at(0), "approvedPrivateOrigins"], [
        "https://bot.example"
      ])

    for candidate <- [
          changed_header,
          extra,
          unauthorized,
          widened_origins,
          widened_tools,
          widened_private,
          stale,
          Map.put(valid, "sharedMemoryGrant", true)
        ] do
      assert {:error, :admission_unavailable} =
               NativeLineage.apply_invocation(source, prepared, candidate)
    end

    assert {:ok, _} = NativeLineage.apply_invocation(source, prepared, valid)
  end

  test "source A authenticates while target C current Core transport and context rotate independently",
       ctx do
    {_source, root} = admit_root(ctx)
    target_id = ctx.prefix <> "-current-target"

    current_template = %{
      "name" => "current-target-core",
      "url" => "https://current-target.example/mcp",
      "headers" => %{},
      "enabledTools" => ["read"],
      "allowedOrigins" => ["https://current-target.example"],
      "approvedPrivateOrigins" => []
    }

    assert {:ok, _} =
             ProfileStore.create(%{"id" => target_id, "mcpServers" => [current_template]})

    fresh = %{fresh_request(ctx, "new-target-epoch") | agent_id: target_id}

    task =
      Task.async(fn ->
        RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
      end)

    assert_receive {:issuer_pending, issuer, id, body, headers, {:ok, lineage}, _, _}, 2000
    assert Jason.decode!(body) == %{"runId" => id}
    assert {"authorization", "Bearer private-issuer-bearer"} in headers
    assert lineage["sourceProfileId"] == ctx.profile_id
    assert lineage["targetProfileId"] == target_id
    assert lineage["sourceInvocationContextKey"] == "original-actor"

    current_core =
      Map.put(current_template, "headers", %{
        "Authorization" => "Bearer ${LEMON_SECRET:current-target-service-epoch}",
        "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{id}}"
      })

    projection =
      invocation(id)
      |> Map.put("invocationContextKey", "current-target-actor-epoch")
      |> Map.put("memoryContextKey", "current-target-private-audience-epoch")
      |> Map.put("invocationMcpServers", [current_core])
      |> put_in(["invocationProof", "serverName"], current_core["name"])
      |> put_in(["invocationProof", "serverUrl"], current_core["url"])

    send(
      issuer,
      {:issuer_reply, id, 200, Jason.encode!(%{"allow" => true, "invocation" => projection})}
    )

    assert Task.await(task) == {:ok, id}
    assert_receive {:native_dispatch, admitted}
    assert admitted.execution_request.meta.mcp_servers == [current_core]
    assert admitted.execution_request.meta.invocation_context_key == "current-target-actor-epoch"

    assert admitted.execution_request.meta.memory_context_key ==
             "current-target-private-audience-epoch"

    assert admitted.execution_request.meta.invocation_proof.run_id == id
    assert admitted.execution_request.tool_policy.allow == ["read"]
    assert "write" in admitted.execution_request.tool_policy.require_approval
    refute admitted.execution_request.meta.shared_memory_grant
  end

  test "missing or empty current target templates reject fixed F before issuer I/O", ctx do
    {_source, root} = admit_root(ctx)

    for {suffix, profile_attrs} <- [
          {"missing-ceiling", %{"id" => ctx.prefix <> "-missing-ceiling"}},
          {"empty-ceiling", %{"id" => ctx.prefix <> "-empty-ceiling", "mcpServers" => []}}
        ] do
      assert {:ok, profile} = ProfileStore.create(profile_attrs)

      fresh = %{
        fresh_request(ctx, suffix)
        | agent_id: profile["id"],
          meta: %{
            mcp_servers: servers(ctx.run_id),
            target_profile_config_hash: "forged-ceiling",
            target_policy_hash: "forged-policy",
            invocation_proof_verified: true
          }
      }

      assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh) ==
               {:error, :admission_unavailable}

      assert {:ok, %{terminal: true, native_failure: :admission_unavailable}} =
               Store.fetch(RunOrchestrator.admission_table(), fresh.run_id)

      assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh) ==
               {:error, :admission_unavailable}
    end

    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
    refute_receive {:native_dispatch, _}, 50
  end

  test "HTTP response cannot widen current target origins or tools", ctx do
    {_source, root} = admit_root(ctx)

    candidates = [
      {"origin-widening",
       fn projection ->
         put_in(projection, ["invocationMcpServers", Access.at(0), "allowedOrigins"], [
           "https://bot.example",
           "https://arbitrary.example"
         ])
       end},
      {"tool-widening",
       fn projection ->
         put_in(projection, ["invocationMcpServers", Access.at(0), "enabledTools"], [
           "read",
           "write"
         ])
       end}
    ]

    for {suffix, widen} <- candidates do
      fresh = fresh_request(ctx, suffix)

      task =
        Task.async(fn ->
          RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
        end)

      assert_receive {:issuer_pending, issuer, id, _, _, _, _, _}, 2000

      send(
        issuer,
        {:issuer_reply, id, 200,
         Jason.encode!(%{"allow" => true, "invocation" => widen.(invocation(id))})}
      )

      assert Task.await(task) == {:error, :admission_unavailable}

      assert {:ok, %{terminal: true, native_followup: %{status: :admission_unavailable}}} =
               Store.fetch(RunOrchestrator.admission_table(), id)
    end

    refute_receive {:native_dispatch, _}, 50
  end

  test "template and policy rotation during callback fence pending provisioning and factory dispatch",
       ctx do
    {_source, root} = admit_root(ctx)

    for kind <- [:templates, :policy] do
      assert {:ok, _} =
               ProfileStore.update(ctx.profile_id, %{
                 "mcpServers" => templates(),
                 "toolPolicy" => %{}
               })

      fresh = fresh_request(ctx, "callback-rotation-#{kind}")

      task =
        Task.async(fn ->
          RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
        end)

      assert_receive {:issuer_pending, issuer, id, _, _, {:ok, lineage}, _, _}, 2000
      refute Map.has_key?(lineage, "targetProfileConfigHash")
      refute Map.has_key?(lineage, "targetPolicyHash")
      assert {:ok, %{pid: nil}} = NativeLineage.pending_destination(id, "local")

      change =
        if kind == :templates,
          do: %{"mcpServers" => Enum.map(templates(), &Map.put(&1, "enabledTools", []))},
          else: %{"toolPolicy" => %{"allow" => []}}

      assert {:ok, _} = ProfileStore.update(ctx.profile_id, change)
      assert {:error, :destination_mismatch} = NativeLineage.pending_destination(id, "local")
      send(issuer, {:issuer_reply, id, 200, approved(id)})
      assert Task.await(task) == {:error, :admission_unavailable}

      assert {:ok, %{terminal: true, native_followup: %{status: :admission_unavailable}} = row} =
               Store.fetch(RunOrchestrator.admission_table(), id)

      refute Map.has_key?(row, :native_source)

      assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh) ==
               {:error, :admission_unavailable}
    end

    refute_receive {:native_dispatch, _}, 50
    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
  end

  test "post-provision owning guard acknowledges current pending F and rejects target ceiling rotation",
       ctx do
    {_source, root} = admit_root(ctx)
    node = ctx.prefix <> "-provision-node"
    node_pid = self()

    assert :ok =
             NodeRegistry.register_session(node, node, node_pid, 7, %{
               capabilities: %{
                 "coding_agent.run" => %{
                   "version" => 2,
                   "executionContext" => %{"version" => 1},
                   "nativePrivacyContext" => %{"version" => 1}
                 }
               }
             })

    on_exit(fn -> NodeRegistry.unregister(node, node_pid) end)

    for kind <- [:templates, :policy] do
      target_id = ctx.prefix <> "-provision-target-#{kind}"

      assert {:ok, _} =
               ProfileStore.create(%{
                 "id" => target_id,
                 "node" => node,
                 "mcpServers" => templates()
               })

      fresh = %{fresh_request(ctx, "post-provision-#{kind}") | agent_id: target_id}

      task =
        Task.async(fn ->
          RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
        end)

      assert_receive {:issuer_pending, issuer, id, _, _, {:ok, lineage}, _, _}, 2000
      assert lineage["sourceProfileId"] == ctx.profile_id
      assert lineage["targetProfileId"] == target_id

      args = %{
        "name" => "lemon_bot/invocations/" <> id,
        "operationId" => id,
        "value" => "private-issued-per-F-" <> id
      }

      assert {:ok, opts} = LemonControlPlane.NodeSecretProofs.dispatch_opts(node, args)
      assert opts[:private_proof_kind] == :pending
      assert opts[:expected_pid] == node_pid
      assert opts[:expected_generation] == 7
      assert :ok = LemonControlPlane.NodeSecretProofs.verify_after_dispatch(node, args, opts)

      change =
        if kind == :templates,
          do: %{"mcpServers" => Enum.map(templates(), &Map.put(&1, "enabledTools", []))},
          else: %{"toolPolicy" => %{"allow" => []}}

      assert {:ok, _} = ProfileStore.update(target_id, change)

      assert {:error,
              {:unavailable, _message,
               %{
                 "reason" => "private_proof_acknowledgement_changed",
                 "preDispatch" => false,
                 "retrySafe" => false,
                 "mutationMayHaveApplied" => true
               }}} = LemonControlPlane.NodeSecretProofs.verify_after_dispatch(node, args, opts)

      assert {:error, :destination_mismatch} = NativeLineage.pending_destination(id, node)
      send(issuer, {:issuer_reply, id, 200, approved(id)})
      assert Task.await(task) == {:error, :admission_unavailable}

      assert {:ok, %{terminal: true, native_followup: %{status: :admission_unavailable}}} =
               Store.fetch(RunOrchestrator.admission_table(), id)
    end

    refute_receive {:native_dispatch, _}, 50
    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
  end

  test "owning queue rejects initial roots and prepared F after current template or policy changes",
       ctx do
    {_source, root} = admit_root(ctx)
    original_coordinator = Application.fetch_env!(:lemon_router, :session_coordinator)
    Application.put_env(:lemon_router, :session_coordinator, LemonRouter.SessionCoordinator)

    :sys.replace_state(ctx.server, fn state ->
      %{state | run_process_opts: Map.put(state.run_process_opts, :submit_to_gateway?, false)}
    end)

    on_exit(fn ->
      Application.put_env(:lemon_router, :session_coordinator, original_coordinator)
    end)

    for kind <- [:templates, :policy], provenance <- [:initial, :followup] do
      target_id = ctx.prefix <> "-queue-#{provenance}-#{kind}"
      assert {:ok, _} = ProfileStore.create(%{"id" => target_id, "mcpServers" => templates()})
      session = "agent:#{target_id}:main"
      ids = Enum.map(["active", "queued"], &(ctx.prefix <> "-queue-#{provenance}-#{kind}-" <> &1))
      conversation = {:session, session}

      on_exit(fn ->
        for {pid, _} <- Registry.lookup(LemonRouter.ConversationRegistry, conversation),
            do: DynamicSupervisor.terminate_child(LemonRouter.SessionCoordinatorSupervisor, pid)

        for id <- ids do
          for {pid, _} <- Registry.lookup(LemonRouter.RunRegistry, id),
              do: DynamicSupervisor.terminate_child(LemonRouter.RunSupervisor, pid)

          Store.delete(:run_receipts, id)
          Store.delete(:runs, id)
          Store.delete(:native_resume_contexts, {:run, id})
        end

        Store.delete(:sessions_index, session)
      end)

      for id <- ids do
        if provenance == :initial do
          request = root_request(%{ctx | profile_id: target_id}, id, servers(id))
          assert RunOrchestrator.submit(ctx.server, request) == {:ok, id}
        else
          fresh = %{
            fresh_request(ctx, "unused")
            | run_id: id,
              agent_id: target_id,
              session_key: session
          }

          task =
            Task.async(fn ->
              RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
            end)

          assert_receive {:issuer_pending, issuer, ^id, _, _, _, _, _}, 2000
          send(issuer, {:issuer_reply, id, 200, approved(id)})
          assert Task.await(task) == {:ok, id}
        end
      end

      [active_id, queued_id] = ids
      [{active, _}] = Registry.lookup(LemonRouter.RunRegistry, active_id)
      [{coordinator, _}] = Registry.lookup(LemonRouter.ConversationRegistry, conversation)
      assert Enum.map(:sys.get_state(coordinator).queue, & &1.run_id) == [queued_id]
      assert :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(queued_id))

      change =
        if kind == :templates,
          do: %{"mcpServers" => Enum.map(templates(), &Map.put(&1, "enabledTools", []))},
          else: %{"toolPolicy" => %{"allow" => []}}

      assert {:ok, _} = ProfileStore.update(target_id, change)
      complete_presence_run(:sys.get_state(active).execution_request, true)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       meta: %{run_id: ^queued_id},
                       payload: %{
                         completed: %{
                           ok: false,
                           error: %{type: :run_start_failed, reason: :admission_unavailable}
                         }
                       }
                     },
                     2000

      assert Registry.lookup(LemonRouter.RunRegistry, queued_id) == []
      assert :sys.get_state(coordinator).queue == []

      assert {:ok, %{terminal: true} = row} =
               Store.fetch(RunOrchestrator.admission_table(), queued_id)

      if provenance == :followup do
        assert row.native_followup.status == :admission_unavailable

        fresh = %{
          fresh_request(ctx, "unused")
          | run_id: queued_id,
            agent_id: target_id,
            session_key: session
        }

        assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh) ==
                 {:error, :admission_unavailable}
      else
        assert row.native_failure == :admission_unavailable
        assert row.native_root_binding.invocation_proof_required
      end

      refute_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^queued_id}}, 50
    end

    refute_receive {:native_dispatch, _}, 50
    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
  end

  test "RunProcess rechecks current ceiling after activation before sending private runtime payload",
       ctx do
    {_source, root} = admit_root(ctx)
    fresh = fresh_request(ctx, "runtime-send-fence")

    task =
      Task.async(fn ->
        RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
      end)

    assert_receive {:issuer_pending, issuer, id, _, _, _, _, _}, 2000
    send(issuer, {:issuer_reply, id, 200, approved(id)})
    assert Task.await(task) == {:ok, id}
    assert_receive {:native_dispatch, submission}
    assert :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(id))

    assert {:ok, run} =
             LemonRouter.RunProcess.start_link(%{
               run_id: id,
               session_key: submission.session_key,
               execution_request: submission.execution_request,
               submit_to_gateway?: false,
               engine_runtime: RuntimeObserver
             })

    on_exit(fn ->
      if Process.alive?(run), do: GenServer.stop(run)
      Store.delete(:runs, id)
      Store.delete(:run_receipts, id)
      Store.delete(:sessions_index, submission.session_key)
    end)

    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"mcpServers" => []})
    send(run, :submit_to_gateway)

    assert_receive %LemonCore.Event{
                     type: :run_completed,
                     meta: %{run_id: ^id},
                     payload: %{
                       completed: %{
                         ok: false,
                         error: %{
                           type: :runtime_submission_failed,
                           reason: :admission_unavailable
                         }
                       }
                     }
                   },
                   2000

    assert {:ok, %{terminal: true, native_followup: %{status: :admission_unavailable}}} =
             Store.fetch(RunOrchestrator.admission_table(), id)

    refute_receive {:native_runtime_payload, _}, 50
    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
  end

  test "destination reconnect during issuer callback cannot receive private F or dispatch it",
       ctx do
    {_source, root} = admit_root(ctx)
    node = ctx.prefix <> "-reconnect-node"

    assert :ok =
             NodeRegistry.register_session(node, node, self(), 7, %{
               capabilities: %{
                 "coding_agent.run" => %{
                   "version" => 2,
                   "executionContext" => %{"version" => 1},
                   "nativePrivacyContext" => %{"version" => 1}
                 }
               }
             })

    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"node" => node})
    fresh = fresh_request(ctx, "reconnect")

    task =
      Task.async(fn ->
        RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh)
      end)

    assert_receive {:issuer_pending, issuer, id, _, _, _, _, _}, 2000

    replacement =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      NodeRegistry.unregister(node, replacement)
      send(replacement, :stop)
    end)

    assert :ok =
             NodeRegistry.register_session(node, node, replacement, 8, %{
               capabilities: %{
                 "coding_agent.run" => %{
                   "version" => 2,
                   "executionContext" => %{"version" => 1},
                   "nativePrivacyContext" => %{"version" => 1}
                 }
               }
             })

    assert {:error, :destination_mismatch} = NativeLineage.pending_destination(id, node)
    send(issuer, {:issuer_reply, id, 200, approved(id)})
    assert Task.await(task) == {:error, :admission_unavailable}

    assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh) ==
             {:error, :admission_unavailable}

    refute_receive {:native_dispatch, _}, 50
    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
  end

  test "unavailable exact target preserves the fixed rejection without issuer I/O", ctx do
    {_source, root} = admit_root(ctx)
    fresh = %{fresh_request(ctx, "missing") | agent_id: "not-a-managed-profile"}

    assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh) ==
             {:error, :admission_unavailable}

    assert {:ok, %{terminal: true, native_failure: :admission_unavailable}} =
             Store.fetch(RunOrchestrator.admission_table(), fresh.run_id)

    assert RunOrchestrator.submit_native_followup(ctx.server, captured(root), fresh) ==
             {:error, :admission_unavailable}

    refute_receive {:issuer_pending, _, _, _, _, _, _, _}, 50
    refute_receive {:native_dispatch, _}, 50
  end

  test "exact destination and source node generation fail closed", ctx do
    node = ctx.prefix <> "-node"

    assert :ok =
             NodeRegistry.register_session(node, ctx.prefix <> "-name", self(), 7, %{
               capabilities: %{
                 "coding_agent.run" => %{
                   "version" => 2,
                   "executionContext" => %{"version" => 1},
                   "nativePrivacyContext" => %{"version" => 1}
                 }
               }
             })

    node_pid = self()
    on_exit(fn -> NodeRegistry.unregister(node, node_pid) end)
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"node" => node})
    {source, root} = admit_root(ctx)
    private = captured(root)
    assert {:error, :invalid_native_lineage} = NativeLineage.authenticate(private, :local)

    assert {:error, :invalid_native_lineage} =
             NativeLineage.authenticate(
               private,
               %{node_id: node, connection_pid: self(), generation: 6}
             )

    assert {:ok, ^source} =
             NativeLineage.authenticate(
               private,
               %{node_id: node, connection_pid: self(), generation: 7}
             )

    assert {:error, :invalid_native_lineage} =
             RunOrchestrator.register_native_source_floor_from_node(private, %{allow: :all}, %{
               node_id: node,
               connection_pid: self(),
               generation: 6
             })

    assert :ok =
             RunOrchestrator.register_native_source_floor_from_node(
               private,
               source.tool_policy,
               %{node_id: node, connection_pid: self(), generation: 7}
             )

    assert {:error, :admission_unavailable} = NativeLineage.destination(ctx.prefix <> "-name")

    assert {:ok, _, destination} =
             NativeLineage.prepare_request(source, fresh_request(ctx, "remote"))

    assert :ok = NativeLineage.current_destination(destination)
    fresh = fresh_request(ctx, "remote-renewed")
    session = %{node_id: node, connection_pid: self(), generation: 7}

    task =
      Task.async(fn ->
        RunOrchestrator.submit_native_followup_from_node(ctx.server, private, fresh, session)
      end)

    assert_receive {:issuer_pending, issuer, id, _, _, {:ok, lineage}, _, _}, 2000
    assert lineage["targetNodeId"] == node
    assert {:ok, %{pid: node_pid, generation: 7}} = NativeLineage.pending_destination(id, node)
    assert node_pid == self()
    send(issuer, {:issuer_reply, id, 200, approved(id)})
    assert Task.await(task) == {:ok, id}
    assert_receive {:native_dispatch, admitted}
    assert admitted.execution_request.meta.native_destination_pid == self()
    assert admitted.execution_request.meta.native_destination_generation == 7
    assert admitted.execution_request.meta.invocation_proof.run_id == id

    assert :ok =
             NodeRegistry.register_session(node, ctx.prefix <> "-name", self(), 8, %{
               capabilities: %{
                 "coding_agent.run" => %{"nativePrivacyContext" => %{"version" => 0}}
               }
             })

    assert {:error, :admission_unavailable} = NativeLineage.current_destination(destination)

    assert {:error, :invalid_native_lineage} =
             NativeLineage.authenticate(
               private,
               %{node_id: node, connection_pid: self(), generation: 7}
             )

    assert {:error, :invalid_native_lineage} =
             RunOrchestrator.register_native_source_floor_from_node(private, %{allow: :all}, %{
               node_id: node,
               connection_pid: self(),
               generation: 8
             })
  end

  test "human-named profile placement seals the actual durable node once", ctx do
    node = ctx.prefix <> "-durable"
    name = ctx.prefix <> "-human"
    assert :ok = NodeRegistry.register_session(node, name, self(), 7, capable())
    node_pid = self()
    on_exit(fn -> NodeRegistry.unregister(node, node_pid) end)
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"node" => name})
    {source, root} = admit_root(ctx)
    assert root.execution_request.meta.node == node
    assert root.execution_request.meta.native_destination_pid == self()
    assert root.execution_request.meta.native_destination_generation == 7
    assert source.node_id == node
    assert source.node_generation == 7

    assert {:error, :invalid_native_lineage} =
             NativeLineage.authenticate(captured(root), %{
               node_id: name,
               connection_pid: self(),
               generation: 7
             })

    assert {:ok, %{"node" => ^name}} = ProfileStore.get(ctx.profile_id)

    assert {:ok, prepared, destination} =
             NativeLineage.prepare_request(source, fresh_request(ctx, "named-prepared"))

    assert destination.node_id == node
    assert prepared.meta.node == node
    fresh = fresh_request(ctx, "named-renewed")
    session = %{node_id: node, connection_pid: self(), generation: 7}

    task =
      Task.async(fn ->
        RunOrchestrator.submit_native_followup_from_node(
          ctx.server,
          captured(root),
          fresh,
          session
        )
      end)

    assert_receive {:issuer_pending, issuer, id, _, _, {:ok, lineage}, _, _}, 2000
    assert lineage["targetNodeId"] == node
    assert {:ok, %{node_id: ^node, generation: 7}} = NativeLineage.pending_destination(id, node)
    assert {:error, :destination_mismatch} = NativeLineage.pending_destination(id, name)
    send(issuer, {:issuer_reply, id, 200, approved(id)})
    assert Task.await(task) == {:ok, id}
    assert_receive {:native_dispatch, admitted}
    assert admitted.execution_request.meta.node == node
    id2 = ctx.prefix <> "-named-proofless"
    assert RunOrchestrator.submit(ctx.server, memory_request(ctx, id2)) == {:ok, id2}
    assert_receive {:native_dispatch, proofless}
    assert proofless.execution_request.meta.node == node

    assert :ok =
             RunOrchestrator.register_native_source_floor_from_node(
               %{run_id: id2},
               %{allow: ["read"]},
               %{node_id: node, connection_pid: self(), generation: 7}
             )
  end

  test "a human name moved to another durable node fences sealed work and binds only the new node",
       ctx do
    name = ctx.prefix <> "-human"
    a = ctx.prefix <> "-a"
    b = ctx.prefix <> "-b"
    a_pid = self()
    assert :ok = NodeRegistry.register_session(a, name, a_pid, 7, capable())
    on_exit(fn -> NodeRegistry.unregister(a, a_pid) end)
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"node" => name})
    {_source, root} = admit_root(ctx)
    NodeRegistry.unregister(a, a_pid)

    b_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = NodeRegistry.register_session(b, name, b_pid, 7, capable())

    on_exit(fn ->
      NodeRegistry.unregister(b, b_pid)
      send(b_pid, :stop)
    end)

    assert NativeLineage.validate_activation(root.execution_request) ==
             {:error, :admission_unavailable}

    assert {:ok, %{terminal: true, native_failure: :admission_unavailable}} =
             Store.fetch(RunOrchestrator.admission_table(), ctx.run_id)

    id = ctx.prefix <> "-moved"
    assert RunOrchestrator.submit(ctx.server, root_request(ctx, id, servers(id))) == {:ok, id}
    assert_receive {:native_dispatch, moved}
    assert moved.execution_request.meta.node == b
    assert moved.execution_request.meta.native_destination_pid == b_pid
  end

  test "unknown, unsupported and offline ID-shadowed placements fail closed without local fallback",
       ctx do
    fenced = fn id ->
      assert {:ok, row} = Store.fetch(RunOrchestrator.admission_table(), id)
      refute Map.has_key?(row, :native_source)
      refute Map.has_key?(row, :native_root_binding)
    end

    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"node" => ctx.prefix <> "-missing"})
    id = ctx.prefix <> "-missing-proof"

    assert RunOrchestrator.submit(ctx.server, root_request(ctx, id, servers(id))) ==
             {:error, :admission_unavailable}

    fenced.(id)
    id = ctx.prefix <> "-missing-proofless"

    assert RunOrchestrator.submit(ctx.server, memory_request(ctx, id)) ==
             {:error, :admission_unavailable}

    fenced.(id)

    c = ctx.prefix <> "-legacy"
    c_name = ctx.prefix <> "-legacy-name"
    c_pid = self()

    assert :ok =
             NodeRegistry.register_session(c, c_name, c_pid, 7, %{
               capabilities: %{"coding_agent.run" => %{"version" => 1}}
             })

    on_exit(fn -> NodeRegistry.unregister(c, c_pid) end)
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"node" => c_name})
    id = ctx.prefix <> "-legacy-proof"

    assert RunOrchestrator.submit(ctx.server, root_request(ctx, id, servers(id))) ==
             {:error, :admission_unavailable}

    fenced.(id)

    x = ctx.prefix <> "-x"
    y = ctx.prefix <> "-y"
    x_pid = self()

    shadow =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = NodeRegistry.register_session(x, ctx.prefix <> "-x-name", x_pid, 7, capable())
    assert :ok = NodeRegistry.register_session(y, x, shadow, 7, capable())

    on_exit(fn ->
      NodeRegistry.unregister(x, x_pid)
      NodeRegistry.unregister(y, shadow)
      send(shadow, :stop)
    end)

    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"node" => x})
    id = ctx.prefix <> "-shadow-live"
    assert RunOrchestrator.submit(ctx.server, root_request(ctx, id, servers(id))) == {:ok, id}
    assert_receive {:native_dispatch, sealed}
    assert sealed.execution_request.meta.node == x
    assert sealed.execution_request.meta.native_destination_pid == self()
    NodeRegistry.unregister(x, x_pid)
    id = ctx.prefix <> "-shadow-offline"

    assert RunOrchestrator.submit(ctx.server, root_request(ctx, id, servers(id))) ==
             {:error, :admission_unavailable}

    refute_receive {:native_dispatch, _}, 50
  end

  defp capable,
    do: %{
      capabilities: %{
        "coding_agent.run" => %{
          "version" => 2,
          "executionContext" => %{"version" => 1},
          "nativePrivacyContext" => %{"version" => 1}
        }
      }
    }

  defp admit_root(ctx, opts \\ []) do
    request = root_request(ctx, ctx.run_id, servers(ctx.run_id))
    assert RunOrchestrator.submit(ctx.server, request) == {:ok, ctx.run_id}
    assert_receive {:native_dispatch, submission}

    transport =
      case submission.execution_request.meta[:node] do
        node when node in [nil, "local"] -> :local
        node -> %{node_id: node, connection_pid: self(), generation: 7}
      end

    if Keyword.get(opts, :register_floor, true) do
      assert :ok =
               NativeLineage.register_source_floor(
                 captured(submission),
                 submission.execution_request.tool_policy,
                 transport
               )
    end

    assert {:ok, source} = NativeLineage.authenticate(captured(submission), transport)
    {source, submission}
  end

  defp memory_request(ctx, id, invocation_servers \\ []) do
    assert {:ok, profile} = ProfileStore.get_for_execution(ctx.profile_id)

    assert {:ok, request} =
             ProfileStore.chat_request(profile, "actual memory-only source",
               run_id: id,
               invocation_mcp_servers: invocation_servers
             )

    assert {:ok, request} =
             InvocationProof.attach_execution_context(request, %{
               "runId" => id,
               "invocationContextKey" => "memory-only-actor",
               "memoryContextKey" => "memory-only-audience",
               "sharedMemoryGrant" => false
             })

    request
  end

  defp root_request(ctx, id, invocation_servers) do
    assert {:ok, profile} = ProfileStore.get_for_execution(ctx.profile_id)

    assert {:ok, request} =
             ProfileStore.chat_request(profile, "actual source",
               run_id: id,
               tool_policy: %{allow: ["read", "write", "task"], require_approval: ["write"]}
             )

    [server | _] = invocation_servers

    descriptor =
      proof(id) |> Map.put("serverName", server["name"]) |> Map.put("serverUrl", server["url"])

    assert {:ok, verified_proof} = InvocationProof.validate(descriptor, id, invocation_servers)

    meta =
      request.meta
      |> Map.put(:invocation_context_key, "original-actor")
      |> Map.put(:memory_context_key, "original-private-audience")
      |> Map.put(:memory_context_verified, true)
      |> Map.put(:invocation_proof, verified_proof)
      |> Map.put(:invocation_proof_verified, true)
      |> Map.put(:shared_memory_grant, false)
      |> Map.put(:mcp_servers, invocation_servers)

    %{request | meta: meta}
  end

  defp captured(submission),
    do: %{
      run_id: submission.execution_request.meta.native_lineage_run_id,
      lineage_handle: submission.execution_request.meta.native_lineage_handle
    }

  defp fresh_request(ctx, suffix),
    do:
      RunRequest.new(%{
        run_id: ctx.prefix <> "-" <> suffix,
        agent_id: ctx.profile_id,
        session_key: "agent:#{ctx.profile_id}:main",
        prompt: "fresh execution",
        queue_mode: :steer,
        tool_policy: %{allow: ["read", "write"]},
        meta: %{
          parent_run_id: "forged-parent",
          invocation_context_key: "forged-actor",
          memory_context_key: "forged-audience",
          shared_memory_grant: true,
          invocation_proof_verified: true
        }
      })

  defp approved(id), do: Jason.encode!(%{"allow" => true, "invocation" => invocation(id)})

  defp invocation(id),
    do: %{
      "invocationContextKey" => "fresh-current-actor",
      "memoryContextKey" => "fresh-private-target-audience",
      "invocationToolPolicy" => %{"allow" => ["read"]},
      "invocationMcpServers" => servers(id),
      "invocationProof" => proof(id),
      "sharedMemoryGrant" => false
    }

  defp servers(id),
    do: [
      %{
        "name" => "core",
        "url" => "https://bot.example/mcp",
        "headers" => %{
          "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{id}}",
          "Authorization" => "${LEMON_SECRET:private-static-header}"
        },
        "allowedOrigins" => ["https://bot.example"],
        "approvedPrivateOrigins" => [],
        "enabledTools" => ["read"]
      }
    ]

  defp proof(id),
    do: %{
      "runId" => id,
      "serverName" => "core",
      "serverUrl" => "https://bot.example/mcp",
      "headerName" => "X-Lemon-Bot-Invocation",
      "secretName" => "lemon_bot/invocations/" <> id
    }

  defp templates, do: Enum.map(servers("template"), &Map.put(&1, "headers", %{}))

  defp complete_presence_run(command, ok?) do
    event =
      LemonCore.Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{
          completed: LemonCore.Events.Completion.new(%{ok: ok?, answer: ""}),
          duration_ms: 0
        }),
        %{run_id: command.run_id, session_key: command.session_key}
      )

    :ok = LemonRouter.RunCompletion.publish(command, event)
  end

  defp eventually(fun, timeout_ms \\ 5_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end

  defp assert_zero_cap(request, cwd) do
    settings = %CodingAgent.SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4o", base_url: nil},
      providers: %{"openai" => %{api_key: "test-key"}},
      provider_routing: %{enabled: false},
      retry_enabled: false,
      compaction_enabled: false,
      model_routing: %{enabled: true, max_cost_usd: 0, rules: []}
    }

    file = Path.join(cwd, "routing.jsonl")
    cwd |> CodingAgent.SessionManager.new() |> CodingAgent.SessionManager.persist(file)
    owner = self()

    session =
      start_supervised!(
        {CodingAgent.Session,
         cwd: cwd,
         workspace_dir: cwd,
         session_file: file,
         settings_manager: settings,
         model: request.model,
         model_explicit: request.model_explicit,
         system_prompt: "test",
         tools: [],
         register: false,
         stream_fn: fn _, _, _ ->
           send(owner, :unexpected_provider_call)
           raise "zero-cap request reached provider"
         end}
      )

    CodingAgent.Session.subscribe(session)
    assert :ok = CodingAgent.Session.prompt(session, request.prompt)
    assert_receive {:session_event, _, {:error, :model_routing_cost_cap, _}}, 5_000
    refute_received :unexpected_provider_call
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
