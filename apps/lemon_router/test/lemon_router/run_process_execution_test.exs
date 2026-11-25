defmodule LemonRouter.RunProcessExecutionTest do
  use ExUnit.Case, async: false

  import LemonPlatformTest.Testing.AsyncHelpers, only: [assert_eventually: 1]

  alias CodingAgent.Executor.Event, as: ExecutorEvent
  alias LemonCore.{Bus, Event, ExecutionCommand, ResumeToken, RunStore, Store}
  alias LemonCore.Events.{Completion, Delta, EngineAction, RunCompleted, RunStarted}
  alias LemonRouter.{RunCompletion, RunProcess, RunSupervisor, Slots, TestExecutor}

  defmodule ReportingExecutor do
    @behaviour CodingAgent.Executor.Behaviour

    @impl true
    def start_run(%ExecutionCommand{} = command, opts, sink) do
      send(command.meta.test_pid, {:executor_invoked, command, opts, sink})

      case command.meta[:start_result] do
        :return_error -> {:error, :could_not_start}
        :raise -> raise "could not start"
        :exit -> exit(:could_not_start)
        :malformed -> :invalid
        nil -> TestExecutor.start_run(command, opts, sink)
      end
    end

    @impl true
    defdelegate cancel(ctx), to: TestExecutor
    @impl true
    defdelegate steer(ctx, text), to: TestExecutor
    @impl true
    defdelegate redirect(ctx, text), to: TestExecutor
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    wait_for_slots(0, 0)
    :ok
  end

  test "the executor receives the command unchanged and one permit with the router slot lender" do
    resume = resume_token()
    meta = %{model: "test-model", origin: :api, node: "worker-east"}

    command = command(meta: meta, resume: resume, cwd: File.cwd!(), prompt: "λ\nnotes")
    %{pid: pid} = run = start_owner(command, executor: ReportingExecutor)
    run_id = command.run_id
    cwd = command.cwd

    assert_receive {:executor_invoked, ^command,
                    [cwd: ^cwd, run_id: ^run_id, slot_lender: Slots, canonical_delta: true], ^pid}

    runner = await_runner(run)
    wait_for_slots(1, 0)
    assert claim_holder({:resume, resume.value}) == pid
    refute claim_holder({:session, command.session_key})

    TestExecutor.complete(runner, %{answer: "done", resume: resume})
    assert %{completed: %{ok: true, answer: "done", resume: %{value: token}}} = terminal(run)
    assert token == resume.value
    assert_down(run)
    assert claim_holder({:resume, resume.value}) == nil
    wait_for_slots(0, 0)
  end

  test "empty and long prompts are handed to the executor without rewriting across sequential runs" do
    initial = command()

    for prompt <- ["", String.duplicate("λ ", 25_000)] do
      command = %{initial | run_id: LemonCore.Id.run_id(), prompt: prompt}
      %{pid: pid} = run = start_owner(command, executor: ReportingExecutor)
      assert_receive {:executor_invoked, ^command, _, ^pid}
      runner = await_runner(run)
      TestExecutor.complete(runner, %{answer: "done"})
      assert %{completed: %{ok: true, answer: "done"}} = terminal(run)
      assert_down(run)
    end
  end

  test "a busy resume claim retries without occupying or queuing a permit, then starts" do
    resume = resume_token()
    first = start_owner(command(resume: resume))
    runner = await_runner(first)
    second = start_owner(command(resume: resume))

    assert {:submitting, %{submit_last_error: :session_in_use}} = :sys.get_state(second.pid)
    assert claim_holder({:resume, resume.value}) == first.pid
    wait_for_slots(1, 0)
    assert_not_started(second)

    TestExecutor.complete(runner, %{answer: "first"})
    assert %{completed: %{ok: true}} = terminal(first)
    assert_down(first)

    next_runner = await_runner(second)
    assert claim_holder({:resume, resume.value}) == second.pid
    TestExecutor.complete(next_runner, %{answer: "second"})
    assert %{completed: %{ok: true, answer: "second"}} = terminal(second)
    assert_down(second)
  end

  test "claim contention beyond the deadline publishes exactly one synthetic submission failure" do
    resume = resume_token()
    first = start_owner(command(resume: resume))
    runner = await_runner(first)
    second = start_owner(command(resume: resume), submit_deadline_ms: 250)

    run_id = second.command.run_id

    assert_receive %Event{
                     type: :run_completed,
                     meta: %{run_id: ^run_id, synthetic: true, failure_stage: :runtime_submission},
                     payload: %RunCompleted{
                       completed: %Completion{
                         ok: false,
                         error: %{
                           type: :runtime_submission_failed,
                           reason: :session_in_use,
                           deadline_ms: 250,
                           attempts: attempts
                         }
                       }
                     }
                   },
                   2_000

    assert attempts >= 1
    assert_down(second)
    assert_not_started(second)
    refute_terminal(second)
    wait_for_slots(1, 0)
    assert claim_holder({:resume, resume.value}) == first.pid
    TestExecutor.complete(runner, %{answer: "first"})
    assert %{completed: %{ok: true}} = terminal(first)
    assert_down(first)
  end

  test "an owner retries while the permit authority is absent and starts when it returns" do
    tree = LemonRouter.ConversationSupervisor
    assert :ok = Supervisor.terminate_child(tree, Slots)

    on_exit(fn ->
      unless Process.whereis(Slots), do: Supervisor.restart_child(tree, Slots)
    end)

    run = start_owner(command(), submit_deadline_ms: 1_500)
    assert {:submitting, %{submit_last_error: :runtime_unavailable}} = :sys.get_state(run.pid)
    assert_not_started(run)
    assert {:ok, _pid} = Supervisor.restart_child(tree, Slots)

    runner = await_runner(run)
    TestExecutor.complete(runner, %{answer: "admitted after recovery"})
    assert %{completed: %{ok: true, answer: "admitted after recovery"}} = terminal(run)
    assert_down(run)
    refute_terminal(run)
  end

  test "an already terminal ID is adopted before admission without invoking the executor" do
    command = command()
    summary = commit_terminal(command)
    run = start_owner(command)

    assert_down(run)
    assert_not_started(run)
    refute_terminal(run)
    assert {:ok, %{summary: ^summary}} = RunStore.fetch(command.run_id)
    assert claim_holder({:session, command.session_key}) == nil
    wait_for_slots(0, 0)
  end

  test "an evicted terminal run is never reopened" do
    command = command()
    now = System.system_time(:millisecond)

    # The terminal fence survives retention of the volatile record.
    assert :ok = Store.put(:run_terminals, command.run_id, %{finalized_at_ms: now})
    on_exit(fn -> Store.delete(:run_terminals, command.run_id) end)
    assert {:error, :evicted} = RunStore.fetch(command.run_id)

    run = start_owner(command)
    assert_down(run)
    assert_not_started(run)
    refute_terminal(run)
  end

  test "the durable fence is checked again when a waiting owner receives its permit" do
    permits = hold_permits()
    run = start_owner(command())
    wait_for_waiters(1)
    summary = commit_terminal(run.command)

    Enum.each(permits, &Slots.release/1)

    assert_down(run)
    assert_not_started(run)
    refute_terminal(run)
    assert {:ok, %{summary: ^summary}} = RunStore.fetch(run.command.run_id)
    assert claim_holder({:session, run.command.session_key}) == nil
    wait_for_slots(0, 0)
  end

  test "a bus completion from another terminal writer cancels the executor without a second terminal" do
    run = start_owner(command())
    runner = await_runner(run)
    runner_ref = Process.monitor(runner)
    run_id = run.command.run_id
    pid = run.pid

    event =
      Event.new(
        :run_completed,
        %RunCompleted{
          completed: %Completion{ok: true, answer: "the other writer won"}
        },
        %{run_id: run_id}
      )

    assert {:published, _} = RunCompletion.finalize(run.command, event)
    assert %{completed: %{ok: true, answer: "the other writer won"}} = terminal(run)
    assert_receive {:test_executor_cancel, ^run_id, ^pid}
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, :normal}
    assert_down(run)
    refute_terminal(run)

    assert {:ok, %{summary: %{completed: %{ok: true, answer: "the other writer won"}}}} =
             RunStore.fetch(run_id)

    wait_for_slots(0, 0)
  end

  test "permit admission advances waiting conversations in arrival order" do
    hold_permits(1)
    first = start_owner(command())
    first_runner = await_runner(first)
    second = start_owner(command())
    wait_for_waiters(1)
    third = start_owner(command())
    wait_for_waiters(2)
    assert_not_started(second)
    assert_not_started(third)

    TestExecutor.complete(first_runner, %{answer: "first"})
    second_runner = await_next_runner(second)
    assert %{completed: %{ok: true, answer: "first"}} = terminal(first)
    assert_down(first)
    wait_for_waiters(1)
    assert_not_started(third)

    TestExecutor.complete(second_runner, %{answer: "second"})
    third_runner = await_next_runner(third)
    assert %{completed: %{ok: true, answer: "second"}} = terminal(second)
    assert_down(second)
    TestExecutor.complete(third_runner, %{answer: "third"})
    assert %{completed: %{ok: true, answer: "third"}} = terminal(third)
    assert_down(third)
  end

  test "concurrent owners finish independently and out of start order after a sibling executor dies" do
    with_capacity(3)
    first = start_owner(command())
    first_runner = await_runner(first)
    second = start_owner(command())
    second_runner = await_runner(second)
    third = start_owner(command())
    third_runner = await_runner(third)
    wait_for_slots(3, 0)

    TestExecutor.crash(first_runner, :normal)
    assert %{completed: %{ok: false, error: %{type: :executor_down}}} = terminal(first)
    assert_down(first)
    wait_for_slots(2, 0)
    assert Process.alive?(second_runner)
    assert Process.alive?(third_runner)

    TestExecutor.complete(third_runner, %{answer: "third"})
    assert %{completed: %{ok: true, answer: "third"}} = terminal(third)
    assert_down(third)
    assert Process.alive?(second_runner)
    refute_terminal(second)

    TestExecutor.complete(second_runner, %{answer: "second"})
    assert %{completed: %{ok: true, answer: "second"}} = terminal(second)
    assert_down(second)
    wait_for_slots(0, 0)
  end

  test "the owner requests permit release before publishing completion without blocking on slots" do
    %{pid: pid} = run = start_owner(command())
    runner = await_runner(run)
    wait_for_slots(1, 0)
    {:running, %{slot_ref: permit}} = :sys.get_state(pid)
    assert is_reference(permit)
    test = self()
    assert 1 = :erlang.trace(pid, true, [:send, {:tracer, test}])
    slots = Process.whereis(Slots)
    :ok = :sys.suspend(slots)

    try do
      TestExecutor.complete(runner, %{answer: "done"})
      assert %{completed: %{ok: true, answer: "done"}} = terminal(run)

      first =
        receive do
          {:trace, ^pid, :send, {:"$gen_cast", {:release, ^permit}}, _destination} ->
            :release

          {:trace, ^pid, :send, %Event{type: :run_completed}, ^test} ->
            :completion
        after
          1_000 -> flunk("owner sent neither a permit release nor a completion")
        end

      assert first == :release
      assert_receive {:trace, ^pid, :send, %Event{type: :run_completed}, ^test}

      # Health reads the published counters without calling the suspended authority.
      health = Task.async(&LemonRouter.Health.status/0)
      assert %{ok: true, checks: checks} = Task.await(health, 1_000)
      assert %{ok: true, detail: %{in_flight: 1}} = Enum.find(checks, &(&1.name == "slots"))
    after
      :ok = :sys.resume(slots)
    end

    wait_for_slots(0, 0)
    assert_down(run)
  end

  test "permit authority loss terminalizes running and waiting owners before fresh admission" do
    hold_permits(1)
    running = start_owner(command())
    await_runner(running)
    waiting = start_owner(command())
    wait_for_waiters(1)

    slots = Process.whereis(Slots)
    Process.exit(slots, :kill)

    # The permit monitor and rest-for-one shutdown can race. The monitor
    # reports the outage directly; supervisor shutdown reports owner loss.
    assert %{completed: %{ok: false, error: running_error}} = terminal(running)
    assert running_error in [:runtime_unavailable, :run_owner_terminated]

    assert %{completed: %{ok: false, error: waiting_error}} = terminal(waiting)
    assert waiting_error in [:runtime_unavailable, :run_owner_terminated]

    for %{pid: pid, monitor: monitor} <- [running, waiting] do
      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}
      assert reason in [:normal, :shutdown]
    end

    refute_terminal(running)
    refute_terminal(waiting)
    assert_not_started(waiting)
    assert claim_holder({:session, running.command.session_key}) == nil
    assert claim_holder({:session, waiting.command.session_key}) == nil

    wait_for_slots(0, 0)
    assert_eventually(fn -> is_pid(Process.whereis(RunSupervisor)) end)
    assert Process.whereis(Slots) != slots
    fresh = start_owner(command())
    runner = await_runner(fresh)
    TestExecutor.complete(runner, %{answer: "fresh"})
    assert %{completed: %{ok: true, answer: "fresh"}} = terminal(fresh)
    assert_down(fresh)
  end

  test "a killed owner is not restarted and its session and permit can be reused" do
    run = start_owner(command())
    await_runner(run)
    run_id = run.command.run_id
    key = {:session, run.command.session_key}

    Process.exit(run.pid, :kill)
    assert_down(run, :killed)
    assert_eventually(fn -> claim_holder(key) == nil end)
    wait_for_slots(0, 0)
    assert RunProcess.whereis(run_id) == nil
    refute_received {:test_executor_started, ^run_id, _, _}

    replacement = start_owner(%{run.command | run_id: LemonCore.Id.run_id()})
    runner = await_runner(replacement)
    assert claim_holder(key) == replacement.pid
    TestExecutor.complete(runner, %{answer: "replacement"})
    assert %{completed: %{ok: true, answer: "replacement"}} = terminal(replacement)
    assert_down(replacement)
  end

  test "supervisor shutdown cancels the runner and terminalizes the owner once" do
    %{pid: pid} = run = start_owner(command())
    runner = await_runner(run)
    runner_ref = Process.monitor(runner)
    run_id = run.command.run_id

    assert :ok = DynamicSupervisor.terminate_child(RunSupervisor, pid)
    assert_received {:test_executor_cancel, ^run_id, ^pid}
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, :normal}
    assert_receive %Event{type: :run_failed, meta: %{run_id: ^run_id, synthetic: true}}
    assert %{completed: %{ok: false, error: :run_owner_terminated}} = terminal(run)
    assert_down(run, :shutdown)
    refute_terminal(run)
    wait_for_slots(0, 0)
  end

  test "terminal storage failure releases the claim and permit without publishing or rerunning" do
    run = start_owner(command())
    runner = await_runner(run)
    run_id = run.command.run_id

    # Finalization rejects a row without a summary key. Insert it only after
    # admission so the failure occurs specifically at terminal persistence.
    :ok = Store.put(:runs, run_id, %{events: [], started_at: 0})
    TestExecutor.complete(runner, %{answer: "uncommittable"})

    assert_down(run, :terminal_persistence_failed)
    refute_terminal(run)
    refute_received {:test_executor_started, ^run_id, _, _}
    assert {:ok, record} = RunStore.fetch(run_id)
    refute Map.has_key?(record, :summary)
    assert claim_holder({:session, run.command.session_key}) == nil
    wait_for_slots(0, 0)
    assert RunProcess.whereis(run_id) == nil
  end

  test "cancelling a queued owner withdraws the request without ever starting the executor" do
    permits = hold_permits()
    run = start_owner(command())
    wait_for_waiters(1)
    assert claim_holder({:session, run.command.session_key}) == run.pid

    assert :ok = RunProcess.abort(run.pid, :withdrawn)
    assert %{completed: %Completion{ok: false, error: :withdrawn, meta: meta}} = terminal(run)
    assert %{cancelled: true, cancel_reason: :withdrawn} = meta
    assert_down(run)
    wait_for_waiters(0)
    assert claim_holder({:session, run.command.session_key}) == nil

    Enum.each(permits, &Slots.release/1)
    wait_for_slots(0, 0)
    assert_not_started(run)
    refute_terminal(run)
  end

  test "a cancelling executor drains actions and holds both claim and permit until it exits" do
    resume = resume_token()
    run = start_owner(command(resume: resume, meta: %{test_executor_hold_cancel: true}))
    runner = await_runner(run)
    run_id = run.command.run_id
    pid = run.pid

    TestExecutor.started(runner, resume)
    assert_receive %Event{type: :engine_started, meta: %{run_id: ^run_id}}
    assert :ok = RunProcess.abort(pid, :first_cancel)
    assert_receive {:test_executor_cancel, ^run_id, ^pid}
    assert :ok = RunProcess.abort(pid, :second_cancel)
    assert {:aborting, _} = :sys.get_state(pid)
    refute_received {:test_executor_cancel, ^run_id, ^pid}

    TestExecutor.action(runner, %{id: "tool", title: "finishing", kind: :tool, phase: :completed})

    assert_receive %Event{
      type: :engine_action,
      meta: %{run_id: ^run_id},
      payload: %EngineAction{phase: :completed, action: %{id: "tool"}}
    }

    assert claim_holder({:resume, resume.value}) == pid
    wait_for_slots(1, 0)
    refute_terminal(run)

    TestExecutor.crash(runner, :normal)

    assert %{
             completed: %Completion{
               ok: false,
               error: :first_cancel,
               resume: %{value: token},
               meta: %{cancelled: true, cancel_reason: :first_cancel}
             }
           } = terminal(run)

    assert token == resume.value
    assert_down(run)
    refute_terminal(run)
    assert claim_holder({:resume, resume.value}) == nil
    wait_for_slots(0, 0)
  end

  test "the 15-second drain deadline releases capacity when the executor never exits" do
    run = start_owner(command(meta: %{test_executor_hold_cancel: true}))
    runner = await_runner(run)
    run_id = run.command.run_id
    pid = run.pid
    started_at = System.monotonic_time(:millisecond)

    :ok = RunProcess.abort(pid, :user_requested)
    assert_receive {:test_executor_cancel, ^run_id, ^pid}
    refute_terminal(run, 100)
    assert Process.alive?(runner)
    assert claim_holder({:session, run.command.session_key}) == pid
    assert {:ok, %{in_flight: 1}} = Slots.stats()

    assert %{
             completed: %Completion{
               ok: false,
               error: :user_requested,
               meta: %{cancelled: true, cancel_reason: :user_requested}
             }
           } = terminal(run, 17_000)

    assert System.monotonic_time(:millisecond) - started_at >= 15_000
    assert_down(run)
    assert Process.alive?(runner)
    assert claim_holder({:session, run.command.session_key}) == nil
    wait_for_slots(0, 0)
    refute_terminal(run)
  end

  test "completion received during drain is marked cancelled instead of successful" do
    run = start_owner(command(meta: %{test_executor_hold_cancel: true}))
    runner = await_runner(run)
    run_id = run.command.run_id
    pid = run.pid
    :ok = RunProcess.abort(pid, :stopped)
    assert_receive {:test_executor_cancel, ^run_id, ^pid}
    TestExecutor.complete(runner, %{ok: true, answer: "partial", meta: %{kept: true}})

    cancelled = %Completion{
      ok: false,
      error: :stopped,
      answer: "partial",
      engine: "lemon",
      meta: %{cancelled: true, cancel_reason: :stopped, kept: true}
    }

    assert_receive %Event{type: :engine_completed, meta: %{run_id: ^run_id}, payload: ^cancelled}
    assert %{completed: completed} = terminal(run)
    assert %{completed | run_id: nil, session_key: nil} == cancelled
    assert_down(run)
    refute_terminal(run)
  end

  for {outcome, error} <- [
        return_error: :could_not_start,
        raise: "executor_start_exception: could not start",
        exit: "executor_start_exit: :could_not_start",
        malformed: {:invalid_executor_start_result, :invalid}
      ] do
    test "executor start #{outcome} produces a single durable failed completion" do
      command = command(meta: %{start_result: unquote(outcome)})
      run = start_owner(command, executor: ReportingExecutor)
      run_id = command.run_id
      pid = run.pid
      error = unquote(Macro.escape(error))

      assert_receive {:executor_invoked, ^command, _, ^pid}
      assert_receive %Event{type: :run_started, meta: %{run_id: ^run_id}}

      assert_receive %Event{
                       type: :run_completed,
                       meta: %{run_id: ^run_id, synthetic: true},
                       payload: %RunCompleted{
                         completed: %Completion{ok: false, error: ^error} = completed
                       }
                     },
                     2_000

      assert {:ok, %{summary: %{completed: ^completed}}} = RunStore.fetch(run_id)
      assert_down(run)
      refute_received {:executor_invoked, ^command, _, _}
      refute_terminal(run)
      assert claim_holder({:session, command.session_key}) == nil
      wait_for_slots(0, 0)
    end
  end

  for {reason, class} <- [normal: :normal, killed: :killed, shutdown: :shutdown] do
    test "executor #{reason} DOWN reports the exact redacted classification" do
      run = start_owner(command())
      runner = await_runner(run)

      case unquote(reason) do
        :killed -> Process.exit(runner, :kill)
        :shutdown -> TestExecutor.crash(runner, {:shutdown, "private reason"})
        :normal -> TestExecutor.crash(runner, :normal)
      end

      assert %{
               completed: %Completion{
                 ok: false,
                 error: %{type: :executor_down, reason: unquote(class)}
               }
             } = terminal(run)

      assert_down(run)
      refute_terminal(run)
      assert claim_holder({:session, run.command.session_key}) == nil
      wait_for_slots(0, 0)
    end
  end

  test "the owner publishes ordered executor events, persists their log, and completes with streamed text" do
    command = command(meta: %{origin: :api, model: "test-model", thinking_level: :high})
    watch_run_telemetry(command)
    run = start_owner(command)
    run_id = command.run_id
    session_key = command.session_key
    runner = await_runner(run)

    assert_receive %Event{
      type: :run_started,
      meta: %{run_id: ^run_id, session_key: ^session_key, origin: :api, model: "test-model"},
      payload: %RunStarted{
        run_id: ^run_id,
        session_key: ^session_key,
        engine: "lemon",
        model: "test-model",
        thinking_level: :high
      }
    }

    resume = resume_token()
    value = resume.value
    TestExecutor.started(runner, resume)
    TestExecutor.delta(runner, "first ")
    TestExecutor.delta(runner, "second")

    TestExecutor.action(runner, %{
      id: "file",
      kind: :tool,
      title: "Read",
      phase: :completed,
      ok: true,
      message: "read finished"
    })

    assert_receive %Event{
      type: :engine_started,
      meta: %{run_id: ^run_id},
      payload: %{engine: "lemon", resume: %{engine: "lemon", value: ^value}}
    }

    assert_receive %Event{
      type: :delta,
      meta: %{run_id: ^run_id},
      payload: %Delta{
        run_id: ^run_id,
        seq: 1,
        text: "first ",
        meta: %{session_key: ^session_key}
      }
    }

    assert_receive %Event{
      type: :delta,
      meta: %{run_id: ^run_id},
      payload: %Delta{
        run_id: ^run_id,
        seq: 2,
        text: "second"
      }
    }

    assert_receive %Event{
      type: :engine_action,
      meta: %{run_id: ^run_id},
      payload: %EngineAction{
        engine: "lemon",
        phase: :completed,
        action: %{id: "file", kind: :tool, title: "Read"},
        ok: true,
        message: "read finished"
      }
    }

    {:running, %{run_ref: run_ref}} = :sys.get_state(run.pid)

    for type <- [:checkpoint_created, :checkpoint_restored, :checkpoint_deleted] do
      payload = %{checkpoint_id: "one"}
      send(run.pid, {:engine_checkpoint, run_ref, type, payload})

      assert_receive %Event{
        type: ^type,
        payload: ^payload,
        meta: %{run_id: ^run_id, remote_node: true}
      }
    end

    TestExecutor.complete(runner, %{answer: "", resume: resume})

    assert_receive %Event{
      type: :engine_completed,
      meta: %{run_id: ^run_id},
      payload: %Completion{
        ok: true,
        answer: "",
        resume: %{value: ^value}
      }
    }

    assert_receive %Event{
      type: :run_completed,
      meta: %{run_id: ^run_id, session_key: ^session_key, origin: :api, model: "test-model"},
      payload: %RunCompleted{
        completed:
          %Completion{
            ok: true,
            run_id: ^run_id,
            session_key: ^session_key,
            answer: "first second",
            resume: %{value: ^value}
          } = completed,
        duration_ms: duration_ms
      }
    }

    assert duration_ms >= 0
    assert_received {:run_telemetry, :start, %{ts_ms: ts}, %{origin: :api, engine: "lemon"}}
    assert is_integer(ts)

    assert_received {:run_telemetry, :first_token, %{latency_ms: latency}, _}
    assert latency >= 0
    refute_received {:run_telemetry, :first_token, _, _}
    assert_received {:run_telemetry, :stop, %{duration_ms: ^duration_ms, ok: true}, _}

    assert %{
             summary: %{completed: ^completed, session_key: ^session_key, engine: "lemon"},
             events: [
               %{__event__: :completed, ok: true, answer: ""},
               %{__event__: :action_event, action: %{id: "file"}},
               %{__event__: :started, resume: %{value: ^value}}
             ]
           } = Store.get_run_with_events(run_id)

    assert_down(run)
    refute_terminal(run)
  end

  test "a resume token discovered at start survives a completion with no token" do
    run = start_owner(command())
    runner = await_runner(run)
    run_id = run.command.run_id
    resume = resume_token()
    value = resume.value

    TestExecutor.started(runner, resume)
    assert_receive %Event{type: :engine_started, meta: %{run_id: ^run_id}}
    TestExecutor.complete(runner, %{answer: "done"})
    assert %{completed: %{ok: true, resume: %{value: ^value}}} = terminal(run)
    assert_down(run)
  end

  test "a failure forwards its structured error and latest resume; an explicit answer wins over deltas" do
    run = start_owner(command())
    runner = await_runner(run)
    earlier = resume_token()
    latest = resume_token()
    value = latest.value
    error = %{type: :context_overflow, message: "context window full"}

    TestExecutor.started(runner, earlier)
    TestExecutor.delta(runner, "preliminary")
    TestExecutor.complete(runner, %{ok: false, answer: "final", resume: latest, error: error})

    assert %{completed: %{ok: false, answer: "final", resume: %{value: ^value}, error: ^error}} =
             terminal(run)

    assert_down(run)
  end

  test "messages for an obsolete executor invocation cannot emit or persist anything" do
    run = start_owner(command())
    runner = await_runner(run)
    run_id = run.command.run_id
    old_ref = make_ref()

    send(run.pid, {:engine_delta, old_ref, "stale"})

    send(
      run.pid,
      {:engine_event, old_ref,
       ExecutorEvent.completed(%{
         engine: "lemon",
         ok: false,
         error: :stale
       })}
    )

    send(run.pid, {:engine_checkpoint, old_ref, :checkpoint_created, %{checkpoint_id: "stale"}})
    send(run.pid, :unknown)
    assert {:running, %{delta_seq: 0}} = :sys.get_state(run.pid)
    assert {:ok, nil} = RunStore.fetch(run_id)

    for type <- [:delta, :engine_completed, :checkpoint_created, :run_completed] do
      refute_received %Event{type: ^type, meta: %{run_id: ^run_id}}
    end

    TestExecutor.complete(runner, %{answer: "live"})
    assert %{completed: %{ok: true, answer: "live", resume: nil}} = terminal(run)
    assert_down(run)
  end

  for {mode, redirect, steer, reply, fallback?} <- [
        {:steer, :ok, {:error, :unsupported}, :steer_rejected, true},
        {:steer_backlog, :ok, :ok, :steer_backlog_accepted, true},
        {:steer_backlog, :ok, {:error, :busy}, :steer_backlog_rejected, true},
        {:redirect, {:error, :unsupported}, :ok, :redirect_accepted, true},
        {:redirect, {:error, :unsupported}, {:error, :unsupported}, :redirect_rejected, true},
        {:redirect, {:error, :busy}, :ok, :redirect_rejected, false}
      ] do
    test "#{mode} with redirect #{inspect(redirect)} and steer #{inspect(steer)} replies #{reply}" do
      mode = unquote(mode)
      reply = unquote(reply)

      run =
        start_owner(
          command(
            meta: %{
              test_executor_redirect_result: unquote(Macro.escape(redirect)),
              test_executor_steer_result: unquote(Macro.escape(steer))
            }
          )
        )

      runner = await_runner(run)
      run_id = run.command.run_id
      pid = run.pid
      submission = "queued-submission"
      prompt = "change direction"
      parent = self()

      relay =
        spawn_link(fn ->
          receive do
            {tag, ^submission} -> send(parent, {self(), tag, submission})
          end
        end)

      assert :ok = RunProcess.steer(pid, mode, submission, prompt, relay)

      if unquote(mode == :redirect) do
        assert_receive {:test_executor_redirect, ^run_id, ^prompt, ^pid}
      else
        refute_received {:test_executor_redirect, ^run_id, _, _}
      end

      assert_receive {^relay, ^reply, ^submission}
      assert {:running, _} = :sys.get_state(pid)

      if unquote(fallback?) do
        assert_received {:test_executor_steer, ^run_id, ^prompt, ^pid}
      else
        refute_received {:test_executor_steer, ^run_id, ^prompt, ^pid}
      end

      refute_received {^reply, ^submission}
      TestExecutor.complete(runner, %{answer: "done"})
      assert %{completed: %{ok: true}} = terminal(run)
      assert_down(run)
    end
  end

  test "format_status preserves phase and run identifiers but drops prompts, messages and stack arguments" do
    secret = "PRIVATE-prompt-and-answer-text"
    ids = %{run_id: "run_1", session_key: "sk_1", queue_mode: :collect}

    status = %{
      state: :running,
      data:
        Map.merge(ids, %{
          execution_request: command(prompt: secret),
          accumulated_text: secret,
          control_ctx: %{messages: [secret]}
        }),
      reason: {%RuntimeError{message: secret}, [{__MODULE__, :run, [secret], [line: 1]}]},
      event: {:engine_delta, make_ref(), secret},
      timeouts: [{:state_timeout, :idle}, {{:timeout, secret}, {secret}}],
      queue: [{:cast, {:steer, secret}}],
      postponed: [{:info, secret}],
      log: [{:in, secret}]
    }

    formatted = RunProcess.format_status(status)

    refute inspect(formatted, limit: :infinity, printable_limit: :infinity) =~ secret
    assert formatted.state == :running
    assert formatted.data == ids
    assert formatted.event == :redacted
    assert formatted.timeouts == [{:state_timeout, :idle}, {:redacted, :redacted}]
    assert formatted.queue == []
    assert formatted.postponed == []
    assert formatted.log == []

    assert {%LemonCore.StatusRedaction.RedactedCrashError{}, [{__MODULE__, :run, 1, _}]} =
             formatted.reason
  end

  defp command(opts \\ []) do
    run_id = LemonCore.Id.run_id()
    session_key = "agent:execution-test:main:#{run_id}"
    meta = Map.merge(%{test_pid: self()}, opts[:meta] || %{})

    %ExecutionCommand{
      run_id: run_id,
      session_key: session_key,
      conversation_key: {:session, session_key},
      prompt: Keyword.get(opts, :prompt, "run test"),
      cwd: opts[:cwd],
      resume: opts[:resume],
      meta: meta
    }
  end

  defp resume_token do
    %ResumeToken{engine: "lemon", value: "resume-#{System.unique_integer([:positive])}"}
  end

  defp watch_run_telemetry(command) do
    test = self()
    run_id = command.run_id
    handler = {__MODULE__, run_id}
    events = Enum.map([:start, :first_token, :stop], &[:lemon, :run, &1])

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn
          [:lemon, :run, event], measurements, %{run_id: ^run_id} = metadata, _ ->
            send(test, {:run_telemetry, event, measurements, metadata})

          _, _, _, _ ->
            :ok
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp start_owner(command, opts \\ []) do
    :ok = Bus.subscribe(Bus.run_topic(command.run_id))

    opts =
      Keyword.merge(
        [
          run_id: command.run_id,
          session_key: command.session_key,
          execution_request: command,
          run_watchdog_timeout_ms: 0,
          executor: TestExecutor
        ],
        opts
      )

    assert {:ok, pid} = DynamicSupervisor.start_child(RunSupervisor, {RunProcess, opts})

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(RunSupervisor, pid)
      Store.delete(:runs, command.run_id)
      Store.delete(:run_receipts, command.run_id)
    end)

    %{pid: pid, monitor: Process.monitor(pid), command: command}
  end

  defp await_runner(%{pid: pid, command: %{run_id: run_id}}) do
    assert_receive {:test_executor_started, ^run_id, runner, ^pid}, 2_000
    on_exit(fn -> Process.exit(runner, :kill) end)
    runner
  end

  defp await_next_runner(%{pid: pid, command: %{run_id: run_id}}) do
    assert_receive {:test_executor_started, observed_run_id, runner, observed_pid}, 2_000
    on_exit(fn -> Process.exit(runner, :kill) end)
    assert observed_run_id == run_id
    assert observed_pid == pid
    runner
  end

  defp assert_down(%{pid: pid, monitor: monitor}, reason \\ :normal) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, ^reason}, 2_000
  end

  defp terminal(%{command: %{run_id: run_id}}, timeout \\ 2_000) do
    assert_receive %Event{type: :run_completed, meta: %{run_id: ^run_id}, payload: payload},
                   timeout

    payload
  end

  defp refute_terminal(%{command: %{run_id: run_id}}, timeout \\ 50) do
    refute_receive %Event{type: :run_completed, meta: %{run_id: ^run_id}}, timeout
  end

  defp assert_not_started(%{command: %{run_id: run_id}}) do
    refute_received {:test_executor_started, ^run_id, _, _}
    refute_received %Event{type: :run_started, meta: %{run_id: ^run_id}}
  end

  defp commit_terminal(command) do
    summary = %{
      run_id: command.run_id,
      session_key: command.session_key,
      completed: %Completion{ok: true, answer: "previously committed"}
    }

    assert :ok = RunCompletion.abandon(command.run_id, summary)

    # Model a notification delivered before this owner can observe it.
    assert :ok = LemonCore.TerminalOutbox.ack(command.run_id, :notification)

    summary
  end

  defp claim_holder(key) do
    case Registry.lookup(LemonRouter.EngineSessionRegistry, key) do
      [{pid, nil}] -> pid
      [] -> nil
    end
  end

  defp with_capacity(max) do
    key = :"Elixir.LemonGateway.Config"
    previous = Application.fetch_env(:lemon_gateway, key)
    assert {:ok, %{max: previous_max}} = Slots.stats()
    reload = Event.new(:config_reloaded, %{reload_id: "run-execution-test"})

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:lemon_gateway, key, config)
        :error -> Application.delete_env(:lemon_gateway, key)
      end

      send(Slots, reload)
      assert_eventually(fn -> match?({:ok, %{max: ^previous_max}}, Slots.stats()) end)
    end)

    config = Map.put(LemonCore.GatewayConfig.load(), :max_concurrent_runs, max)
    Application.put_env(:lemon_gateway, key, config)
    send(Slots, reload)
    assert_eventually(fn -> match?({:ok, %{max: ^max}}, Slots.stats()) end)
  end

  defp hold_permits(leave_free \\ 0) do
    assert {:ok, %{max: max}} = Slots.stats()

    for _ <- List.duplicate(:permit, max - leave_free) do
      assert :ok = Slots.acquire(LemonCore.Id.run_id())
      assert_receive {:slot_granted, permit}, 2_000
      permit
    end
  end

  defp wait_for_waiters(waitq) do
    assert_eventually(fn -> match?({:ok, %{waitq: ^waitq}}, Slots.stats()) end)
  end

  defp wait_for_slots(in_flight, waitq) do
    assert_eventually(fn ->
      match?({:ok, %{in_flight: ^in_flight, waitq: ^waitq}}, Slots.stats())
    end)
  end
end
