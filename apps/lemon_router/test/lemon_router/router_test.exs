defmodule LemonRouter.RouterTest do
  use ExUnit.Case, async: false

  alias LemonCore.RouterBridge
  alias LemonRouter.Router

  defmodule SessionCoordinatorStubRouter do
    def abort_session(session_key, reason) do
      send(test_pid(), {:abort_session, session_key, reason})
      Application.get_env(:lemon_router, :router_abort_session_result, :ok)
    end

    def abort_run(run_id, reason) do
      send(test_pid(), {:abort_run, run_id, reason})
      Application.get_env(:lemon_router, :router_abort_run_result, :ok)
    end

    def busy?(session_key) do
      send(test_pid(), {:busy_query, session_key})

      Process.get(:router_busy_result, false)
    end

    def active_run_for_session(session_key) do
      send(test_pid(), {:active_run_query, session_key})
      Process.get({:active_run, session_key}, :none)
    end

    def list_active_sessions do
      send(test_pid(), :list_active_sessions)
      Process.get(:router_active_sessions, [])
    end

    defp test_pid, do: Application.fetch_env!(:lemon_router, :router_test_pid)
  end

  setup do
    start_if_needed(LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.SessionRegistry)
    end)

    previous_session_coordinator = Application.get_env(:lemon_router, :session_coordinator)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    Application.put_env(:lemon_router, :session_coordinator, SessionCoordinatorStubRouter)
    Application.put_env(:lemon_router, :router_test_pid, self())

    Process.put(:router_test_pid, self())
    Process.delete(:router_busy_result)
    Process.delete(:router_active_sessions)
    Process.delete(:router_abort_session_result)
    Process.delete(:router_abort_run_result)

    on_exit(fn ->
      case previous_session_coordinator do
        nil -> Application.delete_env(:lemon_router, :session_coordinator)
        mod -> Application.put_env(:lemon_router, :session_coordinator, mod)
      end

      case previous_bridge do
        nil -> Application.delete_env(:lemon_core, :router_bridge)
        config -> Application.put_env(:lemon_core, :router_bridge, config)
      end

      Process.delete(:router_test_pid)
      Process.delete(:router_busy_result)
      Process.delete(:router_active_sessions)
      Process.delete(:router_abort_session_result)
      Process.delete(:router_abort_run_result)
      Application.delete_env(:lemon_router, :router_test_pid)
      Application.delete_env(:lemon_router, :router_abort_session_result)
      Application.delete_env(:lemon_router, :router_abort_run_result)
    end)

    :ok
  end

  defp start_if_needed(name, start_fn) do
    if is_nil(Process.whereis(name)) do
      {:ok, _} = start_fn.()
    end
  end

  test "abort/2 aborts the active run registered for the session" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"

    Router.abort(session_key, :test_abort)

    assert_receive {:abort_session, ^session_key, :test_abort}
  end

  test "abort/2 is a no-op when session has no runs" do
    assert :ok = Router.abort("missing:session", :test_abort)
    assert_receive {:abort_session, "missing:session", :test_abort}
  end

  test "abort/2 propagates a coordinator rejection" do
    Application.put_env(
      :lemon_router,
      :router_abort_session_result,
      {:error, :coordinator_unavailable}
    )

    assert {:error, :coordinator_unavailable} =
             Router.abort("agent:test:main", :test_abort)

    assert_receive {:abort_session, "agent:test:main", :test_abort}
  end

  test "RouterBridge reports an unknown abort outcome when tombstone registration exits" do
    orchestrator = Process.whereis(LemonRouter.RunOrchestrator)
    assert is_pid(orchestrator)
    true = Process.unregister(LemonRouter.RunOrchestrator)

    try do
      :ok = RouterBridge.configure(router: Router)

      assert {:error, :outcome_unknown} =
               Router.abort_run("run-tombstone-unavailable-direct", :test_abort)

      assert {:error, :outcome_unknown} =
               RouterBridge.abort_run("run-tombstone-unavailable", :test_abort)

      refute_receive {:abort_run, "run-tombstone-unavailable-direct", :test_abort}, 100
      refute_receive {:abort_run, "run-tombstone-unavailable", :test_abort}, 100
    after
      true = Process.register(orchestrator, LemonRouter.RunOrchestrator)
    end
  end

  test "abort_run/2 reports unknown after a coordinator rejection follows a tombstone" do
    Application.put_env(
      :lemon_router,
      :router_abort_run_result,
      {:error, :coordinator_unavailable}
    )

    assert {:error, :outcome_unknown} =
             Router.abort_run("run-coordinator-rejected", :test_abort)

    assert_receive {:abort_run, "run-coordinator-rejected", :test_abort}
  end

  test "query callbacks propagate coordinator read failures" do
    Process.put(:router_busy_result, {:error, :unavailable})
    Process.put({:active_run, "agent:test:main"}, {:error, :unavailable})
    Process.put(:router_active_sessions, {:error, :unavailable})

    assert {:error, :unavailable} = Router.session_busy?("agent:test:main")
    assert {:error, :unavailable} = Router.active_run("agent:test:main")
    assert {:error, :unavailable} = Router.list_active_sessions()
  end
end
