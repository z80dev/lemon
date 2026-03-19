defmodule LemonRouter.AsyncTaskSurfaceTest do
  use ExUnit.Case, async: false

  alias LemonRouter.AsyncTaskSurface

  test "surface process can be started and located by surface_id" do
    surface_id = unique_surface_id()

    {:ok, pid} =
      AsyncTaskSurface.ensure_started(surface_id,
        metadata: %{parent_run_id: "parent-run-1", surface: {:status_task, "root-1"}}
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    assert pid == AsyncTaskSurface.whereis(surface_id)
    assert [{^pid, _}] = Registry.lookup(LemonRouter.AsyncTaskSurfaceRegistry, surface_id)

    assert {:ok, snapshot} = AsyncTaskSurface.get(surface_id)
    assert snapshot.surface_id == surface_id
    assert snapshot.status == :pending_root
    assert snapshot.metadata.parent_run_id == "parent-run-1"
    assert snapshot.metadata.surface == {:status_task, "root-1"}
  end

  test "redesign-aligned lifecycle requires binding before live" do
    surface_id = unique_surface_id()
    {:ok, pid} = AsyncTaskSurface.ensure_started(surface_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    assert {:error, {:invalid_transition, :pending_root, :live}} =
             AsyncTaskSurface.transition(surface_id, :live)

    assert {:ok, bound} =
             AsyncTaskSurface.transition(surface_id, :bound, %{
               metadata: %{root_action_id: "tool-call-1"}
             })

    assert bound.status == :bound
    assert bound.terminal_at_ms == nil
    assert bound.metadata.root_action_id == "tool-call-1"

    assert {:ok, live} = AsyncTaskSurface.transition(surface_id, :live)
    assert live.status == :live
    assert live.terminal_at_ms == nil

    assert {:ok, terminal} =
             AsyncTaskSurface.transition(surface_id, :terminal_grace, %{result: %{ok: true}})

    assert terminal.status == :terminal_grace
    assert terminal.result == %{ok: true}
    assert is_integer(terminal.terminal_at_ms)
    assert terminal.error == nil

    assert {:ok, reaped} = AsyncTaskSurface.transition(surface_id, :reaped)
    assert reaped.status == :reaped
    assert reaped.result == %{ok: true}
    assert reaped.terminal_at_ms == terminal.terminal_at_ms
  end

  test ":reaped immediately hides the stale pid and allows a fresh surface to be created" do
    surface_id = unique_surface_id()
    {:ok, pid} = AsyncTaskSurface.ensure_started(surface_id)
    ref = Process.monitor(pid)

    assert {:ok, _bound} = AsyncTaskSurface.transition(surface_id, :bound)
    assert {:ok, _live} = AsyncTaskSurface.transition(surface_id, :live)

    assert {:ok, terminal} =
             AsyncTaskSurface.transition(surface_id, :terminal_grace, %{result: :done})

    assert {:ok, reaped} = AsyncTaskSurface.transition(surface_id, :reaped)

    assert reaped.status == :reaped
    assert reaped.result == :done
    assert reaped.terminal_at_ms == terminal.terminal_at_ms

    assert AsyncTaskSurface.whereis(surface_id) == nil

    assert {:ok, fresh_pid} = AsyncTaskSurface.ensure_started(surface_id)

    on_exit(fn ->
      if Process.alive?(fresh_pid) do
        GenServer.stop(fresh_pid, :normal)
      end
    end)

    assert fresh_pid != pid
    assert AsyncTaskSurface.whereis(surface_id) == fresh_pid
    assert {:ok, fresh} = AsyncTaskSurface.get(surface_id)
    assert fresh.status == :pending_root
    assert fresh.metadata == %{}
    assert fresh.result == nil
    assert fresh.error == nil
    assert fresh.terminal_at_ms == nil

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "concurrent ensure_started waits for a fresh pid while the old reaped child is still exiting" do
    surface_id = unique_surface_id()
    reap_ref = make_ref()

    {:ok, pid} =
      AsyncTaskSurface.ensure_started(surface_id, reap_test_hook: {self(), reap_ref})

    on_exit(fn ->
      send(pid, {:continue_async_task_surface_reap, reap_ref})
    end)

    assert {:ok, _bound} = AsyncTaskSurface.transition(surface_id, :bound)
    assert {:ok, _live} = AsyncTaskSurface.transition(surface_id, :live)
    assert {:ok, _terminal} = AsyncTaskSurface.transition(surface_id, :terminal_grace)

    reaped_task =
      Task.async(fn ->
        AsyncTaskSurface.transition(surface_id, :reaped)
      end)

    assert_receive {:async_task_surface_reap_blocked, ^surface_id, ^pid, ^reap_ref}, 1_000
    assert [{^pid, _}] = Registry.lookup(LemonRouter.AsyncTaskSurfaceRegistry, surface_id)
    assert AsyncTaskSurface.whereis(surface_id) == nil
    assert Process.alive?(pid)

    ensure_task =
      Task.async(fn ->
        AsyncTaskSurface.ensure_started(surface_id)
      end)

    assert Task.yield(ensure_task, 100) == nil

    send(pid, {:continue_async_task_surface_reap, reap_ref})

    assert {:ok, %{status: :reaped}} = Task.await(reaped_task, 1_000)
    assert {:ok, fresh_pid} = Task.await(ensure_task, 1_000)

    on_exit(fn ->
      if Process.alive?(fresh_pid) do
        GenServer.stop(fresh_pid, :normal)
      end
    end)

    assert fresh_pid != pid
    assert AsyncTaskSurface.whereis(surface_id) == fresh_pid
    assert {:ok, %{status: :pending_root}} = AsyncTaskSurface.get(surface_id)
    refute Process.alive?(pid)
  end

  test "registry and supervisor wiring reuse the same child for the same surface_id" do
    surface_id = unique_surface_id()
    assert Process.whereis(LemonRouter.AsyncTaskSurfaceRegistry)
    assert Process.whereis(LemonRouter.AsyncTaskSurfaceSupervisor)

    before_counts = DynamicSupervisor.count_children(LemonRouter.AsyncTaskSurfaceSupervisor)

    {:ok, pid} = AsyncTaskSurface.ensure_started(surface_id)
    {:ok, same_pid} = AsyncTaskSurface.ensure_started(surface_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    after_counts = DynamicSupervisor.count_children(LemonRouter.AsyncTaskSurfaceSupervisor)

    assert pid == same_pid
    assert after_counts.active == before_counts.active + 1
    assert after_counts.workers == before_counts.workers + 1
  end

  test "ensure_started reuses a live surface even while it is temporarily suspended" do
    surface_id = unique_surface_id()
    {:ok, pid} = AsyncTaskSurface.ensure_started(surface_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = safe_resume(pid)

        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        end
      end
    end)

    assert {:ok, _bound} =
             AsyncTaskSurface.transition(surface_id, :bound, %{
               metadata: %{root_action_id: "tool-call-1"}
             })

    assert {:ok, _live} = AsyncTaskSurface.transition(surface_id, :live)
    assert :ok = :sys.suspend(pid)

    try do
      assert AsyncTaskSurface.whereis(surface_id) == pid
      assert {:ok, ^pid} = AsyncTaskSurface.ensure_started(surface_id)
    after
      assert :ok = :sys.resume(pid)
    end
  end

  test "duplicate bound transitions preserve the first identity metadata" do
    surface_id = unique_surface_id()
    {:ok, pid} = AsyncTaskSurface.ensure_started(surface_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    assert {:ok, bound} =
             AsyncTaskSurface.transition(surface_id, :bound, %{
               metadata: %{parent_run_id: "parent-run-1", root_action_id: "tool-call-1"}
             })

    assert {:ok, duplicate} =
             AsyncTaskSurface.transition(surface_id, :bound, %{
               metadata: %{parent_run_id: "parent-run-2", root_action_id: "tool-call-2"}
             })

    assert duplicate == bound
    assert duplicate.metadata == %{parent_run_id: "parent-run-1", root_action_id: "tool-call-1"}
  end

  test "duplicate terminal transitions preserve the first payload" do
    surface_id = unique_surface_id()
    {:ok, pid} = AsyncTaskSurface.ensure_started(surface_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    assert {:ok, _bound} = AsyncTaskSurface.transition(surface_id, :bound)
    assert {:ok, _live} = AsyncTaskSurface.transition(surface_id, :live)

    assert {:ok, terminal} =
             AsyncTaskSurface.transition(surface_id, :terminal_grace, %{error: :timeout})

    assert {:ok, duplicate} =
             AsyncTaskSurface.transition(surface_id, :terminal_grace, %{result: %{ok: true}})

    assert terminal.status == :terminal_grace
    assert terminal.error == :timeout
    assert terminal.result == nil
    assert is_integer(terminal.terminal_at_ms)

    assert duplicate == terminal
  end

  test "duplicate live transitions enrich task metadata without rewriting surface identity" do
    surface_id = unique_surface_id()
    surface = {:status_task, "task-surface-live-enrichment"}

    {:ok, pid} =
      AsyncTaskSurface.ensure_started(surface_id,
        metadata: %{
          surface_id: surface_id,
          surface: surface,
          root_action_id: "task-root-live-enrichment",
          parent_run_id: "parent-run-1",
          session_key: "session-1"
        }
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    assert {:ok, _bound} = AsyncTaskSurface.transition(surface_id, :bound)
    assert {:ok, live} = AsyncTaskSurface.transition(surface_id, :live)
    assert live.metadata[:task_id] == nil
    assert :error = AsyncTaskSurface.lookup_identity_by_task_id("task-live-enrichment-1")

    assert {:ok, enriched_live} =
             AsyncTaskSurface.transition(surface_id, :live, %{
               metadata: %{
                 surface_id: "wrong-surface-id",
                 surface: {:status_task, "wrong-surface"},
                 root_action_id: "wrong-root-action-id",
                 parent_run_id: "parent-run-2",
                 session_key: "session-2",
                 task_id: "task-live-enrichment-1",
                 task_ids: ["task-live-enrichment-1"]
               }
             })

    assert enriched_live.status == :live
    assert enriched_live.metadata.surface_id == surface_id
    assert enriched_live.metadata.surface == surface
    assert enriched_live.metadata.root_action_id == "task-root-live-enrichment"
    assert enriched_live.metadata.parent_run_id == "parent-run-1"
    assert enriched_live.metadata.session_key == "session-1"
    assert enriched_live.metadata.task_id == "task-live-enrichment-1"
    assert enriched_live.metadata.task_ids == ["task-live-enrichment-1"]

    assert {:ok,
            %{
              surface_id: ^surface_id,
              surface: ^surface,
              root_action_id: "task-root-live-enrichment"
            }} = AsyncTaskSurface.lookup_identity_by_task_id("task-live-enrichment-1")
  end

  test "stale pid inputs return not_found instead of crashing" do
    surface_id = unique_surface_id()
    {:ok, pid} = AsyncTaskSurface.ensure_started(surface_id)
    GenServer.stop(pid, :normal)

    assert {:error, :not_found} = AsyncTaskSurface.get(pid)
    assert {:error, :not_found} = AsyncTaskSurface.transition(pid, :bound)
  end

  test "invalid startup metadata returns an actionable error and does not register a surface" do
    surface_id = unique_surface_id()

    assert {:error, {:invalid_metadata, :expected_map_or_key_value_list}} =
             AsyncTaskSurface.ensure_started(surface_id, metadata: "bad")

    assert AsyncTaskSurface.whereis(surface_id) == nil
    assert Registry.lookup(LemonRouter.AsyncTaskSurfaceRegistry, surface_id) == []
  end

  test "invalid transition metadata returns an actionable error without crashing the server" do
    surface_id = unique_surface_id()
    {:ok, pid} = AsyncTaskSurface.ensure_started(surface_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    assert {:error, {:invalid_metadata, :expected_map_or_key_value_list}} =
             AsyncTaskSurface.transition(surface_id, :bound, %{metadata: "bad"})

    assert Process.alive?(pid)
    assert {:ok, snapshot} = AsyncTaskSurface.get(surface_id)
    assert snapshot.status == :pending_root
    assert snapshot.metadata == %{}
  end

  defp unique_surface_id do
    "async-task-surface-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp safe_resume(pid) do
    :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end
end
