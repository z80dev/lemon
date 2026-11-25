defmodule LemonRouter.RunLifecycleTerminalizationTest do
  @moduledoc """
  Terminalization between runtime acceptance and the first run event: the real
  `RunProcess` state machine, coordinator and gateway runtime, with only the
  native executor replaced by a fixture.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event, ExecutionCommand, RunRequest, Store}
  alias LemonCore.Events.{Completion, RunCompleted}
  alias LemonRouter.{RestartCarryover, RunOrchestrator, RunProcess, SessionCoordinator}
  alias LemonRouter.RestartCarryover.CrashRecovery
  alias LemonRouter.Submission

  defmodule GatedExecutor do
    @moduledoc false
    # Each run waits for the test to complete it. Cancellation is a request the
    # runner honours by exiting.

    def start_run(request, _opts, sink) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      run_ref = make_ref()
      runner = spawn(fn -> await_finish(sink, run_ref) end)
      send(test_pid, {:executor_started, request.run_id, runner})
      {:ok, run_ref, %{runner_pid: runner}}
    end

    def cancel(%{runner_pid: runner}) do
      send(runner, :cancel)
      :ok
    end

    def steer(_ctx, _text), do: {:error, :unsupported}
    def redirect(_ctx, _text), do: {:error, :unsupported}

    defp await_finish(sink, run_ref) do
      receive do
        {:complete, answer} ->
          completed = LemonGateway.Event.completed(%{engine: "lemon", ok: true, answer: answer})
          send(sink, {:engine_event, run_ref, completed})

        :cancel ->
          :ok
      end
    end
  end

  defmodule AmbiguousRuntime do
    @moduledoc false
    # Starts the run, then fails to acknowledge it.

    def available?, do: true

    def submit_execution(%ExecutionCommand{run_id: run_id, session_key: session_key}) do
      run = spawn(fn -> run(run_id, session_key) end)
      :persistent_term.put({__MODULE__, run_id}, run)
      {:error, :outcome_unknown}
    end

    def run_pid(run_id), do: :persistent_term.get({__MODULE__, run_id}, nil)
    def cancel_by_run_id(_run_id, _reason), do: :ok

    defp run(run_id, session_key) do
      receive do
        {:complete, answer} ->
          completed = Completion.new(%{ok: true, answer: answer})

          Bus.broadcast(
            Bus.run_topic(run_id),
            Event.new(
              :run_completed,
              RunCompleted.new(%{completed: completed, duration_ms: 1}),
              %{run_id: run_id, session_key: session_key}
            )
          )
      end
    end
  end

  defmodule NeverStartedRuntime do
    @moduledoc false
    def available?, do: true
    def submit_execution(_command), do: exit(:timeout)
    def run_pid(_run_id), do: nil
    def cancel_by_run_id(_run_id, _reason), do: :ok
  end

  defmodule OutcomeUnknownCoordinator do
    @moduledoc false
    def submit(_conversation_key, _submission), do: {:error, :outcome_unknown}
    def abort_run(_run_id, _reason), do: :ok
  end

  defmodule ForwardingBridge do
    @moduledoc false
    # Models the control-plane bridge: run events reach the test while subscribed.
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid, name: __MODULE__)
    def subscribe_run(run_id), do: GenServer.call(__MODULE__, {:subscribe, run_id})
    def unsubscribe_run(run_id), do: GenServer.call(__MODULE__, {:unsubscribe, run_id})

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:subscribe, run_id}, _from, test_pid) do
      Bus.subscribe(Bus.run_topic(run_id))
      send(test_pid, {:bridge_subscribed, run_id})
      {:reply, :ok, test_pid}
    end

    def handle_call({:unsubscribe, run_id}, _from, test_pid) do
      Bus.unsubscribe(Bus.run_topic(run_id))
      send(test_pid, {:bridge_unsubscribed, run_id})
      {:reply, :ok, test_pid}
    end

    @impl true
    def handle_info(%Event{} = event, test_pid) do
      send(test_pid, {:bridge_event, event})
      {:noreply, test_pid}
    end
  end

  defmodule FinalAnswerCoalescer do
    @moduledoc false
    def finalize_run(_session_key, _channel_id, run_id, opts) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:final_answer, run_id, opts[:final_text]}
      )

      :ok
    end

    def current_text(_session_key, _channel_id, _run_id), do: nil
  end

  defmodule StubbornRunProcess do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id]},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}
  end

  describe "gateway run monitored from submission" do
    setup :gateway_fixture

    test "killing the gateway run before run_started terminalizes once and the queue advances",
         %{run_supervisor: run_supervisor} do
      blockers = occupy_capacity()
      key = conversation()
      [first, second, third] = ids = Enum.map(1..3, fn _ -> run_id() end)
      Enum.each(ids, &Bus.subscribe(Bus.run_topic(&1)))
      Enum.each(ids, &(:ok = SessionCoordinator.submit(key, submission(key, &1, run_supervisor))))

      {router, gateway} = await_monitored_gateway_run(first)
      router_monitor = Process.monitor(router)
      refute_received %Event{type: :run_started, meta: %{run_id: ^first}}

      Process.exit(gateway, :kill)

      assert_receive %Event{
                       type: :run_completed,
                       meta: %{run_id: ^first, synthetic: true},
                       payload: %{completed: %{ok: false, error: {:gateway_run_down, :killed}}}
                     },
                     2_000

      assert_receive {:DOWN, ^router_monitor, :process, ^router, :normal}, 2_000

      # The queued messages were neither dropped nor failed: each runs in order.
      _ = await_gateway_run(second)
      release(blockers)
      complete(second, "second done")
      assert_completed_ok(second, "second done")
      complete(third, "third done")
      assert_completed_ok(third, "third done")

      refute_receive %Event{type: :run_completed, meta: %{run_id: ^first}}, 300
      assert SessionCoordinator.active_run(key) == :none
    end

    test "killed queued gateway runs leak no run process or busy conversation",
         %{run_supervisor: run_supervisor} do
      blockers = occupy_capacity()

      runs =
        for _ <- 1..4 do
          key = conversation()
          id = run_id()
          Bus.subscribe(Bus.run_topic(id))
          :ok = SessionCoordinator.submit(key, submission(key, id, run_supervisor))
          {key, id}
        end

      gateways = Enum.map(runs, fn {_key, id} -> elem(await_monitored_gateway_run(id), 1) end)
      Enum.each(gateways, &Process.exit(&1, :kill))

      for {_key, id} <- runs do
        assert_receive %Event{
                         type: :run_completed,
                         meta: %{run_id: ^id},
                         payload: %{completed: %{error: {:gateway_run_down, :killed}}}
                       },
                       2_000
      end

      assert eventually(fn ->
               DynamicSupervisor.count_children(run_supervisor).active == 0 and
                 Enum.all?(runs, fn {{:session, session_key} = key, id} ->
                   Registry.lookup(LemonRouter.RunRegistry, id) == [] and
                     SessionCoordinator.active_run(key) == :none and
                     SessionCoordinator.busy?(session_key) == false
                 end)
             end)

      assert eventually(fn -> match?({:ok, %{waitq: 0}}, LemonGateway.Slots.stats()) end)
      release(blockers)
    end

    test "a normal run binds and monitors its gateway run exactly once",
         %{run_supervisor: run_supervisor} do
      key = conversation()
      id = run_id()
      Bus.subscribe(Bus.run_topic(id))
      :ok = SessionCoordinator.submit(key, submission(key, id, run_supervisor))

      assert_receive {:executor_started, ^id, runner}, 2_000
      gateway = LemonGateway.Runtime.run_pid(id)
      router = await_router_run(id)
      router_monitor = Process.monitor(router)

      assert eventually(fn -> match?({:running, _}, :sys.get_state(router)) end)
      assert {:running, %{gateway_run_pid: ^gateway}} = :sys.get_state(router)
      {:monitored_by, monitors} = Process.info(gateway, :monitored_by)
      assert Enum.count(monitors, &(&1 == router)) == 1

      send(runner, {:complete, "done"})
      assert_completed_ok(id, "done")
      assert_receive {:DOWN, ^router_monitor, :process, ^router, :normal}, 2_000
      refute_receive %Event{type: :run_completed, meta: %{run_id: ^id}}, 300
    end
  end

  describe "unknown submission outcomes" do
    test "an unknown coordinator outcome keeps the run's event subscription" do
      previous_bridge = Application.get_env(:lemon_core, :event_bridge_impl)
      previous_coordinator = Application.get_env(:lemon_router, :session_coordinator)
      start_supervised!({ForwardingBridge, self()})
      :ok = LemonCore.EventBridge.configure(ForwardingBridge)
      Application.put_env(:lemon_router, :session_coordinator, OutcomeUnknownCoordinator)
      id = run_id()

      on_exit(fn ->
        restore_env(:lemon_core, :event_bridge_impl, previous_bridge)
        restore_env(:lemon_router, :session_coordinator, previous_coordinator)
        Store.delete(RunOrchestrator.admission_table(), id)
      end)

      {:ok, orchestrator} = GenServer.start_link(RunOrchestrator, [])

      request =
        RunRequest.new(%{
          run_id: id,
          session_key: "agent:default:main:#{id}",
          agent_id: "default",
          prompt: "may already be queued"
        })

      assert {:error, :outcome_unknown} = RunOrchestrator.submit(orchestrator, request)
      assert_received {:bridge_subscribed, ^id}
      refute_received {:bridge_unsubscribed, ^id}

      :ok = Bus.broadcast(Bus.run_topic(id), completed_event(id, "late answer"))

      assert_receive {:bridge_event,
                      %Event{type: :run_completed, meta: %{run_id: ^id}, payload: payload}}

      assert payload.completed.answer == "late answer"
    end

    test "an unknown runtime outcome adopts the started run and receives its completion" do
      id = run_id()
      session_key = "agent:test:main:#{id}"
      on_exit(fn -> :persistent_term.erase({AmbiguousRuntime, id}) end)

      pid = start_run_process(id, session_key, engine_runtime: AmbiguousRuntime)
      monitor = Process.monitor(pid)
      run = await(fn -> AmbiguousRuntime.run_pid(id) end)

      assert eventually(fn ->
               match?({:awaiting_start, %{gateway_run_pid: ^run}}, :sys.get_state(pid))
             end)

      send(run, {:complete, "adopted answer"})

      assert_receive %Event{type: :run_completed, meta: meta, payload: payload}, 2_000
      refute Map.get(meta, :synthetic)
      assert %{ok: true, answer: "adopted answer"} = payload.completed
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
      refute_received %Event{type: :run_completed}
    end

    test "an unknown runtime outcome without a live run terminalizes once after the bind grace" do
      id = run_id()
      on_exit(fn -> Store.delete(:runs, id) end)

      pid = start_run_process(id, "agent:test:main:#{id}", engine_runtime: NeverStartedRuntime)
      monitor = Process.monitor(pid)

      assert_receive %Event{
                       type: :run_completed,
                       meta: %{synthetic: true},
                       payload: %{completed: %{error: :gateway_run_missing_after_start}}
                     },
                     3_000

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
      refute_received %Event{type: :run_completed}
    end
  end

  test "a store error while retaining terminal evidence still delivers the answer" do
    previous = Application.get_env(:lemon_router, :stream_coalescer)
    Application.put_env(:lemon_router, :stream_coalescer, FinalAnswerCoalescer)
    :persistent_term.put({FinalAnswerCoalescer, :test_pid}, self())

    on_exit(fn ->
      restore_env(:lemon_router, :stream_coalescer, previous)
      :persistent_term.erase({FinalAnswerCoalescer, :test_pid})
    end)

    id = run_id()

    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "test",
        channel_id: "lifecycle",
        account_id: "default",
        peer_kind: :dm,
        peer_id: id
      })

    pid =
      start_run_process(id, session_key,
        submit_to_gateway?: false,
        receipt_store: :"#{__MODULE__}.UnavailableStore"
      )

    monitor = Process.monitor(pid)
    :ok = Bus.broadcast(Bus.run_topic(id), completed_event(id, "the answer"))

    assert_receive {:final_answer, ^id, "the answer"}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  describe "restart recovery exits" do
    test "an exiting recovery call leaves only that admission pending" do
      recover = fn
        "slow", _admission -> exit({:timeout, {GenServer, :call, []}})
        "done", _admission -> {:ok, :skipped}
      end

      assert %{pending: 1, skipped: 1} =
               CrashRecovery.reconcile([{"slow", %{}}, {"done", %{}}], recover: recover)
    end

    test "an exiting replay submit keeps that item for the next boot and replays the rest" do
      store = :"#{__MODULE__}.ReplayStore"
      start_supervised!({Store, name: store, backend: Store.EtsBackend})
      slow = %RunRequest{session_key: "agent:test:main:replay", prompt: "a", run_id: run_id()}
      fast = %RunRequest{session_key: "agent:test:main:replay", prompt: "b", run_id: run_id()}

      :ok =
        Store.put(store, RestartCarryover.table(), {1, 0}, %{
          items: [
            %{kind: :replay, outcome: :queued, request: slow},
            %{kind: :replay, outcome: :queued, request: fast}
          ],
          version: 1,
          recorded_at_ms: 1,
          attempts: 0
        })

      slow_id = slow.run_id

      submit = fn
        %RunRequest{run_id: ^slow_id} -> exit({:timeout, {GenServer, :call, []}})
        %RunRequest{run_id: run_id} -> {:ok, run_id}
      end

      assert {:ok, %{submitted: 1, pending: 1, rejected: 0}} =
               RestartCarryover.replay(submit: submit, store: store)

      assert {:ok, [{_key, %{items: [%{request: %{run_id: ^slow_id}}]}}]} =
               Store.fetch_all(store, RestartCarryover.table())
    end

    test "an exiting recovered coordinator submit is an unknown outcome" do
      key = conversation()
      {:session, session_key} = key
      id = run_id()

      :ok = SessionCoordinator.submit(key, submission(key, run_id(), nil, StubbornRunProcess))
      [{coordinator, _}] = Registry.lookup(LemonRouter.ConversationRegistry, key)
      :ok = :sys.suspend(coordinator)

      task =
        Task.async(fn ->
          command = %ExecutionCommand{run_id: id, session_key: session_key, prompt: "recovered"}

          SessionCoordinator.submit_recovered(
            key,
            Submission.new!(%{
              run_id: id,
              session_key: session_key,
              conversation_key: key,
              queue_mode: :collect,
              execution_request: %{command | conversation_key: key}
            })
          )
        end)

      assert eventually(fn ->
               match?(
                 {:message_queue_len, n} when n > 0,
                 Process.info(coordinator, :message_queue_len)
               )
             end)

      Process.exit(coordinator, :kill)
      assert Task.await(task) == {:error, :outcome_unknown}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp gateway_fixture(_context) do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    previous = Application.fetch_env(:lemon_gateway, :executor)
    Application.put_env(:lemon_gateway, :executor, GatedExecutor)
    :persistent_term.put({GatedExecutor, :test_pid}, self())

    on_exit(fn ->
      # A failed test must not leave a fixture run holding an execution permit.
      for {_, run, _, _} <- DynamicSupervisor.which_children(LemonGateway.RunSupervisor),
          Enum.any?(Registry.keys(LemonGateway.RunRegistry, run), &lifecycle_run_id?/1),
          do: Process.exit(run, :kill)

      case previous do
        {:ok, executor} -> Application.put_env(:lemon_gateway, :executor, executor)
        :error -> Application.delete_env(:lemon_gateway, :executor)
      end

      :persistent_term.erase({GatedExecutor, :test_pid})
    end)

    %{run_supervisor: start_supervised!({DynamicSupervisor, strategy: :one_for_one})}
  end

  # Fill every execution permit, so later runs wait in the gateway FIFO before
  # they emit run_started.
  defp occupy_capacity do
    {:ok, %{max: max}} = LemonGateway.Slots.stats()

    for _ <- 1..max do
      id = run_id()
      session_key = "agent:test:main:blocker-#{id}"

      :ok =
        LemonGateway.Runtime.submit_execution(%ExecutionCommand{
          run_id: id,
          session_key: session_key,
          prompt: "hold a permit",
          conversation_key: {:session, session_key}
        })

      assert_receive {:executor_started, ^id, runner}, 2_000
      on_exit(fn -> Process.exit(runner, :kill) end)
      runner
    end
  end

  defp release(blockers), do: Enum.each(blockers, &send(&1, {:complete, "released"}))

  defp complete(id, answer) do
    assert_receive {:executor_started, ^id, runner}, 2_000
    send(runner, {:complete, answer})
  end

  defp assert_completed_ok(id, answer) do
    assert_receive %Event{
                     type: :run_completed,
                     meta: %{run_id: ^id},
                     payload: %{completed: %{ok: true, answer: ^answer}}
                   },
                   2_000
  end

  defp await_gateway_run(id), do: await(fn -> LemonGateway.Runtime.run_pid(id) end)

  # The router run monitors its gateway run before run_started: the gateway run
  # is still waiting for an execution permit.
  defp await_monitored_gateway_run(id) do
    gateway = await_gateway_run(id)
    router = await_router_run(id)

    await(fn ->
      match?({:awaiting_start, %{gateway_run_pid: ^gateway}}, :sys.get_state(router)) || nil
    end)

    {router, gateway}
  end

  defp await_router_run(id) do
    await(fn ->
      case Registry.lookup(LemonRouter.RunRegistry, id) do
        [{pid, _}] -> pid
        _ -> nil
      end
    end)
  end

  defp start_run_process(id, session_key, opts) do
    Bus.subscribe(Bus.session_topic(session_key))

    command = %ExecutionCommand{
      run_id: id,
      session_key: session_key,
      prompt: "work",
      conversation_key: {:session, session_key}
    }

    options =
      Map.merge(
        %{run_id: id, session_key: session_key, execution_request: command},
        Map.new(opts)
      )

    {:ok, pid} = RunProcess.start_link(options)
    Process.unlink(pid)
    pid
  end

  defp submission(key, id, run_supervisor, run_process_module \\ RunProcess) do
    {:session, session_key} = key

    command = %ExecutionCommand{
      run_id: id,
      session_key: session_key,
      prompt: "work #{id}",
      conversation_key: key
    }

    Submission.new!(%{
      run_id: id,
      session_key: session_key,
      conversation_key: key,
      queue_mode: :collect,
      execution_request: command,
      run_supervisor:
        run_supervisor || start_supervised!({DynamicSupervisor, strategy: :one_for_one}),
      run_process_module: run_process_module,
      run_process_opts: %{engine_runtime: LemonGateway.Runtime}
    })
  end

  defp completed_event(id, answer) do
    completed = Completion.new(%{ok: true, answer: answer})

    Event.new(
      :run_completed,
      RunCompleted.new(%{completed: completed, duration_ms: 1}),
      %{run_id: id}
    )
  end

  defp conversation,
    do: {:session, "agent:test:main:lifecycle-#{System.unique_integer([:positive])}"}

  defp run_id, do: "run_lifecycle_#{System.unique_integer([:positive])}"
  defp lifecycle_run_id?(key), do: is_binary(key) and String.starts_with?(key, "run_lifecycle_")

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp await(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition not met before the deadline")
        else
          Process.sleep(10)
          do_await(fun, deadline)
        end

      value ->
        value
    end
  end

  defp eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_eventually(fun, deadline)
    end
  end
end
