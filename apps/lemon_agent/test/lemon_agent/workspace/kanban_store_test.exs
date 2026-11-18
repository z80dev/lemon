defmodule LemonAgent.Workspace.KanbanStoreTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.KanbanStore

  setup do
    on_exit(fn ->
      KanbanStore.list_boards(limit: 100)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
    end)

    :ok
  end

  test "exhausted board acquisition preserves the lock error and does not lease a task" do
    assert {:ok, board} = KanbanStore.create_board("Contended board")
    assert {:ok, task} = KanbanStore.create_task(board.id, "Must not be leased")
    lock = {{KanbanStore, board.id}, self()}
    assert :global.set_lock(lock, [node()], 0)

    try do
      contender = Task.async(fn -> KanbanStore.lease_task(board.id, "contending-worker") end)
      assert {:error, :lock_aborted} = Task.await(contender, 10_000)
      assert KanbanStore.get_task(task.id) == task
    after
      :global.del_lock(lock, [node()])
    end

    assert {:ok, leased} = KanbanStore.lease_task(board.id, "successful-worker")
    assert leased.id == task.id
  end

  test "workflow checkpoint is lease-bound and cancellation cannot be cleared by late writes" do
    {:ok, board} = KanbanStore.create_board("Review gate", meta: %{"codingWorkflow" => %{}})
    {:ok, task} = KanbanStore.create_task(board.id, "Reviewed change")
    {:ok, leased} = KanbanStore.lease_task(board.id, "worker")
    lease_id = leased.meta["kanbanLease"]["id"]
    assert {:error, :stale_lease} = KanbanStore.checkpoint_leased_workflow(task.id, "wrong", %{})

    checkpoint = %{
      "phase" => "completed",
      "commitSha" => String.duplicate("a", 40),
      "review" => %{"approved" => true}
    }

    assert {:ok, _} =
             KanbanStore.checkpoint_leased_workflow(
               task.id,
               lease_id,
               Map.put(checkpoint, "cancelRequested", true)
             )

    assert {:ok, late} = KanbanStore.checkpoint_leased_workflow(task.id, lease_id, checkpoint)
    assert late.meta["codingWorkflow"]["cancelRequested"]
    assert {:error, :review_required} = KanbanStore.complete_leased_task(task.id, lease_id)
    assert {:error, :task_leased} = KanbanStore.update_task(task.id, status: "done")
  end

  test "creates boards, moves tasks, comments, lists, archives, and clears" do
    assert {:ok, board} =
             KanbanStore.create_board("Hermes parity",
               workspace: "/tmp/lemon",
               owner: "codex",
               columns: ["todo", "doing", "blocked", "done"]
             )

    assert board.name == "Hermes parity"
    assert board.status == "active"
    assert board.columns == ["todo", "doing", "blocked", "done"]

    assert KanbanStore.get_board(board.id).id == board.id
    assert Enum.any?(KanbanStore.list_boards(owner: "codex"), &(&1.id == board.id))

    assert {:ok, task} =
             KanbanStore.create_task(board.id, "Build board store",
               description: "private details",
               assignee: "sonnet",
               worker_profile: "junior",
               depends_on: ["task-a", "task-a", ""]
             )

    assert task.status == "todo"
    assert task.depends_on == ["task-a"]
    assert KanbanStore.get_task(task.id).id == task.id

    assert {:ok, doing} =
             KanbanStore.update_task(task.id,
               status: "doing",
               priority: "high"
             )

    assert doing.status == "doing"
    assert doing.priority == "high"

    assert {:ok, commented} =
             KanbanStore.add_comment(task.id, "Needs live proof", author: "codex")

    assert length(commented.comments) == 1
    assert hd(commented.comments)["body"] == "Needs live proof"

    assert {:ok, done} = KanbanStore.update_task(task.id, %{status: "done"})
    assert done.status == "done"
    assert is_integer(done.completed_at_ms)

    assert [%{id: task_id}] = KanbanStore.list_tasks(board.id, status: "done")
    assert task_id == task.id

    assert {:ok, archived} = KanbanStore.archive_board(board.id)
    assert archived.status == "archived"
    assert is_integer(archived.archived_at_ms)

    assert :ok = KanbanStore.clear_board(board.id)
    assert KanbanStore.get_board(board.id) == %{}
    assert KanbanStore.get_task(task.id) == %{}
  end

  test "diagnostics redacts task contents and raw session ids" do
    assert {:ok, board} = KanbanStore.create_board("Secret board", workspace: "/private/repo")

    assert {:ok, task} =
             KanbanStore.create_task(board.id, "Secret task", description: "private description")

    assert {:ok, _task} = KanbanStore.add_comment(task.id, "private comment")
    {:ok, leased} = KanbanStore.lease_task(board.id, "dispatcher")

    {:ok, %{session_key: "session-secret"}} =
      KanbanStore.track_leased_run(task.id, leased.meta["kanbanLease"]["id"], "run_secret", %{
        "sessionKey" => "session-secret"
      })

    diagnostics = KanbanStore.diagnostics(limit: 10)

    assert diagnostics.board_count >= 1
    assert diagnostics.task_count >= 1
    assert diagnostics.cleanup.includes_titles == false
    assert diagnostics.cleanup.includes_descriptions == false
    assert diagnostics.cleanup.includes_comments == false
    assert diagnostics.cleanup.includes_raw_session_ids == false

    refute inspect(diagnostics) =~ "Secret task"
    refute inspect(diagnostics) =~ "private description"
    refute inspect(diagnostics) =~ "private comment"
    refute inspect(diagnostics) =~ "session-secret"
  end

  test "validates board and task input" do
    assert {:error, :empty_name} = KanbanStore.create_board("  ")
    assert {:error, :board_not_found} = KanbanStore.create_task("missing", "Task")

    assert {:ok, board} = KanbanStore.create_board("Validation", columns: ["todo", "done"])
    assert {:error, :empty_title} = KanbanStore.create_task(board.id, " ")
    assert {:error, :invalid_status} = KanbanStore.create_task(board.id, "Task", status: "review")
  end

  test "leases dependency-unblocked tasks and reclaims expired leases" do
    assert {:ok, board} =
             KanbanStore.create_board("Leases", columns: ["todo", "doing", "blocked", "done"])

    assert {:ok, dependency} = KanbanStore.create_task(board.id, "Dependency")

    assert {:ok, dependent} =
             KanbanStore.create_task(board.id, "Dependent", depends_on: [dependency.id])

    assert {:ok, leased} = KanbanStore.lease_task(board.id, "worker-a", lease_ms: 1)
    assert leased.id == dependency.id
    assert leased.status == "doing"
    assert leased.meta["kanbanLease"]["workerId"] == "worker-a"

    assert {:error, :no_available_task} = KanbanStore.lease_task(board.id, "worker-b")

    Process.sleep(2)

    assert {:ok, [reclaimed]} = KanbanStore.reclaim_expired_leases(board.id)
    assert reclaimed.id == dependency.id
    assert reclaimed.status == "todo"
    refute Map.has_key?(reclaimed.meta, "kanbanLease")

    assert {:ok, leased_again} = KanbanStore.lease_task(board.id, "worker-b")
    assert leased_again.id == dependency.id

    assert {:ok, completed} =
             KanbanStore.complete_leased_task(
               dependency.id,
               leased_again.meta["kanbanLease"]["id"],
               run_id: "run_done"
             )

    assert completed.status == "done"
    assert completed.run_id == "run_done"
    refute Map.has_key?(completed.meta, "kanbanLease")

    assert {:ok, next} = KanbanStore.lease_task(board.id, "worker-c")
    assert next.id == dependent.id

    assert {:ok, failed} =
             KanbanStore.fail_leased_task(
               dependent.id,
               next.meta["kanbanLease"]["id"],
               "needs human",
               worker_id: "worker-c"
             )

    assert failed.status == "blocked"
    assert failed.meta["lastFailure"]["reason"] == "needs human"
    refute Map.has_key?(failed.meta, "kanbanLease")
  end

  test "concurrent dispatchers cannot lease the same task more than once" do
    assert {:ok, board} =
             KanbanStore.create_board("Lease contention", columns: ["todo", "doing", "done"])

    assert {:ok, task} = KanbanStore.create_task(board.id, "Exactly once")

    parent = self()

    contenders =
      for index <- 1..64 do
        Task.async(fn ->
          send(parent, {:lease_contender_ready, self()})

          receive do
            :lease_now -> KanbanStore.lease_task(board.id, "worker-#{index}")
          end
        end)
      end

    contender_pids =
      for _ <- contenders do
        assert_receive {:lease_contender_ready, pid}, 1_000
        pid
      end

    Enum.each(contender_pids, &send(&1, :lease_now))
    results = Task.await_many(contenders, 5_000)

    assert [{:ok, leased}] = Enum.filter(results, &match?({:ok, _task}, &1))
    assert leased.id == task.id
    assert Enum.count(results, &(&1 == {:error, :no_available_task})) == 63

    persisted = KanbanStore.get_task(task.id)
    assert persisted.meta["kanbanLease"]["id"] == leased.meta["kanbanLease"]["id"]
  end

  test "tracked coding runs survive expiry and restart until exact lease completion" do
    {:ok, board} = KanbanStore.create_board("Tracked work")
    {:ok, task} = KanbanStore.create_task(board.id, "Code")
    {:ok, leased} = KanbanStore.lease_task(board.id, "dispatcher", lease_ms: 1)
    assert leased.assignee == nil
    lease_id = leased.meta["kanbanLease"]["id"]

    assert {:error, :stale_lease} =
             KanbanStore.track_leased_run(task.id, "old-lease", "run_stale")

    {:ok, tracked} =
      KanbanStore.track_leased_run(task.id, lease_id, "run_live", %{
        "cwd" => "/scratch/worktree",
        "branch" => "lemon-kanban/task"
      })

    assert tracked.run_id == "run_live"
    Process.sleep(2)
    assert {:ok, []} = KanbanStore.reclaim_expired_leases(board.id)
    assert {:ok, []} = KanbanStore.reclaim_worker_leases(board.id, "dispatcher")
    assert {:error, :no_available_task} = KanbanStore.lease_task(board.id, "other")
    {:ok, done} = KanbanStore.complete_leased_task(task.id, lease_id, output: "Verified change")
    assert done.meta["kanbanRun"]["output"] == "Verified change"
    assert done.meta["kanbanRun"]["cwd"] == "/scratch/worktree"
    assert done.meta["kanbanRun"]["status"] == "completed"
    refute done.meta["kanbanLease"]
  end

  test "update_task cannot re-point a leased card's run, session or routing" do
    {:ok, board} = KanbanStore.create_board("Hijack guard")
    {:ok, task} = KanbanStore.create_task(board.id, "Leased work")
    {:ok, leased} = KanbanStore.lease_task(board.id, "dispatcher")
    lease_id = leased.meta["kanbanLease"]["id"]

    {:ok, tracked} =
      KanbanStore.track_leased_run(task.id, lease_id, "run_live", %{
        "sessionKey" => "agent:default:main:sub:kanban_live"
      })

    for attrs <- [
          %{run_id: "run_other", session_key: "agent:victim:main"},
          %{"runId" => "run_other"},
          %{sessionKey: "agent:victim:main"},
          %{meta: %{}},
          %{assignee: "victim"},
          %{description: "new instructions"}
        ] do
      assert {:error, _} = KanbanStore.update_task(task.id, attrs), inspect(attrs)
      assert KanbanStore.get_task(task.id) == tracked
    end

    assert tracked.meta["kanbanRun"]["runId"] == "run_live"
  end

  test "update_task never writes router run or session identity" do
    {:ok, board} = KanbanStore.create_board("Identity guard")
    {:ok, task} = KanbanStore.create_task(board.id, "Idle", session_key: "agent:victim:main")
    assert task.session_key == nil

    assert {:error, _} = KanbanStore.update_task(task.id, run_id: "run_other")
    assert {:error, _} = KanbanStore.update_task(task.id, session_key: "agent:victim:main")
    assert KanbanStore.get_task(task.id) == task
  end

  test "reserved authority and run metadata have a single trusted writer" do
    {:ok, board} =
      KanbanStore.create_board("Reserved",
        meta: %{"kanbanAuthority" => %{"forged" => true}, "deliverTo" => "none"}
      )

    assert board.meta == %{"deliverTo" => "none"}

    {:ok, task} =
      KanbanStore.create_task(board.id, "Forged",
        meta: %{
          "kanbanRun" => %{"sessionKey" => "agent:x:main:sub:kanban_x", "status" => "failed"},
          "kanbanLease" => %{"id" => "lease_forged"},
          "codingWorkflow" => %{"phase" => "completed"},
          "dispatchPolicy" => %{},
          "lastFailure" => %{"reason" => "x"},
          "notes" => "kept"
        }
      )

    assert task.meta == %{"notes" => "kept"}
  end

  test "archive cannot undo a concurrent authority narrowing" do
    root = Path.join(System.tmp_dir!(), "kanban-archive-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, authority} =
      LemonAgent.Workspace.KanbanAuthority.new(
        %{agent_id: "default", session_key: "agent:default:main"},
        nil,
        root
      )

    {:ok, board} = KanbanStore.create_board("Archive race", workspace: root, authority: authority)
    lock = {{KanbanStore, board.id}, self()}
    assert :global.set_lock(lock, [node()], 0)

    try do
      # Archive needs the board lock that guards authority writes: while a
      # narrowing holds it, archive cannot read and then rewrite a stale board.
      archiver = Task.async(fn -> KanbanStore.archive_board(board.id) end)
      assert {:error, :lock_aborted} = Task.await(archiver, 10_000)
      assert KanbanStore.get_board(board.id).status == "active"

      {:ok, _} =
        KanbanStore.restrict_authority(board.id, LemonCore.ToolPolicy.custom(deny: ["bash"]))
    after
      :global.del_lock(lock, [node()])
    end

    assert {:ok, archived} = KanbanStore.archive_board(board.id)
    assert archived.status == "archived"
    refute LemonCore.ToolPolicy.allowed?(archived.meta["kanbanAuthority"]["policy"], "bash")

    refute LemonCore.ToolPolicy.allowed?(
             KanbanStore.get_board(board.id).meta["kanbanAuthority"]["policy"],
             "bash"
           )
  end
end
