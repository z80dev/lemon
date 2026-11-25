defmodule CodingAgent.StoreOwnerRestartTest do
  @moduledoc """
  Durable store owners keep live state across a crash (their ETS heir hands
  the mirror back) and apply restart normalization only at boot.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.{
    BashExecutor,
    JoinAwait,
    ProcessStore,
    ProcessStoreServer,
    RunGraph,
    RunGraphServer,
    TaskStore,
    TaskStoreServer
  }

  @moduletag :tmp_dir

  test "killing TaskStoreServer mid-run keeps live tasks running and accepts their finishes" do
    running = TaskStore.new_task(%{description: "live child"})
    :ok = TaskStore.mark_running(running)
    queued = TaskStore.new_task(%{description: "queued child"})

    kill_and_await_restart(CodingAgent.Supervisor, TaskStoreServer)

    assert {:ok, %{status: :running}, _} = TaskStore.get(running)
    assert {:ok, %{status: :queued}, _} = TaskStore.get(queued)

    :ok = TaskStore.finish(running, %{answer: "done"})
    assert {:ok, %{status: :completed, result: %{answer: "done"}}, _} = TaskStore.get(running)

    # The reclaimed mirror's expiry index was rebuilt for terminal rows.
    :ok =
      TaskStoreServer.insert_record(
        "expired-#{running}",
        %{id: "expired-#{running}", status: :completed, completed_at: 1},
        []
      )

    assert {:ok, deleted} = TaskStoreServer.cleanup(TaskStoreServer, 60)
    assert deleted >= 1
    assert {:error, :not_found} = TaskStore.get("expired-#{running}")
    assert {:ok, %{status: :completed}, _} = TaskStore.get(running)
  end

  test "killing RunGraphServer keeps queued and running runs without normalization" do
    queued = RunGraph.new_run(%{type: :agent})
    running = RunGraph.new_run(%{type: :agent})
    :ok = RunGraph.mark_running(running)

    kill_and_await_restart(CodingAgent.Supervisor, RunGraphServer)

    assert {:ok, %{status: :queued}} = RunGraph.get(queued)
    assert {:ok, %{status: :running}} = RunGraph.get(running)
    assert :ok = RunGraph.finish(running, :ok)
    assert {:ok, %{status: :completed}} = RunGraph.get(running)
  end

  test "a queued run becomes lost at boot and a sync join returns instead of hanging" do
    queued = RunGraph.new_run(%{type: :agent})
    parent = self()

    # A join already waiting when its coordination owner goes away returns.
    waiter =
      spawn(fn ->
        send(parent, {:joined_before, JoinAwait.await([queued], [], :wait_all, nil)})
      end)

    wait_until(fn -> waiting_in_receive?(waiter) end)

    assert :ok = Supervisor.terminate_child(CodingAgent.Supervisor, RunGraphServer)
    assert {:ok, _pid} = Supervisor.restart_child(CodingAgent.Supervisor, RunGraphServer)

    assert_receive {:joined_before, {:error, :coordination_owner_down}}, 5_000

    assert {:ok, %{status: :lost, error: :lost_on_restart} = lost} = RunGraph.get(queued)
    assert is_integer(lost.completed_at)

    # The boot outcome is persisted, so another boot does not reopen it.
    assert [{^queued, %{status: :lost, error: :lost_on_restart}}] =
             :dets.lookup(:coding_agent_run_graph_dets, queued)

    assert {:ok, %{mode: :wait_all, runs: [%{status: :lost}]}} =
             JoinAwait.await([queued], [], :wait_all, nil)
  end

  test "a stale queued run is marked lost by the sweep instead of hanging forever" do
    stale = RunGraph.new_run(%{type: :agent})
    old = System.system_time(:second) - 8 * 86_400

    :ok =
      RunGraphServer.insert_record(stale, %{
        id: stale,
        status: :queued,
        inserted_at: old,
        updated_at: old,
        children: []
      })

    {:ok, _count} = RunGraphServer.cleanup(RunGraphServer, 86_400)

    assert {:ok, %{status: :lost, error: :stale}} = RunGraph.get(stale)

    assert {:ok, %{runs: [%{status: :lost}]}} =
             JoinAwait.await([stale], [], :wait_all, nil, timeout_ms: 1_000)
  end

  test "killing ProcessStoreServer does not kill a running foreground bash", ctx do
    manager = Process.whereis(CodingAgent.ProcessManager)
    marker = Path.join(ctx.tmp_dir, "started")
    parent = self()

    command =
      "touch #{BashExecutor.shell_escape(marker)}; sleep 1; echo foreground-finished"

    runner =
      Task.async(fn ->
        result = BashExecutor.execute(command, ctx.tmp_dir, timeout: 30_000)
        send(parent, :bash_returned)
        result
      end)

    wait_until(fn -> File.exists?(marker) end)
    kill_and_await_restart(CodingAgent.ProcessSupervisor, ProcessStoreServer)

    assert {:ok, %{exit_code: 0, output: output}} = Task.await(runner, 30_000)
    assert output =~ "foreground-finished"
    assert Process.whereis(CodingAgent.ProcessManager) == manager
  end

  test "ProcessStoreServer replies :store_unavailable for unavailable storage and keeps running",
       ctx do
    locked = Path.join(ctx.tmp_dir, "locked")
    File.mkdir_p!(locked)

    assert :ok = Supervisor.terminate_child(CodingAgent.ProcessSupervisor, ProcessStoreServer)

    on_exit(fn ->
      File.chmod(locked, 0o700)
      _ = Supervisor.restart_child(CodingAgent.ProcessSupervisor, ProcessStoreServer)
    end)

    File.chmod!(locked, 0o500)
    pid = start_supervised!({ProcessStoreServer, dets_path: Path.join(locked, "processes.dets")})
    deadline = System.system_time(:millisecond) + 60_000

    assert {:error, :store_unavailable} =
             ProcessStore.register_launch("unavailable", "owner", "fingerprint", deadline, nil)

    assert {:error, :store_unavailable} = ProcessStore.insert_record("unavailable", %{}, [])
    assert catch_exit(ProcessStore.get("unavailable")) == :store_unavailable
    assert Process.alive?(pid)
    assert ProcessStoreServer.dets_status(pid).info == %{status: :not_initialized}
  end

  defp kill_and_await_restart(supervisor, name) do
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    wait_until(fn ->
      Enum.any?(Supervisor.which_children(supervisor), fn
        {^name, child, _, _} -> is_pid(child) and child != pid
        _ -> false
      end)
    end)

    assert :ok = name.ensure_table(name)
  end

  defp waiting_in_receive?(pid) do
    match?({:status, :waiting}, Process.info(pid, :status))
  end

  defp wait_until(fun, attempts \\ 500) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      true ->
        flunk("condition not reached")
    end
  end
end
