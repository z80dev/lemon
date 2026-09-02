defmodule LemonRouter.SessionCoordinatorTest do
  use ExUnit.Case, async: false

  alias LemonCore.ExecutionCommand
  alias LemonRouter.{SessionCoordinator, Submission}

  defmodule StubRunProcess do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id]},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def abort(pid, reason), do: GenServer.cast(pid, {:abort, reason})

    @impl true
    def init(opts) do
      send(opts[:test_pid], {:started, opts[:run_id], opts})
      {:ok, %{run_id: opts[:run_id], test_pid: opts[:test_pid]}}
    end

    @impl true
    def handle_cast({:abort, reason}, state) do
      send(state.test_pid, {:aborted, state.run_id, reason})
      {:stop, :normal, state}
    end
  end

  defmodule SessionCoordinatorFailingRunProcess do
    def start_link(_opts), do: {:error, :run_failed_to_start}

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id]},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end
  end

  defmodule SessionCoordinatorEventBridgeStub do
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

  defmodule SessionCoordinatorRuntime do
    def submit_execution(_command), do: :ok
    def cancel_by_run_id(_run_id, _reason), do: :ok
    def available?, do: true

    def run_pid(run_id) do
      case Registry.lookup(LemonRouter.RunRegistry, run_id) do
        [{pid, _}] -> pid
        _ -> nil
      end
    end
  end

  defmodule SessionCoordinatorRuntimeRunStub do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(
        __MODULE__,
        opts,
        name:
          {:via, Registry,
           {LemonRouter.RunRegistry, opts[:run_id], %{session_key: opts[:session_key]}}}
      )
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast({_kind, _submission_run_id, _prompt, _worker_pid}, state),
      do: {:noreply, state}
  end

  defmodule SessionCoordinatorForwardingRunStub do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(
        __MODULE__,
        opts,
        name:
          {:via, Registry,
           {LemonRouter.RunRegistry, opts[:run_id], %{session_key: opts[:session_key]}}}
      )
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast({kind, submission_run_id, prompt, worker_pid}, state) do
      send(state[:test_pid], {:run_cast, kind, submission_run_id, prompt, worker_pid})
      {:noreply, state}
    end
  end

  defmodule SessionCoordinatorNoticeDispatcher do
    # The dispatcher is swapped in globally, so intents flushed by coalescers
    # left running by other modules land here too. Only :notice intents are
    # under test; forwarding anything else makes the refutes below fire on
    # unrelated traffic.
    def dispatch(%LemonCore.DeliveryIntent{kind: :notice} = intent) do
      case Application.get_env(:lemon_router, :notice_dispatcher_test_pid) do
        pid when is_pid(pid) -> send(pid, {:notice_dispatched, intent})
        _ -> :ok
      end

      :ok
    end

    def dispatch(_intent), do: :ok
  end

  setup do
    ensure_pubsub()

    start_if_needed(LemonRouter.ConversationRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.ConversationRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :duplicate, name: LemonRouter.SessionRegistry)
    end)

    start_if_needed(LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
    end)

    {:ok, run_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, coord_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    original =
      Process.whereis(LemonRouter.SessionCoordinatorSupervisor) ||
        Application.get_env(:lemon_router, :session_coordinator_supervisor)

    if is_pid(Process.whereis(LemonRouter.SessionCoordinatorSupervisor)) do
      safe_unregister(LemonRouter.SessionCoordinatorSupervisor)
    end

    Process.register(coord_supervisor, LemonRouter.SessionCoordinatorSupervisor)

    on_exit(fn ->
      if is_pid(Process.whereis(LemonRouter.SessionCoordinatorSupervisor)) do
        safe_unregister(LemonRouter.SessionCoordinatorSupervisor)
      end

      if is_pid(original) do
        Process.register(original, LemonRouter.SessionCoordinatorSupervisor)
      end
    end)

    original_bridge_impl = Application.get_env(:lemon_core, :event_bridge_impl)
    original_bridge_test_pid = Application.get_env(:lemon_router, :event_bridge_test_pid)
    original_engine_runtime = Application.get_env(:lemon_router, :engine_runtime)
    Application.put_env(:lemon_router, :event_bridge_test_pid, self())
    Application.put_env(:lemon_router, :engine_runtime, SessionCoordinatorRuntime)
    :ok = LemonCore.EventBridge.configure(SessionCoordinatorEventBridgeStub)

    on_exit(fn ->
      restore_event_bridge_impl(original_bridge_impl)
      restore_engine_runtime(original_engine_runtime)

      case original_bridge_test_pid do
        nil -> Application.delete_env(:lemon_router, :event_bridge_test_pid)
        pid -> Application.put_env(:lemon_router, :event_bridge_test_pid, pid)
      end
    end)

    {:ok, run_supervisor: run_supervisor}
  end

  test "collect submissions queue behind the active run", %{run_supervisor: run_supervisor} do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:started, "run2", _}, 500
  end

  test "cancel(session_key) preserves queued work end to end", %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    :ok = submit(key, "run3", "three", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100
    refute_receive {:started, "run3", _}, 100

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:started, "run2", _}, 500
    refute_receive {:started, "run3", _}, 100

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run2", :user_requested}, 500
    assert_receive {:started, "run3", _}, 500
  end

  test "followup submissions merge while queued behind an active run", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = submit(key, "run2", "part1", :followup, run_supervisor)
    :ok = submit(key, "run3", "part2", :followup, run_supervisor)

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500

    assert_receive {:started, "run3", opts}, 500
    assert opts[:execution_request].prompt == "part1\npart2"
  end

  test "interrupt submissions preempt queued work after canceling the active run", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    :ok = submit(key, "run3", "urgent", :interrupt, run_supervisor)

    assert_receive {:aborted, "run1", :interrupted}, 500
    assert_receive {:started, "run3", _}, 500

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run3", :user_requested}, 500
    assert_receive {:started, "run2", _}, 500
  end

  test "abort_session/2 clears queued work for the matching session", %{
    run_supervisor: run_supervisor
  } do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100

    :ok = SessionCoordinator.abort_session(session_key, :user_requested)

    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:bridge_unsubscribed, "run2"}, 500
    refute_receive {:started, "run2", _}, 300
  end

  test "abort_run/2 clears queued work before it starts", %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100

    :ok = SessionCoordinator.abort_run("run2", :user_requested)
    assert_receive {:bridge_unsubscribed, "run2"}, 500

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    refute_receive {:started, "run2", _}, 300
  end

  test "immediate submit surfaces router_not_ready when run start fails before any active run exists" do
    key = {:session, unique_session_key()}
    dead_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    GenServer.stop(dead_supervisor)

    failing_submission =
      submission(key, "run1", "one", :collect, dead_supervisor)

    assert {:error, :router_not_ready} = SessionCoordinator.submit(key, failing_submission)
    refute_receive {:started, "run1", _}, 100
  end

  test "SessionCoordinator owns SessionRegistry entries for the active session", %{
    run_supervisor: run_supervisor
  } do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    assert eventually(fn ->
             case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
               [{_pid, %{run_id: "run1"}}] -> true
               _ -> false
             end
           end)

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500

    assert eventually(fn ->
             Registry.lookup(LemonRouter.SessionRegistry, session_key) == []
           end)
  end

  test "query helpers expose router-owned active session state", %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}

    refute SessionCoordinator.busy?(session_key)
    assert SessionCoordinator.active_run_for_session(session_key) == :none

    refute Enum.any?(
             SessionCoordinator.list_active_sessions(),
             &(&1.session_key == session_key)
           )

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    assert SessionCoordinator.busy?(session_key)
    assert SessionCoordinator.active_run_for_session(session_key) == {:ok, "run1"}

    assert [%{session_key: ^session_key, run_id: "run1"}] =
             Enum.filter(
               SessionCoordinator.list_active_sessions(),
               &(&1.session_key == session_key)
             )

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500

    assert eventually(fn -> not SessionCoordinator.busy?(session_key) end)
    assert eventually(fn -> SessionCoordinator.active_run_for_session(session_key) == :none end)
  end

  test "query helpers report unavailable while the session registry cannot be consulted" do
    assert :ok =
             Supervisor.terminate_child(LemonRouter.Supervisor, LemonRouter.SessionRegistry)

    try do
      assert {:error, :unavailable} =
               SessionCoordinator.active_run_for_session("agent:test:main")

      assert {:error, :unavailable} = SessionCoordinator.busy?("agent:test:main")
      assert {:error, :unavailable} = SessionCoordinator.list_active_sessions()
    after
      assert {:ok, _pid} =
               Supervisor.restart_child(LemonRouter.Supervisor, LemonRouter.SessionRegistry)
    end
  end

  test "active queries consult the surviving run registry after registry-linked coordinator loss",
       %{
         run_supervisor: run_supervisor
       } do
    session_key = unique_session_key()
    key = {:session, session_key}

    assert :ok =
             SessionCoordinator.submit(
               key,
               submission(key, "run-registry-repair", "one", :collect, run_supervisor,
                 run_process_module: SessionCoordinatorRuntimeRunStub
               )
             )

    assert eventually(fn ->
             Registry.lookup(LemonRouter.RunRegistry, "run-registry-repair") != []
           end)

    assert [{coordinator_pid, _meta}] = Registry.lookup(LemonRouter.ConversationRegistry, key)

    assert :ok = Supervisor.terminate_child(LemonRouter.Supervisor, LemonRouter.SessionRegistry)

    assert {:ok, _pid} =
             Supervisor.restart_child(LemonRouter.Supervisor, LemonRouter.SessionRegistry)

    refute Process.alive?(coordinator_pid)
    assert Registry.lookup(LemonRouter.SessionRegistry, session_key) == []
    assert {:ok, "run-registry-repair"} = SessionCoordinator.active_run_for_session(session_key)
  end

  test "submission adopts a surviving run after SessionRegistry restart before starting the next",
       %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}
    run1 = "run-registry-single-flight-1-#{System.unique_integer([:positive])}"
    run2 = "run-registry-single-flight-2-#{System.unique_integer([:positive])}"

    assert :ok =
             SessionCoordinator.submit(
               key,
               submission(key, run1, "one", :collect, run_supervisor,
                 run_process_module: SessionCoordinatorRuntimeRunStub
               )
             )

    assert eventually(fn -> Registry.lookup(LemonRouter.RunRegistry, run1) != [] end)
    assert [{old_coordinator, _meta}] = Registry.lookup(LemonRouter.ConversationRegistry, key)

    assert :ok = Supervisor.terminate_child(LemonRouter.Supervisor, LemonRouter.SessionRegistry)

    assert {:ok, _pid} =
             Supervisor.restart_child(LemonRouter.Supervisor, LemonRouter.SessionRegistry)

    refute Process.alive?(old_coordinator)
    assert [{run1_pid, _}] = Registry.lookup(LemonRouter.RunRegistry, run1)

    assert :ok =
             SessionCoordinator.submit(
               key,
               submission(key, run2, "two", :collect, run_supervisor,
                 run_process_module: SessionCoordinatorRuntimeRunStub
               )
             )

    refute eventually(fn -> Registry.lookup(LemonRouter.RunRegistry, run2) != [] end, 100)
    assert Process.alive?(run1_pid)

    GenServer.stop(run1_pid)
    assert eventually(fn -> Registry.lookup(LemonRouter.RunRegistry, run2) != [] end)
  end

  test "an unrelated suspended run cannot block idle submission", %{run_supervisor: run_supervisor} do
    unrelated_run = "run-unrelated-suspended-#{System.unique_integer([:positive])}"

    unrelated_pid =
      start_supervised!(
        {SessionCoordinatorRuntimeRunStub,
         run_id: unrelated_run, session_key: "agent:unrelated:main"},
        id: {:unrelated_suspended_run, unrelated_run}
      )

    :ok = :sys.suspend(unrelated_pid)

    on_exit(fn ->
      if Process.alive?(unrelated_pid), do: :sys.resume(unrelated_pid)
    end)

    session_key = unique_session_key()
    key = {:session, session_key}
    target_run = "run-not-blocked-#{System.unique_integer([:positive])}"

    assert :ok =
             SessionCoordinator.submit(
               key,
               submission(key, target_run, "one", :collect, run_supervisor,
                 run_process_module: SessionCoordinatorRuntimeRunStub
               )
             )

    assert eventually(fn -> Registry.lookup(LemonRouter.RunRegistry, target_run) != [] end)
  end

  test "merged queued followups unsubscribe the superseded run", %{run_supervisor: run_supervisor} do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "part1", :followup, run_supervisor)

    :ok = LemonCore.EventBridge.subscribe_run("run3")
    assert_receive {:bridge_subscribed, "run3"}, 500
    :ok = submit(key, "run3", "part2", :followup, run_supervisor)

    assert_receive {:bridge_unsubscribed, "run2"}, 500
    refute_receive {:bridge_unsubscribed, "run3"}, 100
  end

  test "queued runs that fail to start later are unsubscribed", %{run_supervisor: run_supervisor} do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500

    failing_submission =
      submission(key, "run2", "two", :collect, run_supervisor,
        run_process_module: SessionCoordinatorFailingRunProcess
      )

    :ok = SessionCoordinator.submit(key, failing_submission)
    [{_, active_pid, _, _}] = DynamicSupervisor.which_children(run_supervisor)
    GenServer.stop(active_pid, :normal)
    assert_receive {:bridge_unsubscribed, "run2"}, 500
  end

  test "queued start failure emits one terminal completion and advances the queue", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    LemonCore.Bus.subscribe(LemonCore.Bus.run_topic("run2"))

    failing_submission =
      submission(key, "run2", "two", :collect, run_supervisor,
        run_process_module: SessionCoordinatorFailingRunProcess
      )

    :ok = SessionCoordinator.submit(key, failing_submission)
    :ok = submit(key, "run3", "three", :collect, run_supervisor)

    [{_, active_pid, _, _}] = DynamicSupervisor.which_children(run_supervisor)
    GenServer.stop(active_pid, :normal)

    assert_receive %LemonCore.Event{
                     type: :run_completed,
                     payload: %{
                       completed: %{
                         ok: false,
                         error: %{type: :run_start_failed, reason: :run_failed_to_start}
                       }
                     },
                     meta: %{
                       run_id: "run2",
                       synthetic: true,
                       failure_stage: :run_start
                     }
                   },
                   500

    refute_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: "run2"}}, 100
    assert_receive {:bridge_unsubscribed, "run2"}, 500
    assert_receive {:started, "run3", _}, 500

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run3", :user_requested}, 500
  end

  test "steer dispatch failure falls back to queued work correctly", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    with_stopped_run_registry(fn ->
      :ok = submit(key, "run2", "two", :steer, run_supervisor)
      refute_receive {:started, "run2", _}, 100
    end)

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:started, "run2", _}, 500
  end

  test "steer_backlog dispatch failure falls back to collect semantics correctly", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    with_stopped_run_registry(fn ->
      :ok = submit(key, "run2", "two", :steer_backlog, run_supervisor)
      refute_receive {:started, "run2", _}, 100
    end)

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:started, "run2", opts}, 500
    assert opts[:queue_mode] == :collect
  end

  test "canceling a conversation unsubscribes dropped queued runs", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100

    SessionCoordinator.cancel(key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:bridge_unsubscribed, "run2"}, 500
    refute_receive {:started, "run2", _}, 300
  end

  test "cancel drops pending steer submissions and unsubscribes them", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    runtime_run = start_supervised!({SessionCoordinatorRuntimeRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :steer, run_supervisor)

    SessionCoordinator.cancel(key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:bridge_unsubscribed, "run2"}, 500

    GenServer.stop(runtime_run)
  end

  test "abort_session drops pending steer submissions and unsubscribes them", %{
    run_supervisor: run_supervisor
  } do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    runtime_run = start_supervised!({SessionCoordinatorRuntimeRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :steer, run_supervisor)

    :ok = SessionCoordinator.abort_session(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:bridge_unsubscribed, "run2"}, 500

    GenServer.stop(runtime_run)
  end

  test "cancel drops pending steer_backlog submissions and unsubscribes them", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    runtime_run = start_supervised!({SessionCoordinatorRuntimeRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :steer_backlog, run_supervisor)

    SessionCoordinator.cancel(key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:bridge_unsubscribed, "run2"}, 500

    GenServer.stop(runtime_run)
  end

  test "redirect dispatch casts the stable control tuple LemonGateway.Run consumes", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    runtime_run = start_runtime_run("run1")

    :ok = submit(key, "run2", "two", :redirect, run_supervisor)

    assert_receive {:run_cast, :redirect, "run2", "two", coord_pid}, 500

    assert is_pid(coord_pid)
    assert coord_pid == coordinator_pid(key)

    GenServer.stop(runtime_run)
  end

  test "accepted redirect clears the pending entry so it never re-runs", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    runtime_run = start_runtime_run("run1")

    :ok = submit(key, "run2", "two", :redirect, run_supervisor)
    assert_receive {:run_cast, :redirect, "run2", "two", coord_pid}, 500

    send(coord_pid, {:redirect_accepted, "run2"})
    # Flush the coordinator mailbox so the acceptance is applied before run1 exits.
    assert {:ok, "run1"} = SessionCoordinator.active_run(key)

    stop_active_run(run_supervisor)
    refute_receive {:started, "run2", _}, 300

    GenServer.stop(runtime_run)
  end

  test "accepted steer acknowledgement matches the submitted run id", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    runtime_run = start_runtime_run("run1")

    :ok = submit(key, "run2", "two", :steer, run_supervisor)
    assert_receive {:run_cast, :steer, "run2", "two", coord_pid}, 500

    send(coord_pid, {:steer_accepted, "run2"})
    assert {:ok, "run1"} = SessionCoordinator.active_run(key)

    stop_active_run(run_supervisor)
    refute_receive {:started, "run2", _}, 300

    GenServer.stop(runtime_run)
  end

  test "accepted steer backlog acknowledgement matches the submitted run id", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    runtime_run = start_runtime_run("run1")

    :ok = submit(key, "run2", "two", :steer_backlog, run_supervisor)
    assert_receive {:run_cast, :steer_backlog, "run2", "two", coord_pid}, 500

    send(coord_pid, {:steer_backlog_accepted, "run2"})
    assert {:ok, "run1"} = SessionCoordinator.active_run(key)

    stop_active_run(run_supervisor)
    refute_receive {:started, "run2", _}, 300

    GenServer.stop(runtime_run)
  end

  test "rejected redirect notifies the user and falls back to a followup", %{
    run_supervisor: run_supervisor
  } do
    with_notice_dispatcher(fn ->
      key = {:session, channel_session_key()}

      :ok = submit(key, "run1", "one", :collect, run_supervisor)
      assert_receive {:started, "run1", _}, 500
      runtime_run = start_runtime_run("run1")

      :ok = submit(key, "run2", "two", :redirect, run_supervisor)
      assert_receive {:run_cast, :redirect, "run2", "two", coord_pid}, 500

      send(coord_pid, {:redirect_rejected, "run2"})

      assert_receive {:notice_dispatched, %LemonCore.DeliveryIntent{} = intent}, 500
      assert intent.kind == :notice
      assert intent.run_id == "run2"
      assert intent.intent_id == "run2:redirect:fallback"
      assert intent.session_key == elem(key, 1)
      assert intent.meta[:surface] == :status
      assert intent.body[:seq] == 0
      assert intent.body[:text] =~ "follow-up"
      assert intent.route.channel_id == "telegram"
      assert intent.route.peer_kind == :dm

      refute_receive {:started, "run2", _}, 200

      stop_active_run(run_supervisor)
      assert_receive {:started, "run2", opts}, 500
      assert opts[:queue_mode] == :followup

      GenServer.stop(runtime_run)
    end)
  end

  test "redirect dispatch failure notifies the user while steer stays silent", %{
    run_supervisor: run_supervisor
  } do
    with_notice_dispatcher(fn ->
      key = {:session, channel_session_key()}

      :ok = submit(key, "run1", "one", :collect, run_supervisor)
      assert_receive {:started, "run1", _}, 500

      with_stopped_run_registry(fn ->
        :ok = submit(key, "run2", "two", :steer, run_supervisor)
        refute_receive {:notice_dispatched, _}, 200

        :ok = submit(key, "run3", "three", :redirect, run_supervisor)

        assert_receive {:notice_dispatched, %LemonCore.DeliveryIntent{run_id: "run3"} = intent},
                       500

        assert intent.kind == :notice
      end)

      SessionCoordinator.cancel(elem(key, 1), :user_requested)
      assert_receive {:aborted, "run1", :user_requested}, 500
    end)
  end

  test "rejected redirect on a non-channel session key dispatches no notice", %{
    run_supervisor: run_supervisor
  } do
    with_notice_dispatcher(fn ->
      key = {:session, unique_session_key()}

      :ok = submit(key, "run1", "one", :collect, run_supervisor)
      assert_receive {:started, "run1", _}, 500
      runtime_run = start_runtime_run("run1")

      :ok = submit(key, "run2", "two", :redirect, run_supervisor)
      assert_receive {:run_cast, :redirect, "run2", "two", coord_pid}, 500

      send(coord_pid, {:redirect_rejected, "run2"})
      refute_receive {:notice_dispatched, _}, 200

      # The coordinator survives and still applies the followup fallback.
      assert {:ok, "run1"} = SessionCoordinator.active_run(key)
      assert Process.alive?(coord_pid)

      stop_active_run(run_supervisor)
      assert_receive {:started, "run2", _}, 500

      GenServer.stop(runtime_run)
    end)
  end

  defp start_runtime_run(run_id) do
    start_supervised!(
      {SessionCoordinatorForwardingRunStub, run_id: run_id, test_pid: self()},
      id: {:forwarding_run, run_id}
    )
  end

  defp coordinator_pid(key) do
    [{pid, _}] = Registry.lookup(LemonRouter.ConversationRegistry, key)
    pid
  end

  defp stop_active_run(run_supervisor) do
    [{_, active_pid, _, _}] = DynamicSupervisor.which_children(run_supervisor)
    GenServer.stop(active_pid, :normal)
    :ok
  end

  defp with_notice_dispatcher(fun) when is_function(fun, 0) do
    original_dispatcher = Application.get_env(:lemon_router, :dispatcher)
    original_test_pid = Application.get_env(:lemon_router, :notice_dispatcher_test_pid)

    Application.put_env(:lemon_router, :dispatcher, SessionCoordinatorNoticeDispatcher)
    Application.put_env(:lemon_router, :notice_dispatcher_test_pid, self())

    try do
      fun.()
    after
      restore_env(:dispatcher, original_dispatcher)
      restore_env(:notice_dispatcher_test_pid, original_test_pid)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_router, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_router, key, value)

  defp channel_session_key do
    "agent:test:telegram:default:dm:#{System.unique_integer([:positive])}"
  end

  defp submit(key, run_id, prompt, queue_mode, run_supervisor) do
    SessionCoordinator.submit(key, submission(key, run_id, prompt, queue_mode, run_supervisor))
  end

  defp submission(key, run_id, prompt, queue_mode, run_supervisor, overrides \\ []) do
    request = %ExecutionCommand{
      run_id: run_id,
      session_key: elem(key, 1),
      prompt: prompt,
      conversation_key: key,
      meta: %{}
    }

    attrs =
      %{
        run_id: run_id,
        session_key: elem(key, 1),
        conversation_key: key,
        queue_mode: queue_mode,
        execution_request: request,
        run_supervisor: run_supervisor,
        run_process_module: StubRunProcess,
        run_process_opts: %{test_pid: self()}
      }
      |> Map.merge(Enum.into(overrides, %{}))

    Submission.new!(attrs)
  end

  defp unique_session_key do
    "agent:test:main:#{System.unique_integer([:positive])}"
  end

  defp eventually(fun, timeout_ms \\ 500) when is_function(fun, 0) do
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

  defp start_if_needed(name, fun) do
    if is_nil(Process.whereis(name)) do
      {:ok, _pid} = fun.()
    end

    :ok
  end

  defp ensure_pubsub do
    if Process.whereis(LemonCore.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: LemonCore.PubSub})
    end
  end

  defp safe_unregister(name) do
    Process.unregister(name)
  rescue
    ArgumentError -> :ok
  end

  defp restore_event_bridge_impl(nil) do
    Application.delete_env(:lemon_core, :event_bridge_impl)
  end

  defp restore_event_bridge_impl(value) do
    Application.put_env(:lemon_core, :event_bridge_impl, value)
  end

  defp restore_engine_runtime(nil), do: Application.delete_env(:lemon_router, :engine_runtime)

  defp restore_engine_runtime(value),
    do: Application.put_env(:lemon_router, :engine_runtime, value)

  defp with_stopped_run_registry(fun) when is_function(fun, 0) do
    registry_pid = Process.whereis(LemonRouter.RunRegistry)

    if is_pid(registry_pid) do
      GenServer.stop(registry_pid)
    end

    try do
      fun.()
    after
      start_if_needed(LemonRouter.RunRegistry, fn ->
        Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
      end)
    end
  end
end
