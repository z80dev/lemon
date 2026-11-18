defmodule LemonControlPlane.Methods.SessionLifecycleAdmissionTest do
  @moduledoc """
  `sessions.reset` and `sessions.delete` against the real router admission
  path: orchestrator, coordinator, fixed-ID admission and RunProcess. Only the
  execution boundary is replaced, so another client's run stays active until the
  test completes it.
  """

  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{SessionsDelete, SessionsPrune, SessionsReset}

  alias LemonCore.{
    ChatStateStore,
    Event,
    ExecutionCommand,
    PolicyStore,
    RunHistoryStore,
    RunRequest,
    RunStore,
    SessionLifecycle,
    Store
  }

  alias LemonRouter.RunCompletion

  defmodule ControlledRuntime do
    @behaviour LemonCore.EngineRuntime
    def available?, do: true
    def run_pid(_), do: nil
    def cancel_by_run_id(_, _), do: :ok

    def submit_execution(command) do
      send(Application.fetch_env!(:lemon_router, :sessions_reset_test_pid), {:execution, command})
      :ok
    end
  end

  # Fresh ETS store whose session-policy deletion fails with the configured
  # reason and reports each attempt, so a retry would be observable.
  defmodule PolicyDeleteFailingBackend do
    alias LemonCore.Store.EtsBackend

    for {name, arity} <- EtsBackend.__info__(:functions), {name, arity} != {:delete, 3} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: EtsBackend.unquote(name)(unquote_splicing(args))
    end

    def delete(_state, :session_policies, key) do
      send(Application.fetch_env!(:lemon_router, :sessions_reset_test_pid), {:policy_delete, key})
      {:error, Application.fetch_env!(:lemon_router, :sessions_reset_policy_delete_error)}
    end

    def delete(state, table, key), do: EtsBackend.delete(state, table, key)
  end

  # The test Store's ETS backend, except that deleting a lifecycle fence row
  # fails while the configured flag is set.
  defmodule FenceDeleteFailingBackend do
    alias LemonCore.Store.EtsBackend

    for {name, arity} <- EtsBackend.__info__(:functions), {name, arity} != {:delete, 3} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: EtsBackend.unquote(name)(unquote_splicing(args))
    end

    def delete(state, :session_lifecycle_fences = table, key) do
      if Application.get_env(:lemon_router, :sessions_reset_fail_fence_delete),
        do: {:error, :disk_full},
        else: EtsBackend.delete(state, table, key)
    end

    def delete(state, table, key), do: EtsBackend.delete(state, table, key)
  end

  setup do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    key = "agent:default:tui:local:main:reset-#{suffix}"
    previous_runtime = Application.get_env(:lemon_router, :engine_runtime)
    previous_pid = Application.get_env(:lemon_router, :sessions_reset_test_pid)
    Application.put_env(:lemon_router, :engine_runtime, ControlledRuntime)
    Application.put_env(:lemon_router, :sessions_reset_test_pid, self())

    on_exit(fn ->
      if pid = Process.whereis(RunHistoryStore), do: :sys.resume(pid)
      LemonRouter.abort(key)
      restore_env(:engine_runtime, previous_runtime)
      restore_env(:sessions_reset_test_pid, previous_pid)
      RunStore.delete_session(key)
      ChatStateStore.delete(key)
      PolicyStore.delete_session(key)
      Store.delete(:agent_messaging_sessions, key)
    end)

    %{key: key}
  end

  test "reset is refused while another client's run is active and changes nothing", %{key: key} do
    seed_session(key)

    assert {:ok, run_id} = LemonRouter.submit(request(key, "active work"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = active}, 2_000

    assert {:error,
            {:conflict, _message,
             %{"reason" => "session_busy", "mutationMayHaveApplied" => false}}} =
             SessionsReset.handle(%{"sessionKey" => key}, %{})

    assert policy(key) == %{model: "private-model"}
    refute ChatStateStore.get(key) == nil
    assert {:ok, [_ | _]} = RunHistoryStore.fetch(key, limit: 1)

    finish(active)

    await(fn ->
      match?({:ok, %{presence: %{idle: true}}}, LemonRouter.run_presence(%{session_key: key}))
    end)

    assert {:ok, %{"summary" => %{"verified" => true, "reset" => true}}} =
             SessionsReset.handle(%{"sessionKey" => key}, %{})

    assert policy(key) == nil
    assert ChatStateStore.get(key) == nil
    assert {:ok, []} = RunHistoryStore.fetch(key, limit: 1)
  end

  test "run admission for the session is refused while its reset is in flight", %{key: key} do
    seed_session(key)
    history = Process.whereis(RunHistoryStore)
    :ok = :sys.suspend(history)
    reset = Task.async(fn -> SessionsReset.handle(%{"sessionKey" => key}, %{}) end)

    try do
      # The reset has deleted policy and is now waiting on run-history deletion.
      await(fn -> policy(key) == nil end)

      assert {:error, :session_lifecycle_in_progress} =
               LemonRouter.submit(request(key, "racing work from another client"))

      refute_receive {:execution, _}, 100

      for method <- [SessionsReset, SessionsDelete] do
        assert {:error,
                {:conflict, _message,
                 %{"reason" => "lifecycle_in_progress", "mutationMayHaveApplied" => false}}} =
                 method.handle(%{"sessionKey" => key}, %{})
      end
    after
      :sys.resume(history)
    end

    assert {:ok, %{"summary" => %{"verified" => true}}} = Task.await(reset, 10_000)
    assert {:ok, []} = RunHistoryStore.fetch(key, limit: 1)
    assert ChatStateStore.get(key) == nil

    # The fence ends with the reset: the next admission for the session is accepted.
    assert {:ok, run_id} = LemonRouter.submit(request(key, "work after reset"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = after_reset}, 2_000
    finish(after_reset)
  end

  test "an unverifiable history deletion is reported as unknown and is not retried",
       %{key: key} do
    seed_session(key)
    history = Process.whereis(RunHistoryStore)
    :ok = :sys.suspend(history)

    try do
      assert {:error,
              {:unavailable, _message,
               %{
                 "reason" => "outcome_unknown",
                 "retrySafe" => false,
                 "mutationMayHaveApplied" => true
               }}} = SessionsReset.handle(%{"sessionKey" => key}, %{})

      {:messages, messages} = Process.info(history, :messages)

      assert Enum.count(messages, &match?({:"$gen_call", _from, {:delete_session, ^key}}, &1)) ==
               1
    after
      :sys.resume(history)
    end
  end

  test "a dead reset owner's fence is held until reconciled, then released", %{key: key} do
    seed_session(key)
    history = Process.whereis(RunHistoryStore)
    :ok = :sys.suspend(history)
    caller = spawn(fn -> SessionsReset.handle(%{"sessionKey" => key}, %{}) end)

    try do
      await(fn -> policy(key) == nil end)

      assert {:error, :session_lifecycle_in_progress} =
               LemonRouter.submit(request(key, "blocked"))

      # The operation has its own fence owner; the caller is not it.
      assert {:ok, %{owner_pid: owner}} = LemonCore.LifecycleFenceStore.fetch(key)
      refute owner == caller
      Process.exit(owner, :kill)

      # The dead owner's history deletion is still queued at its owner, so the
      # reconcile check cannot pass and the fence must stay held.
      Process.sleep(200)

      assert {:error, :session_lifecycle_in_progress} =
               LemonRouter.submit(request(key, "still blocked"))
    after
      :sys.resume(history)
    end

    await(fn -> match?({:ok, []}, RunHistoryStore.fetch(key, limit: 1)) end)
    command = await_admitted(key, "after owner exit")

    # The released fence records that the dead owner's reset may have partly applied.
    assert {:ok, %{state: "outcome_unknown", operation: :reset}} =
             LemonCore.LifecycleFenceStore.fetch(key)

    finish(command)
  end

  test "the admission fence survives an orchestrator restart", %{key: key} do
    seed_session(key)
    history = Process.whereis(RunHistoryStore)
    :ok = :sys.suspend(history)
    reset = Task.async(fn -> SessionsReset.handle(%{"sessionKey" => key}, %{}) end)

    try do
      await(fn -> policy(key) == nil end)
      original = Process.whereis(LemonRouter.RunOrchestrator)
      Process.exit(original, :kill)

      await(fn ->
        replacement = Process.whereis(LemonRouter.RunOrchestrator)
        is_pid(replacement) and replacement != original
      end)

      assert {:error, :session_lifecycle_in_progress} =
               LemonRouter.submit(request(key, "racing work after restart"))

      refute_receive {:execution, _}, 100

      for method <- [SessionsReset, SessionsDelete] do
        assert {:error, {:conflict, _message, %{"reason" => "lifecycle_in_progress"}}} =
                 method.handle(%{"sessionKey" => key}, %{})
      end
    after
      :sys.resume(history)
    end

    assert {:ok, %{"summary" => %{"verified" => true}}} = Task.await(reset, 10_000)
    assert {:ok, run_id} = LemonRouter.submit(request(key, "work after reset"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000
    finish(command)
  end

  test "a definitively rejected submission leaves the session provably idle", %{key: key} do
    seed_session(key)
    missing = "missing-agent-#{System.unique_integer([:positive])}"

    assert {:error, _reason} =
             LemonRouter.submit(%{request(key, "unknown agent") | agent_id: missing})

    refute_receive {:execution, _}, 100
    assert {:ok, %{presence: %{idle: true}}} = LemonRouter.run_presence(%{session_key: key})

    assert {:ok, %{"summary" => %{"verified" => true}}} =
             SessionsReset.handle(%{"sessionKey" => key}, %{})
  end

  test "a submission refused by the fence leaves no unresolved admission", %{key: key} do
    seed_session(key)
    holder = hold_fence(key)

    assert {:error, :session_lifecycle_in_progress} =
             LemonRouter.submit(request(key, "refused by the fence"))

    release_fence(holder)
    assert {:ok, %{presence: %{idle: true}}} = LemonRouter.run_presence(%{session_key: key})

    assert {:ok, %{"summary" => %{"verified" => true}}} =
             SessionsReset.handle(%{"sessionKey" => key}, %{})
  end

  @tag :tmp_dir
  test "an idle native session's follow-up is fenced and present until its turn ends",
       %{key: key, tmp_dir: tmp_dir} do
    owner = self()

    stream_fn = fn _model, _context, _options ->
      send(owner, {:model_request, self()})

      receive do
        :finish_turn -> :ok
      after
        5_000 -> :ok
      end

      {:error, :test_turn_finished}
    end

    session =
      start_supervised!(
        {CodingAgent.Session,
         cwd: tmp_dir,
         workspace_dir: Path.join(tmp_dir, "workspace"),
         model: %LemonAi.Types.Model{
           id: "lifecycle-model",
           name: "Lifecycle",
           api: :mock,
           provider: :mock_provider,
           base_url: "https://api.mock.test",
           context_window: 128_000,
           max_tokens: 4096
         },
         session_key: key,
         stream_fn: stream_fn}
      )

    holder = hold_fence(key)

    assert {:error, :session_lifecycle_in_progress} =
             CodingAgent.Session.handle_async_followup(session, "background task finished")

    refute_receive {:model_request, _}, 200
    release_fence(holder)

    assert :ok = CodingAgent.Session.handle_async_followup(session, "background task finished")
    assert_receive {:model_request, turn}, 2_000
    assert {:ok, %{presence: %{idle: false}}} = LemonRouter.run_presence(%{session_key: key})

    assert {:error, {:conflict, _message, %{"reason" => "session_busy"}}} =
             SessionsReset.handle(%{"sessionKey" => key}, %{})

    send(turn, :finish_turn)

    await(fn ->
      match?({:ok, %{presence: %{idle: true}}}, LemonRouter.run_presence(%{session_key: key}))
    end)
  end

  @tag :tmp_dir
  test "a follow-up turn stays present across an activity registry restart",
       %{key: key, tmp_dir: tmp_dir} do
    owner = self()

    stream_fn = fn _model, _context, _options ->
      send(owner, {:model_request, self()})

      receive do
        :finish_turn -> :ok
      after
        5_000 -> :ok
      end

      {:error, :test_turn_finished}
    end

    session =
      start_supervised!(
        {CodingAgent.Session,
         cwd: tmp_dir,
         workspace_dir: Path.join(tmp_dir, "workspace"),
         model: %LemonAi.Types.Model{
           id: "lifecycle-model",
           name: "Lifecycle",
           api: :mock,
           provider: :mock_provider,
           base_url: "https://api.mock.test",
           context_window: 128_000,
           max_tokens: 4096
         },
         session_key: key,
         stream_fn: stream_fn}
      )

    assert :ok = CodingAgent.Session.handle_async_followup(session, "background task finished")
    assert_receive {:model_request, turn}, 2_000

    activity =
      Enum.find_value(
        [LemonCore.SessionActivity, LemonCore.SessionActivity.Registry],
        &Process.whereis/1
      )

    Process.exit(activity, :kill)

    await(fn ->
      replacement =
        Enum.find_value(
          [LemonCore.SessionActivity, LemonCore.SessionActivity.Registry],
          &Process.whereis/1
        )

      is_pid(replacement) and replacement != activity
    end)

    assert Process.alive?(session)

    assert {:error, {:conflict, _message, %{"reason" => "session_busy"}}} =
             SessionsReset.handle(%{"sessionKey" => key}, %{})

    send(turn, :finish_turn)

    await(fn ->
      match?({:ok, %{presence: %{idle: true}}}, LemonRouter.run_presence(%{session_key: key}))
    end)
  end

  test "node.invoke coding_agent.run is fenced and present until the node stops it",
       %{key: key} do
    node_id = start_test_node(self())

    params = %{
      "nodeId" => node_id,
      "method" => "coding_agent.run",
      "args" => %{"version" => 2, "prompt" => "direct work", "sessionKey" => key}
    }

    ctx = %{conn_pid: self(), auth: %{role: :operator, scopes: [:write]}}
    holder = hold_fence(key)

    assert {:error, {:conflict, _message, %{"reason" => "lifecycle_in_progress"}}} =
             LemonControlPlane.Methods.NodeInvoke.handle(params, ctx)

    refute_receive {:node_event, "node.invoke.request", _}, 100
    release_fence(holder)

    assert {:ok, %{"invokeId" => invoke_id}} =
             LemonControlPlane.Methods.NodeInvoke.handle(params, ctx)

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}, 2_000
    assert {:ok, %{presence: %{idle: false}}} = LemonRouter.run_presence(%{session_key: key})

    assert {:error, {:conflict, _message, %{"reason" => "session_busy"}}} =
             SessionsDelete.handle(%{"sessionKey" => key}, %{})

    # A cancellation request is not proof that the remote run stopped.
    LemonCore.NodeRegistry.cancel(invoke_id)
    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}, 2_000
    assert {:ok, %{presence: %{idle: false}}} = LemonRouter.run_presence(%{session_key: key})

    assert {:error, {:conflict, _message, %{"reason" => "session_busy"}}} =
             SessionsReset.handle(%{"sessionKey" => key}, %{})

    # The node's terminal acknowledgement is.
    LemonCore.NodeRegistry.complete(node_id, invoke_id, nil, "cancelled")

    await(fn ->
      match?({:ok, %{presence: %{idle: true}}}, LemonRouter.run_presence(%{session_key: key}))
    end)
  end

  test "a disconnected node's invocation stays present until its worker reports it stopped",
       %{key: key} do
    test = self()
    node_id = start_test_node(test)
    {:ok, %{pid: node_pid}} = LemonCore.NodeRegistry.resolve_id(node_id)

    params = %{
      "nodeId" => node_id,
      "method" => "coding_agent.run",
      "args" => %{"version" => 2, "prompt" => "direct work", "sessionKey" => key}
    }

    ctx = %{conn_pid: self(), auth: %{role: :operator, scopes: [:write]}}

    assert {:ok, %{"invokeId" => invoke_id}} =
             LemonControlPlane.Methods.NodeInvoke.handle(params, ctx)

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}, 2_000
    Process.exit(node_pid, :kill)
    assert_receive {:lemon_node_result, ^invoke_id, {:error, {:node_disconnected, _}}}, 2_000

    assert {:ok, %{presence: %{idle: false}}} = LemonRouter.run_presence(%{session_key: key})

    assert {:error, {:conflict, _message, %{"reason" => "session_busy"}}} =
             SessionsReset.handle(%{"sessionKey" => key}, %{})

    await(fn -> match?({:ok, %{}}, Store.fetch(:session_activity_unresolved, invoke_id)) end)

    # A reconnect alone proves nothing about the earlier execution.
    LemonCore.NodeRegistry.unregister(node_id, node_pid)
    reconnected = spawn(fn -> forward_node_events(test) end)
    :ok = LemonCore.NodeRegistry.register(node_id, "Lifecycle Node", reconnected)
    on_exit(fn -> Process.exit(reconnected, :kill) end)
    assert {:ok, %{presence: %{idle: false}}} = LemonRouter.run_presence(%{session_key: key})

    # Nor does a report from a connection that is not the node's live one.
    assert {:error, :stale_session} =
             LemonCore.NodeRegistry.report_active(node_id, node_pid, 0, [])

    # The worker still stopping the invocation reports it as active.
    assert :ok = LemonCore.NodeRegistry.report_active(node_id, reconnected, 0, [invoke_id])
    assert {:ok, %{presence: %{idle: false}}} = LemonRouter.run_presence(%{session_key: key})

    # Once its cancellation barrier proved the run stopped, its report omits it.
    assert :ok = LemonCore.NodeRegistry.report_active(node_id, reconnected, 0, [])
    assert {:ok, %{presence: %{idle: true}}} = LemonRouter.run_presence(%{session_key: key})
  end

  test "a direct invocation reusing another session's run id leaves both sessions busy",
       %{key: key} do
    other = key <> "-direct"
    assert {:ok, run_id} = LemonRouter.submit(request(key, "active work"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = active}, 2_000
    node_id = start_test_node(self())

    params = %{
      "nodeId" => node_id,
      "method" => "coding_agent.run",
      "args" => %{"version" => 2, "prompt" => "x", "sessionKey" => other, "runId" => run_id}
    }

    ctx = %{conn_pid: self(), auth: %{role: :operator, scopes: [:write]}}

    assert {:ok, %{"invokeId" => invoke_id}} =
             LemonControlPlane.Methods.NodeInvoke.handle(params, ctx)

    for session <- [key, other] do
      assert {:ok, %{presence: %{idle: false}}} =
               LemonRouter.run_presence(%{session_key: session})

      assert {:error, {:conflict, _message, %{"reason" => "session_busy"}}} =
               SessionsReset.handle(%{"sessionKey" => session}, %{})
    end

    LemonCore.NodeRegistry.complete(node_id, invoke_id, %{"ok" => true}, nil)
    finish(active)
  end

  test "node.invoke sends the worker exactly the session key it admitted", %{key: _key} do
    node_id = start_test_node(self())

    params = %{
      "nodeId" => node_id,
      "method" => "coding_agent.run",
      "args" => %{"version" => 2, "prompt" => "x", "runId" => " padded-run "}
    }

    ctx = %{conn_pid: self(), auth: %{role: :operator, scopes: [:write]}}

    assert {:ok, %{"invokeId" => invoke_id}} =
             LemonControlPlane.Methods.NodeInvoke.handle(params, ctx)

    assert_receive {:node_event, "node.invoke.request",
                    %{"invokeId" => ^invoke_id, "args" => args}},
                   2_000

    assert args["runId"] == "padded-run"
    assert is_binary(args["sessionKey"])

    assert {:ok, %{presence: %{idle: false}}} =
             LemonRouter.run_presence(%{session_key: args["sessionKey"]})

    LemonCore.NodeRegistry.complete(node_id, invoke_id, %{"ok" => true}, nil)

    await(fn ->
      match?(
        {:ok, %{presence: %{idle: true}}},
        LemonRouter.run_presence(%{session_key: args["sessionKey"]})
      )
    end)
  end

  test "prune refuses a session with active work and changes nothing", %{key: key} do
    seed_session(key)
    assert {:ok, _} = SessionLifecycle.patch(key, %{archived: true})
    assert {:ok, run_id} = LemonRouter.submit(request(key, "active work"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = active}, 2_000
    cutoff = System.system_time(:millisecond) + 60_000
    prune = %{"olderThanMs" => cutoff, "archivedOnly" => true}

    assert {:ok, %{"confirmToken" => token, "candidateSessionKeys" => candidates}} =
             SessionsPrune.handle(prune, %{})

    assert key in candidates

    assert {:error, {:internal_error, _message, %{"failureCount" => failures}}} =
             SessionsPrune.handle(
               Map.merge(prune, %{"dryRun" => false, "confirmToken" => token}),
               %{}
             )

    assert failures >= 1
    assert SessionLifecycle.get(key)
    assert policy(key) == %{model: "private-model"}
    assert {:ok, [_ | _]} = RunHistoryStore.fetch(key, limit: 1)
    finish(active)
  end

  test "a failed fence release is reconciled after the operation ends", %{key: key} do
    seed_session(key)
    Application.put_env(:lemon_router, :sessions_reset_fail_fence_delete, true)
    :sys.replace_state(Store, &%{&1 | backend: FenceDeleteFailingBackend})

    try do
      assert {:ok, %{"summary" => %{"verified" => true}}} =
               SessionsReset.handle(%{"sessionKey" => key}, %{})

      assert {:ok, %{state: "held"}} = LemonCore.LifecycleFenceStore.fetch(key)
      assert {:error, :session_lifecycle_in_progress} = LemonRouter.submit(request(key, "held"))
    after
      Application.delete_env(:lemon_router, :sessions_reset_fail_fence_delete)
      :sys.replace_state(Store, &%{&1 | backend: LemonCore.Store.EtsBackend})
    end

    # The operation finished, so its fence is released, not marked unknown.
    await(fn -> LemonCore.LifecycleFenceStore.fetch(key) == {:ok, nil} end, 500)
    command = await_admitted(key, "after release")
    finish(command)
  end

  test "direct gateway submission is refused while the session is fenced", %{key: key} do
    run_id = "gateway-direct-#{System.unique_integer([:positive])}"

    command = %ExecutionCommand{
      run_id: run_id,
      session_key: key,
      prompt: "direct gateway work",
      conversation_key: {:session, key}
    }

    holder = hold_fence(key)

    try do
      assert {:error, :session_lifecycle_in_progress} = LemonGateway.submit(command)
      assert LemonGateway.Runtime.run_pid(run_id) == nil
    after
      release_fence(holder)
      LemonGateway.Runtime.cancel_by_run_id(run_id)
    end
  end

  test "delete is refused while another client's run is active and changes nothing",
       %{key: key} do
    seed_session(key)

    assert {:ok, run_id} = LemonRouter.submit(request(key, "active work"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = active}, 2_000

    assert {:error,
            {:conflict, _message,
             %{"reason" => "session_busy", "mutationMayHaveApplied" => false}}} =
             SessionsDelete.handle(%{"sessionKey" => key}, %{})

    assert SessionLifecycle.get(key)
    assert policy(key) == %{model: "private-model"}
    refute ChatStateStore.get(key) == nil
    assert {:ok, [_ | _]} = RunHistoryStore.fetch(key, limit: 1)

    finish(active)

    await(fn ->
      match?({:ok, %{presence: %{idle: true}}}, LemonRouter.run_presence(%{session_key: key}))
    end)

    assert {:ok, %{"deleted" => true, "summary" => %{"verified" => true, "existed" => true}}} =
             SessionsDelete.handle(%{"sessionKey" => key}, %{})

    assert SessionLifecycle.get(key) == nil
    assert policy(key) == nil
    assert {:ok, []} = RunHistoryStore.fetch(key, limit: 1)
  end

  test "run admission for the session is refused while its deletion is in flight",
       %{key: key} do
    seed_session(key)
    history = Process.whereis(RunHistoryStore)
    :ok = :sys.suspend(history)
    delete = Task.async(fn -> SessionsDelete.handle(%{"sessionKey" => key}, %{}) end)

    try do
      # The deletion has removed policy and is now verifying run-history deletion.
      await(fn -> policy(key) == nil end)

      assert {:error, :session_lifecycle_in_progress} =
               LemonRouter.submit(request(key, "racing work from another client"))

      refute_receive {:execution, _}, 100

      for method <- [SessionsReset, SessionsDelete] do
        assert {:error,
                {:conflict, _message,
                 %{"reason" => "lifecycle_in_progress", "mutationMayHaveApplied" => false}}} =
                 method.handle(%{"sessionKey" => key}, %{})
      end
    after
      :sys.resume(history)
    end

    assert {:ok, %{"summary" => %{"verified" => true}}} = Task.await(delete, 10_000)
    assert SessionLifecycle.get(key) == nil
    assert {:ok, []} = RunHistoryStore.fetch(key, limit: 1)

    # The fence ends with the deletion: the next admission for the key is accepted.
    assert {:ok, run_id} = LemonRouter.submit(request(key, "work after delete"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = after_delete}, 2_000
    finish(after_delete)
  end

  test "a failed or unknown policy deletion is never reported as success or retried",
       %{key: key} do
    seed_session(key)
    original = :sys.get_state(Store)

    on_exit(fn ->
      Application.delete_env(:lemon_router, :sessions_reset_policy_delete_error)
    end)

    for {method, noun} <- [{SessionsReset, "reset"}, {SessionsDelete, "deletion"}],
        {error, expected_code, expected_details} <- [
          {:outcome_unknown, :unavailable,
           %{
             "reason" => "outcome_unknown",
             "retrySafe" => false,
             "mutationMayHaveApplied" => true
           }},
          {:disk_full, :internal_error,
           %{
             "reason" => "#{noun}_failed",
             "retrySafe" => false,
             "mutationMayHaveApplied" => false
           }}
        ] do
      Application.put_env(:lemon_router, :sessions_reset_policy_delete_error, error)

      :sys.replace_state(Store, fn state ->
        {:ok, backend_state} = PolicyDeleteFailingBackend.init([])
        %{state | backend: PolicyDeleteFailingBackend, backend_state: backend_state}
      end)

      try do
        :ok = ChatStateStore.put(key, %{last_engine: "lemon", last_resume_token: "kept"})
        :ok = PolicyStore.put_session(key, %{model: "private-model"})

        assert {:error, {^expected_code, _message, ^expected_details}} =
                 method.handle(%{"sessionKey" => key}, %{})

        assert_receive {:policy_delete, ^key}
        refute_receive {:policy_delete, ^key}, 100
        assert %{last_resume_token: "kept"} = ChatStateStore.get(key)
        assert policy(key) == %{model: "private-model"}
        assert {:ok, [_ | _]} = RunHistoryStore.fetch(key, limit: 1)
      after
        :sys.replace_state(Store, fn current ->
          Enum.each(current.backend_state, fn {_key, table} -> :ets.delete(table) end)
          original
        end)
      end
    end
  end

  defp seed_session(key) do
    assert {:ok, run_id} = LemonRouter.submit(request(key, "earlier work"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000
    finish(command)
    await(fn -> match?({:ok, [_ | _]}, RunHistoryStore.fetch(key, limit: 1)) end)

    await(fn ->
      match?({:ok, %{presence: %{idle: true}}}, LemonRouter.run_presence(%{session_key: key}))
    end)

    :ok = ChatStateStore.put(key, %{last_engine: "lemon", last_resume_token: "resume-#{run_id}"})
    :ok = PolicyStore.put_session(key, %{model: "private-model"})
  end

  defp request(key, prompt) do
    %RunRequest{
      session_key: key,
      agent_id: "default",
      prompt: prompt,
      cwd: File.cwd!(),
      model: "test-model"
    }
  end

  defp finish(command) do
    completed = LemonCore.Events.Completion.new(%{engine: "lemon", ok: true, answer: "done"})

    event =
      Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{completed: completed, duration_ms: 1}),
        %{run_id: command.run_id, session_key: command.session_key}
      )

    :ok = RunCompletion.publish(command, event)
    # Later test modules read global presence: leave no finishing run behind.
    await(fn -> not LemonRouter.run_active?(command.run_id) end)
  end

  # Holds the session's lifecycle fence (as a reset or delete would) until released.
  # The operation runs in its own fence owner, which receives the release.
  defp hold_fence(key) do
    test = self()

    holder =
      spawn(fn ->
        caller = self()

        LemonRouter.with_session_lifecycle_fence(key, :reset, fn _generation ->
          send(test, {:fence_held, caller, self()})

          receive do
            :release_fence -> {:ok, :released}
          end
        end)

        send(test, {:fence_released, caller})
      end)

    assert_receive {:fence_held, ^holder, operation}, 2_000
    {holder, operation}
  end

  defp release_fence({holder, operation}) do
    send(operation, :release_fence)
    assert_receive {:fence_released, ^holder}, 2_000
  end

  # Fence release after an owner's death is asynchronous: retry until admitted.
  defp await_admitted(key, prompt, attempts \\ 200) do
    case LemonRouter.submit(request(key, prompt)) do
      {:ok, run_id} ->
        assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000
        command

      {:error, :session_lifecycle_in_progress} when attempts > 0 ->
        Process.sleep(10)
        await_admitted(key, prompt, attempts - 1)
    end
  end

  defp start_test_node(test) do
    suffix = System.unique_integer([:positive])
    node_id = "lifecycle-node-#{suffix}"
    node_pid = spawn(fn -> forward_node_events(test) end)

    :ok =
      LemonControlPlane.NodeStore.put_node(node_id, %{
        id: node_id,
        name: "Lifecycle Node #{suffix}",
        type: "worker",
        capabilities: %{},
        status: :offline
      })

    :ok = LemonCore.NodeRegistry.register(node_id, "Lifecycle Node #{suffix}", node_pid)

    on_exit(fn ->
      LemonCore.NodeRegistry.unregister(node_id, node_pid)
      Store.delete(:nodes_registry, node_id)
      Process.exit(node_pid, :kill)
    end)

    node_id
  end

  defp forward_node_events(test) do
    receive do
      message ->
        send(test, message)
        forward_node_events(test)
    end
  end

  defp policy(key) do
    {:ok, policy} = PolicyStore.fetch_session(key)
    policy
  end

  defp await(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        await(fun, attempts - 1)

      true ->
        flunk("condition not reached")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_router, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_router, key, value)
end
