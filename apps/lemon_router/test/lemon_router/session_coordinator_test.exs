defmodule LemonRouter.SessionCoordinatorTest do
  use ExUnit.Case, async: false

  alias LemonGateway.ExecutionRequest
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

  defmodule SessionCoordinatorGatewayRunStub do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(
        __MODULE__,
        opts,
        name: {:via, Registry, {LemonGateway.RunRegistry, opts[:run_id]}}
      )
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast({_kind, _request, _worker_pid}, state), do: {:noreply, state}
  end

  setup do
    ensure_pubsub()

    start_if_needed(LemonRouter.ConversationRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.ConversationRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :duplicate, name: LemonRouter.SessionRegistry)
    end)

    start_if_needed(LemonGateway.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonGateway.RunRegistry)
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
    Application.put_env(:lemon_router, :event_bridge_test_pid, self())
    :ok = LemonCore.EventBridge.configure(SessionCoordinatorEventBridgeStub)

    on_exit(fn ->
      restore_event_bridge_impl(original_bridge_impl)

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
    assert SessionCoordinator.list_active_sessions() == []

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
    gateway_run = start_supervised!({SessionCoordinatorGatewayRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :steer, run_supervisor)

    SessionCoordinator.cancel(key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:bridge_unsubscribed, "run2"}, 500

    GenServer.stop(gateway_run)
  end

  test "abort_session drops pending steer submissions and unsubscribes them", %{
    run_supervisor: run_supervisor
  } do
    session_key = unique_session_key()
    key = {:session, session_key}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    gateway_run = start_supervised!({SessionCoordinatorGatewayRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :steer, run_supervisor)

    :ok = SessionCoordinator.abort_session(session_key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:bridge_unsubscribed, "run2"}, 500

    GenServer.stop(gateway_run)
  end

  test "cancel drops pending steer_backlog submissions and unsubscribes them", %{
    run_supervisor: run_supervisor
  } do
    key = {:session, unique_session_key()}

    :ok = submit(key, "run1", "one", :collect, run_supervisor)
    assert_receive {:started, "run1", _}, 500
    gateway_run = start_supervised!({SessionCoordinatorGatewayRunStub, run_id: "run1"})

    :ok = LemonCore.EventBridge.subscribe_run("run2")
    assert_receive {:bridge_subscribed, "run2"}, 500
    :ok = submit(key, "run2", "two", :steer_backlog, run_supervisor)

    SessionCoordinator.cancel(key, :user_requested)
    assert_receive {:aborted, "run1", :user_requested}, 500
    assert_receive {:bridge_unsubscribed, "run2"}, 500

    GenServer.stop(gateway_run)
  end

  defp submit(key, run_id, prompt, queue_mode, run_supervisor) do
    SessionCoordinator.submit(key, submission(key, run_id, prompt, queue_mode, run_supervisor))
  end

  defp submission(key, run_id, prompt, queue_mode, run_supervisor, overrides \\ []) do
    request = %ExecutionRequest{
      run_id: run_id,
      session_key: elem(key, 1),
      prompt: prompt,
      engine_id: "codex",
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

  defp with_stopped_run_registry(fun) when is_function(fun, 0) do
    registry_pid = Process.whereis(LemonGateway.RunRegistry)

    if is_pid(registry_pid) do
      GenServer.stop(registry_pid)
    end

    try do
      fun.()
    after
      start_if_needed(LemonGateway.RunRegistry, fn ->
        Registry.start_link(keys: :unique, name: LemonGateway.RunRegistry)
      end)
    end
  end
end
