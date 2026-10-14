defmodule LemonRouter.SessionCoordinatorTest do
  use ExUnit.Case, async: false

  alias LemonCore.ExecutionCommand
  alias LemonRouter.{RunReceiptStore, SessionCoordinator, Submission}

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

  defmodule ReceiptRefusingBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(opts) do
      {:ok, %{
        data: %{},
        refuse_initial: opts[:refuse_initial],
        allow_fence: opts[:allow_fence],
        allow_updates: opts[:allow_updates],
        sync_failure: opts[:sync_failure]
      }}
    end

    @impl true
    def put(%{allow_updates: true} = state, :run_receipts, key, value),
      do: {:ok, %{state | data: Map.put(state.data, {:run_receipts, key}, value)}}

    def put(%{allow_fence: true} = state, :run_receipts, key, %{state: :outcome_unknown} = value),
      do: {:ok, %{state | data: Map.put(state.data, {:run_receipts, key}, value)}}

    def put(_state, :run_receipts, _key, _value), do: {:error, :write_refused}
    def put(state, table, key, value),
      do: {:ok, %{state | data: Map.put(state.data, {table, key}, value)}}

    @impl true
    def put_new(%{refuse_initial: true}, :run_receipts, _key, _value),
      do: {:error, :write_refused}

    def put_new(state, table, key, value) do
      if Map.has_key?(state.data, {table, key}) do
        {:exists, state}
      else
        {:ok, %{state | data: Map.put(state.data, {table, key}, value)}}
      end
    end

    @impl true
    def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

    @impl true
    def delete(state, table, key),
      do: {:ok, %{state | data: Map.delete(state.data, {table, key})}}

    @impl true
    def list(state, table),
      do: {:ok, for({{^table, key}, value} <- state.data, do: {key, value}), state}

    @impl true
    def sync(state) do
      failure = Map.get(state.data, {:receipt_backend_failures, :sync}, state.sync_failure)

      refused =
        case failure do
          true -> true
          pattern when is_map(pattern) ->
            Enum.any?(state.data, fn
              {{:run_receipts, _key}, receipt} ->
                Enum.all?(pattern, fn {key, value} -> Map.get(receipt, key) == value end)
              _other -> false
            end)
          _other -> false
        end

      if refused, do: {:error, :sync_refused}, else: {:ok, state}
    end
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
    Enum.each(~w(run1 run2 run3 run4 run-registry-repair), fn run_id ->
      LemonCore.Store.delete(:runs, run_id)
      LemonCore.Store.delete(:run_receipts, run_id)
      LemonCore.Store.delete(:native_resume_contexts, {:run, run_id})
    end)

    on_exit(fn ->
      restore_event_bridge_impl(original_bridge_impl)
      restore_engine_runtime(original_engine_runtime)
      Enum.each(~w(run1 run2 run3 run4 run-registry-repair), fn run_id ->
        LemonCore.Store.delete(:run_receipts, run_id)
        LemonCore.Store.delete(:native_resume_contexts, {:run, run_id})
      end)

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
    assert_receive {:started, "run1", _}

    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:started, "run2", _}
  end

  test "cancel(session_key) preserves queued work end to end", %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    :ok = submit(key, "run3", "three", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100
    refute_receive {:started, "run3", _}, 100

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:started, "run2", _}
    refute_receive {:started, "run3", _}, 100

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run2", :user_requested}
    assert_receive {:started, "run3", _}
  end

  test "followup submissions merge while queued behind an active run", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    :ok = submit(key, "run2", "part1", :followup, run_supervisor)
    :ok = submit(key, "run3", "part2", :followup, run_supervisor)

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run1", :user_requested}

    assert_receive {:started, "run3", opts}
    assert opts[:execution_request].prompt == "part1\npart2"
  end

  test "interrupt submissions preempt queued work after canceling the active run", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    :ok = submit(key, "run3", "urgent", :interrupt, run_supervisor)

    assert_receive {:aborted, "run1", :interrupted}
    assert_receive {:started, "run3", _}

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run3", :user_requested}
    assert_receive {:started, "run2", _}
  end

  test "abort_session/2 clears queued work for the matching session", %{
    run_supervisor: run_supervisor
  } do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}
    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100

    :ok = SessionCoordinator.abort_session(session_key, :user_requested)

    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:bridge_unsubscribed, "run2"}
    refute_receive {:started, "run2", _}, 300
  end

  test "abort_run/2 clears queued work before it starts", %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}
    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100

    :ok = SessionCoordinator.abort_run("run2", :user_requested)
    assert_receive {:bridge_unsubscribed, "run2"}

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
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
    assert_receive {:started, "run1", _}

    assert eventually(fn ->
             case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
               [{_pid, %{run_id: "run1"}}] -> true
               _ -> false
             end
           end)

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}

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
    assert_receive {:started, "run1", _}

    assert SessionCoordinator.busy?(session_key)
    assert SessionCoordinator.active_run_for_session(session_key) == {:ok, "run1"}

    assert [%{session_key: ^session_key, run_id: "run1"}] =
             Enum.filter(
               SessionCoordinator.list_active_sessions(),
               &(&1.session_key == session_key)
             )

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}

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

  test "an unrelated suspended run cannot block idle submission", %{
    run_supervisor: run_supervisor
  } do
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
    assert_receive {:started, "run1", _}

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}
    :ok = submit(key, "run2", "part1", :followup, run_supervisor)

    :ok = LemonCore.EventBridge.subscribe_run("run3")
    assert_receive {:bridge_subscribed, "run3"}
    :ok = submit(key, "run3", "part2", :followup, run_supervisor)

    assert_receive {:bridge_unsubscribed, "run2"}
    refute_receive {:bridge_unsubscribed, "run3"}, 100
  end

  test "merged followups and queued aborts have durable terminal receipts", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}
    active = "active-receipts-#{System.unique_integer([:positive])}"
    merged = "merged-receipt-#{System.unique_integer([:positive])}"
    replacement = "replacement-receipt-#{System.unique_integer([:positive])}"
    cancelled = "cancelled-receipt-#{System.unique_integer([:positive])}"

    :ok = submit(key, active, "hold", :collect, run_supervisor)
    assert_receive {:started, ^active, _}
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(merged))
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(cancelled))
    :ok = submit(key, merged, "part1", :followup, run_supervisor)
    :ok = submit(key, replacement, "part2", :followup, run_supervisor)

    assert_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^merged}}

    assert %{
             summary: %{
               completed: %{
                 ok: false,
                 error: %{type: :superseded, replacement_run_id: ^replacement}
               }
             }
           } =
             LemonCore.RunStore.get(merged)

    :ok = submit(key, cancelled, "cancel me", :collect, run_supervisor)
    [{pid, _}] = Registry.lookup(LemonRouter.ConversationRegistry, key)
    assert GenServer.call(pid, :pending_count) == 2
    :ok = SessionCoordinator.abort_run(cancelled)
    assert_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^cancelled}}

    assert %{
             summary: %{
               completed: %{
                 ok: false,
                 error: :user_requested,
                 run_id: ^cancelled,
                 meta: %{cancelled: true}
               }
             }
           } =
             LemonCore.RunStore.get(cancelled)

    assert GenServer.call(pid, :pending_count) == 1
    refute_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^cancelled}}, 50
  end

  test "queued runs that fail to start later are unsubscribed", %{run_supervisor: run_supervisor} do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}

    failing_submission =
      submission(key, "run2", "two", :collect, run_supervisor,
        run_process_module: SessionCoordinatorFailingRunProcess
      )

    :ok = SessionCoordinator.submit(key, failing_submission)
    [{_, active_pid, _, _}] = DynamicSupervisor.which_children(run_supervisor)
    GenServer.stop(active_pid, :normal)
    assert_receive {:bridge_unsubscribed, "run2"}
  end

  test "queued start failure emits one terminal completion and advances the queue", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}
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
    assert_receive {:bridge_unsubscribed, "run2"}
    assert_receive {:started, "run3", _}

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run3", :user_requested}
  end

  test "steer dispatch failure falls back to queued work correctly", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    with_stopped_run_registry(fn ->
      :ok = submit(key, "run2", "two", :steer, run_supervisor)
      refute_receive {:started, "run2", _}, 100
    end)

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:started, "run2", _}
  end

  test "steer_backlog dispatch failure falls back to collect semantics correctly", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    with_stopped_run_registry(fn ->
      :ok = submit(key, "run2", "two", :steer_backlog, run_supervisor)
      refute_receive {:started, "run2", _}, 100
    end)

    SessionCoordinator.cancel(elem(key, 1), :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:started, "run2", opts}
    assert opts[:queue_mode] == :collect
  end

  test "canceling a conversation unsubscribes dropped queued runs", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}
    :ok = submit(key, "run2", "two", :collect, run_supervisor)
    refute_receive {:started, "run2", _}, 100

    SessionCoordinator.cancel(key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:bridge_unsubscribed, "run2"}
    refute_receive {:started, "run2", _}, 300
  end

  test "cancel drops pending steer submissions and unsubscribes them", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}
    runtime_run = start_supervised!({SessionCoordinatorRuntimeRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}
    :ok = submit(key, "run2", "two", :steer, run_supervisor)

    SessionCoordinator.cancel(key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:bridge_unsubscribed, "run2"}

    GenServer.stop(runtime_run)
  end

  test "abort_session drops pending steer submissions and unsubscribes them", %{
    run_supervisor: run_supervisor
  } do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}
    runtime_run = start_supervised!({SessionCoordinatorRuntimeRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}
    :ok = submit(key, "run2", "two", :steer, run_supervisor)

    :ok = SessionCoordinator.abort_session(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:bridge_unsubscribed, "run2"}

    GenServer.stop(runtime_run)
  end

  test "cancel drops pending steer_backlog submissions and unsubscribes them", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}
    runtime_run = start_supervised!({SessionCoordinatorRuntimeRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}
    :ok = submit(key, "run2", "two", :steer_backlog, run_supervisor)

    SessionCoordinator.cancel(key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}
    assert_receive {:bridge_unsubscribed, "run2"}

    GenServer.stop(runtime_run)
  end

  test "redirect dispatch casts the stable control tuple LemonGateway.Run consumes", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}
    runtime_run = start_runtime_run("run1")

    :ok = submit(key, "run2", "two", :redirect, run_supervisor)

    assert_receive {:run_cast, :redirect, "run2", "two", coord_pid}

    assert is_pid(coord_pid)
    assert coord_pid == coordinator_pid(key)

    GenServer.stop(runtime_run)
  end

  @tag :tmp_dir
  test "live commands expand for local users but preserve internal and destination-local prompts",
       %{run_supervisor: run_supervisor, tmp_dir: cwd} do
    command = Path.join(cwd, ".claude/commands/review.md")
    File.mkdir_p!(Path.dirname(command))
    File.write!(command, "Review [$1] carefully")
    other_cwd = Path.join(cwd, "other-project")
    other_command = Path.join(other_cwd, ".claude/commands/review.md")
    File.mkdir_p!(Path.dirname(other_command))
    File.write!(other_command, "Do not use incoming cwd")
    original_provider = Application.get_env(:lemon_core, :agent_runtime_provider)
    :ok = LemonCore.AgentRuntime.register(CodingAgent.ControlPlaneProvider)

    on_exit(fn ->
      if original_provider,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, original_provider),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    key = {:session, unique_session_key()}
    active_id = "command-active-#{System.unique_integer([:positive])}"

    active_request = %ExecutionCommand{
      run_id: active_id,
      session_key: elem(key, 1),
      conversation_key: key,
      cwd: cwd,
      prompt: "one",
      meta: %{}
    }

    :ok =
      SessionCoordinator.submit(
        key,
        submission(key, active_id, "one", :collect, run_supervisor,
          execution_request: active_request
        )
      )

    assert_receive {:started, ^active_id, _}
    runtime_run = start_runtime_run(active_id)

    cases = [
      {:steer, %{origin: :control_plane}, "Review [lib/app.ex] carefully"},
      {:redirect, %{origin: :channel}, "Review [lib/app.ex] carefully"},
      {:steer, %{origin: :node}, "/review lib/app.ex"},
      {:redirect, %{origin: :control_plane, node: "worker"}, "/review lib/app.ex"},
      {:steer, %{origin: :channel, async_followups: [%{task_id: "task"}]}, "/review lib/app.ex"}
    ]

    for {mode, meta, expected} <- cases do
      id = "command-submission-#{System.unique_integer([:positive])}"

      request = %ExecutionCommand{
        run_id: id,
        session_key: elem(key, 1),
        conversation_key: key,
        cwd: other_cwd,
        prompt: "/review lib/app.ex",
        meta: meta
      }

      :ok =
        SessionCoordinator.submit(
          key,
          submission(key, id, request.prompt, mode, run_supervisor, execution_request: request)
        )

      assert_receive {:run_cast, ^mode, ^id, ^expected, coordinator}
      acknowledgement = if mode == :redirect, do: :redirect_accepted, else: :steer_accepted
      send(coordinator, {acknowledgement, id})
      assert {:ok, ^active_id} = SessionCoordinator.active_run(key)
    end

    GenServer.stop(runtime_run)

    remote_key = {:session, unique_session_key()}
    remote_id = "command-remote-#{System.unique_integer([:positive])}"

    remote_request = %{
      active_request
      | run_id: remote_id,
        session_key: elem(remote_key, 1),
        conversation_key: remote_key,
        meta: %{"node" => "worker"}
    }

    :ok =
      SessionCoordinator.submit(
        remote_key,
        submission(remote_key, remote_id, "one", :collect, run_supervisor,
          execution_request: remote_request
        )
      )

    assert_receive {:started, ^remote_id, _}
    remote_runtime = start_runtime_run(remote_id)
    steer_id = "remote-steer-#{System.unique_integer([:positive])}"

    incoming = %{
      remote_request
      | run_id: steer_id,
        prompt: "/review lib/app.ex",
        meta: %{origin: :control_plane, node: "local"}
    }

    :ok =
      SessionCoordinator.submit(
        remote_key,
        submission(remote_key, steer_id, incoming.prompt, :steer, run_supervisor,
          execution_request: incoming
        )
      )

    assert_receive {:run_cast, :steer, ^steer_id, "/review lib/app.ex", _}
    GenServer.stop(remote_runtime)
  end

  test "accepted redirect clears the pending entry so it never re-runs", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}
    runtime_run = start_runtime_run("run1")

    :ok = submit(key, "run2", "two", :redirect, run_supervisor)
    assert_receive {:run_cast, :redirect, "run2", "two", coord_pid}

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
    assert_receive {:started, "run1", _}
    runtime_run = start_runtime_run("run1")

    :ok = submit(key, "run2", "two", :steer, run_supervisor)
    assert_receive {:run_cast, :steer, "run2", "two", coord_pid}

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
    assert_receive {:started, "run1", _}
    runtime_run = start_runtime_run("run1")

    :ok = submit(key, "run2", "two", :steer_backlog, run_supervisor)
    assert_receive {:run_cast, :steer_backlog, "run2", "two", coord_pid}

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
      assert_receive {:started, "run1", _}
      runtime_run = start_runtime_run("run1")

      :ok = submit(key, "run2", "two", :redirect, run_supervisor)
      assert_receive {:run_cast, :redirect, "run2", "two", coord_pid}

      send(coord_pid, {:redirect_rejected, "run2"})

      assert_receive {:notice_dispatched, %LemonCore.DeliveryIntent{} = intent}
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
      assert_receive {:started, "run2", opts}
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
      assert_receive {:started, "run1", _}

      with_stopped_run_registry(fn ->
        :ok = submit(key, "run2", "two", :steer, run_supervisor)
        refute_receive {:notice_dispatched, _}, 200

        :ok = submit(key, "run3", "three", :redirect, run_supervisor)

        assert_receive {:notice_dispatched, %LemonCore.DeliveryIntent{run_id: "run3"} = intent},
                       500

        assert intent.kind == :notice
      end)

      SessionCoordinator.cancel(elem(key, 1), :user_requested)
      assert_receive {:aborted, "run1", :user_requested}
    end)
  end

  test "rejected redirect on a non-channel session key dispatches no notice", %{
    run_supervisor: run_supervisor
  } do
    with_notice_dispatcher(fn ->
      key = {:session, unique_session_key()}

      :ok = submit(key, "run1", "one", :collect, run_supervisor)
      assert_receive {:started, "run1", _}
      runtime_run = start_runtime_run("run1")

      :ok = submit(key, "run2", "two", :redirect, run_supervisor)
      assert_receive {:run_cast, :redirect, "run2", "two", coord_pid}

      send(coord_pid, {:redirect_rejected, "run2"})
      refute_receive {:notice_dispatched, _}, 200

      # The coordinator survives and still applies the followup fallback.
      assert {:ok, "run1"} = SessionCoordinator.active_run(key)
      assert Process.alive?(coord_pid)

      stop_active_run(run_supervisor)
      assert_receive {:started, "run2", _}

      GenServer.stop(runtime_run)
    end)
  end

  test "receipts expose applied new and queued dispositions and replay without dispatch", %{
    run_supervisor: supervisor
  } do
    session_key = unique_session_key()
    key = {:session, session_key}
    active = receipt_run_id()
    queued = receipt_run_id()

    assert {:ok, receipt} = receipt_submit(key, active, "hold", :steer, supervisor)
    assert %{
             run_id: ^active,
             session_key: ^session_key,
             state: :accepted,
             effective_mode: :new_run,
             target_run_id: ^active
           } = receipt
    assert_receive {:started, ^active, _}

    assert :ok = submit(key, queued, "original", :collect, supervisor)
    assert {:ok, queued_receipt} = RunReceiptStore.fetch(queued)
    assert queued_receipt.effective_mode == :queued
    assert queued_receipt.target_run_id == queued

    assert {:ok, ^queued_receipt} =
             receipt_submit(key, queued, "must not replace original", :interrupt, supervisor)
    refute_receive {:aborted, ^active, _}, 50
    refute_receive {:started, ^queued, _}, 50

    :ok = abort_active_run(supervisor, :user_requested)
    assert_receive {:aborted, ^active, :user_requested}
    assert_receive {:started, ^queued, opts}
    assert opts[:execution_request].prompt == "original"
  end

  test "merged receipts follow the newest surviving queued ID transitively", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    first = receipt_run_id()
    second = receipt_run_id()
    survivor = receipt_run_id()

    assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
    assert_receive {:started, ^active, _}
    assert {:ok, %{effective_mode: :queued}} =
             receipt_submit(key, first, "first", :followup, supervisor)
    assert {:ok, %{effective_mode: :merged, target_run_id: ^second}} =
             receipt_submit(key, second, "second", :followup, supervisor)
    assert {:ok, %{effective_mode: :merged, target_run_id: ^survivor}} =
             receipt_submit(key, survivor, "third", :followup, supervisor)

    for id <- [first, second, survivor] do
      assert {:ok, %{run_id: ^id, effective_mode: :merged, target_run_id: ^survivor}} =
               RunReceiptStore.fetch(id)
    end

    assert {:ok, %{effective_mode: :merged, target_run_id: ^survivor}} =
             receipt_submit(key, first, "duplicate", :interrupt, supervisor)
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^survivor, opts}
    assert opts[:execution_request].prompt == "first\nsecond\nthird"
    refute_receive {:started, ^first, _}, 50
    refute_receive {:started, ^second, _}, 50

    # Durable replay does not even need the original coordinator to survive.
    GenServer.stop(coordinator_pid(key))
    assert {:ok, %{target_run_id: ^survivor}} =
             receipt_submit(key, first, "duplicate again", :collect, supervisor)
    refute_receive {:started, ^first, _}, 50
  end

  test "steering receipts stay pending until invocation acknowledgement and retain its target", %{
    run_supervisor: supervisor
  } do
    for {mode, pending, accepted} <- [
          {:steer, :steer_pending, :steer_accepted},
          {:steer_backlog, :steer_backlog_pending, :steer_backlog_accepted},
          {:redirect, :redirect_pending, :redirect_accepted}
        ] do
      key = {:session, unique_session_key()}
      active = receipt_run_id()
      steering = receipt_run_id()
      next = receipt_run_id()
      assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
      assert_receive {:started, ^active, _}
      runtime_run = start_runtime_run(active)

      assert {:ok, %{effective_mode: ^pending, target_run_id: ^active}} =
               receipt_submit(key, steering, "correction", mode, supervisor)
      assert_receive {:run_cast, ^mode, ^steering, "correction", owner}
      assert {:ok, %{effective_mode: ^pending, target_run_id: ^active}} =
               RunReceiptStore.fetch(steering)

      send(owner, {accepted, steering})
      assert {:ok, ^active} = SessionCoordinator.active_run(key)
      assert {:ok, %{effective_mode: ^mode, target_run_id: ^active}} =
               RunReceiptStore.fetch(steering)

      assert {:ok, _} = receipt_submit(key, next, "next", :collect, supervisor)
      :ok = stop_active_run(supervisor)
      assert_receive {:started, ^next, _}
      assert {:ok, ^next} = SessionCoordinator.active_run(key)
      assert {:ok, %{effective_mode: ^mode, target_run_id: ^active}} =
               receipt_submit(key, steering, "duplicate", mode, supervisor)
      refute_receive {:run_cast, ^mode, ^steering, _, _}, 50
      refute_receive {:started, ^steering, _}, 50
      GenServer.stop(runtime_run)
      :ok = stop_active_run(supervisor)
      assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
    end
  end

  test "rejected steering records queued fallback instead of accepted steering", %{
    run_supervisor: supervisor
  } do
    for {mode, rejected, fallback} <- [
          {:steer, :steer_rejected, :followup},
          {:steer_backlog, :steer_backlog_rejected, :collect},
          {:redirect, :redirect_rejected, :followup}
        ] do
      key = {:session, unique_session_key()}
      active = receipt_run_id()
      steering = receipt_run_id()
      assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
      assert_receive {:started, ^active, _}
      runtime_run = start_runtime_run(active)
      assert {:ok, _} = receipt_submit(key, steering, "correction", mode, supervisor)
      assert_receive {:run_cast, ^mode, ^steering, _, owner}

      send(owner, {rejected, steering})
      assert {:ok, ^active} = SessionCoordinator.active_run(key)
      assert {:ok, %{effective_mode: :queued, target_run_id: ^steering}} =
               RunReceiptStore.fetch(steering)
      :ok = stop_active_run(supervisor)
      assert_receive {:started, ^steering, opts}
      assert opts[:queue_mode] == fallback
      GenServer.stop(runtime_run)
      :ok = stop_active_run(supervisor)
      assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
    end
  end

  test "rejected and active-down steering fallbacks update merged follower receipts", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    queued = receipt_run_id()
    rejected = receipt_run_id()
    fallen_back = receipt_run_id()
    assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
    assert_receive {:started, ^active, _}
    runtime_run = start_runtime_run(active)
    assert {:ok, _} = receipt_submit(key, queued, "queued", :followup, supervisor)
    assert {:ok, _} = receipt_submit(key, rejected, "rejected", :steer, supervisor)
    assert_receive {:run_cast, :steer, ^rejected, _, owner}
    send(owner, {:steer_rejected, rejected})
    assert {:ok, ^active} = SessionCoordinator.active_run(key)
    assert {:ok, %{effective_mode: :merged, target_run_id: ^rejected}} =
             RunReceiptStore.fetch(queued)

    assert {:ok, %{effective_mode: :steer_pending, target_run_id: ^active}} =
             receipt_submit(key, fallen_back, "down", :steer, supervisor)
    assert_receive {:run_cast, :steer, ^fallen_back, _, ^owner}
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^fallen_back, opts}
    assert {:ok, ^fallen_back} = SessionCoordinator.active_run(key)
    assert opts[:execution_request].prompt == "queued\nrejected\ndown"

    for id <- [queued, rejected, fallen_back] do
      assert {:ok, %{effective_mode: :merged, target_run_id: ^fallen_back}} =
               RunReceiptStore.fetch(id)
    end

    # A late acknowledgement from the dead invocation cannot relabel its fallback.
    send(owner, {:steer_accepted, fallen_back})
    assert {:ok, ^fallen_back} = SessionCoordinator.active_run(key)
    assert {:ok, %{effective_mode: :merged, target_run_id: ^fallen_back}} =
             RunReceiptStore.fetch(fallen_back)
    GenServer.stop(runtime_run)
  end

  test "active-down steering with no backlog becomes its own new run", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    steering = receipt_run_id()
    assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
    assert_receive {:started, ^active, _}
    runtime_run = start_runtime_run(active)
    assert {:ok, %{effective_mode: :redirect_pending, target_run_id: ^active}} =
             receipt_submit(key, steering, "correction", :redirect, supervisor)
    assert_receive {:run_cast, :redirect, ^steering, _, _owner}
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^steering, _}
    assert {:ok, ^steering} = SessionCoordinator.active_run(key)
    assert {:ok, %{effective_mode: :new_run, target_run_id: ^steering}} =
             RunReceiptStore.fetch(steering)
    GenServer.stop(runtime_run)
  end

  test "image steering falls back before dispatch and keeps its own queued identity", %{
    run_supervisor: supervisor
  } do
    for mode <- [:steer, :steer_backlog, :redirect] do
      key = {:session, unique_session_key()}
      active = receipt_run_id()
      image_run = receipt_run_id()
      assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
      assert_receive {:started, ^active, _}
      runtime_run = start_runtime_run(active)
      original = submission(key, image_run, "look", mode, supervisor)
      images = [%{data: "image bytes", mime_type: "image/png"}]
      image_submission = %{original | execution_request: %{original.execution_request | images: images}}

      assert {:ok, %{effective_mode: :queued, target_run_id: ^image_run}} =
               SessionCoordinator.submit_with_receipt(key, image_submission)
      refute_receive {:run_cast, ^mode, ^image_run, _, _}, 50
      :ok = stop_active_run(supervisor)
      assert_receive {:started, ^image_run, opts}
      assert opts[:execution_request].images == images
      GenServer.stop(runtime_run)
      :ok = stop_active_run(supervisor)
      assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
    end
  end

  test "interrupt receipts bind the interrupted invocation while idle interrupt starts a run", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    queued = receipt_run_id()
    urgent = receipt_run_id()
    assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
    assert_receive {:started, ^active, _}
    assert {:ok, _} = receipt_submit(key, queued, "waiting", :collect, supervisor)

    assert {:ok, %{effective_mode: :interrupt, target_run_id: ^active}} =
             receipt_submit(key, urgent, "urgent", :interrupt, supervisor)
    assert_receive {:aborted, ^active, :interrupted}
    assert_receive {:started, ^urgent, _}
    assert {:ok, ^urgent} = SessionCoordinator.active_run(key)
    assert {:ok, %{effective_mode: :interrupt, target_run_id: ^active}} =
             receipt_submit(key, urgent, "duplicate", :interrupt, supervisor)
    refute_receive {:aborted, ^urgent, _}, 50

    idle_key = {:session, unique_session_key()}
    idle = receipt_run_id()
    assert {:ok, %{effective_mode: :new_run, target_run_id: ^idle}} =
             receipt_submit(idle_key, idle, "idle urgent", :interrupt, supervisor)
    assert_receive {:started, ^idle, _}
  end

  test "initial receipt write failure reports unknown without dispatching a replay", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store(refuse_initial: true)
    key = {:session, unique_session_key()}
    run_id = receipt_run_id()
    prepared = submission(key, run_id, "accepted but unrecorded", :collect, supervisor)

    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    assert_receive {:started, ^run_id, _}
    assert {:ok, nil} = RunReceiptStore.fetch(store, run_id)
    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    refute_receive {:started, ^run_id, _}, 50
  end

  test "failed asynchronous receipt update cannot advertise accepted steering", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store([])
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    steering = receipt_run_id()
    prepared = submission(key, active, "hold", :collect, supervisor)
    assert {:ok, _} = SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    assert_receive {:started, ^active, _}
    runtime_run = start_runtime_run(active)
    correction = submission(key, steering, "correction", :steer, supervisor)
    assert {:ok, %{effective_mode: :steer_pending}} =
             SessionCoordinator.submit_with_receipt(key, correction, receipt_store: store)
    assert_receive {:run_cast, :steer, ^steering, _, owner}

    ExUnit.CaptureLog.capture_log(fn ->
      send(owner, {:steer_accepted, steering})
      assert {:ok, ^active} = SessionCoordinator.active_run(key)
    end)
    assert {:ok, %{effective_mode: :steer_pending, target_run_id: ^active}} =
             RunReceiptStore.fetch(store, steering)
    GenServer.stop(runtime_run)
  end

  test "private request identity survives receipt updates and conflicting replay never dispatches", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    queued = receipt_run_id()
    merged = receipt_run_id()
    identity = String.duplicate("d", 64)
    assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
    assert_receive {:started, ^active, _}
    prepared = submission(key, queued, "first", :followup, supervisor,
      meta: %{router_request_identity: identity})
    assert {:ok, %{request_identity: ^identity}} =
             SessionCoordinator.submit_with_receipt(key, prepared)
    assert {:ok, _} = receipt_submit(key, merged, "second", :followup, supervisor)
    assert {:ok, %{effective_mode: :merged, target_run_id: ^merged, request_identity: ^identity}} =
             SessionCoordinator.submit_with_receipt(key, prepared)

    changed = %{prepared | meta: %{router_request_identity: String.duplicate("e", 64)}}
    assert {:error, :run_id_conflict} = SessionCoordinator.submit_with_receipt(key, changed)
    refute_receive {:started, ^queued, _}, 50
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^merged, opts}
    assert opts[:execution_request].prompt == "first\nsecond"
  end

  test "missing private identity cannot prove a newly identity-bearing replay", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    run_id = receipt_run_id()
    prepared = submission(key, run_id, "original", :collect, supervisor)
    assert {:ok, _} = SessionCoordinator.submit_with_receipt(key, prepared)
    assert_receive {:started, ^run_id, _}
    request = %{prepared.execution_request |
      meta: %{router_request_identity: String.duplicate("f", 64)}}
    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(key, %{prepared | execution_request: request})
    refute_receive {:started, ^run_id, _}, 50
  end

  test "automatic async followups report promoted steering rather than requested followup", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    followup = receipt_run_id()
    assert {:ok, _} = receipt_submit(key, active, "hold", :collect, supervisor)
    assert_receive {:started, ^active, _}
    runtime_run = start_runtime_run(active)
    prepared = submission(key, followup, "task completion", :followup, supervisor,
      meta: %{task_auto_followup: true, task_id: "task"})
    assert {:ok, %{effective_mode: :steer_pending, target_run_id: ^active}} =
             SessionCoordinator.submit_with_receipt(key, prepared)
    assert_receive {:run_cast, :steer, ^followup, _, owner}
    send(owner, {:steer_accepted, followup})
    assert {:ok, ^active} = SessionCoordinator.active_run(key)
    assert {:ok, %{effective_mode: :steer, target_run_id: ^active}} =
             RunReceiptStore.fetch(followup)
    GenServer.stop(runtime_run)
  end

  test "a failed pre-merge uncertainty fence leaves the queue unmerged", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store([])
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    first = receipt_run_id()
    second = receipt_run_id()
    for {id, prompt, mode} <- [{active, "hold", :collect}, {first, "first", :followup}] do
      assert {:ok, _} = SessionCoordinator.submit_with_receipt(
        key, submission(key, id, prompt, mode, supervisor), receipt_store: store)
    end
    assert_receive {:started, ^active, _}

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :outcome_unknown} = SessionCoordinator.submit_with_receipt(
        key, submission(key, second, "second", :followup, supervisor), receipt_store: store)
    end)
    assert {:ok, %{state: :accepted, effective_mode: :queued, target_run_id: ^first}} =
             RunReceiptStore.fetch(store, first)
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^first, opts}
    assert opts[:execution_request].prompt == "first"
    refute_receive {:started, ^second, _}, 50
  end

  test "post-merge receipt failure leaves durable uncertainty instead of stale targets", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store(allow_fence: true)
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    first = receipt_run_id()
    second = receipt_run_id()
    for {id, prompt, mode} <- [{active, "hold", :collect}, {first, "first", :followup}] do
      assert {:ok, _} = SessionCoordinator.submit_with_receipt(
        key, submission(key, id, prompt, mode, supervisor), receipt_store: store)
    end
    assert_receive {:started, ^active, _}
    prepared = submission(key, second, "second", :followup, supervisor)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :outcome_unknown} =
               SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    end)
    for id <- [first, second] do
      assert {:ok, %{state: :outcome_unknown, effective_mode: nil, target_run_id: nil}} =
               RunReceiptStore.fetch(store, id)
    end
    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^second, opts}
    assert opts[:execution_request].prompt == "first\nsecond"
    refute_receive {:started, ^first, _}, 50
  end

  test "concurrent fixed-ID admission returns the same receipt and starts only once", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    run_id = receipt_run_id()
    prepared = submission(key, run_id, "one invocation", :collect, supervisor)
    results =
      1..8
      |> Task.async_stream(fn _ -> SessionCoordinator.submit_with_receipt(key, prepared) end,
        max_concurrency: 8, timeout: 15_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, receipt}] = Enum.uniq(results)
    assert receipt.effective_mode == :new_run
    assert receipt.target_run_id == run_id
    assert_receive {:started, ^run_id, _}
    refute_receive {:started, ^run_id, _}, 50
  end

  test "unavailable receipt read rejects before coordinator dispatch", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store([])
    stop_supervised!(LemonCore.Store)
    key = {:session, unique_session_key()}
    run_id = receipt_run_id()
    prepared = submission(key, run_id, "must not dispatch", :collect, supervisor)
    assert {:error, :store_unavailable} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    assert Registry.lookup(LemonRouter.ConversationRegistry, key) == []
    refute_receive {:started, ^run_id, _}, 50
  end

  test "failed active-down merge fence releases the owner through supervision", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store([])
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    queued = receipt_run_id()
    steering = receipt_run_id()
    for {id, prompt, mode} <- [{active, "hold", :collect}, {queued, "queued", :followup}] do
      assert {:ok, _} = SessionCoordinator.submit_with_receipt(
        key, submission(key, id, prompt, mode, supervisor), receipt_store: store)
    end
    assert_receive {:started, ^active, _}
    runtime_run = start_runtime_run(active)
    prepared = submission(key, steering, "pending", :steer, supervisor)
    assert {:ok, %{effective_mode: :steer_pending}} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    assert_receive {:run_cast, :steer, ^steering, _, owner}
    monitor = Process.monitor(owner)

    ExUnit.CaptureLog.capture_log(fn ->
      :ok = abort_active_run(supervisor, :user_requested)
      assert_receive {:aborted, ^active, :user_requested}
      assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}
    end)

    assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
    assert {:ok, %{effective_mode: :steer_pending, target_run_id: ^active}} =
             RunReceiptStore.fetch(store, steering)
    refute_receive {:started, ^steering, _}, 50
    GenServer.stop(runtime_run)
  end

  test "receipt barriers reject visible initial, CAS and uncertainty rows until sync succeeds" do
    store = start_receipt_store(allow_updates: true, sync_failure: true)
    run_id = receipt_run_id()
    receipt = %{
      run_id: run_id,
      session_key: unique_session_key(),
      state: :accepted,
      effective_mode: :queued,
      target_run_id: run_id
    }
    barrier_error = {:error, {:sync_failed, :sync_refused}}

    assert ^barrier_error = RunReceiptStore.put(store, receipt)
    assert {:ok, ^receipt} = LemonCore.Store.fetch(store, :run_receipts, run_id)
    assert ^barrier_error = RunReceiptStore.fetch(store, run_id)
    assert ^barrier_error = RunReceiptStore.put(store, receipt)

    assert :ok = LemonCore.Store.put(store, :receipt_backend_failures, :sync, false)
    assert {:ok, ^receipt} = RunReceiptStore.fetch(store, run_id)
    assert :ok = RunReceiptStore.put(store, receipt)

    changes = %{effective_mode: :merged, target_run_id: "survivor"}
    assert :ok = LemonCore.Store.put(store, :receipt_backend_failures, :sync, changes)
    assert ^barrier_error = RunReceiptStore.update(store, run_id, changes)
    updated = Map.merge(receipt, changes)
    assert {:ok, ^updated} = LemonCore.Store.fetch(store, :run_receipts, run_id)
    assert ^barrier_error = RunReceiptStore.fetch(store, run_id)
    assert ^barrier_error = RunReceiptStore.update(store, run_id, changes)

    assert :ok = LemonCore.Store.put(store, :receipt_backend_failures, :sync, false)
    assert :ok = RunReceiptStore.update(store, run_id, changes)
    assert {:ok, ^updated} = RunReceiptStore.fetch(store, run_id)

    assert :ok = LemonCore.Store.put(
      store, :receipt_backend_failures, :sync, %{state: :outcome_unknown})
    assert ^barrier_error = RunReceiptStore.mark_unknown(store, run_id)
    unknown = %{updated | state: :outcome_unknown, effective_mode: nil, target_run_id: nil}
    assert {:ok, ^unknown} = LemonCore.Store.fetch(store, :run_receipts, run_id)
    assert ^barrier_error = RunReceiptStore.fetch(store, run_id)
    assert ^barrier_error = RunReceiptStore.mark_unknown(store, run_id)

    assert :ok = LemonCore.Store.put(store, :receipt_backend_failures, :sync, false)
    assert :ok = RunReceiptStore.mark_unknown(store, run_id)
    assert {:ok, ^unknown} = RunReceiptStore.fetch(store, run_id)
    assert :ok = RunReceiptStore.update(store, run_id, changes)
    assert {:ok, ^updated} = RunReceiptStore.fetch(store, run_id)
  end

  test "failed initial and replay barriers preserve the fixed ID without dispatching again", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store(sync_failure: true)
    key = {:session, unique_session_key()}
    run_id = receipt_run_id()
    prepared = submission(key, run_id, "accepted but unsynced", :collect, supervisor)

    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    assert_receive {:started, ^run_id, _}
    assert {:ok, %{run_id: ^run_id, state: :accepted} = receipt} =
             LemonCore.Store.fetch(store, :run_receipts, run_id)
    assert {:error, {:sync_failed, :sync_refused}} = RunReceiptStore.fetch(store, run_id)
    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    [{owner, _}] = Registry.lookup(LemonRouter.ConversationRegistry, key)
    assert {:error, :outcome_unknown} =
             GenServer.call(owner, {:submit_with_receipt, prepared})
    refute_receive {:started, ^run_id, _}, 50

    assert :ok = LemonCore.Store.put(store, :receipt_backend_failures, :sync, false)
    assert {:ok, ^receipt} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    assert {:ok, ^receipt} = GenServer.call(owner, {:submit_with_receipt, prepared})
    refute_receive {:started, ^run_id, _}, 50

    assert :ok = LemonCore.Store.put(store, :receipt_backend_failures, :sync, true)
    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(
               key, %{prepared | queue_mode: :interrupt}, receipt_store: store)
    assert {:ok, ^run_id} = SessionCoordinator.active_run(key)
    refute_receive {:aborted, ^run_id, _}, 50
    refute_receive {:started, ^run_id, _}, 50
  end

  test "failed pre-merge sync preserves the original input without merge or second dispatch", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store(allow_updates: true)
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    first = receipt_run_id()
    second = receipt_run_id()
    for {id, prompt, mode} <- [{active, "hold", :collect}, {first, "first", :followup}] do
      assert {:ok, _} = SessionCoordinator.submit_with_receipt(
        key, submission(key, id, prompt, mode, supervisor), receipt_store: store)
    end
    assert_receive {:started, ^active, _}
    assert :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(first))
    assert :ok = LemonCore.Store.put(
      store, :receipt_backend_failures, :sync, %{run_id: first, state: :outcome_unknown})
    prepared = submission(key, second, "second", :followup, supervisor)

    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(key, prepared, receipt_store: store)
    assert {:ok, %{run_id: ^first, state: :outcome_unknown}} =
             LemonCore.Store.fetch(store, :run_receipts, first)
    assert {:ok, nil} = LemonCore.Store.fetch(store, :run_receipts, second)
    refute_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^first}}, 50
    refute_receive {:bridge_unsubscribed, ^first}, 50
    refute_receive {:started, ^second, _}, 50

    assert :ok = LemonCore.Store.put(store, :receipt_backend_failures, :sync, false)
    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(
               key, submission(key, first, "first", :followup, supervisor), receipt_store: store)
    assert :ok = stop_active_run(supervisor)
    assert_receive {:started, ^first, opts}
    assert opts[:execution_request].prompt == "first"
    assert :ok = SessionCoordinator.cancel(key)
    assert_receive {:aborted, ^first, :user_requested}
    assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
    refute_receive {:started, ^second, _}, 50
  end

  test "failed steering update sync cannot become definite through visible-row replay", %{
    run_supervisor: supervisor
  } do
    store = start_receipt_store(allow_updates: true)
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    steering = receipt_run_id()
    assert {:ok, _} = SessionCoordinator.submit_with_receipt(
      key, submission(key, active, "hold", :collect, supervisor), receipt_store: store)
    assert_receive {:started, ^active, _}
    runtime_run = start_runtime_run(active)
    correction = submission(key, steering, "correction", :steer, supervisor)
    assert {:ok, %{effective_mode: :steer_pending}} =
             SessionCoordinator.submit_with_receipt(key, correction, receipt_store: store)
    assert_receive {:run_cast, :steer, ^steering, _, owner}
    assert :ok = LemonCore.Store.put(
      store, :receipt_backend_failures, :sync, %{run_id: steering, effective_mode: :steer})

    ExUnit.CaptureLog.capture_log(fn ->
      send(owner, {:steer_accepted, steering})
      assert {:ok, ^active} = SessionCoordinator.active_run(key)
    end)
    assert {:ok, %{effective_mode: :steer, target_run_id: ^active}} =
             LemonCore.Store.fetch(store, :run_receipts, steering)
    assert {:error, {:sync_failed, :sync_refused}} = RunReceiptStore.fetch(store, steering)
    assert {:error, :outcome_unknown} =
             SessionCoordinator.submit_with_receipt(key, correction, receipt_store: store)
    refute_receive {:run_cast, :steer, ^steering, _, _}, 50
    refute_receive {:started, ^steering, _}, 50

    assert :ok = LemonCore.Store.put(store, :receipt_backend_failures, :sync, false)
    assert {:ok, %{effective_mode: :steer, target_run_id: ^active}} =
             SessionCoordinator.submit_with_receipt(key, correction, receipt_store: store)
    refute_receive {:run_cast, :steer, ^steering, _, _}, 50
    GenServer.stop(runtime_run)
  end

  test "different contexts queue own receipts and preserve each sequential execution's capabilities", %{
    run_supervisor: supervisor
  } do
    contexts = [
      {%{invocation_context_key: "principal-a"}, %{invocation_context_key: "principal-b"}, %{}, %{}},
      {%{invocation_context_key: "principal-a"},
       %{invocation_context_key: "principal-b", task_auto_followup: true}, %{}, %{}},
      {%{invocation_context_key: "principal-a"},
       %{invocation_context_key: "principal-b", delegated_auto_followup: true}, %{}, %{}},
      {%{}, %{invocation_context_key: "principal-b"}, %{}, %{}},
      {%{invocation_context_key: "principal-a"}, %{}, %{}, %{}},
      {%{invocation_context_key: "same", memory_context_key: "private-room"},
       %{invocation_context_key: "same", memory_context_key: "shared-room"}, %{}, %{}},
      {%{memory_context_key: "private-room"}, %{}, %{}, %{}},
      {%{invocation_context_key: "same", memory_context_key: "room", memory_context_verified: true},
       %{invocation_context_key: "same", memory_context_key: "room"}, %{}, %{}},
      {%{invocation_context_key: "same", memory_context_key: "room", shared_memory_grant: true},
       %{invocation_context_key: "same", memory_context_key: "room", shared_memory_grant: false}, %{}, %{}},
      {%{invocation_context_key: "same"}, %{invocation_context_key: "same"},
       %{deny: ["bash"]}, %{deny: ["read"]}},
      {%{}, %{}, %{deny: ["bash"]}, %{deny: ["read"]}},
      {%{mcp_servers: [%{url: "https://mcp.invalid", secret_ref: "grant-a"}]},
       %{mcp_servers: []}, %{}, %{}},
      {%{}, %{mcp_servers: []}, %{}, %{}}
    ]

    for {active_meta, incoming_meta, active_policy, incoming_policy} <- contexts,
        mode <- [:followup, :steer, :steer_backlog, :redirect, :interrupt] do
      key = {:session, unique_session_key()}
      active = receipt_run_id()
      first = receipt_run_id()
      second = receipt_run_id()
      holding = context_submission(key, active, "hold", :collect, supervisor, active_meta, active_policy)
      own_first = context_submission(key, first, "first own prompt", mode, supervisor, incoming_meta, incoming_policy)
      own_second = context_submission(key, second, "second own prompt", mode, supervisor, incoming_meta, incoming_policy)

      assert {:ok, %{effective_mode: :new_run, target_run_id: ^active}} =
               SessionCoordinator.submit_with_receipt(key, holding)
      assert_receive {:started, ^active, active_opts}
      assert active_opts[:execution_request].tool_policy == active_policy
      runtime_run = start_runtime_run(active)

      for own <- [own_first, own_second] do
        id = own.run_id
        assert {:ok, %{effective_mode: :queued, target_run_id: ^id}} =
                 SessionCoordinator.submit_with_receipt(key, own)
        assert {:ok, %{effective_mode: :queued, target_run_id: ^id}} =
                 RunReceiptStore.fetch(id)
      end

      # Calls serialize behind any control casts before checking their absence.
      _ = :sys.get_state(runtime_run)
      assert {:ok, ^active} = SessionCoordinator.active_run(key)
      refute_receive {:run_cast, _, _, _, _}, 0
      refute_receive {:aborted, ^active, _}, 0

      :ok = stop_active_run(supervisor)
      assert_receive {:started, ^first, first_opts}
      assert first_opts[:execution_request].run_id == first
      assert first_opts[:execution_request].prompt == "first own prompt"
      assert first_opts[:execution_request].tool_policy == incoming_policy
      assert Map.take(first_opts[:execution_request].meta, [:invocation_context_key, :mcp_servers]) ==
               Map.take(incoming_meta, [:invocation_context_key, :mcp_servers])
      assert {:ok, ^first} = SessionCoordinator.active_run(key)
      refute_receive {:started, ^second, _}, 0

      :ok = stop_active_run(supervisor)
      assert_receive {:started, ^second, second_opts}
      assert second_opts[:execution_request].run_id == second
      assert second_opts[:execution_request].prompt == "second own prompt"
      assert second_opts[:execution_request].tool_policy == incoming_policy
      assert Map.take(second_opts[:execution_request].meta, [:invocation_context_key, :mcp_servers]) ==
               Map.take(incoming_meta, [:invocation_context_key, :mcp_servers])
      assert {:ok, ^second} = SessionCoordinator.active_run(key)
      :ok = stop_active_run(supervisor)
      assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
      GenServer.stop(runtime_run)
    end
  end

  test "matching private contexts still steer backlog redirect and interrupt the owner", %{
    run_supervisor: supervisor
  } do
    meta = %{invocation_context_key: "same", mcp_servers: []}
    policy = %{deny: ["bash"]}

    for {mode, pending, accepted} <- [
          {:steer, :steer_pending, :steer_accepted},
          {:steer_backlog, :steer_backlog_pending, :steer_backlog_accepted},
          {:redirect, :redirect_pending, :redirect_accepted}
        ] do
      key = {:session, unique_session_key()}
      active = receipt_run_id()
      control = receipt_run_id()
      holding = context_submission(key, active, "hold", :collect, supervisor, meta, policy)
      correction = context_submission(key, control, "correction", mode, supervisor, meta, policy)
      assert {:ok, _} = SessionCoordinator.submit_with_receipt(key, holding)
      assert_receive {:started, ^active, _}
      runtime_run = start_runtime_run(active)
      assert {:ok, %{effective_mode: ^pending, target_run_id: ^active}} =
               SessionCoordinator.submit_with_receipt(key, correction)
      assert_receive {:run_cast, ^mode, ^control, "correction", owner}
      send(owner, {accepted, control})
      assert {:ok, ^active} = SessionCoordinator.active_run(key)
      assert {:ok, %{effective_mode: ^mode, target_run_id: ^active}} =
               RunReceiptStore.fetch(control)
      :ok = stop_active_run(supervisor)
      assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
      refute_receive {:started, ^control, _}, 0
      GenServer.stop(runtime_run)
    end

    key = {:session, unique_session_key()}
    active = receipt_run_id()
    urgent = receipt_run_id()
    assert {:ok, _} = SessionCoordinator.submit_with_receipt(
      key, context_submission(key, active, "hold", :collect, supervisor, meta, policy))
    assert_receive {:started, ^active, _}
    assert {:ok, %{effective_mode: :interrupt, target_run_id: ^active}} =
             SessionCoordinator.submit_with_receipt(
               key, context_submission(key, urgent, "urgent", :interrupt, supervisor, meta, policy))
    assert_receive {:aborted, ^active, :interrupted}
    assert_receive {:started, ^urgent, opts}
    assert opts[:execution_request].prompt == "urgent"
    assert opts[:execution_request].tool_policy == policy
  end

  test "matching keyed followups still merge and run the complete prompt under their policy", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    active = receipt_run_id()
    first = receipt_run_id()
    second = receipt_run_id()
    meta = %{invocation_context_key: "same", mcp_servers: []}
    policy = %{deny: ["bash"]}
    assert {:ok, _} = SessionCoordinator.submit_with_receipt(
      key, context_submission(key, active, "hold", :collect, supervisor, meta, policy))
    assert_receive {:started, ^active, _}
    assert {:ok, %{effective_mode: :queued, target_run_id: ^first}} =
             SessionCoordinator.submit_with_receipt(
               key, context_submission(key, first, "first", :followup, supervisor, meta, policy))
    assert {:ok, %{effective_mode: :merged, target_run_id: ^second}} =
             SessionCoordinator.submit_with_receipt(
               key, context_submission(key, second, "second", :followup, supervisor, meta, policy))
    assert {:ok, %{effective_mode: :merged, target_run_id: ^second}} = RunReceiptStore.fetch(first)
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^second, opts}
    assert opts[:execution_request].prompt == "first\nsecond"
    assert opts[:execution_request].tool_policy == policy
    assert opts[:execution_request].meta.invocation_context_key == "same"
    refute_receive {:started, ^first, _}, 0
  end

  test "recovered active execution without submission cannot receive a keyed control", %{
    run_supervisor: supervisor
  } do
    for mode <- [:followup, :steer, :steer_backlog, :redirect, :interrupt] do
      session_key = unique_session_key()
      key = {:session, session_key}
      active = receipt_run_id()
      own = receipt_run_id()
      survivor =
        start_supervised!(
          {SessionCoordinatorForwardingRunStub,
           run_id: active, session_key: session_key, test_pid: self()},
          id: {:recovered_context, active}
        )
      input = context_submission(key, own, "own prompt", mode, supervisor,
        %{invocation_context_key: "new"}, %{deny: ["bash"]})

      assert {:ok, %{effective_mode: :queued, target_run_id: ^own}} =
               SessionCoordinator.submit_with_receipt(key, input)
      assert {:ok, ^active} = SessionCoordinator.active_run(key)
      _ = :sys.get_state(survivor)
      refute_receive {:run_cast, _, _, _, _}, 0
      assert Process.alive?(survivor)
      GenServer.stop(survivor)
      assert_receive {:started, ^own, opts}
      assert opts[:execution_request].prompt == "own prompt"
      assert opts[:execution_request].tool_policy == %{deny: ["bash"]}
      :ok = stop_active_run(supervisor)
      assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
    end
  end

  test "context handoff starts a new journal without deleting the prior owner's resume", %{
    run_supervisor: supervisor
  } do
    session_key = unique_session_key()
    key = {:session, session_key}
    active = receipt_run_id()
    own = receipt_run_id()
    token = "shared-transcript-#{System.unique_integer([:positive])}"
    holding = context_submission(key, active, "hold", :collect, supervisor,
      %{invocation_context_key: "old", memory_context_key: "private-room"}, %{deny: ["read"]})
    assert :ok = LemonRouter.ResumeResolver.bind(
      %LemonCore.ResumeToken{engine: "lemon", value: token}, holding.execution_request)
    assert :ok = LemonCore.ChatStateStore.put(session_key, %{
      last_engine: "lemon", last_resume_token: token
    })
    on_exit(fn -> LemonCore.ChatStateStore.delete(session_key) end)

    assert {:ok, _} = SessionCoordinator.submit_with_receipt(key, holding)
    assert_receive {:started, ^active, active_opts}
    assert active_opts[:execution_request].resume ==
             %LemonCore.ResumeToken{engine: "lemon", value: token}
    assert {:ok, %{effective_mode: :queued, target_run_id: ^own}} =
             SessionCoordinator.submit_with_receipt(
               key, context_submission(key, own, "new principal prompt", :interrupt, supervisor,
                 %{invocation_context_key: "new", memory_context_key: "shared-room", mcp_servers: []},
                 %{deny: ["bash"]}))
    assert {:ok, ^active} = SessionCoordinator.active_run(key)
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^own, own_opts}
    assert own_opts[:execution_request].run_id != active_opts[:execution_request].run_id
    assert own_opts[:execution_request].prompt == "new principal prompt"
    assert own_opts[:execution_request].tool_policy == %{deny: ["bash"]}
    assert own_opts[:execution_request].meta.mcp_servers == []
    assert own_opts[:execution_request].resume == nil
    assert LemonCore.ChatStateStore.get(session_key).last_resume_token == token
    refute_receive {:aborted, ^active, _}, 0
  end

  test "durable same-context resume survives coordinator restart but changed capabilities start fresh", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    session_key = elem(key, 1)
    meta = %{invocation_context_key: "same", memory_context_key: "same-room", mcp_servers: []}
    policy = %{blocked_tools: ["bash"]}
    token = %LemonCore.ResumeToken{engine: "lemon", value: session_key}
    first = context_submission(key, receipt_run_id(), "first", :collect, supervisor, meta, policy)
    assert :ok = LemonRouter.ResumeResolver.bind(token, first.execution_request)
    assert :ok = LemonCore.ChatStateStore.put(session_key, %{
      last_engine: "lemon", last_resume_token: token.value
    })
    on_exit(fn -> LemonCore.ChatStateStore.delete(session_key) end)

    assert {:ok, _} = SessionCoordinator.submit_with_receipt(key, first)
    first_id = first.run_id
    assert_receive {:started, ^first_id, first_opts}
    assert first_opts[:execution_request].resume == token
    :ok = stop_active_run(supervisor)
    assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
    # Remove the permanent child without consuming the linked supervisor's restart intensity.
    :ok = DynamicSupervisor.terminate_child(LemonRouter.SessionCoordinatorSupervisor, coordinator_pid(key))

    second = context_submission(key, receipt_run_id(), "second", :collect, supervisor, meta, policy)
    second_id = second.run_id
    assert {:ok, _} = SessionCoordinator.submit_with_receipt(key, second)
    assert_receive {:started, ^second_id, second_opts}
    assert second_opts[:execution_request].resume == token
    :ok = stop_active_run(supervisor)
    assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
    :ok = DynamicSupervisor.terminate_child(LemonRouter.SessionCoordinatorSupervisor, coordinator_pid(key))

    for changed <- [
          %{meta | invocation_context_key: "changed"},
          %{meta | memory_context_key: "other-room"},
          Map.delete(meta, :mcp_servers)
        ] do
      input = context_submission(key, receipt_run_id(), "fresh", :collect, supervisor, changed, policy)
      id = input.run_id
      assert {:ok, _} = SessionCoordinator.submit_with_receipt(key, input)
      assert_receive {:started, ^id, opts}
      assert opts[:execution_request].resume == nil
      assert opts[:execution_request].prompt == "fresh"
      assert LemonCore.ChatStateStore.get(session_key).last_resume_token == token.value
      :ok = stop_active_run(supervisor)
      assert eventually(fn -> SessionCoordinator.active_run(key) == :none end)
      :ok = DynamicSupervisor.terminate_child(LemonRouter.SessionCoordinatorSupervisor, coordinator_pid(key))
    end
  end

  test "attested rotating proofs retain steering and resume without replacing raw execution headers", %{
    run_supervisor: supervisor
  } do
    key = {:session, unique_session_key()}
    session_key = elem(key, 1)
    active = receipt_run_id()
    steering = receipt_run_id()
    queued = receipt_run_id()
    unattested = receipt_run_id()
    policy = %{blocked_tools: ["bash"]}
    active_meta = proof_meta(active)
    steering_meta = proof_meta(steering)
    queued_meta = proof_meta(queued)
    unattested_meta = Map.delete(proof_meta(unattested), :invocation_proof_verified)
    holding = context_submission(key, active, "hold", :collect, supervisor, active_meta, policy)
    token = %LemonCore.ResumeToken{engine: "lemon", value: session_key}
    assert :ok = LemonRouter.ResumeResolver.bind(token, holding.execution_request)
    assert :ok = LemonCore.ChatStateStore.put(session_key, %{
      last_engine: "lemon", last_resume_token: token.value
    })
    on_exit(fn -> LemonCore.ChatStateStore.delete(session_key) end)

    assert {:ok, _} = SessionCoordinator.submit_with_receipt(key, holding)
    assert_receive {:started, ^active, active_opts}
    assert active_opts[:execution_request].meta.mcp_servers == active_meta.mcp_servers
    active_runtime = start_runtime_run(active)
    assert {:ok, %{effective_mode: :steer_pending, target_run_id: ^active}} =
             SessionCoordinator.submit_with_receipt(key,
               context_submission(key, steering, "correction", :steer, supervisor, steering_meta, policy))
    assert_receive {:run_cast, :steer, ^steering, "correction", owner}
    send(owner, {:steer_accepted, steering})
    assert {:ok, ^active} = SessionCoordinator.active_run(key)
    assert {:ok, %{effective_mode: :steer, target_run_id: ^active}} = RunReceiptStore.fetch(steering)

    assert {:ok, %{effective_mode: :queued, target_run_id: ^queued}} =
             SessionCoordinator.submit_with_receipt(key,
               context_submission(key, queued, "next turn", :collect, supervisor, queued_meta, policy))
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^queued, queued_opts}
    assert queued_opts[:execution_request].resume == token
    assert queued_opts[:execution_request].prompt == "next turn"
    assert queued_opts[:execution_request].meta.mcp_servers == queued_meta.mcp_servers
    assert queued_opts[:execution_request].meta.invocation_proof == queued_meta.invocation_proof
    queued_runtime = start_runtime_run(queued)

    assert {:ok, %{effective_mode: :queued, target_run_id: ^unattested}} =
             SessionCoordinator.submit_with_receipt(key,
               context_submission(key, unattested, "unattested own turn", :steer, supervisor,
                 unattested_meta, policy))
    _ = :sys.get_state(queued_runtime)
    assert {:ok, ^queued} = SessionCoordinator.active_run(key)
    refute_receive {:run_cast, _, ^unattested, _, _}, 0
    :ok = stop_active_run(supervisor)
    assert_receive {:started, ^unattested, unattested_opts}
    assert unattested_opts[:execution_request].resume == nil
    assert unattested_opts[:execution_request].prompt == "unattested own turn"
    assert unattested_opts[:execution_request].meta.mcp_servers == unattested_meta.mcp_servers
    GenServer.stop(active_runtime)
    GenServer.stop(queued_runtime)
  end

  defp proof_meta(run_id) do
    name = "lemon_bot/invocations/#{run_id}"
    servers = [%{name: "core", url: "https://core.invalid/mcp", headers: %{
      "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:#{name}}",
      "Authorization" => "${LEMON_SECRET:connector/same}"
    }}]
    descriptor = %{"runId" => run_id, "serverName" => "core",
      "serverUrl" => "https://core.invalid/mcp", "headerName" => "X-Lemon-Bot-Invocation",
      "secretName" => name}
    assert {:ok, proof} = LemonCore.InvocationProof.validate(descriptor, run_id, servers)
    %{invocation_context_key: "same-actor", memory_context_key: "same-room",
      memory_context_verified: true, invocation_proof_verified: true,
      invocation_proof: proof, mcp_servers: servers}
  end

  defp context_submission(key, id, prompt, mode, supervisor, meta, policy) do
    input = submission(key, id, prompt, mode, supervisor, meta: meta)
    %{input | execution_request: %{input.execution_request | meta: meta, tool_policy: policy}}
  end

  defp receipt_run_id, do: "receipt-#{System.unique_integer([:positive, :monotonic])}"

  defp receipt_submit(key, id, prompt, mode, supervisor) do
    SessionCoordinator.submit_with_receipt(key, submission(key, id, prompt, mode, supervisor))
  end

  defp start_receipt_store(opts) do
    name = :"receipt_failure_#{System.unique_integer([:positive])}"
    start_supervised!({LemonCore.Store, name: name, backend: ReceiptRefusingBackend, backend_opts: opts})
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

  defp abort_active_run(run_supervisor, reason) do
    [{_, active_pid, _, _}] = DynamicSupervisor.which_children(run_supervisor)
    StubRunProcess.abort(active_pid, reason)
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
