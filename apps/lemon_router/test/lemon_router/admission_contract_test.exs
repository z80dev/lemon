defmodule LemonRouter.AdmissionContractTest do
  @moduledoc """
  End-to-end proofs of the run admission contract (epic #67):

    * an acknowledged fixed-ID admission stays discoverable and replays its
      original receipt after a lost acknowledgement (#78, #81);
    * any number of concurrent submissions of one fixed ID start at most one
      execution, and a different command under that ID is a conflict (#79);
    * cancelling accepted work that is still waiting, either in its
      conversation backlog or for a gateway execution permit, means it never
      starts later, and a replay of it never resurrects it (#80).

  The cancellation proofs run the real router admission path (orchestrator,
  coordinator, RunProcess) against the real gateway runtime and permit
  authority. Only the native executor is replaced, so the test observes every
  execution start.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{RouterBridge, RunRequest, RunStore, Store}
  alias LemonGateway.Slots
  alias LemonRouter.{RunOrchestrator, SessionCoordinator}

  @test_pid_key :admission_contract_test_pid

  defmodule GatedExecutor do
    @moduledoc false
    @behaviour LemonGateway.Executor

    @impl true
    def start_run(request, _opts, sink) do
      ref = make_ref()

      case Application.get_env(:lemon_router, :admission_contract_test_pid) do
        pid when is_pid(pid) -> send(pid, {:executor_started, request.run_id, sink, ref})
        _ -> :ok
      end

      {:ok, ref, %{}}
    end

    @impl true
    def cancel(_context), do: :ok

    @impl true
    def steer(_context, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_context, _text), do: {:error, :unsupported}
  end

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
    def init(%{lose_recipient: true} = opts) do
      send(opts[:notify_pid], {:start_attempted, opts[:run_id]})
      Process.exit(opts[:coordinator_pid], :kill)
      {:stop, :recipient_lost}
    end

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
        RunStore.delete_session("agent:default:test:#{run_id}")
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

      try do
        assert {:timeout, _} = catch_exit(RunOrchestrator.submit(orchestrator, intent))
      after
        :ok = :sys.resume(orchestrator)
      end

      # The sender reconciles by replaying the same fixed ID. The replay is
      # serialized behind the original request that is still in flight.
      assert {:ok, %{run_id: ^run_id, state: :accepted, effective_mode: :new_run} = receipt} =
               RunOrchestrator.submit_with_receipt(orchestrator, intent)

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

    test "a lost admission owner fences a delayed recipient before permitting explicit retry",
         %{run_id: run_id, opts: opts} do
      request = intent(run_id, "not yet received")

      coordinator =
        start_supervised!({SessionCoordinator, conversation_key: {:session, request.session_key}})

      sender = start_supervised!({RunOrchestrator, opts}, restart: :temporary)
      sender_ref = Process.monitor(sender)
      :ok = :sys.suspend(coordinator)

      try do
        caller = Task.async(fn -> catch_exit(RunOrchestrator.submit(sender, request)) end)

        assert eventually(fn ->
                 {:messages, messages} = Process.info(coordinator, :messages)

                 Enum.any?(messages, fn
                   {:"$gen_call", _, {:submit_with_receipt, %{run_id: ^run_id}, _}} -> true
                   _ -> false
                 end)
               end)

        assert {:ok, %{state: :outcome_unknown}} = RunOrchestrator.run_receipt(run_id)
        Process.exit(sender, :kill)
        assert_receive {:DOWN, ^sender_ref, :process, ^sender, :killed}, 1_000
        assert {:killed, _} = Task.await(caller, 1_000)
        assert {:ok, %{state: :rejected}} = RunOrchestrator.run_receipt(run_id)
      after
        :ok = :sys.resume(coordinator)
      end

      assert 0 = GenServer.call(coordinator, :pending_count, 1_000)
      refute_receive {:execution_started, ^run_id, _}, 100

      replacement = start_supervised!({RunOrchestrator, opts}, id: :handoff_replacement)
      assert {:ok, ^run_id} = RunOrchestrator.submit(replacement, request)
      assert_receive {:execution_started, ^run_id, _}, 1_000
      assert {:ok, %{state: :accepted}} = RunOrchestrator.run_receipt(run_id)
      assert {:ok, ^run_id} = RunOrchestrator.submit(replacement, request)
      refute_receive {:execution_started, ^run_id, _}, 100
    end

    test "recipient loss after crossing the handoff never authorizes another start",
         %{run_id: run_id, opts: opts} do
      request = intent(run_id, "recipient crashes in start")
      opts = put_in(opts[:run_process_opts][:lose_recipient], true)
      sender = start_supervised!({RunOrchestrator, opts})

      assert {:error, :outcome_unknown} = RunOrchestrator.submit(sender, request)
      assert_receive {:start_attempted, ^run_id}, 1_000

      assert {:ok, %{state: :terminal}} = RunOrchestrator.run_receipt(run_id)
      assert %{summary: %{completed: %{outcome: :unknown}}} = RunStore.get(run_id)
      assert {:ok, ^run_id} = RunOrchestrator.submit(sender, request)
      refute_receive {:start_attempted, ^run_id}, 100
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
              {:lemon_gateway, :executor},
              {:lemon_router, :engine_runtime},
              {:lemon_router, @test_pid_key}
            ],
            do: {app, key, Application.fetch_env(app, key)}

      Application.put_env(:lemon_gateway, :executor, GatedExecutor)
      Application.put_env(:lemon_router, :engine_runtime, LemonGateway.Runtime)
      Application.put_env(:lemon_router, @test_pid_key, self())

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
               is_pid(LemonGateway.Runtime.run_pid(id)) and
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
               LemonGateway.Runtime.run_pid(id) == nil and not LemonRouter.run_active?(id)
             end)

      release_permits(holders)
      refute_receive {:executor_started, ^id, _sink, _ref}, 300
      assert %{summary: %{completed: %{ok: false}}} = RunStore.get(id)

      # A late replay of the cancelled intent is acknowledged, never re-executed.
      assert {:ok, ^id} = RouterBridge.submit_run(waiting)
      assert {:ok, %{run_id: ^id, state: :accepted}} = RouterBridge.run_receipt(id)
      refute_receive {:executor_started, ^id, _sink, _ref}, 300
      refute LemonRouter.run_active?(id)
    end

    for cancel <- [:cast, :tombstone] do
      test "work cancelled by #{cancel} in its conversation backlog never starts" do
        cancel = unquote(cancel)
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
        assert_receive {:executor_started, ^active_id, sink, ref}, 2_000

        assert {:ok, ^queued_id} = RouterBridge.submit_run(queued)

        assert {:ok, %{state: :accepted, effective_mode: :queued}} =
                 RouterBridge.run_receipt(queued_id)

        case cancel do
          :cast ->
            assert :ok = RouterBridge.abort_run(queued_id, :user_requested)

          :tombstone ->
            # The fence is durable but the recipient never got its cancellation cast.
            assert :ok =
                     Store.put(
                       Store,
                       RunOrchestrator.abort_tombstone_table(),
                       queued_id,
                       %{state: "aborted", reason_code: :user_requested},
                       durable: true
                     )

            send(sink, {:engine_event, ref, completed_event()})
        end

        assert_receive %LemonCore.Event{
                         type: :run_completed,
                         meta: %{run_id: ^queued_id},
                         payload: %{completed: %{ok: false}}
                       },
                       2_000

        if cancel == :cast, do: send(sink, {:engine_event, ref, completed_event()})

        assert eventually(fn ->
                 not LemonRouter.run_active?(active_id) and
                   match?(
                     {:ok, %{presence: %{idle: true}}},
                     LemonRouter.run_presence(%{session_key: session_key})
                   )
               end)

        refute_receive {:executor_started, ^queued_id, _sink, _ref}, 300
        refute LemonRouter.run_active?(queued_id)
        assert %{summary: %{completed: %{ok: false}}} = RunStore.get(queued_id)

        assert {:ok, ^queued_id} = RouterBridge.submit_run(queued)
        refute_receive {:executor_started, ^queued_id, _sink, _ref}, 300
        refute LemonRouter.run_active?(queued_id)
      end
    end
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

  defp completed_event,
    do: LemonGateway.Event.completed(%{engine: "lemon", ok: true, answer: "done"})

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
    LemonGateway.Runtime.cancel_by_run_id(run_id, :test_cleanup)
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
