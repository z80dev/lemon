defmodule LemonControlPlane.Methods.RunPresenceTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.RunsActiveList
  alias LemonCore.{ExecutionCommand, Store}
  alias LemonRouter.{RunOrchestrator, RunProcess, RunReceiptStore, SessionCoordinator, Submission}

  defmodule MetadataBarrier do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      {:ok, _} = Registry.register(LemonRouter.RunRegistry, opts.id, nil)
      {:ok, opts}
    end

    def handle_call(:get_metadata, _from, state) do
      :ok =
        LemonCore.Store.put(LemonRouter.RunOrchestrator.admission_table(), state.admission_id, %{
          state: "submitting",
          identity: "raced",
          scope: %{profile_id: state.profile}
        })

      send(state.test_pid, {:metadata_read, self()})
      {:reply, %{session_key: "arbitrary", profile_id: state.profile, agent_id: "actual"}, state}
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    # Earlier teardown may have stopped runs the registry has not yet dropped.
    await_exited_runs_unregistered()
    original = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      {:ok, backend_state} = LemonCore.Store.EtsBackend.init([])
      %{state | backend: LemonCore.Store.EtsBackend, backend_state: backend_state}
    end)

    on_exit(fn ->
      :sys.replace_state(Store, fn current ->
        Enum.each(current.backend_state, fn {_key, table} -> :ets.delete(table) end)
        original
      end)
    end)

    %{suffix: Integer.to_string(System.unique_integer([:positive]))}
  end

  test "available empty scope is explicitly complete and idle", %{suffix: suffix} do
    assert {:ok, %{"runs" => [], "presence" => presence}} =
             RunsActiveList.handle(%{"profileId" => "empty-#{suffix}"}, %{})

    assert presence == %{
             "active" => 0,
             "queued" => 0,
             "unknown" => 0,
             "idle" => true,
             "complete" => true
           }
  end

  test "missing controller, registry or durable store is UNAVAILABLE, never empty success" do
    for name <- [RunOrchestrator, LemonRouter.RunRegistry, Store] do
      pid = Process.whereis(name)
      Process.unregister(name)

      try do
        assert {:error, {:unavailable, "Run presence is unavailable"}} =
                 RunsActiveList.handle(%{}, %{})
      after
        Process.register(pid, name)
      end
    end
  end

  test "actual active and queued work use executed profile and agent rather than session syntax",
       %{suffix: suffix} do
    key = "agent:misleading:arbitrary-#{suffix}"
    profile = "executed-#{suffix}"
    agent = "actual-agent-#{suffix}"
    conversation = {:session, key}
    first = submission("run_presence_active_#{suffix}", key, conversation, profile, agent)
    second = submission("run_presence_queued_#{suffix}", key, conversation, profile, agent)
    third = submission("run_presence_queued2_#{suffix}", key, conversation, profile, agent)
    {:ok, receipt} = SessionCoordinator.submit_with_receipt(conversation, first)
    {:ok, _} = SessionCoordinator.submit_with_receipt(conversation, second)
    {:ok, _} = SessionCoordinator.submit_with_receipt(conversation, third)
    [{coordinator, _}] = Registry.lookup(LemonRouter.ConversationRegistry, conversation)
    [{run, _}] = Registry.lookup(LemonRouter.RunRegistry, first.run_id)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(LemonRouter.SessionCoordinatorSupervisor, coordinator)
      DynamicSupervisor.terminate_child(LemonRouter.RunSupervisor, run)
    end)

    assert receipt.effective_mode == :new_run

    assert {:ok, result} =
             RunsActiveList.handle(
               %{"profileId" => profile, "agentId" => agent, "limit" => 1},
               %{}
             )

    assert result["presence"] == %{
             "active" => 1,
             "queued" => 2,
             "unknown" => 0,
             "idle" => false,
             "complete" => true
           }

    assert [%{"runId" => id, "profileId" => ^profile, "agentId" => ^agent, "sessionKey" => ^key}] =
             result["runs"]

    assert id == first.run_id
    extra_id = "run_presence_extra_#{suffix}"
    extra = %{first.execution_request | run_id: extra_id}

    start_supervised!(
      {RunProcess,
       run_id: extra_id,
       session_key: key,
       execution_request: extra,
       submit_to_gateway?: false,
       manage_session_registry?: false}
    )

    assert {:ok, %{"runs" => [_], "presence" => %{"active" => 2, "queued" => 2}}} =
             RunsActiveList.handle(%{"profileId" => profile, "limit" => 1}, %{})

    stop_run!(extra_id)

    assert {:ok, %{"presence" => %{"idle" => true}}} =
             RunsActiveList.handle(%{"profileId" => "misleading"}, %{})

    # A duplicated durable receipt/admission must not add another live row.
    :ok =
      Store.put(RunOrchestrator.admission_table(), first.run_id, %{
        state: "accepted",
        identity: "fixed",
        scope: %{profile_id: profile, agent_id: agent, session_key: key}
      })

    assert {:ok, %{"presence" => %{"active" => 1, "queued" => 2, "unknown" => 0}}} =
             RunsActiveList.handle(%{"profileId" => profile}, %{})

    :ok = :sys.suspend(run)

    try do
      assert {:ok, %{"presence" => %{"active" => 1, "queued" => 2, "idle" => false}}} =
               RunsActiveList.handle(%{"profileId" => profile}, %{})
    after
      :sys.resume(run)
    end
  end

  test "unattributed busy metadata and legacy admission fences cannot prove profile idle", %{
    suffix: suffix
  } do
    key = "agent:busy:#{suffix}"
    id = "run_presence_unknown_#{suffix}"

    command = %ExecutionCommand{
      run_id: id,
      session_key: key,
      conversation_key: {:session, key},
      prompt: "private"
    }

    run =
      start_supervised!(
        {RunProcess,
         run_id: id, session_key: key, execution_request: command, submit_to_gateway?: false}
      )

    :ok = :sys.suspend(run)

    try do
      assert {:ok,
              %{
                "runs" => [%{"runId" => ^id, "profileId" => nil}],
                "presence" => %{"unknown" => 1, "active" => 0, "idle" => false}
              }} =
               RunsActiveList.handle(%{"profileId" => "unattributed-#{suffix}"}, %{})
    after
      :sys.resume(run)
    end

    stop_run!(id)

    :ok =
      Store.put(RunOrchestrator.admission_table(), id, %{state: "submitting", identity: "legacy"})

    assert {:ok, %{"runs" => [], "presence" => %{"unknown" => 1, "idle" => false}}} =
             RunsActiveList.handle(%{"profileId" => "unrelated-#{suffix}"}, %{})

    :ok = Store.put(:runs, id, %{summary: %{session_key: key, completed: %{ok: true}}})

    assert {:ok, %{"presence" => %{"unknown" => 0, "idle" => true}}} =
             RunsActiveList.handle(%{"profileId" => "unrelated-#{suffix}"}, %{})
  end

  test "admission changing during live metadata reads invalidates the idle proof", %{
    suffix: suffix
  } do
    profile = "racing-#{suffix}"

    probe =
      start_supervised!(
        {MetadataBarrier,
         %{
           id: "run_barrier_#{suffix}",
           admission_id: "run_raced_#{suffix}",
           profile: profile,
           test_pid: self()
         }}
      )

    assert {:error, {:unavailable, "Run presence is unavailable"}} =
             RunsActiveList.handle(%{"profileId" => profile}, %{})

    assert_receive {:metadata_read, ^probe}, 1_000
  end

  test "scoped unknown admissions survive missing run rows and exclude only known other scopes",
       %{suffix: suffix} do
    id = "run_scoped_unknown_#{suffix}"
    profile = "scope-#{suffix}"

    :ok =
      Store.put(RunOrchestrator.admission_table(), id, %{
        state: "submitting",
        identity: "fixed",
        scope: %{profile_id: profile, agent_id: "actual", session_key: "arbitrary"}
      })

    assert {:ok, %{"presence" => %{"unknown" => 1, "idle" => false}}} =
             RunsActiveList.handle(%{"profileId" => profile}, %{})

    assert {:ok, %{"presence" => %{"unknown" => 0, "idle" => true}}} =
             RunsActiveList.handle(%{"profileId" => "other"}, %{})

    command = %ExecutionCommand{
      run_id: id,
      session_key: "arbitrary",
      prompt: "private",
      meta: %{profile_id: profile, agent_id: "actual"}
    }

    event =
      LemonCore.Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{
          completed: LemonCore.Events.Completion.new(%{ok: true, answer: ""}),
          duration_ms: 0
        }),
        %{run_id: id, session_key: "arbitrary"}
      )

    :ok = LemonRouter.RunCompletion.publish(command, event)
    :ok = Store.delete(:runs, id)

    assert {:ok, %{"presence" => %{"unknown" => 0, "idle" => true}}} =
             RunsActiveList.handle(%{"profileId" => profile}, %{})
  end

  test "accepted merged and steering receipts follow actual target and terminal evidence", %{
    suffix: suffix
  } do
    target = "run_target_#{suffix}"
    profile = "target-profile-#{suffix}"

    :ok =
      Store.put(RunOrchestrator.admission_table(), target, %{
        state: "accepted",
        identity: "target",
        scope: %{profile_id: profile, agent_id: "target", session_key: "arbitrary"}
      })

    for mode <- [:merged, :steer, :redirect, :steer_backlog] do
      id = "run_#{mode}_#{suffix}"

      :ok =
        RunReceiptStore.put(%{
          run_id: id,
          session_key: "another-session",
          profile_id: "source-profile",
          agent_id: "source",
          state: :accepted,
          effective_mode: mode,
          target_run_id: target
        })
    end

    assert {:ok, %{"presence" => %{"unknown" => 1, "idle" => false}}} =
             RunsActiveList.handle(%{"profileId" => profile}, %{})

    assert {:ok, %{"presence" => %{"unknown" => 0, "idle" => true}}} =
             RunsActiveList.handle(%{"profileId" => "source-profile"}, %{})

    :ok = Store.put(:runs, target, %{summary: %{completed: %{ok: true}}})

    assert {:ok, %{"presence" => %{"unknown" => 0, "idle" => true}}} =
             RunsActiveList.handle(%{"profileId" => profile}, %{})

    :ok = RunReceiptStore.retain_terminal_evidence(target)
    :ok = Store.delete(:runs, target)

    assert {:ok, %{"presence" => %{"unknown" => 0, "idle" => true}}} =
             RunsActiveList.handle(%{"profileId" => profile}, %{})
  end

  defp stop_run!(run_id) do
    :ok = stop_supervised!({RunProcess, run_id})
    await_exited_runs_unregistered()
  end

  # Registry drops an exited process's entry only after its partition handles
  # the exit signal. Until then `LemonRouter.active_runs/0`, which reads with
  # `Registry.select/2`, still reports the run as a disappearing, unattributed
  # active run. Presence assertions must not race that cleanup.
  defp await_exited_runs_unregistered(attempts \\ 100) do
    exited =
      LemonRouter.RunRegistry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.reject(fn {_run_id, pid} -> Process.alive?(pid) end)

    cond do
      exited == [] ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        await_exited_runs_unregistered(attempts - 1)

      true ->
        flunk("exited runs remain registered: #{inspect(Enum.map(exited, &elem(&1, 0)))}")
    end
  end

  defp submission(id, key, conversation, profile, agent) do
    command = %ExecutionCommand{
      run_id: id,
      session_key: key,
      conversation_key: conversation,
      prompt: "private content",
      meta: %{profile_id: profile, agent_id: agent}
    }

    Submission.new!(%{
      run_id: id,
      session_key: key,
      conversation_key: conversation,
      queue_mode: :collect,
      execution_request: command,
      run_supervisor: LemonRouter.RunSupervisor,
      run_process_module: RunProcess,
      run_process_opts: %{submit_to_gateway?: false},
      meta: command.meta
    })
  end
end
