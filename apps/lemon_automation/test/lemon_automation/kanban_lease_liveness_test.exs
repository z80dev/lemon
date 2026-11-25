defmodule LemonAutomation.KanbanLeaseLivenessTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.KanbanStore
  alias LemonAutomation.KanbanDispatcher

  setup do
    {:ok, board} = KanbanStore.create_board("lease-liveness")
    {:ok, task} = KanbanStore.create_task(board.id, "long task")
    {:ok, leased} = KanbanStore.lease_task(board.id, "liveness-worker")
    on_exit(fn -> KanbanStore.clear_board(board.id) end)
    %{board: board, task: task, leased: leased, lease_id: leased.meta["kanbanLease"]["id"]}
  end

  test "a monitored live worker renews before expired leases are reclaimed", ctx do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)

    try do
      expire(ctx)
      state = dispatcher_state(ctx, pid, ref)

      assert {:noreply, renewed} =
               KanbanDispatcher.handle_info({:dispatch_tick, ctx.board.id}, state)

      Process.cancel_timer(renewed.boards[ctx.board.id].timer)
      task = KanbanStore.get_task(ctx.task.id)
      assert task.meta["kanbanLease"]["id"] == ctx.lease_id
      assert task.meta["kanbanLease"]["expiresAtMs"] > System.system_time(:millisecond)
      assert {:ok, []} = KanbanStore.reclaim_expired_leases(ctx.board.id)
    after
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  test "a dead worker is not renewed and its persisted lease expires", ctx do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    expire(ctx)
    state = dispatcher_state(ctx, pid, ref)

    assert {:noreply, updated} =
             KanbanDispatcher.handle_info({:dispatch_tick, ctx.board.id}, state)

    Process.cancel_timer(updated.boards[ctx.board.id].timer)
    refute Map.has_key?(KanbanStore.get_task(ctx.task.id).meta, "kanbanLease")
  end

  test "renewal rejects an obsolete lease and restart still reclaims unsubmitted work", ctx do
    assert {:error, :stale_lease} = KanbanStore.renew_task_lease(ctx.task.id, "obsolete")
    assert {:ok, _} = KanbanStore.renew_task_lease(ctx.task.id, ctx.lease_id)
    assert {:ok, [reclaimed]} = KanbanStore.reclaim_worker_leases(ctx.board.id, "liveness-worker")
    assert reclaimed.id == ctx.task.id
  end

  test "renewed tracked runs remain protected on expiry and restart", ctx do
    assert {:ok, _} = KanbanStore.track_leased_run(ctx.task.id, ctx.lease_id, "liveness-run")
    expire(ctx)
    assert {:ok, []} = KanbanStore.reclaim_expired_leases(ctx.board.id)
    assert {:ok, []} = KanbanStore.reclaim_worker_leases(ctx.board.id, "liveness-worker")
    assert KanbanStore.get_task(ctx.task.id).meta["kanbanLease"]["id"] == ctx.lease_id
  end

  defp expire(ctx) do
    assert {:ok, _} =
             KanbanStore.renew_task_lease(ctx.task.id, ctx.lease_id, now_ms: 0, lease_ms: 1)
  end

  defp dispatcher_state(ctx, pid, ref) do
    worker = %{task_id: ctx.task.id, lease_id: ctx.lease_id, pid: pid, board_id: ctx.board.id}

    %{
      refs: %{ref => worker},
      boards: %{
        ctx.board.id => %{
          running: %{ref => worker},
          max_concurrency: 1,
          lease_ms: 300_000,
          interval_ms: 300_000,
          timer: nil
        }
      }
    }
  end
end
