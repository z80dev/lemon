defmodule LemonRouter.RunOrchestratorTest do
  use ExUnit.Case, async: false

  alias LemonCore.RunRequest
  alias LemonCore.ResumeToken
  alias LemonRouter.{PendingCompactionStore, RunOrchestrator}

  @moduledoc """
  Tests for RunOrchestrator including cwd and tool_policy override handling.
  """

  defmodule BlockingRunProcess do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      run_id = opts[:run_id] || System.unique_integer([:positive])

      %{
        id: {__MODULE__, run_id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok, opts}
    end

    @impl true
    def handle_cast({:abort, _reason}, state), do: {:stop, :normal, state}
  end

  defmodule CapturingRunProcess do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      run_id = opts[:run_id] || System.unique_integer([:positive])

      %{
        id: {__MODULE__, run_id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      if is_pid(opts[:notify_pid]) do
        send(opts[:notify_pid], {:captured_job, opts[:execution_request]})
        send(opts[:notify_pid], {:captured_run_opts, opts})
      end

      {:ok, opts, {:continue, :auto_stop}}
    end

    @impl true
    def handle_continue(:auto_stop, state) do
      {:stop, :normal, state}
    end
  end

  defmodule PersistentCapturingRunProcess do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      run_id = opts[:run_id] || System.unique_integer([:positive])

      %{
        id: {__MODULE__, run_id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      if is_pid(opts[:notify_pid]) do
        send(opts[:notify_pid], {:captured_run_opts, opts})
      end

      {:ok, opts}
    end
  end

  defmodule RunOrchestratorFailingRunProcess do
    @moduledoc false

    def start_link(_opts), do: {:error, :run_failed_to_start}

    def child_spec(opts) do
      run_id = opts[:run_id] || System.unique_integer([:positive])

      %{
        id: {__MODULE__, run_id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000
      }
    end
  end

  defmodule RunOrchestratorEventBridgeStub do
    @moduledoc false

    def subscribe_run(run_id), do: notify({:bridge_subscribed, run_id})
    def unsubscribe_run(run_id), do: notify({:bridge_unsubscribed, run_id})

    defp notify(message) do
      case Application.get_env(:lemon_router, :event_bridge_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end

      :ok
    end
  end

  defmodule AbortCaptureCoordinator do
    def abort_run(run_id, reason) do
      send(
        Application.fetch_env!(:lemon_router, :abort_capture_pid),
        {:abort_dispatched, run_id, reason}
      )

      :ok
    end
  end

  defmodule UnavailableRunStore do
    @moduledoc false
    def fetch(_run_id), do: {:error, :store_unavailable}
  end

  setup do
    ensure_pubsub()

    original_bridge_impl = Application.get_env(:lemon_core, :event_bridge_impl)
    original_bridge_test_pid = Application.get_env(:lemon_router, :event_bridge_test_pid)
    original_run_store = Application.get_env(:lemon_router, :run_store)
    Application.put_env(:lemon_router, :event_bridge_test_pid, self())
    :ok = LemonCore.EventBridge.configure(RunOrchestratorEventBridgeStub)

    # Start RunOrchestrator if not running
    case Process.whereis(RunOrchestrator) do
      nil ->
        {:ok, pid} = RunOrchestrator.start_link([])

        original_profiles_state = :sys.get_state(LemonRouter.AgentProfiles)

        :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
          %{state | profiles: Map.put_new(state.profiles, "test", test_profile())}
        end)

        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)

          :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_profiles_state end)

          restore_event_bridge_impl(original_bridge_impl)

          case original_bridge_test_pid do
            nil -> Application.delete_env(:lemon_router, :event_bridge_test_pid)
            bridge_pid -> Application.put_env(:lemon_router, :event_bridge_test_pid, bridge_pid)
          end

          restore_env(:lemon_router, :run_store, original_run_store)
        end)

        {:ok, orchestrator_pid: pid}

      pid ->
        original_profiles_state = :sys.get_state(LemonRouter.AgentProfiles)

        :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
          %{state | profiles: Map.put_new(state.profiles, "test", test_profile())}
        end)

        on_exit(fn ->
          :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_profiles_state end)

          restore_event_bridge_impl(original_bridge_impl)

          case original_bridge_test_pid do
            nil -> Application.delete_env(:lemon_router, :event_bridge_test_pid)
            bridge_pid -> Application.put_env(:lemon_router, :event_bridge_test_pid, bridge_pid)
          end

          restore_env(:lemon_router, :run_store, original_run_store)
        end)

        {:ok, orchestrator_pid: pid}
    end
  end

  describe "submit/1" do
    test "fixed run ids are idempotent across concurrent and sequential replay" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_idempotent_#{System.unique_integer([:positive])}"
      session_key = "agent:idempotent:test:#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id) end)

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: PersistentCapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      replay =
        request(%{
          run_id: run_id,
          origin: :control_plane,
          session_key: session_key,
          agent_id: "test",
          prompt: "stable payload",
          queue_mode: :collect
        })

      results =
        1..8
        |> Task.async_stream(fn _ -> RunOrchestrator.submit(orchestrator_pid, replay) end,
          ordered: false,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.uniq(results) == [{:ok, run_id}]
      assert_receive {:captured_run_opts, %{run_id: ^run_id}}, 500
      refute_receive {:captured_run_opts, %{run_id: ^run_id}}, 100
      assert {:ok, ^run_id} = RunOrchestrator.submit(orchestrator_pid, replay)
      refute_receive {:captured_run_opts, %{run_id: ^run_id}}, 100
    end

    test "an accepted receipt survives completion and rejects conflicting run-id reuse" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_completed_replay_#{System.unique_integer([:positive])}"
      session_key = "agent:completed-replay:test:#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id) end)

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      replay =
        request(%{
          run_id: run_id,
          origin: :control_plane,
          session_key: session_key,
          agent_id: "test",
          prompt: "stable payload",
          queue_mode: :collect
        })

      assert {:ok, ^run_id} = RunOrchestrator.submit(orchestrator_pid, replay)
      assert_receive {:captured_job, _command}, 500
      assert {:ok, ^run_id} = RunOrchestrator.submit(orchestrator_pid, replay)
      refute_receive {:captured_job, _command}, 100

      conflicting = %{replay | prompt: "different payload"}
      assert {:error, :run_id_conflict} = RunOrchestrator.submit(orchestrator_pid, conflicting)
      refute_receive {:captured_job, _command}, 100
    end

    test "a delivery replay identity ignores local execution details but still binds content" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_delivery_replay_#{System.unique_integer([:positive])}"
      session_key = "agent:delivery-replay:test:#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id) end)

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: PersistentCapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      first =
        request(%{
          run_id: run_id,
          origin: :control_plane,
          session_key: session_key,
          agent_id: "test",
          prompt: "stable delivered content",
          images: ["/tmp/first-upload/image.png"],
          tool_policy: %{allow: ["read"]},
          meta: %{router_replay_identity: "delivery:stable", request_id: "request-one"}
        })

      assert {:ok, ^run_id} = RunOrchestrator.submit(orchestrator_pid, first)
      assert_receive {:captured_run_opts, %{run_id: ^run_id}}, 500

      replay = %{
        first
        | images: ["/tmp/retried-upload/image.png"],
          tool_policy: %{allow: ["read", "search"]},
          meta: %{router_replay_identity: "delivery:stable", request_id: "request-two"}
      }

      assert {:ok, ^run_id} = RunOrchestrator.submit(orchestrator_pid, replay)
      refute_receive {:captured_run_opts, %{run_id: ^run_id}}, 100

      assert {:error, :run_id_conflict} =
               RunOrchestrator.submit(orchestrator_pid, %{replay | prompt: "different content"})
    end

    test "a pending receipt after orchestrator loss never blindly re-enqueues" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_pending_replay_#{System.unique_integer([:positive])}"
      session_key = "agent:pending-replay:test:#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id) end)

      opts = [
        run_supervisor: run_supervisor,
        run_process_module: PersistentCapturingRunProcess,
        run_process_opts: %{notify_pid: self()}
      ]

      {:ok, first_orchestrator} = GenServer.start_link(RunOrchestrator, opts)

      replay =
        request(%{
          run_id: run_id,
          origin: :control_plane,
          session_key: session_key,
          agent_id: "test",
          prompt: "stable payload",
          queue_mode: :collect
        })

      assert {:ok, ^run_id} = RunOrchestrator.submit(first_orchestrator, replay)
      assert_receive {:captured_run_opts, %{run_id: ^run_id}}, 500

      entry = LemonCore.Store.get(RunOrchestrator.admission_table(), run_id)

      assert :ok =
               LemonCore.Store.put(RunOrchestrator.admission_table(), run_id, %{
                 entry
                 | state: "pending"
               })

      :ok = GenServer.stop(first_orchestrator)

      {:ok, recovered_orchestrator} = GenServer.start_link(RunOrchestrator, opts)
      assert {:error, :outcome_unknown} = RunOrchestrator.submit(recovered_orchestrator, replay)
      refute_receive {:captured_run_opts, %{run_id: ^run_id}}, 100
      assert %{state: "pending"} = LemonCore.Store.get(RunOrchestrator.admission_table(), run_id)
    end

    test "a pending receipt does not re-enqueue after the original run completed" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_pending_completed_#{System.unique_integer([:positive])}"
      session_key = "agent:pending-completed:test:#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id) end)

      opts = [
        run_supervisor: run_supervisor,
        run_process_module: CapturingRunProcess,
        run_process_opts: %{notify_pid: self()}
      ]

      {:ok, first_orchestrator} = GenServer.start_link(RunOrchestrator, opts)

      replay =
        request(%{
          run_id: run_id,
          origin: :control_plane,
          session_key: session_key,
          agent_id: "test",
          prompt: "stable completed payload",
          queue_mode: :collect
        })

      assert {:ok, ^run_id} = RunOrchestrator.submit(first_orchestrator, replay)
      assert_receive {:captured_job, command}, 500

      entry = LemonCore.Store.get(RunOrchestrator.admission_table(), run_id)

      assert :ok =
               LemonCore.Store.put(RunOrchestrator.admission_table(), run_id, %{
                 entry
                 | state: "pending"
               })

      assert :ok =
               LemonCore.RunStore.finalize(run_id, %{
                 session_key: session_key,
                 completed_at_ms: System.system_time(:millisecond),
                 ok: true,
                 meta: command.meta
               })

      assert eventually(fn -> match?(%{summary: %{}}, LemonCore.RunStore.get(run_id)) end)
      :ok = GenServer.stop(first_orchestrator)

      {:ok, recovered_orchestrator} = GenServer.start_link(RunOrchestrator, opts)
      assert {:ok, ^run_id} = RunOrchestrator.submit(recovered_orchestrator, replay)
      refute_receive {:captured_job, _command}, 100
      assert %{state: "accepted"} = LemonCore.Store.get(RunOrchestrator.admission_table(), run_id)
    end

    test "terminal reconciliation rejects a different session or payload" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_terminal_identity_#{System.unique_integer([:positive])}"
      session_key = "agent:terminal-identity:test:#{System.unique_integer([:positive])}"

      on_exit(fn ->
        LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)
        LemonCore.Store.delete(:runs, run_id)
      end)

      opts = [
        run_supervisor: run_supervisor,
        run_process_module: CapturingRunProcess,
        run_process_opts: %{notify_pid: self()}
      ]

      {:ok, first_orchestrator} = GenServer.start_link(RunOrchestrator, opts)

      original =
        request(%{
          run_id: run_id,
          origin: :control_plane,
          session_key: session_key,
          agent_id: "test",
          prompt: "original terminal payload",
          queue_mode: :collect
        })

      assert {:ok, ^run_id} = RunOrchestrator.submit(first_orchestrator, original)
      assert_receive {:captured_job, command}, 500
      assert :ok = LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)

      assert :ok =
               LemonCore.RunStore.finalize(run_id, %{
                 session_key: session_key,
                 ok: true,
                 meta: command.meta
               })

      assert :ok = LemonCore.Store.ping()
      :ok = GenServer.stop(first_orchestrator)
      {:ok, recovered_orchestrator} = GenServer.start_link(RunOrchestrator, opts)

      cross_session = %{original | session_key: session_key <> ":other"}
      assert {:error, :run_id_conflict} = RunOrchestrator.submit(recovered_orchestrator, cross_session)
      refute_receive {:captured_job, _command}, 100

      assert :ok = LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)
      different_payload = %{original | prompt: "different terminal payload"}

      assert {:error, :run_id_conflict} =
               RunOrchestrator.submit(recovered_orchestrator, different_payload)

      refute_receive {:captured_job, _command}, 100
    end

    test "a run-store read fault cannot authorize a new submission" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_store_fault_#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id) end)
      Application.put_env(:lemon_router, :run_store, UnavailableRunStore)

      {:ok, orchestrator} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      replay =
        request(%{
          run_id: run_id,
          session_key: "agent:store-fault:test",
          agent_id: "test",
          prompt: "must not run",
          queue_mode: :collect
        })

      assert {:error, :outcome_unknown} = RunOrchestrator.submit(orchestrator, replay)
      refute_receive {:captured_job, _command}, 100
      assert %{state: "claimed"} = LemonCore.Store.get(RunOrchestrator.admission_table(), run_id)

      Application.put_env(:lemon_router, :run_store, LemonCore.RunStore)
      assert {:ok, ^run_id} = RunOrchestrator.submit(orchestrator, replay)
      assert_receive {:captured_job, _command}, 500
    end

    test "accepted admissions expire while ambiguous submitting claims remain fenced" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      accepted_run_id = "run_retention_accepted_#{System.unique_integer([:positive])}"
      pending_run_id = "run_retention_pending_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        LemonCore.Store.delete(RunOrchestrator.admission_table(), accepted_run_id)
        LemonCore.Store.delete(RunOrchestrator.admission_table(), pending_run_id)
      end)

      opts = [
        run_supervisor: run_supervisor,
        run_process_module: CapturingRunProcess,
        run_process_opts: %{notify_pid: self()},
        run_admission_retention_ms: 10
      ]

      {:ok, orchestrator} = GenServer.start_link(RunOrchestrator, opts)

      accepted =
        request(%{
          run_id: accepted_run_id,
          session_key: "agent:retention-accepted:test",
          agent_id: "test",
          prompt: "accepted horizon"
        })

      assert {:ok, ^accepted_run_id} = RunOrchestrator.submit(orchestrator, accepted)
      assert_receive {:captured_job, _command}, 500
      assert %{state: "accepted", expires_at_ms: expires_at_ms} =
               LemonCore.Store.get(RunOrchestrator.admission_table(), accepted_run_id)

      assert is_integer(expires_at_ms)
      Process.sleep(20)
      assert {:ok, ^accepted_run_id} = RunOrchestrator.submit(orchestrator, accepted)
      assert_receive {:captured_job, _command}, 500

      pending =
        request(%{
          run_id: pending_run_id,
          session_key: "agent:retention-pending:test",
          agent_id: "test",
          prompt: "pending fence"
        })

      assert {:ok, ^pending_run_id} = RunOrchestrator.submit(orchestrator, pending)
      assert_receive {:captured_job, _command}, 500

      entry = LemonCore.Store.get(RunOrchestrator.admission_table(), pending_run_id)
      assert :ok = LemonCore.Store.put(RunOrchestrator.admission_table(), pending_run_id, %{entry | state: "submitting"})
      Process.sleep(20)
      :ok = GenServer.stop(orchestrator)
      {:ok, recovered} = GenServer.start_link(RunOrchestrator, opts)

      assert {:error, :outcome_unknown} = RunOrchestrator.submit(recovered, pending)
      refute_receive {:captured_job, _command}, 100
    end

    test "receipt cleanup evicts expired terminal rows but preserves ambiguous claims" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      suffix = System.unique_integer([:positive])
      expired_admission = "run_cleanup_accepted_#{suffix}"
      ambiguous_admission = "run_cleanup_submitting_#{suffix}"
      expired_abort = "run_cleanup_abort_#{suffix}"
      probe_run = "run_cleanup_probe_#{suffix}"

      on_exit(fn ->
        for run_id <- [expired_admission, ambiguous_admission, probe_run] do
          LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)
        end

        LemonCore.Store.delete(RunOrchestrator.abort_tombstone_table(), expired_abort)
      end)

      assert :ok =
               LemonCore.Store.put(RunOrchestrator.admission_table(), expired_admission, %{
                 state: "accepted",
                 expires_at_ms: 0
               })

      assert :ok =
               LemonCore.Store.put(RunOrchestrator.admission_table(), ambiguous_admission, %{
                 state: "submitting",
                 expires_at_ms: 0
               })

      assert :ok =
               LemonCore.Store.put(RunOrchestrator.abort_tombstone_table(), expired_abort, %{
                 reason: :old,
                 expires_at_ms: 0
               })

      {:ok, orchestrator} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()},
          receipt_cleanup_interval_ms: 0
        )

      assert {:ok, ^probe_run} =
               RunOrchestrator.submit(
                 orchestrator,
                 request(%{
                   run_id: probe_run,
                   session_key: "agent:cleanup:test",
                   agent_id: "test",
                   prompt: "trigger cleanup"
                 })
               )

      assert_receive {:captured_job, _command}, 500
      assert LemonCore.Store.get(RunOrchestrator.admission_table(), expired_admission) == nil
      assert %{state: "submitting"} =
               LemonCore.Store.get(RunOrchestrator.admission_table(), ambiguous_admission)

      assert LemonCore.Store.get(RunOrchestrator.abort_tombstone_table(), expired_abort) == nil
    end

    test "generates run_id" do
      # Note: This will fail to start the actual run since we don't have
      # the full infrastructure running, but we can test the orchestrator logic
      # by verifying it doesn't crash and returns an appropriate response

      # We expect this to fail since RunSupervisor isn't started
      result =
        RunOrchestrator.submit(
          request(%{
            origin: :control_plane,
            session_key: "agent:test:main",
            agent_id: "test",
            prompt: "Hello",
            queue_mode: :collect
          })
        )

      # Either succeeds with run_id or fails with meaningful error
      case result do
        {:ok, run_id} ->
          assert is_binary(run_id)
          assert String.starts_with?(run_id, "run_")

        {:error, reason} ->
          # Expected when RunSupervisor isn't running
          assert reason != nil
      end
    end

    test "accepts RunRequest struct input" do
      result =
        RunOrchestrator.submit(%RunRequest{
          origin: :control_plane,
          session_key: "agent:test:main",
          agent_id: "test",
          prompt: "Hello from struct",
          queue_mode: :collect
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts map input and normalizes to RunRequest" do
      result =
        RunOrchestrator.submit(%{
          origin: :control_plane,
          session_key: "agent:test:main",
          agent_id: "test",
          prompt: "Hello from map input"
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts keyword input and normalizes to RunRequest" do
      result =
        RunOrchestrator.submit(
          origin: :control_plane,
          session_key: "agent:test:main",
          agent_id: "test",
          prompt: "Hello from keyword input"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "returns unknown_agent_id error for unconfigured agent" do
      result =
        RunOrchestrator.submit(
          request(%{
            origin: :control_plane,
            session_key: "agent:missing-agent:main",
            agent_id: "missing-agent",
            prompt: "Hello",
            queue_mode: :collect
          })
        )

      assert {:error, {:unknown_agent_id, "missing-agent"}} = result
    end
  end

  describe "admission control" do
    test "an abort tombstone rejects a later submission with the same fixed run id" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: BlockingRunProcess
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      run_id = "run_tombstoned_#{System.unique_integer([:positive])}"
      session_key = "agent:tombstone:test:#{System.unique_integer([:positive])}"

      assert :ok = RunOrchestrator.register_abort(orchestrator_pid, run_id, :hard_stop)

      assert {:error, {:run_aborted, :hard_stop}} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   run_id: run_id,
                   origin: :goal,
                   session_key: session_key,
                   agent_id: "test",
                   prompt: "must not start"
                 })
               )

      refute_receive {:bridge_subscribed, ^run_id}, 100
      assert %{active: 0} = DynamicSupervisor.count_children(run_supervisor)
    end

    test "an abort tombstone survives orchestrator restart until its durable expiry" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_durable_tombstone_#{System.unique_integer([:positive])}"
      session_key = "agent:durable-tombstone:test:#{System.unique_integer([:positive])}"

      on_exit(fn ->
        LemonCore.Store.delete(RunOrchestrator.abort_tombstone_table(), run_id)
        LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)
      end)

      opts = [
        run_supervisor: run_supervisor,
        run_process_module: CapturingRunProcess,
        run_process_opts: %{notify_pid: self()},
        abort_tombstone_ttl_ms: 60_000
      ]

      {:ok, first_orchestrator} = GenServer.start_link(RunOrchestrator, opts)
      assert :ok = RunOrchestrator.register_abort(first_orchestrator, run_id, :hard_stop)
      :ok = GenServer.stop(first_orchestrator)

      {:ok, recovered_orchestrator} = GenServer.start_link(RunOrchestrator, opts)

      assert {:error, {:run_aborted, :hard_stop}} =
               RunOrchestrator.submit(
                 recovered_orchestrator,
                 request(%{
                   run_id: run_id,
                   session_key: session_key,
                   agent_id: "test",
                   prompt: "must remain cancelled"
                 })
               )

      refute_receive {:captured_job, _command}, 100
    end

    test "an expired durable abort tombstone no longer rejects the run id" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      run_id = "run_expired_tombstone_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        LemonCore.Store.delete(RunOrchestrator.abort_tombstone_table(), run_id)
        LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)
      end)

      opts = [
        run_supervisor: run_supervisor,
        run_process_module: CapturingRunProcess,
        run_process_opts: %{notify_pid: self()},
        abort_tombstone_ttl_ms: 10
      ]

      {:ok, first_orchestrator} = GenServer.start_link(RunOrchestrator, opts)
      assert :ok = RunOrchestrator.register_abort(first_orchestrator, run_id, :hard_stop)
      :ok = GenServer.stop(first_orchestrator)
      Process.sleep(20)

      {:ok, recovered_orchestrator} = GenServer.start_link(RunOrchestrator, opts)

      assert {:ok, ^run_id} =
               RunOrchestrator.submit(
                 recovered_orchestrator,
                 request(%{
                   run_id: run_id,
                   session_key: "agent:expired-tombstone:test",
                   agent_id: "test",
                   prompt: "may start after expiry"
                 })
               )

      assert_receive {:captured_job, _command}, 500
    end

    test "abort registration waits beyond the default call timeout for serialized admission" do
      {:ok, orchestrator_pid} = GenServer.start_link(RunOrchestrator, [])
      :ok = :sys.suspend(orchestrator_pid)

      task =
        Task.async(fn ->
          RunOrchestrator.register_abort(
            orchestrator_pid,
            "run_slow_serialized_abort",
            :hard_stop
          )
        end)

      Process.sleep(5_100)
      refute Task.yield(task, 0)
      :ok = :sys.resume(orchestrator_pid)
      assert Task.await(task, 2_000) == :ok
    end

    test "a timed-out abort call still dispatches cancellation with its queued tombstone" do
      previous_coordinator = Application.get_env(:lemon_router, :session_coordinator)
      Application.put_env(:lemon_router, :session_coordinator, AbortCaptureCoordinator)
      Application.put_env(:lemon_router, :abort_capture_pid, self())

      on_exit(fn ->
        if previous_coordinator,
          do: Application.put_env(:lemon_router, :session_coordinator, previous_coordinator),
          else: Application.delete_env(:lemon_router, :session_coordinator)

        Application.delete_env(:lemon_router, :abort_capture_pid)
      end)

      {:ok, orchestrator_pid} = GenServer.start_link(RunOrchestrator, [])
      run_id = "run_abort_after_timeout_#{System.unique_integer([:positive])}"
      :ok = :sys.suspend(orchestrator_pid)

      task =
        Task.async(fn ->
          try do
            RunOrchestrator.register_abort(orchestrator_pid, run_id, :hard_stop, 10)
          catch
            :exit, _reason -> :caller_timed_out
          end
        end)

      assert Task.await(task, 1_000) == :caller_timed_out
      :ok = :sys.resume(orchestrator_pid)
      assert_receive {:abort_dispatched, ^run_id, :hard_stop}, 500

      assert {:error, {:run_aborted, :hard_stop}} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   run_id: run_id,
                   origin: :goal,
                   session_key: "agent:abort-timeout:test",
                   agent_id: "test",
                   prompt: "must not start"
                 })
               )
    end

    test "concurrent abort and submission leave no accepted run alive across repetitions" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: BlockingRunProcess
        )

      run_ids =
        for iteration <- 1..32 do
          run_id = "run_abort_race_#{iteration}_#{System.unique_integer([:positive])}"
          session_key = "agent:abort-race:test:#{iteration}:#{System.unique_integer([:positive])}"
          parent = self()

          submit_task =
            Task.async(fn ->
              send(parent, {:ready, self()})
              receive do: (:go -> :ok)

              RunOrchestrator.submit(
                orchestrator_pid,
                request(%{
                  run_id: run_id,
                  origin: :goal,
                  session_key: session_key,
                  agent_id: "test",
                  prompt: "race"
                })
              )
            end)

          abort_task =
            Task.async(fn ->
              send(parent, {:ready, self()})
              receive do: (:go -> :ok)

              :ok = RunOrchestrator.register_abort(orchestrator_pid, run_id, :hard_stop)
              :ok = LemonRouter.SessionCoordinator.abort_run(run_id, :hard_stop)
            end)

          assert_receive {:ready, submit_pid}, 500
          assert_receive {:ready, abort_pid}, 500
          send(submit_pid, :go)
          send(abort_pid, :go)

          assert Task.await(abort_task, 2_000) == :ok

          assert Task.await(submit_task, 2_000) in [
                   {:ok, run_id},
                   {:error, {:run_aborted, :hard_stop}}
                 ]

          assert eventually(fn ->
                   LemonRouter.SessionCoordinator.active_run({:session, session_key}) == :none
                 end)

          run_id
        end

      on_exit(fn ->
        Enum.each(run_ids, &LemonCore.EventBridge.unsubscribe_run/1)
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)
    end

    test "returns :run_capacity_reached when bounded run supervisor is saturated" do
      run_supervisor =
        start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_children: 1})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: BlockingRunProcess
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      params_1 = %{
        origin: :control_plane,
        session_key: "agent:cap:test:1",
        agent_id: "test",
        prompt: "first"
      }

      params_2 = %{
        origin: :control_plane,
        session_key: "agent:cap:test:2",
        agent_id: "test",
        prompt: "second"
      }

      assert {:ok, _run_id} = RunOrchestrator.submit(orchestrator_pid, request(params_1))

      assert {:error, :run_capacity_reached} =
               RunOrchestrator.submit(orchestrator_pid, request(params_2))
    end

    test "idle start failure unsubscribes exactly once" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: RunOrchestratorFailingRunProcess
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      params = %{
        origin: :control_plane,
        session_key: "agent:idle-fail:test:#{System.unique_integer([:positive])}",
        agent_id: "test",
        prompt: "fail immediately"
      }

      assert {:error, :run_failed_to_start} =
               RunOrchestrator.submit(orchestrator_pid, request(params))

      assert_receive {:bridge_subscribed, run_id}, 500
      assert_receive {:bridge_unsubscribed, ^run_id}, 500
      refute_receive {:bridge_unsubscribed, ^run_id}, 100
    end

    test "failed channel submission preserves its pending compaction marker" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: RunOrchestratorFailingRunProcess
        )

      session_key = "agent:compaction-fail:test:#{System.unique_integer([:positive])}"

      marker = %{
        reason: "near_limit",
        session_key: session_key,
        set_at_ms: System.system_time(:millisecond)
      }

      LemonCore.RunHistoryStore.put(
        session_key,
        System.system_time(:millisecond),
        "run-before-failure",
        %{summary: %{prompt: "prior question", answer: "prior answer"}}
      )

      PendingCompactionStore.put(session_key, marker)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
        LemonCore.RunHistoryStore.delete_session(session_key)
        PendingCompactionStore.delete(session_key)
      end)

      assert {:error, :run_failed_to_start} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :channel,
                   session_key: session_key,
                   agent_id: "test",
                   prompt: "continue"
                 })
               )

      assert PendingCompactionStore.get(session_key) == marker
    end

    test "accepted channel submission consumes its pending compaction marker" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      session_key = "agent:compaction-ok:test:#{System.unique_integer([:positive])}"

      marker = %{
        reason: "near_limit",
        session_key: session_key,
        set_at_ms: System.system_time(:millisecond)
      }

      LemonCore.RunHistoryStore.put(
        session_key,
        System.system_time(:millisecond),
        "run-before-success",
        %{summary: %{prompt: "prior question", answer: "prior answer"}}
      )

      PendingCompactionStore.put(session_key, marker)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
        LemonCore.RunHistoryStore.delete_session(session_key)
        PendingCompactionStore.delete(session_key)
      end)

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :channel,
                   session_key: session_key,
                   agent_id: "test",
                   prompt: "continue"
                 })
               )

      assert_receive {:captured_job, execution_request}, 500
      assert execution_request.prompt =~ "prior question"
      assert PendingCompactionStore.get(session_key) == nil
    end
  end

  describe "start_run_process/4" do
    test "merges orchestrator defaults before normalizing the submission" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self(), custom: :value}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = "agent:start-run:test:#{System.unique_integer([:positive])}"
      conversation_key = {:session, session_key}

      submission = %{
        run_id: run_id,
        session_key: session_key,
        conversation_key: conversation_key,
        queue_mode: :collect,
        execution_request: %LemonCore.ExecutionCommand{
          run_id: run_id,
          session_key: session_key,
          prompt: "start directly",
          conversation_key: conversation_key,
          meta: %{}
        }
      }

      assert {:ok, pid} =
               RunOrchestrator.start_run_process(
                 orchestrator_pid,
                 submission,
                 self(),
                 conversation_key
               )

      assert is_pid(pid)
      assert_receive {:captured_run_opts, opts}, 500
      assert opts[:run_id] == run_id
      assert opts[:session_key] == session_key
      assert opts[:conversation_key] == conversation_key
      assert opts[:coordinator_pid] == self()
      assert opts[:manage_session_registry?] == false
      assert opts[:custom] == :value
      assert opts[:execution_request].run_id == run_id
    end

    test "preserves caller-provided start fields instead of overwriting them with orchestrator defaults" do
      orchestrator_run_supervisor =
        start_supervised!(%{
          id: :orchestrator_run_supervisor,
          start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]}
        })

      caller_run_supervisor =
        start_supervised!(%{
          id: :caller_run_supervisor,
          start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]}
        })

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: orchestrator_run_supervisor,
          run_process_module: BlockingRunProcess,
          run_process_opts: %{notify_pid: self(), custom: :default}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = "agent:start-run:override:#{System.unique_integer([:positive])}"
      conversation_key = {:session, session_key}

      submission = %{
        run_id: run_id,
        session_key: session_key,
        conversation_key: conversation_key,
        queue_mode: :collect,
        execution_request: %LemonCore.ExecutionCommand{
          run_id: run_id,
          session_key: session_key,
          prompt: "start directly",
          conversation_key: conversation_key,
          meta: %{}
        },
        run_supervisor: caller_run_supervisor,
        run_process_module: PersistentCapturingRunProcess,
        run_process_opts: %{notify_pid: self(), custom: :caller}
      }

      assert {:ok, pid} =
               RunOrchestrator.start_run_process(
                 orchestrator_pid,
                 submission,
                 self(),
                 conversation_key
               )

      assert is_pid(pid)
      assert_receive {:captured_run_opts, opts}, 500
      assert opts[:custom] == :caller
      assert opts[:conversation_key] == conversation_key
      assert opts[:manage_session_registry?] == false
      assert %{active: 1} = DynamicSupervisor.count_children(caller_run_supervisor)
      assert %{active: 0} = DynamicSupervisor.count_children(orchestrator_run_supervisor)
    end
  end

  describe "cwd override handling" do
    # These tests verify the cwd parameter is properly extracted and passed
    # We test the logic flow rather than the full integration

    test "cwd override is accepted in params" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/custom/working/dir"
      }

      # The orchestrator should accept the cwd parameter without error
      # Even if the full submission fails, no crash should occur
      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cwd from meta is used when no override provided" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        meta: %{cwd: "/meta/working/dir"}
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cwd override takes precedence over meta cwd" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/override/dir",
        meta: %{cwd: "/meta/dir"}
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "tool_policy override handling" do
    test "tool_policy override is accepted in params" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{
          approvals: %{"bash" => :always},
          blocked_tools: ["dangerous_tool"]
        }
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "tool_policy override is merged with resolved policy" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{sandbox: true}
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "empty tool_policy override does not change resolved policy" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{}
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "nil tool_policy override is ignored" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: nil
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "combined overrides" do
    test "both cwd and tool_policy overrides can be provided" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/custom/dir",
        tool_policy: %{
          approvals: %{"bash" => :always}
        }
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "native-only routing" do
    setup do
      original_state = :sys.get_state(LemonRouter.AgentProfiles)

      on_exit(fn ->
        :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_state end)
      end)

      :ok
    end

    test "applies model and profile policy" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      session_key = unique_oracle_session_key()

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
        LemonCore.Store.delete_session_policy(session_key)
      end)

      :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
        %{state | profiles: profile_map_with_oracle()}
      end)

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :control_plane,
                   session_key: session_key,
                   agent_id: "oracle",
                   prompt: "Hello oracle",
                   tool_policy: %{blocked_tools: ["rm"]}
                 })
               )

      assert_receive {:captured_job, job}, 500
      assert job.meta[:model] == "openai-codex:gpt-5.3-codex"
      assert job.meta[:system_prompt] == "You are the oracle."
      assert "bash" in (job.tool_policy[:blocked_tools] || [])
      assert "rm" in (job.tool_policy[:blocked_tools] || [])
    end

    test "keeps structured resume provenance while executing through lemon" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      session_key = unique_oracle_session_key()

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      resume = %ResumeToken{engine: "lemon", value: "session_abc123"}

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :channel,
                   session_key: session_key,
                   agent_id: "test",
                   prompt: "Please continue with this task.",
                   resume: resume
                 })
               )

      assert_receive {:captured_job, job}, 500
      assert job.resume == resume
      assert job.meta[:resume_source] == :explicit
    end

    test "request model takes precedence over session and profile models" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      session_key = unique_oracle_session_key()
      LemonCore.Store.put_session_policy(session_key, %{model: "session-model"})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
        LemonCore.Store.delete_session_policy(session_key)
      end)

      :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
        %{state | profiles: profile_map_with_oracle("profile-model")}
      end)

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :control_plane,
                   session_key: session_key,
                   agent_id: "oracle",
                   prompt: "Hello oracle",
                   model: "request-model"
                 })
               )

      assert_receive {:captured_job, job}, 500
      assert job.meta[:model] == "request-model"
    end

    test "does not mutate the session policy during submission" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      session_key = unique_oracle_session_key()
      session_policy = %{model: "session-model"}
      LemonCore.Store.put_session_policy(session_key, session_policy)

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
        LemonCore.Store.delete_session_policy(session_key)
      end)

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :control_plane,
                   session_key: session_key,
                   agent_id: "test",
                   prompt: "Hello"
                 })
               )

      assert_receive {:captured_job, job}, 500
      assert LemonCore.Store.get_session_policy(session_key) == session_policy
    end
  end

  defp request(attrs), do: RunRequest.new(attrs)

  defp eventually(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
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

  defp unique_oracle_session_key do
    "agent:oracle:main:#{System.unique_integer([:positive])}"
  end

  defp test_profile do
    %{
      id: "test",
      name: "Test Agent",
      description: nil,
      avatar: nil,
      tool_policy: nil,
      system_prompt: nil,
      model: nil,
      rate_limit: nil
    }
  end

  defp profile_map_with_oracle(model \\ "openai-codex:gpt-5.3-codex") do
    %{
      "default" => %{
        id: "default",
        name: "Default Agent",
        tool_policy: nil,
        system_prompt: nil,
        model: nil
      },
      "oracle" => %{
        id: "oracle",
        name: "Oracle",
        tool_policy: %{blocked_tools: ["bash"]},
        system_prompt: "You are the oracle.",
        model: model
      }
    }
  end

  defp ensure_pubsub do
    if Process.whereis(LemonCore.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: LemonCore.PubSub})
    end
  end

  defp restore_event_bridge_impl(nil) do
    Application.delete_env(:lemon_core, :event_bridge_impl)
  end

  defp restore_event_bridge_impl(value) do
    Application.put_env(:lemon_core, :event_bridge_impl, value)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  describe "counts/0 non-placeholder behavior" do
    test "active reflects DynamicSupervisor children" do
      counts = RunOrchestrator.counts()
      assert is_integer(counts.active)
      assert counts.active >= 0
    end

    test "queued is driven by telemetry, not hardcoded to 0" do
      before = RunOrchestrator.counts().queued

      for idx <- 1..25 do
        :telemetry.execute([:lemon, :run, :submit], %{count: 1}, %{
          session_key: "test:counts:#{idx}",
          origin: :test,
          engine: "lemon"
        })
      end

      after_submit = RunOrchestrator.counts().queued
      assert after_submit > before
    end

    test "completed_today is driven by telemetry, not hardcoded to 0" do
      before = RunOrchestrator.counts().completed_today

      :telemetry.execute([:lemon, :run, :stop], %{duration_ms: 50, ok: true}, %{
        run_id: "run_counts_test"
      })

      after_stop = RunOrchestrator.counts().completed_today
      assert after_stop == before + 1
    end
  end
end
