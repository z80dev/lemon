defmodule LemonRouter.RunPhaseSequenceTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event}
  alias LemonGateway.ExecutionRequest
  alias LemonRouter.{SessionCoordinator, Submission}

  defmodule PhaseStubRunProcess do
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

  defmodule RunPhaseSequenceGatewayRunStub do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(
        __MODULE__,
        opts,
        name: {:via, Registry, {LemonGateway.RunRegistry, opts[:run_id]}}
      )
    end

    @impl true
    def init(opts), do: {:ok, %{test_pid: opts[:test_pid]}}

    @impl true
    def handle_cast({kind, %ExecutionRequest{} = request, worker_pid}, state)
        when kind in [:steer, :steer_backlog] do
      send(state.test_pid, {:steer_dispatched, kind, request, worker_pid})
      {:noreply, state}
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

    {:ok, run_supervisor: run_supervisor}
  end

  test "immediate submit emits accepted then waiting_for_slot", %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}
    run_id = "run_phase_immediate"

    :ok = Bus.subscribe(Bus.run_topic(run_id))

    :ok = submit(key, run_id, "one", :collect, run_supervisor)

    assert_phase_event(run_id, :accepted, nil)
    assert_phase_event(run_id, :waiting_for_slot, :accepted)
    assert_receive {:started, ^run_id, _opts}, 500
  end

  test "queued submit emits accepted then queued_in_session then waiting_for_slot when started",
       %{
         run_supervisor: run_supervisor
       } do
    session_key = unique_session_key()
    key = {:session, session_key}
    run_id_1 = "run_phase_active"
    run_id_2 = "run_phase_queued"

    :ok = Bus.subscribe(Bus.run_topic(run_id_1))
    :ok = Bus.subscribe(Bus.run_topic(run_id_2))

    :ok = submit(key, run_id_1, "one", :collect, run_supervisor)
    assert_phase_event(run_id_1, :accepted, nil)
    assert_phase_event(run_id_1, :waiting_for_slot, :accepted)
    assert_receive {:started, ^run_id_1, _opts}, 500

    :ok = submit(key, run_id_2, "two", :collect, run_supervisor)
    assert_phase_event(run_id_2, :accepted, nil)
    assert_phase_event(run_id_2, :queued_in_session, :accepted)

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, ^run_id_1, :user_requested}, 500
    assert_receive {:started, ^run_id_2, _opts}, 500
    assert_phase_event(run_id_2, :waiting_for_slot, :queued_in_session)
  end

  test "steer rejection fallback emits no router phases", %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}
    run_id_1 = "run_phase_steer_active"
    run_id_2 = "run_phase_steer_rejected"

    :ok = Bus.subscribe(Bus.run_topic(run_id_2))

    :ok = submit(key, run_id_1, "one", :collect, run_supervisor)
    assert_receive {:started, ^run_id_1, _opts}, 500

    {:ok, gateway_run} =
      start_supervised({RunPhaseSequenceGatewayRunStub, test_pid: self(), run_id: run_id_1})

    :ok = submit(key, run_id_2, "two", :steer, run_supervisor)

    assert_receive {:steer_dispatched, :steer, %ExecutionRequest{run_id: ^run_id_2} = request,
                    worker_pid},
                   500

    send(worker_pid, {:steer_rejected, request})
    refute_phase_event(run_id_2)

    SessionCoordinator.cancel(session_key, :user_requested)
    assert_receive {:aborted, ^run_id_1, :user_requested}, 500
    assert_receive {:started, ^run_id_2, _opts}, 500
    refute_phase_event(run_id_2)

    GenServer.stop(gateway_run)
  end

  test "merged followup aborts the superseded queued run", %{run_supervisor: run_supervisor} do
    session_key = unique_session_key()
    key = {:session, session_key}
    run_id_1 = "run_phase_merge_active"
    run_id_2 = "run_phase_merge_old"
    run_id_3 = "run_phase_merge_new"

    :ok = Bus.subscribe(Bus.run_topic(run_id_2))
    :ok = Bus.subscribe(Bus.run_topic(run_id_3))

    :ok = submit(key, run_id_1, "one", :collect, run_supervisor)
    assert_receive {:started, ^run_id_1, _opts}, 500

    :ok = submit(key, run_id_2, "part1", :followup, run_supervisor)
    assert_phase_event(run_id_2, :accepted, nil)
    assert_phase_event(run_id_2, :queued_in_session, :accepted)

    :ok = submit(key, run_id_3, "part2", :followup, run_supervisor)
    assert_phase_event(run_id_2, :aborted, :queued_in_session)
    assert_phase_event(run_id_3, :accepted, nil)
    assert_phase_event(run_id_3, :queued_in_session, :accepted)
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

    submission =
      Submission.new!(%{
        run_id: run_id,
        session_key: elem(key, 1),
        conversation_key: key,
        queue_mode: queue_mode,
        execution_request: request,
        run_supervisor: run_supervisor,
        run_process_module: PhaseStubRunProcess,
        run_process_opts: %{test_pid: self()}
      })

    SessionCoordinator.submit(key, submission)
  end

  defp assert_phase_event(run_id, phase, previous_phase) do
    assert_receive %Event{
                     type: :run_phase_changed,
                     payload: %{
                       run_id: ^run_id,
                       phase: ^phase,
                       previous_phase: ^previous_phase,
                       source: :lemon_router_session_coordinator
                     },
                     meta: %{run_id: ^run_id}
                   },
                   1_000
  end

  defp refute_phase_event(run_id) do
    refute_receive %Event{
                     type: :run_phase_changed,
                     meta: %{run_id: ^run_id}
                   },
                   300
  end

  defp unique_session_key do
    "agent:run-phase:#{System.unique_integer([:positive])}"
  end

  defp ensure_pubsub do
    if Process.whereis(LemonCore.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: LemonCore.PubSub})
    end
  end

  defp start_if_needed(name, fun) do
    if is_nil(Process.whereis(name)) do
      {:ok, _pid} = fun.()
    end

    :ok
  end

  defp safe_unregister(name) do
    Process.unregister(name)
  rescue
    ArgumentError -> :ok
  end
end
