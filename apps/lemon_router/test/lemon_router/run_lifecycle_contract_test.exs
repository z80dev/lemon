defmodule LemonRouter.RunLifecycleContractTest do
  @moduledoc """
  Router-side proofs for the authoritative run lifecycle (epic #68): a durable
  terminal decision is first-writer-wins, presentation work that runs after it
  cannot change the committed execution outcome, and restart recovery records
  an unknowable outcome instead of re-driving work it cannot resume.
  """
  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event, ExecutionCommand, RunRequest, RunStore, SessionKey, Store}
  alias LemonRouter.RestartCarryover.CrashRecovery
  alias LemonRouter.{RunOrchestrator, RunProcess}

  defmodule RejectingCoalescer do
    @moduledoc false

    def finalize_run(_session_key, _channel_id, _run_id, _opts),
      do: {:error, :injected_coalescer_failure}

    def current_text(_session_key, _channel_id, _run_id), do: nil
  end

  defmodule RejectingDispatcher do
    @moduledoc false

    def dispatch(%LemonCore.DeliveryIntent{} = intent) do
      case :persistent_term.get({__MODULE__, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:dispatch_rejected, intent.kind, intent.run_id})
        _ -> :ok
      end

      {:error, :injected_delivery_failure}
    end
  end

  setup do
    previous =
      Map.new([:stream_coalescer, :dispatcher], &{&1, Application.fetch_env(:lemon_router, &1)})

    on_exit(fn ->
      :persistent_term.erase({RejectingDispatcher, :test_pid})

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_router, key, value)
        {key, :error} -> Application.delete_env(:lemon_router, key)
      end)
    end)

    :ok
  end

  test "a later synthetic terminal decision cannot replace the committed outcome" do
    run_id = "run_lifecycle_#{System.unique_integer([:positive])}"
    session_key = SessionKey.main("lifecycle-agent")
    committed = %{ok: true, answer: "committed answer", run_id: run_id, session_key: session_key}

    :ok =
      RunStore.finalize(run_id, %{
        run_id: run_id,
        session_key: session_key,
        completed: committed,
        engine: "lemon"
      })

    :ok = Bus.subscribe(Bus.session_topic(session_key))
    {:ok, pid} = start_run(run_id, session_key)
    ref = Process.monitor(pid)

    assert_receive %Event{
                     type: :run_completed,
                     meta: %{run_id: ^run_id},
                     payload: %{completed: %{ok: true, answer: "committed answer"}}
                   },
                   2_000

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    refute_received %Event{
      type: :run_completed,
      meta: %{run_id: ^run_id},
      payload: %{completed: %{ok: false}}
    }

    assert {:ok, %{summary: %{completed: ^committed}}} = RunStore.fetch(run_id)
  end

  test "rejected final delivery leaves a completed execution completed" do
    Application.put_env(:lemon_router, :stream_coalescer, RejectingCoalescer)
    Application.put_env(:lemon_router, :dispatcher, RejectingDispatcher)
    :persistent_term.put({RejectingDispatcher, :test_pid}, self())

    run_id = "run_lifecycle_#{System.unique_integer([:positive])}"

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "lifecycle-agent",
        channel_id: "telegram",
        account_id: "lifecycle-bot",
        peer_kind: :dm,
        peer_id: Integer.to_string(System.unique_integer([:positive]))
      })

    :ok = Bus.subscribe(Bus.run_topic(run_id))
    {:ok, pid} = start_run(run_id, session_key)
    ref = Process.monitor(pid)
    assert_receive {:test_executor_started, ^run_id, runner, ^pid}
    LemonRouter.TestExecutor.complete(runner, %{answer: "final answer"})

    assert_receive %Event{
      type: :run_completed,
      payload: %{
        completed:
          %{ok: true, answer: "final answer", run_id: ^run_id, session_key: ^session_key} =
            committed
      }
    }

    # Delivery was attempted and rejected, and the run still ends normally.
    assert_receive {:dispatch_rejected, :final_text, ^run_id}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    refute_received %Event{type: :run_failed, meta: %{run_id: ^run_id}}
    assert {:ok, %{summary: %{completed: ^committed}}} = RunStore.fetch(run_id)
  end

  test "restart recovery records a lost remote invocation as unknown and never re-drives it" do
    set_crash_resume("on")
    run_id = "run_lifecycle_remote_#{System.unique_integer([:positive])}"
    session_key = SessionKey.main("lifecycle-agent")
    admission_row = %{state: "submitting", identity: "remote-identity", scope: %{}}

    on_exit(fn ->
      Enum.each([RunOrchestrator.admission_table(), CrashRecovery.table(), :runs], fn table ->
        :ok = Store.delete(table, run_id)
      end)

      RunStore.delete_session(session_key)
    end)

    request = %RunRequest{
      run_id: run_id,
      session_key: session_key,
      agent_id: "lifecycle-agent",
      prompt: "remote work",
      meta: %{}
    }

    command = %ExecutionCommand{
      run_id: run_id,
      session_key: session_key,
      prompt: "remote work",
      conversation_key: {:session, session_key},
      meta: %{node: "worker-east"}
    }

    :ok = CrashRecovery.capture(%{request: request, execution_request: command}, true)

    assert {:ok, %{state: :unresumable, reason: :remote_invocation}} =
             Store.fetch(CrashRecovery.table(), run_id)

    # The controller died after dispatch: the admission is unfinalized and no
    # local process owns the run.
    :ok = Store.put(RunOrchestrator.admission_table(), run_id, admission_row)
    assert {:ok, :abandoned} = RunOrchestrator.recover_orphan(run_id, admission_row)

    assert {:ok, %{summary: %{completed: completed}}} = RunStore.fetch(run_id)
    assert %{ok: false, error: :outcome_unknown, interrupted: true, outcome: :unknown} = completed
    assert Registry.lookup(LemonRouter.RunRegistry, run_id) == []

    assert {:ok, %{state: :abandoned, reason: :unresumable}} =
             Store.fetch(CrashRecovery.table(), run_id)

    # A second scan converges on the recorded terminal state.
    assert {:ok, :skipped} = RunOrchestrator.recover_orphan(run_id, admission_row)
    assert {:ok, %{summary: %{completed: ^completed}}} = RunStore.fetch(run_id)
  end

  defp set_crash_resume(value) do
    previous = System.get_env("LEMON_FEATURE_CRASH_RESUME")
    System.put_env("LEMON_FEATURE_CRASH_RESUME", value)
    LemonCore.Config.reload()

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_FEATURE_CRASH_RESUME", previous),
        else: System.delete_env("LEMON_FEATURE_CRASH_RESUME")

      LemonCore.Config.reload()
    end)
  end

  defp start_run(run_id, session_key) do
    on_exit(fn ->
      :ok = Store.delete(:runs, run_id)
      RunStore.delete_session(session_key)
    end)

    request = %ExecutionCommand{
      run_id: run_id,
      session_key: session_key,
      prompt: "lifecycle contract",
      conversation_key: {:session, session_key},
      meta: %{test_pid: self()}
    }

    RunProcess.start_link(%{
      run_id: run_id,
      session_key: session_key,
      execution_request: request,
      executor: LemonRouter.TestExecutor
    })
  end
end
