defmodule LemonRouter.SessionCoordinatorTest do
  use ExUnit.Case, async: false

  alias LemonGateway.ExecutionRequest
  alias LemonRouter.SessionCoordinator

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

  setup do
    start_if_needed(LemonRouter.ConversationRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.ConversationRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :duplicate, name: LemonRouter.SessionRegistry)
    end)

    {:ok, run_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, coord_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    original =
      Process.whereis(LemonRouter.SessionCoordinatorSupervisor) ||
        Application.get_env(:lemon_router, :session_coordinator_supervisor)

    if is_pid(Process.whereis(LemonRouter.SessionCoordinatorSupervisor)) do
      Process.unregister(LemonRouter.SessionCoordinatorSupervisor)
    end

    Process.register(coord_supervisor, LemonRouter.SessionCoordinatorSupervisor)

    on_exit(fn ->
      if is_pid(Process.whereis(LemonRouter.SessionCoordinatorSupervisor)) do
        Process.unregister(LemonRouter.SessionCoordinatorSupervisor)
      end

      if is_pid(original) do
        Process.register(original, LemonRouter.SessionCoordinatorSupervisor)
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

  test "followup submissions merge while queued behind an active run", %{run_supervisor: run_supervisor} do
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

  defp submit(key, run_id, prompt, queue_mode, run_supervisor) do
    request = %ExecutionRequest{
      run_id: run_id,
      session_key: elem(key, 1),
      prompt: prompt,
      engine_id: "codex",
      conversation_key: key,
      meta: %{}
    }

    submission = %{
      run_id: run_id,
      session_key: elem(key, 1),
      queue_mode: queue_mode,
      execution_request: request,
      run_supervisor: run_supervisor,
      run_process_module: StubRunProcess,
      run_process_opts: %{test_pid: self()}
    }

    SessionCoordinator.submit(key, submission)
  end

  defp unique_session_key do
    "agent:test:main:#{System.unique_integer([:positive])}"
  end

  defp start_if_needed(name, fun) do
    if is_nil(Process.whereis(name)) do
      {:ok, _pid} = fun.()
    end

    :ok
  end
end
