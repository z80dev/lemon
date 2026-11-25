defmodule LemonRouter.AdmissionContractTest do
  @moduledoc """
  End-to-end proofs of the run admission contract (epic #67):

    * an acknowledged fixed-ID admission stays discoverable and replays its
      original receipt after a lost acknowledgement (#78, #81);
    * any number of concurrent submissions of one fixed ID start at most one
      execution, and a different command under that ID is a conflict (#79);
    * cancelling accepted work that is still waiting, either in its
      conversation backlog or for a router execution permit, means it never
      starts later, and a replay of it never resurrects it (#80).

  The cancellation proofs run the real router admission path (orchestrator,
  coordinator, RunProcess) against the real router permit
  authority. Only the native executor is replaced, so the test observes every
  execution start.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{RouterBridge, RunRequest, RunStore}
  alias LemonRouter.{RunProcess, Slots, TestExecutor}
  alias LemonRouter.RunOrchestrator

  defmodule RecordingRunProcess do
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
    def init(opts) do
      send(opts[:notify_pid], {:execution_started, opts[:run_id], opts[:execution_request]})
      {:ok, opts}
    end
  end

  describe "fixed-ID admission" do
    setup do
      run_id = "run_admission_contract_#{System.unique_integer([:positive])}"
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      on_exit(fn ->
        LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)
        LemonCore.Store.delete(:run_receipts, run_id)
      end)

      opts = [
        name: nil,
        run_supervisor: run_supervisor,
        run_process_module: RecordingRunProcess,
        run_process_opts: %{notify_pid: self()}
      ]

      %{run_id: run_id, opts: opts}
    end

    test "a lost acknowledgement converges to the recorded admission without re-execution",
         %{run_id: run_id, opts: opts} do
      orchestrator = start_supervised!({RunOrchestrator, opts}, id: :lost_ack_owner)
      intent = intent(run_id, "ack lost after acceptance")

      # Delayed processing: the runtime cannot answer before the sender's deadline.
      :ok = :sys.suspend(orchestrator)
      assert {:timeout, _} = catch_exit(submit_with_deadline(orchestrator, intent, 20))

      # The sender reconciles by replaying the same fixed ID. The replay is
      # serialized behind the original request that is still in flight.
      replay = Task.async(fn -> RunOrchestrator.submit_with_receipt(orchestrator, intent) end)
      :ok = :sys.resume(orchestrator)

      assert {:ok, %{run_id: ^run_id, state: :accepted, effective_mode: :new_run} = receipt} =
               Task.await(replay, 5_000)

      assert_receive {:execution_started, ^run_id, _command}, 1_000
      refute_receive {:execution_started, ^run_id, _command}, 100

      # A query by stable identity and further replays converge on the receipt.
      assert {:ok, ^receipt} = RunOrchestrator.run_receipt(run_id)
      assert {:ok, ^run_id} = RunOrchestrator.submit(orchestrator, intent)
      assert {:ok, ^receipt} = RunOrchestrator.submit_with_receipt(orchestrator, intent)

      # The admission survives loss of its owner and stays discoverable.
      stop_supervised!(:lost_ack_owner)
      replacement = start_supervised!({RunOrchestrator, opts}, id: :lost_ack_replacement)
      assert {:ok, ^receipt} = RunOrchestrator.run_receipt(run_id)
      assert {:ok, ^receipt} = RunOrchestrator.submit_with_receipt(replacement, intent)

      assert {:error, :run_id_conflict} =
               RunOrchestrator.submit(replacement, %{intent | prompt: "a different command"})

      refute_receive {:execution_started, ^run_id, _command}, 100
    end

    test "concurrent identical and conflicting submissions of one ID start at most once",
         %{run_id: run_id, opts: opts} do
      orchestrator = start_supervised!({RunOrchestrator, opts}, id: :concurrent_owner)
      x = intent(run_id, "command X")
      y = intent(run_id, "command Y")
      parent = self()

      tasks =
        for n <- 1..24 do
          command = if rem(n, 2) == 0, do: x, else: y

          task =
            Task.async(fn ->
              send(parent, {:ready, self()})
              receive do: (:go -> :ok)
              {command.prompt, RunOrchestrator.submit(orchestrator, command)}
            end)

          assert_receive {:ready, pid}
          {task, pid}
        end

      Enum.each(tasks, fn {_task, pid} -> send(pid, :go) end)
      results = Enum.map(tasks, fn {task, _pid} -> Task.await(task, 10_000) end)

      assert_receive {:execution_started, ^run_id, %{prompt: winner}}, 1_000
      refute_receive {:execution_started, ^run_id, _command}, 200

      # The first command to reach admission owns the ID; every replay of it is
      # acknowledged and every other command is a conflict.
      for {prompt, result} <- results do
        if prompt == winner,
          do: assert(result == {:ok, run_id}),
          else: assert(result == {:error, :run_id_conflict})
      end

      {owner, other} = if winner == x.prompt, do: {x, y}, else: {y, x}

      stop_supervised!(:concurrent_owner)
      replacement = start_supervised!({RunOrchestrator, opts}, id: :concurrent_replacement)

      for _ <- 1..3 do
        assert {:ok, ^run_id} = RunOrchestrator.submit(replacement, owner)
        assert {:error, :run_id_conflict} = RunOrchestrator.submit(replacement, other)
      end

      refute_receive {:execution_started, ^run_id, _command}, 100
    end
  end

  describe "cancellation before execution" do
    setup do
      previous =
        for {app, key} <- [
              {:lemon_router, :test_executor},
              {:lemon_router, :test_executor_owner}
            ],
            do: {app, key, Application.fetch_env(app, key)}

      Application.put_env(:lemon_router, :test_executor, TestExecutor)
      Application.put_env(:lemon_router, :test_executor_owner, self())

      on_exit(fn ->
        Enum.each(previous, fn
          {app, key, {:ok, value}} -> Application.put_env(app, key, value)
          {app, key, :error} -> Application.delete_env(app, key)
        end)
      end)

      :ok
    end

    test "work cancelled while waiting for an execution permit never starts" do
      holders = occupy_all_permits()
      waiting = intent(unique_id("permit_wait"), "waits for a permit")
      id = waiting.run_id
      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(id))
      on_exit(fn -> cleanup_run(id, waiting.session_key) end)

      assert {:ok, ^id} = RouterBridge.submit_run(waiting)

      assert eventually(fn ->
               is_pid(RunProcess.whereis(id)) and
                 match?({:ok, %{waitq: waitq}} when waitq >= 1, Slots.stats())
             end)

      assert :ok = RouterBridge.abort_run(id, :user_requested)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       meta: %{run_id: ^id},
                       payload: %{completed: %{ok: false}}
                     },
                     2_000

      assert eventually(fn ->
               RunProcess.whereis(id) == nil and not LemonRouter.run_active?(id)
             end)

      release_permits(holders)
      refute_receive {:test_executor_started, ^id, _sink, _ref}, 300
      assert %{summary: %{completed: %{ok: false}}} = RunStore.get(id)

      # A late replay of the cancelled intent is acknowledged, never re-executed.
      assert {:ok, ^id} = RouterBridge.submit_run(waiting)
      assert {:ok, %{run_id: ^id, state: :accepted}} = RouterBridge.run_receipt(id)
      refute_receive {:test_executor_started, ^id, _sink, _ref}, 300
      refute LemonRouter.run_active?(id)
    end

    test "work cancelled in its conversation backlog never starts after the active run ends" do
      session_key = "agent:default:test:admission-backlog:#{System.unique_integer([:positive])}"

      active = %{
        intent(unique_id("backlog_active"), "holds the conversation")
        | session_key: session_key
      }

      queued = %{
        intent(unique_id("backlog_queued"), "waits in the backlog")
        | session_key: session_key
      }

      active_id = active.run_id
      queued_id = queued.run_id
      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(queued_id))

      on_exit(fn ->
        cleanup_run(active_id, session_key)
        cleanup_run(queued_id, session_key)
      end)

      assert {:ok, ^active_id} = RouterBridge.submit_run(active)
      assert_receive {:test_executor_started, ^active_id, runner, _sink}, 2_000

      assert {:ok, ^queued_id} = RouterBridge.submit_run(queued)

      assert {:ok, %{state: :accepted, effective_mode: :queued}} =
               RouterBridge.run_receipt(queued_id)

      assert :ok = RouterBridge.abort_run(queued_id, :user_requested)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       meta: %{run_id: ^queued_id},
                       payload: %{completed: %{ok: false}}
                     },
                     2_000

      TestExecutor.complete(runner, %{answer: "done"})

      assert eventually(fn ->
               not LemonRouter.run_active?(active_id) and
                 match?(
                   {:ok, %{presence: %{idle: true}}},
                   LemonRouter.run_presence(%{session_key: session_key})
                 )
             end)

      refute_receive {:test_executor_started, ^queued_id, _sink, _ref}, 300
      refute LemonRouter.run_active?(queued_id)
      assert %{summary: %{completed: %{ok: false}}} = RunStore.get(queued_id)

      assert {:ok, ^queued_id} = RouterBridge.submit_run(queued)
      refute_receive {:test_executor_started, ^queued_id, _sink, _ref}, 300
      refute LemonRouter.run_active?(queued_id)
    end
  end

  # `RunOrchestrator.submit/2` is this call with the default deadline.
  defp submit_with_deadline(orchestrator, %RunRequest{} = request, timeout_ms) do
    {:ok, settings} = LemonRouter.SubmissionBuilder.admission_settings()
    GenServer.call(orchestrator, {:submit, request, settings}, timeout_ms)
  end

  defp intent(run_id, prompt) do
    RunRequest.new(%{
      run_id: run_id,
      origin: :control_plane,
      session_key: "agent:default:test:#{run_id}",
      agent_id: "default",
      prompt: prompt,
      cwd: File.cwd!(),
      model: "test-model",
      queue_mode: :collect
    })
  end

  defp unique_id(label), do: "run_#{label}_#{System.unique_integer([:positive])}"

  # Hold every global execution permit from processes this test owns.
  defp occupy_all_permits do
    {:ok, %{max: max}} = Slots.stats()
    test = self()

    for n <- 1..max do
      holder =
        spawn_link(fn ->
          :ok = Slots.acquire("permit-holder-#{n}-#{System.unique_integer([:positive])}")

          receive do
            {:slot_granted, permit} ->
              send(test, {:permit_held, self()})

              receive do
                :release -> Slots.release(permit)
              end
          end
        end)

      assert_receive {:permit_held, ^holder}, 5_000
      holder
    end
  end

  defp release_permits(holders), do: Enum.each(holders, &send(&1, :release))

  defp cleanup_run(run_id, session_key) do
    # A failed assertion must not leave a run holding the global permit.
    if pid = RunProcess.whereis(run_id) do
      ref = Process.monitor(pid)
      RunProcess.abort(pid, :test_cleanup)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    LemonCore.Store.delete(RunOrchestrator.admission_table(), run_id)
    LemonCore.Store.delete(RunOrchestrator.abort_tombstone_table(), run_id)
    LemonCore.Store.delete(:run_receipts, run_id)
    RunStore.delete_session(session_key)
  end

  defp eventually(fun, timeout_ms \\ 5_000) do
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
