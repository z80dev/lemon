defmodule LemonRouter.CrashRecoveryTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ResumeToken, RunRequest, RunStore, Store}
  alias LemonRouter.{RestartCarryover, RunOrchestrator, RunReceiptStore}
  alias LemonRouter.RestartCarryover.CrashRecovery

  @moduletag :tmp_dir
  @tables [
    :router_run_admissions,
    :router_abort_tombstones,
    :router_restart_carryover,
    :router_crash_recovery
  ]

  defmodule JournalProvider do
    def interrupted_tool_calls(cwd, _resume) do
      CodingAgent.ToolIntent.unknown_calls(Path.join(cwd, "journal.jsonl"))
    end

    def token(cwd) do
      id = :crypto.hash(:sha256, cwd) |> Base.encode16(case: :lower)
      LemonCore.ResumeToken.new("lemon", id)
    end
  end

  defmodule RunningExecution do
    use GenServer, restart: :temporary

    def start_link(%{execution_request: command}), do: start_link(command)

    def start_link(command) do
      GenServer.start_link(__MODULE__, command,
        name:
          {:via, Registry,
           {LemonRouter.RunRegistry, command.run_id, %{session_key: command.session_key}}}
      )
    end

    @impl true
    def init(command) do
      token = JournalProvider.token(command.cwd)
      :ok = LemonRouter.RunOrchestrator.register_native_resume(command.run_id, token)
      send(Application.fetch_env!(:lemon_router, :crash_test_pid), {:execution, self(), command})
      {:ok, command}
    end
  end

  defmodule Coordinator do
    def submit(_key, submission) do
      command = submission.execution_request

      :ok =
        LemonRouter.RunReceiptStore.put(%{
          run_id: command.run_id,
          session_key: command.session_key,
          state: :accepted,
          effective_mode: :new_run,
          target_run_id: command.run_id,
          request_identity: command.meta.router_request_identity
        })

      start(submission)
    end

    def submit_recovered(_key, submission) do
      case start(submission) do
        :ok -> Application.get_env(:lemon_router, :crash_test_ack, :ok)
        error -> error
      end
    end

    def abort_run(_run_id, _reason), do: :ok

    defp start(submission) do
      case DynamicSupervisor.start_child(
             LemonRouter.RunSupervisor,
             {RunningExecution, submission.execution_request}
           ) do
        {:ok, _pid} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  setup %{tmp_dir: dir} do
    apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    env = System.get_env("LEMON_FEATURE_CRASH_RESUME")

    settings = [
      {:lemon_router, :restart_replay_after},
      {:lemon_router, :session_coordinator},
      {:lemon_router, :crash_test_pid},
      {:lemon_router, :crash_test_ack},
      {:lemon_core, :agent_runtime_provider}
    ]

    original =
      Map.new(settings, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)

    Application.put_env(:lemon_router, :restart_replay_after, [])
    :ok = Application.stop(:lemon_router)

    saved =
      Map.new(@tables, fn table ->
        {:ok, rows} = Store.fetch_all(table)
        Enum.each(rows, fn {id, _} -> :ok = Store.delete(table, id) end)
        {table, rows}
      end)

    Application.put_env(:lemon_router, :session_coordinator, Coordinator)
    Application.put_env(:lemon_router, :crash_test_pid, self())
    Application.put_env(:lemon_router, :crash_test_ack, :ok)
    Application.put_env(:lemon_core, :agent_runtime_provider, JournalProvider)
    set_flag("on")
    write_journal(dir)
    {:ok, _} = Application.ensure_all_started(:lemon_router)

    on_exit(fn ->
      :ok = Application.stop(:lemon_router)
      cleanup_runs()
      token = JournalProvider.token(dir)
      :ok = Store.delete(:native_resume_contexts, {token.engine, token.value})

      Enum.each(saved, fn {table, _rows} ->
        {:ok, current} = Store.fetch_all(table)
        Enum.each(current, fn {id, _} -> :ok = Store.delete(table, id) end)
      end)

      Enum.each(original, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)

      if env do
        System.put_env("LEMON_FEATURE_CRASH_RESUME", env)
      else
        System.delete_env("LEMON_FEATURE_CRASH_RESUME")
      end

      LemonCore.Config.reload()
      if MapSet.member?(apps, :lemon_router), do: Application.ensure_all_started(:lemon_router)

      if MapSet.member?(apps, :lemon_router), do: await_replayer()

      Enum.each(saved, fn {table, rows} ->
        Enum.each(rows, fn {id, row} -> :ok = Store.put(table, id, row) end)
      end)
    end)

    %{cwd: dir}
  end

  test "brutal stop resumes once under the same ID and lists unknown journal calls", ctx do
    {request, pid} = start_run(ctx.cwd)
    brutal_restart(pid)

    assert_receive {:execution, resumed, command}, 5_000
    assert command.run_id == request.run_id
    assert command.prompt =~ "bash (unknown-call)"
    assert command.prompt =~ "Do not repeat it automatically"
    refute command.prompt =~ "completed-call"
    assert command.meta.crash_resume
    assert command.meta.restart_attempt == 1
    assert %ResumeToken{} = command.resume
    assert command.resume == JournalProvider.token(ctx.cwd)

    {:ok, admissions} = Store.fetch_all(RunOrchestrator.admission_table())
    assert %{skipped: 1, resumed: 0} = CrashRecovery.reconcile(admissions)
    refute_receive {:execution, _, _}
    assert Process.alive?(resumed)
  end

  test "boot never resumes or abandons a committed run whose live summary was lost", ctx do
    {request, pid} = start_run(ctx.cwd)

    assert :ok =
             RunStore.finalize(request.run_id, %{
               session_key: request.session_key,
               completed: %{ok: true, answer: "committed before VM loss"}
             })

    assert :ok = Store.delete(:runs, request.run_id)
    brutal_restart(pid)
    await_replayer()

    refute_receive {:execution, _, _}
    assert {:ok, %{status: :completed}} = LemonCore.TerminalOutbox.decision(request.run_id)

    assert {:ok, %{terminal: true}} =
             Store.fetch(RunOrchestrator.admission_table(), request.run_id)

    assert {:ok, []} = CrashRecovery.operator_view()
  end

  test "an ambiguous continuation acknowledgement never re-drives in the same boot", ctx do
    {request, pid} = start_run(ctx.cwd)
    Application.put_env(:lemon_router, :crash_test_ack, {:error, :outcome_unknown})
    brutal_restart(pid)
    assert_receive {:execution, resumed, %{run_id: run_id}}, 5_000
    assert run_id == request.run_id
    await_replayer()
    kill_execution(resumed)

    {:ok, admissions} = Store.fetch_all(RunOrchestrator.admission_table())
    assert %{skipped: 1, resumed: 0} = CrashRecovery.reconcile(admissions)
    refute_receive {:execution, _, _}
  end

  test "flag off reconciles the orphan as interrupted with an unknown outcome", ctx do
    {request, pid} = start_run(ctx.cwd)
    set_flag("off")
    brutal_restart(pid)
    await_replayer()

    refute_receive {:execution, _, _}
    assert {:ok, %{summary: %{completed: completed}}} = RunStore.fetch(request.run_id)
    assert completed.error == :outcome_unknown
    assert completed.interrupted
    assert completed.outcome == :unknown
    assert {:ok, [%{state: :abandoned, reason: :disabled}]} = CrashRecovery.operator_view()
  end

  test "an abort tombstone prevents continuation even when enabled", ctx do
    {request, pid} = start_run(ctx.cwd)
    kill_execution(pid)
    :ok = RunOrchestrator.register_abort(request.run_id, :user_requested)
    restart_router()
    await_replayer()

    refute_receive {:execution, _, _}
    assert {:ok, %{summary: %{completed: %{error: :aborted}}}} = RunStore.fetch(request.run_id)
    assert {:ok, [%{reason: :aborted}]} = CrashRecovery.operator_view()
  end

  test "repeated brutal stops consume at most three durable attempts", ctx do
    {request, pid} = start_run(ctx.cwd)

    pid =
      Enum.reduce(1..3, pid, fn attempt, current ->
        brutal_restart(current)
        assert_receive {:execution, resumed, command}, 5_000
        assert command.run_id == request.run_id
        assert command.meta.restart_attempt == attempt
        resumed
      end)

    brutal_restart(pid)
    await_replayer()
    refute_receive {:execution, _, _}

    assert {:ok, [%{state: :abandoned, reason: :attempt_limit, attempts: 3}]} =
             CrashRecovery.operator_view()
  end

  test "carryover and crash scan of the same fixed ID dispatch only once", ctx do
    {request, pid} = start_run(ctx.cwd)

    :ok =
      Store.put(RestartCarryover.table(), {1, 0}, %{
        items: [%{request: request, interrupted_run_id: request.run_id}],
        attempts: 0
      })

    brutal_restart(pid)
    assert_receive {:execution, _, command}, 5_000
    assert command.run_id == request.run_id
    await_replayer()
    refute_receive {:execution, _, _}
    assert {:ok, []} = Store.fetch_all(RestartCarryover.table())
  end

  test "a graceful continuation replaces the orphan scan rather than duplicating it", ctx do
    {request, pid} = start_run(ctx.cwd)
    carried = %{request | run_id: request.run_id <> "_carried"}

    :ok =
      Store.put(RestartCarryover.table(), {1, 0}, %{
        items: [%{request: carried, interrupted_run_id: request.run_id}],
        attempts: 0
      })

    brutal_restart(pid)
    assert_receive {:execution, _, command}, 5_000
    assert command.run_id == carried.run_id
    await_replayer()
    refute_receive {:execution, _, _}
    assert {:ok, [%{reason: :graceful_carryover}]} = CrashRecovery.operator_view()
  end

  test "the real coordinator starts a claimed continuation despite its old receipt", ctx do
    id = "run_crash_coordinator_#{System.unique_integer([:positive])}"

    request = %RunRequest{
      run_id: id,
      session_key: "agent:default:main:#{id}",
      agent_id: "default",
      origin: :control_plane,
      prompt: "A continuation",
      cwd: ctx.cwd,
      meta: %{router_request_identity: "original-identity"}
    }

    {:ok, submission} =
      LemonRouter.SubmissionBuilder.build(request, %{
        run_supervisor: LemonRouter.RunSupervisor,
        run_process_module: RunningExecution,
        run_process_opts: %{}
      })

    :ok = CrashRecovery.capture(submission)

    :ok =
      RunReceiptStore.put(%{
        run_id: id,
        session_key: request.session_key,
        state: :accepted,
        effective_mode: :queued,
        target_run_id: id,
        request_identity: "original-identity"
      })

    assert :ok =
             LemonRouter.SessionCoordinator.submit_recovered(
               submission.conversation_key,
               submission
             )

    assert_receive {:execution, _, %{run_id: ^id}}, 5_000

    assert {:ok, %{effective_mode: :new_run, request_identity: "original-identity"}} =
             RunReceiptStore.fetch(id)
  end

  test "a claim that never crossed dispatch is not automatically executed" do
    id = "run_crash_claim_#{System.unique_integer([:positive])}"

    :ok =
      Store.put(RunOrchestrator.admission_table(), id, %{
        state: "claimed",
        identity: "never-dispatched",
        scope: %{session_key: "agent:default:main:#{id}", agent_id: "default"}
      })

    restart_router()
    await_replayer()
    refute_receive {:execution, _, _}
    assert {:ok, %{summary: %{completed: %{outcome: :not_started}}}} = RunStore.fetch(id)
    assert {:ok, [%{reason: :not_started}]} = CrashRecovery.operator_view()
  end

  test "operator view is capped and never projects private restart requests" do
    Enum.each(1..105, fn index ->
      :ok = CrashRecovery.record("view-#{index}", :abandoned, :disabled, 0)
    end)

    assert {:ok, rows} = CrashRecovery.operator_view(limit: 1_000)
    assert length(rows) == 100

    assert Enum.all?(rows, fn row ->
             Enum.sort(Map.keys(row)) ==
               Enum.sort([:run_id, :state, :reason, :attempts, :updated_at_ms])
           end)
  end

  test "a terminal result written before restart wins over the orphan scan", ctx do
    {request, pid} = start_run(ctx.cwd)
    kill_execution(pid)

    summary = %{
      run_id: request.run_id,
      session_key: request.session_key,
      completed: %{ok: true, answer: "finished"},
      meta: %{}
    }

    :ok = RunStore.finalize(request.run_id, summary)
    restart_router()
    await_replayer()
    refute_receive {:execution, _, _}
    assert {:ok, %{summary: ^summary}} = RunStore.fetch(request.run_id)
  end

  test "a graceful carryover continuation cannot bypass its original abort fence", ctx do
    {request, pid} = start_run(ctx.cwd)
    kill_execution(pid)
    :ok = RunOrchestrator.register_abort(request.run_id, :user_requested)
    carried = %{request | run_id: request.run_id <> "_carried"}

    :ok =
      Store.put(RestartCarryover.table(), {1, 0}, %{
        items: [%{request: carried, interrupted_run_id: request.run_id}],
        attempts: 0
      })

    restart_router()
    await_replayer()
    refute_receive {:execution, _, _}
    assert {:ok, []} = Store.fetch_all(RestartCarryover.table())
  end

  describe "pre-fix channel requests without trusted provenance" do
    test "graceful carryover replay refuses them instead of running them", ctx do
      n = System.unique_integer([:positive])

      legacy = %RunRequest{
        run_id: "run_legacy_carry_#{n}",
        session_key: "agent:default:telegram:default:group:-#{n}:new_reflection",
        agent_id: "default",
        origin: :channel,
        prompt: "Before we start a new session, review the transcript",
        cwd: ctx.cwd,
        meta: %{
          channel_id: "telegram",
          account_id: "default",
          peer: %{kind: :group, id: "-#{n}", thread_id: nil},
          sender: %{id: "100"}
        }
      }

      :ok =
        Store.put(RestartCarryover.table(), {1, 0}, %{
          items: [%{kind: :replay, request: legacy}],
          attempts: 0
        })

      restart_router()
      await_replayer()

      refute_receive {:execution, _, _}
      assert {:ok, []} = Store.fetch_all(RestartCarryover.table())
    end

    test "crash recovery abandons them truthfully instead of running them", ctx do
      {request, pid} = start_channel_run(ctx.cwd)

      assert {:ok, %{request: stored} = descriptor} =
               Store.fetch(CrashRecovery.table(), request.run_id)

      # Shape persisted before channel provenance existed.
      legacy_meta = Map.drop(stored.meta, [:channel_context, :channel_identity])

      :ok =
        Store.put(CrashRecovery.table(), request.run_id, %{
          descriptor
          | request: %{stored | meta: legacy_meta}
        })

      brutal_restart(pid)
      await_replayer()

      refute_receive {:execution, _, _}
      assert {:ok, %{summary: %{completed: completed}}} = RunStore.fetch(request.run_id)
      assert completed.ok == false
      assert completed.interrupted
      assert {:ok, [%{state: :abandoned, reason: :rejected}]} = CrashRecovery.operator_view()
    end
  end

  defp start_channel_run(cwd) do
    n = System.unique_integer([:positive])
    id = "run_crash_channel_#{n}"

    request = %RunRequest{
      run_id: id,
      session_key: "agent:default:telegram:default:group:-#{n}",
      agent_id: "default",
      origin: :channel,
      prompt: "Continue my original work",
      cwd: cwd,
      meta: %{
        channel_id: "telegram",
        account_id: "default",
        peer: %{kind: :group, id: "-#{n}", thread_id: nil},
        sender: %{id: "100"},
        channel_context: %{
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :group,
          peer_id: "-#{n}",
          thread_id: nil
        },
        channel_identity: %{
          channel_id: "telegram",
          sender_id: "100",
          is_bot: false,
          owner?: false,
          verified?: true
        }
      }
    }

    assert {:ok, ^id} = RunOrchestrator.submit(request)
    assert_receive {:execution, pid, _command}, 5_000
    {request, pid}
  end

  defp start_run(cwd) do
    id = "run_crash_#{System.unique_integer([:positive])}"

    request = %RunRequest{
      run_id: id,
      session_key: "agent:default:main:#{id}",
      agent_id: "default",
      origin: :control_plane,
      prompt: "Continue my original work",
      cwd: cwd,
      meta: %{}
    }

    assert {:ok, ^id} = RunOrchestrator.submit(request)
    assert_receive {:execution, pid, _command}, 5_000
    {request, pid}
  end

  defp brutal_restart(pid) do
    kill_execution(pid)
    restart_router()
  end

  defp kill_execution(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp restart_router do
    # :kill above skips every execution terminate callback and graceful drain.
    # The actual applications stop/restart; the durable Store is retained.
    :ok = Application.stop(:lemon_router)
    {:ok, _} = Application.ensure_all_started(:lemon_router)
  end

  defp await_replayer do
    case List.keyfind(
           Supervisor.which_children(LemonRouter.Supervisor),
           LemonRouter.RestartCarryover.Replayer,
           0
         ) do
      {_, pid, _, _} when is_pid(pid) ->
        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000

      _ ->
        :ok
    end
  end

  defp set_flag(value) do
    System.put_env("LEMON_FEATURE_CRASH_RESUME", value)
    LemonCore.Config.reload()
  end

  defp write_journal(cwd) do
    records = [
      %{
        "type" => "session",
        "version" => 3,
        "id" => JournalProvider.token(cwd).value,
        "cwd" => cwd
      },
      intent("unknown-call"),
      intent("completed-call"),
      %{
        "type" => "message",
        "message" => %{"role" => "tool_result", "tool_call_id" => "completed-call"}
      }
    ]

    records =
      records
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        entry |> Map.put_new("id", "entry-#{index}") |> Map.put("timestamp", index)
      end)

    jsonl = Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
    File.write!(Path.join(cwd, "journal.jsonl"), jsonl)
  end

  defp cleanup_runs do
    {:ok, receipts} = Store.fetch_all(:run_receipts)
    {:ok, admissions} = Store.fetch_all(RunOrchestrator.admission_table())
    rows = Map.merge(Map.new(admissions), Map.new(receipts))

    Enum.each(rows, fn {id, record} ->
      if is_binary(id) and String.starts_with?(id, "run_crash_") do
        :ok = Store.delete(:run_receipts, id)
        :ok = Store.delete(:runs, id)
        :ok = Store.delete(:native_resume_contexts, {:run, id})
        session_key = record[:session_key] || get_in(record, [:scope, :session_key])
        RunStore.delete_session(session_key)
      end
    end)
  end

  defp intent(id) do
    %{
      "type" => "custom",
      "customType" => "lemon.tool_intent",
      "data" => %{"toolCallId" => id, "tool" => "bash"}
    }
  end
end
