defmodule CodingAgent.DurableTableProbeOwner do
  use CodingAgent.DurableTable

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state =
      DurableTable.open(%{}, opts,
        table: :durable_table_probe,
        dets_table: :durable_table_probe_dets,
        path: Keyword.fetch!(opts, :dets_path),
        timestamp: fn {_id, record, _events} ->
          if Process.get(:forbid_expiry_callback), do: raise("sweep scanned a retained row")
          record[:timestamp]
        end,
        ttl_key: :durable_table_probe_ttl,
        interval_key: :durable_table_probe_interval
      )

    {:ok, state}
  end

  @impl true
  def handle_call({:run, fun}, _from, state), do: {:reply, fun.(state), state}
end

defmodule CodingAgent.DurableTableContractTest do
  use ExUnit.Case, async: false

  alias CodingAgent.DurableTable
  alias CodingAgent.ParentQuestionStoreServer
  alias CodingAgent.ProcessStore
  alias CodingAgent.ProcessStoreServer
  alias CodingAgent.RunGraphServer
  alias CodingAgent.TaskProgressBindingServer
  alias CodingAgent.TaskStoreServer

  @stores [
    TaskStoreServer,
    ProcessStoreServer,
    RunGraphServer,
    ParentQuestionStoreServer,
    TaskProgressBindingServer
  ]

  @moduletag :tmp_dir

  setup do
    # These facades intentionally address canonical tables. Stop only their
    # original owners and restore exactly the children that were running.
    running = Enum.filter(@stores, &is_pid(Process.whereis(&1)))

    on_exit(fn ->
      Enum.each(running, fn module ->
        case Supervisor.restart_child(store_supervisor(module), module) do
          {:ok, _pid} -> :ok
          {:error, :running} -> :ok
        end
      end)
    end)

    Enum.each(running, fn module ->
      assert :ok = Supervisor.terminate_child(store_supervisor(module), module)
    end)

    {fixtures, []} =
      Code.eval_file(Path.expand("../fixtures/durable_table_current_format.exs", __DIR__))

    %{fixtures: fixtures}
  end

  defp store_supervisor(ProcessStoreServer), do: CodingAgent.ProcessSupervisor
  defp store_supervisor(_module), do: CodingAgent.Supervisor

  test "current-format DETS files load synchronously without rewriting their tuples", ctx do
    specs = [
      {TaskStoreServer, :tasks, :coding_agent_tasks_dets},
      {ProcessStoreServer, :processes, :coding_agent_processes_dets},
      {RunGraphServer, :runs, :coding_agent_run_graph_dets},
      {ParentQuestionStoreServer, :questions, :coding_agent_parent_questions_dets}
    ]

    Enum.each(specs, fn {module, fixture, dets} ->
      path = Path.join(ctx.tmp_dir, "#{fixture}.dets")
      write_fixture(path, dets, ctx.fixtures[fixture])
      pid = start_supervised!({module, dets_path: path})
      assert :ok = module.ensure_table(pid)
      state = :sys.get_state(pid)
      assert state.loaded_from_dets
      assert :ets.info(state.table, :owner) == pid
      assert :ets.info(state.table, :read_concurrency)

      # Recovery is a projection, not a format migration. Even interrupted rows
      # retain their original disk representation until a domain mutation. The
      # task store's restart outcome (:lost/:interrupted) is that mutation: it is
      # persisted so crash resume (#556) cannot reopen it after another restart.
      Enum.each(ctx.fixtures[fixture], fn row ->
        expected =
          case :ets.lookup(state.table, elem(row, 0)) do
            [{_, %{status: status}, _} = restored]
            when module == TaskStoreServer and status in [:lost, :interrupted] ->
              restored

            _ ->
              row
          end

        assert :dets.lookup(dets, elem(row, 0)) == [expected]
      end)
    end)

    assert [{"task-running", task, [{:text, "retained"}]}] =
             :ets.lookup(TaskStoreServer.table_name(), "task-running")

    assert task.status == :lost
    assert task.error == :lost_on_restart
    assert task.agent_state == :aborted
    refute Map.has_key?(task, :auto_followup_join_tokens)
    assert is_integer(task.completed_at)

    # The in-memory admission queue does not survive a restart, so a queued task
    # can never start; crash resume (#556) settles it as lost with the others.
    for id <- ["task-tracking", "task-background", "task-queued"] do
      assert [{^id, %{status: :lost, error: :lost_on_restart}, []}] =
               :ets.lookup(TaskStoreServer.table_name(), id)
    end

    assert [{"process-running", process, ["new", "old"]}] =
             :ets.lookup(ProcessStoreServer.table_name(), "process-running")

    assert process.status == :lost
    assert process.error == :lost_on_restart
    assert process.output == %{received_bytes: 8, retained_bytes: 4, discarded_bytes: 4}
    assert is_integer(process.completed_at)

    assert [{"process-held", %{status: :lost, launch_classification: :outcome_unknown}, []}] =
             :ets.lookup(ProcessStoreServer.table_name(), "process-held")

    assert %{occupied: 1, unknown: 1, canceled: 1} =
             GenServer.call(ProcessStoreServer, :background_counts)

    assert [
             {"process-queued", %{status: :canceled, launch_reason: :admission_owner_restarted},
              []}
           ] =
             :ets.lookup(ProcessStoreServer.table_name(), "process-queued")

    assert [{"run-running", run}] = :ets.lookup(RunGraphServer.table_name(), "run-running")
    assert run.status == :lost
    assert run.error == :lost_on_restart
    assert run.children == ["run-done"]
    assert run.budget == %{tokens_used: 17}
    assert is_integer(run.completed_at)

    assert [{"question-waiting", question, [{:created, "retained"}]}] =
             :ets.lookup(ParentQuestionStoreServer.table_name(), "question-waiting")

    assert question.status == :error
    assert question.error == :lost_on_restart
    assert is_integer(question.completed_at)

    for {table, rows, id} <- [
          {TaskStoreServer.table_name(), ctx.fixtures.tasks, "task-done"},
          {ProcessStoreServer.table_name(), ctx.fixtures.processes, "process-done"},
          {RunGraphServer.table_name(), ctx.fixtures.runs, "run-done"},
          {ParentQuestionStoreServer.table_name(), ctx.fixtures.questions, "question-done"}
        ] do
      expected = Enum.find(rows, &(elem(&1, 0) == id))
      assert :ets.lookup(table, id) == [expected]
    end

    assert {:ok, 1} = TaskStoreServer.cleanup(TaskStoreServer, 60)
    assert {:ok, 2} = ProcessStoreServer.cleanup(ProcessStoreServer, 60)
    assert {:ok, 1} = RunGraphServer.cleanup(RunGraphServer, 60)
    assert {:ok, 1} = ParentQuestionStoreServer.cleanup(ParentQuestionStoreServer, 60)

    assert [{"process-cleared", _, []}] =
             :ets.lookup(ProcessStoreServer.table_name(), "process-cleared")

    assert [{"process-held", _, []}] =
             :ets.lookup(ProcessStoreServer.table_name(), "process-held")
  end

  test "owner restart recovers unmanaged tails without inventing an admission charge", ctx do
    path = Path.join(ctx.tmp_dir, "restart.dets")
    pid = start_supervised!({ProcessStoreServer, dets_path: path})

    :ok =
      ProcessStoreServer.transaction(pid, fn ->
        ProcessStore.insert_record("tail", %{id: "tail", status: :running}, ["two", "one"])
      end)

    assert :ok = stop_supervised(ProcessStoreServer)
    recovered = start_supervised!({ProcessStoreServer, dets_path: path})
    assert :ok = ProcessStoreServer.ensure_table(recovered)

    assert {:ok, %{status: :lost, error: :lost_on_restart}, ["one", "two"]} =
             ProcessStore.get("tail")

    assert %{occupied: 0, unknown: 0} = GenServer.call(recovered, :background_counts)
  end

  test "sweep touches only expired indexed keys, including with a large retained tail", ctx do
    owner =
      start_supervised!(
        {CodingAgent.DurableTableProbeOwner, dets_path: Path.join(ctx.tmp_dir, "indexed.dets")}
      )

    now = System.system_time(:millisecond)

    :ok =
      run(owner, fn state ->
        for id <- 1..2_000 do
          DurableTable.put(state.table, {"retained-#{id}", %{timestamp: now + 3_600_000}, []})
        end

        DurableTable.put(state.table, {"expired", %{timestamp: 1}, ["retained log"]})
        DurableTable.put(state.table, {"active", %{}, ["not eligible"]})
        Process.put(:forbid_expiry_callback, true)
        :ok
      end)

    # The timestamp callback raises if invoked during cleanup. No retained
    # record or log is read; the deletion callback sees exactly one key.
    parent = self()

    assert 1 ==
             run(owner, fn state ->
               DurableTable.cleanup(state, 60, fn id ->
                 send(parent, {:expired_key, id})
                 DurableTable.delete(state.table, id)
               end)
             end)

    assert_receive {:expired_key, "expired"}
    refute_receive {:expired_key, _}, 0
    assert :ets.info(:durable_table_probe, :size) == 2_001
    assert [] == :dets.lookup(:durable_table_probe_dets, "expired")
    assert 0 == run(owner, &DurableTable.cleanup(&1, 60))
  end

  test "updates, eligibility changes, explicit deletes and clear maintain expiration indexes",
       ctx do
    owner =
      start_supervised!(
        {CodingAgent.DurableTableProbeOwner, dets_path: Path.join(ctx.tmp_dir, "updates.dets")}
      )

    assert 0 ==
             run(owner, fn state ->
               DurableTable.put(state.table, {"updated", %{timestamp: 1}, []})
               DurableTable.put(state.table, {"updated", %{timestamp: 9_999_999_999_999}, []})
               DurableTable.put(state.table, {"active", %{timestamp: 1}, []})
               DurableTable.put(state.table, {"active", %{}, []})
               DurableTable.put(state.table, {"deleted", %{timestamp: 1}, []})
               DurableTable.delete(state.table, "deleted")
               DurableTable.cleanup(state, 60)
             end)

    assert 1 ==
             run(owner, fn state ->
               DurableTable.put(state.table, {"updated", %{timestamp: 1}, []})
               DurableTable.cleanup(state, 60)
             end)

    assert 0 ==
             run(owner, fn state ->
               DurableTable.put(state.table, {"cleared", %{timestamp: 1}, []})
               DurableTable.clear(state)
               DurableTable.cleanup(state, 60)
             end)

    assert :ets.info(:durable_table_probe, :size) == 0
    assert :dets.info(:durable_table_probe_dets, :size) == 0
  end

  test "failed domain deletion remains eligible and retries only on the next sweep", ctx do
    owner =
      start_supervised!(
        {CodingAgent.DurableTableProbeOwner, dets_path: Path.join(ctx.tmp_dir, "refused.dets")}
      )

    assert 0 ==
             run(owner, fn state ->
               DurableTable.put(state.table, {"refused", %{timestamp: 1}, []})
               DurableTable.cleanup(state, 60, fn _id -> {:error, :capture_open} end)
             end)

    assert [{"refused", _, []}] = :ets.lookup(:durable_table_probe, "refused")
    assert 1 == run(owner, &DurableTable.cleanup(&1, 60))
    assert [] == :dets.lookup(:durable_table_probe_dets, "refused")
  end

  test "periodic run graph cleanup is serialized with live writes and has no worker", ctx do
    pid = start_supervised!({RunGraphServer, dets_path: Path.join(ctx.tmp_dir, "sweep.dets")})
    :ok = RunGraphServer.insert_record("same", %{status: :completed, completed_at: 1}, pid)
    assert 1 = :erlang.trace(pid, true, [:procs])

    try do
      send(pid, :cleanup)

      # Same-sender call ordering is a barrier after the sweep. Trace delivery
      # is separately synchronized, so a spawned worker cannot escape detection.
      :ok = RunGraphServer.insert_record("same", %{status: :running}, pid)
      :ok = RunGraphServer.ensure_table(pid)
      ref = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^ref}
      refute_receive {:trace, ^pid, :spawn, _child, _entry}, 0
      assert [{"same", %{status: :running}}] = :ets.lookup(RunGraphServer.table_name(), "same")
      refute Map.has_key?(:sys.get_state(pid), :cleanup_ref)
    after
      :erlang.trace(pid, false, [:procs])
    end
  end

  test "process artifact deletion refusal retains its charge and expiration entry", ctx do
    pid =
      start_supervised!({ProcessStoreServer, dets_path: Path.join(ctx.tmp_dir, "artifact.dets")})

    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    output = Path.join(System.tmp_dir!(), "lemon-process-#{token}.log")
    File.mkdir!(output)
    on_exit(fn -> File.rm_rf!(output) end)

    :ok =
      ProcessStoreServer.transaction(pid, fn ->
        ProcessStore.insert_record(
          "artifact",
          %{
            id: "artifact",
            status: :completed,
            completed_at: 1,
            full_output_path: output,
            output: %{finalized: true, artifact_capacity: 7}
          },
          []
        )
      end)

    # rm of a directory fails, deterministically, without chmod/root behavior.
    assert {:ok, 0} = ProcessStoreServer.cleanup(pid, 60)

    assert {:ok, %{full_output_path: ^output, output: %{artifact_capacity: 7}}, []} =
             ProcessStore.get("artifact")

    File.rmdir!(output)
    assert {:ok, 1} = ProcessStoreServer.cleanup(pid, 60)
    assert {:error, :not_found} = ProcessStore.get("artifact")
    assert [] == :dets.lookup(:coding_agent_processes_dets, "artifact")
  end

  test "idle children stay retained and new turns invalidate old expiration entries", ctx do
    pid = start_supervised!({TaskStoreServer, dets_path: Path.join(ctx.tmp_dir, "idle.dets")})

    :ok =
      TaskStoreServer.insert_record(
        "idle",
        %{id: "idle", status: :completed, agent_state: :idle, completed_at: 1},
        [],
        pid
      )

    assert {:ok, 0} = TaskStoreServer.cleanup(pid, 60)
    assert :ok = TaskStoreServer.begin_agent_turn("idle")
    assert {:ok, 0} = TaskStoreServer.cleanup(pid, 60)

    :ok =
      TaskStoreServer.transition(
        "idle",
        :completed,
        &Map.merge(&1, %{status: :completed, agent_state: :stopped, completed_at: 1}),
        pid
      )

    assert {:ok, 1} = TaskStoreServer.cleanup(pid, 60)
  end

  test "transient bindings share expiration while keeping their secondary index coherent" do
    pid = start_supervised!(TaskProgressBindingServer)
    old = %{child_run_id: "old", task_id: "task", inserted_at_ms: 1, status: :running}
    new = %{child_run_id: "new", task_id: "task", inserted_at_ms: 1, status: :running}
    :ok = TaskProgressBindingServer.put_binding(pid, old)
    :ok = TaskProgressBindingServer.put_binding(pid, new)
    assert {:error, :not_found} = TaskProgressBindingServer.get_by_child_run_id(pid, "old")
    assert {:ok, ^new} = TaskProgressBindingServer.get_by_task_id(pid, "task")
    assert {:ok, 1} = TaskProgressBindingServer.cleanup(pid, 60)
    assert {:error, :not_found} = TaskProgressBindingServer.get_by_task_id(pid, "task")
    assert :ets.info(TaskProgressBindingServer.binding_table_name(), :size) == 0
    assert :ets.info(TaskProgressBindingServer.task_index_table_name(), :size) == 0
    assert :sys.get_state(pid).dets_table == nil

    :ok = TaskProgressBindingServer.put_binding(pid, new)
    :ok = stop_supervised(TaskProgressBindingServer)
    restarted = start_supervised!(TaskProgressBindingServer)
    assert [] == TaskProgressBindingServer.list_all(restarted)
  end

  defp run(owner, fun), do: GenServer.call(owner, {:run, fun}, 30_000)

  defp write_fixture(path, table, rows) do
    assert {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)
    assert :ok = :dets.insert(table, rows)
    assert :ok = :dets.close(table)
  end
end
