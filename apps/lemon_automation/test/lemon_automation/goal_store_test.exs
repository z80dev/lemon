defmodule LemonAutomation.GoalStoreTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.GoalStore

  setup do
    session_key = "goal-store-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> GoalStore.clear(session_key) end)
    {:ok, session_key: session_key}
  end

  test "terminal loop status retains the judge identity rather than a previous continuation", %{
    session_key: session_key
  } do
    assert {:ok, _} =
             GoalStore.set(session_key, "Verify the completed change",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert {:ok, _} = GoalStore.record_continuation(session_key, "prior_continuation")

    assert {:ok, _} =
             GoalStore.record_loop_status(session_key, :running,
               run_id: "terminal_judge",
               run_kind: "judge"
             )

    assert {:ok, goal} = GoalStore.record_loop_status(session_key, :finished)
    assert goal.last_run_id == "prior_continuation"
    assert goal.meta["goalLoop"]["lastRunId"] == "terminal_judge"
    assert goal.meta["goalLoop"]["lastRunKind"] == "judge"

    assert {:ok, goal} =
             GoalStore.record_loop_verdict(session_key, %{action: :done, source: "manual"})

    refute Map.has_key?(goal.meta["goalLoop"]["lastVerdict"], "runId")
  end

  test "sets, transitions, lists, and clears a goal", %{session_key: session_key} do
    assert {:ok, goal} =
             GoalStore.set(session_key, "Ship Hermes parity",
               agent_id: "default",
               run_id: "run_goal_test",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert goal.session_key == session_key
    assert goal.objective == "Ship Hermes parity"
    assert goal.status == "active"
    assert is_binary(goal.id)

    assert GoalStore.get(session_key).id == goal.id
    assert Enum.any?(GoalStore.list(agent_id: "default"), &(&1.id == goal.id))

    assert {:ok, paused} = GoalStore.pause(session_key)
    assert paused.status == "paused"
    assert is_integer(paused.paused_at_ms)

    assert {:ok, resumed} = GoalStore.resume(session_key)
    assert resumed.status == "active"
    assert resumed.paused_at_ms == nil

    assert {:ok, continued} = GoalStore.record_continuation(session_key, "run_continue")
    assert continued.status == "active"
    assert continued.last_run_id == "run_continue"
    assert continued.continuation_count == 1

    assert {:ok, looped} =
             GoalStore.record_loop_verdict(
               session_key,
               %{action: :continue, reason: "more work remains", source: "test"},
               run_id: "run_continue"
             )

    assert looped.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert looped.meta["goalLoop"]["lastVerdict"]["reason"] == "more work remains"
    assert looped.meta["goalLoop"]["lastVerdict"]["runId"] == "run_continue"
    assert looped.meta["goalLoop"]["verdictCount"] == 1

    assert {:ok, running} = GoalStore.record_loop_status(session_key, :running)
    assert running.meta["goalLoop"]["status"] == "running"
    assert running.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert is_integer(running.meta["goalLoop"]["startedAtMs"])

    assert {:ok, stopped} = GoalStore.record_loop_status(session_key, :stopped)
    assert stopped.meta["goalLoop"]["status"] == "stopped"
    assert stopped.meta["goalLoop"]["lastVerdict"]["action"] == "continue"
    assert is_integer(stopped.meta["goalLoop"]["stoppedAtMs"])

    assert {:ok, auto_goal} =
             GoalStore.configure_loop_auto(session_key, true,
               max_ticks: 2,
               max_continuations: 3,
               interval_ms: 5,
               wait_timeout_ms: 10,
               judge_model: "judge-model",
               judge_failure_policy: :pause,
               model: "worker-model"
             )

    assert auto_goal.meta["goalLoop"]["auto"]["enabled"] == true
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["maxTicks"] == 2
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["maxContinuations"] == 3
    assert auto_goal.meta["goalLoop"]["auto"]["options"]["judgeFailurePolicy"] == "pause"

    assert {:ok, manual_goal} = GoalStore.configure_loop_auto(session_key, false)
    assert manual_goal.meta["goalLoop"]["auto"]["enabled"] == false
    assert manual_goal.meta["goalLoop"]["lastVerdict"]["action"] == "continue"

    assert {:error, :invalid_loop_action} =
             GoalStore.record_loop_verdict(session_key, %{action: :unknown})

    assert {:error, :invalid_loop_status} = GoalStore.record_loop_status(session_key, :unknown)

    assert {:ok, completed} = GoalStore.complete(session_key)
    assert completed.status == "completed"
    assert is_integer(completed.completed_at_ms)

    assert :ok = GoalStore.clear(session_key)
    assert GoalStore.get(session_key) == %{}
  end

  test "diagnostics redacts objectives and raw session ids", %{session_key: session_key} do
    assert {:ok, _goal} =
             GoalStore.set(session_key, "private objective text",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    diagnostics = GoalStore.diagnostics(limit: 10)

    assert diagnostics.count >= 1
    assert diagnostics.active_count >= 1
    assert diagnostics.cleanup.includes_objectives == false
    assert diagnostics.cleanup.includes_raw_session_ids == false

    assert Enum.any?(diagnostics.recent, fn goal ->
             goal.session_hash && goal.objective_bytes == byte_size("private objective text") &&
               goal.loop_auto_enabled == false
           end)

    refute inspect(diagnostics) =~ "private objective text"
    refute inspect(diagnostics) =~ session_key
  end

  test "persists cwd without inventing a nil agent id", %{session_key: session_key} do
    assert {:ok, goal} =
             GoalStore.set(session_key, "Work here",
               cwd: ".",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert goal.cwd == Path.expand(".")
    assert goal.agent_id == nil

    assert {:ok, updated} =
             GoalStore.set(session_key, "Still here",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert updated.cwd == goal.cwd
    assert GoalStore.get(session_key).cwd == goal.cwd
  end

  test "late completion preserves pause and records bounded result once", %{session_key: key} do
    assert {:ok, _} =
             GoalStore.set(key, "Bound results",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert {:ok, _} = GoalStore.record_continuation(key, "run_result")
    assert {:ok, _} = GoalStore.pause(key)

    assert {:ok, goal} =
             GoalStore.record_continuation(key, "run_result",
               completion: {:ok, String.duplicate("x", 9_000)}
             )

    assert goal.status == "paused"
    assert goal.continuation_count == 1
    assert goal.meta["lastResult"]["runId"] == "run_result"
    assert goal.meta["lastResult"]["status"] == "completed"
    assert String.length(goal.meta["lastResult"]["output"]) == 8_000
  end

  test "new run clears prior abort intent", %{session_key: key} do
    assert {:ok, _} =
             GoalStore.set(key, "Restart explicitly",
               authority: LemonAutomation.GoalAuthority.operator()
             )

    assert {:ok, _} =
             GoalStore.record_loop_status(key, :reconciling,
               run_id: "old",
               abort_attempted: true,
               abort_result: :outcome_unknown
             )

    assert {:ok, goal} = GoalStore.record_loop_status(key, :running, run_id: "new")
    assert goal.meta["goalLoop"]["lastRunId"] == "new"
    refute Map.has_key?(goal.meta["goalLoop"], "abortAttempted")
    refute Map.has_key?(goal.meta["goalLoop"], "abortResult")
  end

  test "rejects empty objectives", %{session_key: session_key} do
    assert {:error, :empty_objective} =
             GoalStore.set(session_key, "  ", authority: LemonAutomation.GoalAuthority.operator())
  end

  describe "goal authority" do
    alias LemonAutomation.GoalAuthority

    setup do
      root = Path.join(System.tmp_dir!(), "goal-store-root-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "inner"))
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root} = LemonAutomation.KanbanAuthority.canonical_directory(root)
      %{root: root}
    end

    test "set requires valid recorded authority", %{session_key: key} do
      assert {:error, :goal_authority_missing} = GoalStore.set(key, "No authority")

      assert {:error, :goal_authority_missing} =
               GoalStore.set(key, "Forged", authority: %{"grantedBy" => "operator"})

      assert GoalStore.get(key) == %{}
    end

    test "session authority binds the principal and confines the target", %{
      session_key: key,
      root: root
    } do
      {:ok, other} =
        GoalAuthority.new(%{agent_id: "default", session_key: "other-session"}, nil, root)

      assert {:error, :goal_authority_missing} = GoalStore.set(key, "Work", authority: other)

      {:ok, authority} =
        GoalAuthority.new(
          %{agent_id: "default", session_key: key},
          %{blocked_tools: ["bash"]},
          root
        )

      assert {:error, :workspace_outside_root} =
               GoalStore.set(key, "Work", authority: authority, cwd: Path.dirname(root))

      assert {:error, :workspace_outside_root} =
               GoalStore.set(key, "Work", authority: authority, cwd: "../")

      assert {:ok, goal} =
               GoalStore.set(key, "Work", authority: authority, cwd: "inner", agent_id: "other")

      assert goal.cwd == Path.join(root, "inner")
      assert goal.agent_id == "default"
      assert GoalStore.get(key).authority == authority
    end

    test "restrict_authority narrows policy and root for the goal's own starter only", %{
      session_key: key,
      root: root
    } do
      assert {:ok, _} =
               GoalStore.set(key, "Work",
                 authority: GoalAuthority.operator(),
                 cwd: Path.join(root, "inner")
               )

      # Another session, or the goal's session under another agent, cannot start it.
      assert {:error, :starter_not_permitted} =
               GoalStore.restrict_authority(key, starter("other-session", root, nil))

      {:ok, other_agent} =
        GoalAuthority.new(%{agent_id: "other", session_key: key}, nil, root)

      assert {:error, :starter_not_permitted} = GoalStore.restrict_authority(key, other_agent)

      # A starter whose root does not contain the target cannot start it.
      sibling = Path.join(Path.dirname(root), "sibling-#{System.unique_integer([:positive])}")
      File.mkdir_p!(sibling)
      on_exit(fn -> File.rm_rf!(sibling) end)

      assert {:error, :workspace_outside_root} =
               GoalStore.restrict_authority(key, starter(key, sibling, nil))

      # The goal's own starter narrows the root and policy durably.
      assert {:ok, narrowed} =
               GoalStore.restrict_authority(key, starter(key, root, %{blocked_tools: ["bash"]}))

      {:ok, canonical_root} = LemonAutomation.KanbanAuthority.canonical_directory(root)
      assert narrowed.authority["root"] == canonical_root
      refute narrowed.authority["unrestricted"]
      refute LemonCore.ToolPolicy.allowed?(narrowed.authority["policy"], "bash")

      # A later, stricter starter narrows the root further; a broader one cannot widen it.
      assert {:ok, inner} =
               GoalStore.restrict_authority(key, starter(key, Path.join(root, "inner"), nil))

      assert inner.authority["root"] == Path.join(canonical_root, "inner")
      assert {:ok, still} = GoalStore.restrict_authority(key, starter(key, root, nil))
      assert still.authority["root"] == Path.join(canonical_root, "inner")
      refute LemonCore.ToolPolicy.allowed?(still.authority["policy"], "bash")

      assert {:error, :goal_authority_missing} =
               GoalStore.restrict_authority(key, %{"policy" => %{}})
    end

    # Deterministic interleaving: with the Store suspended, both writers queue
    # their read before either can write, so both compute from the same
    # snapshot. A last-writer-wins store would drop one of the two updates.
    for writer <- [:pause, :resume, :loop_status, :loop_auto, :continuation, :verdict] do
      @tag writer: writer
      test "a concurrent #{writer} never overwrites a narrowed authority", %{
        session_key: key,
        root: root,
        writer: writer
      } do
        {:ok, authority} = GoalAuthority.new(%{agent_id: "default", session_key: key}, nil, root)
        assert {:ok, _} = GoalStore.set(key, "Work", authority: authority)
        if writer == :resume, do: assert({:ok, _} = GoalStore.pause(key))

        assert [{:ok, _}, {:ok, _}] =
                 race([
                   fn -> write(writer, key) end,
                   fn ->
                     GoalStore.restrict_authority(
                       key,
                       starter(key, root, %{blocked_tools: ["bash"]})
                     )
                   end
                 ])

        goal = GoalStore.get(key)
        assert written?(writer, goal)
        refute LemonCore.ToolPolicy.allowed?(goal.authority["policy"], "bash")
      end
    end
  end

  defp starter(key, root, policy) do
    {:ok, starter} =
      LemonAutomation.GoalAuthority.new(
        %{agent_id: "default", session_key: key},
        policy,
        root
      )

    starter
  end

  defp write(:pause, key), do: GoalStore.pause(key)
  defp write(:resume, key), do: GoalStore.resume(key)
  defp write(:loop_status, key), do: GoalStore.record_loop_status(key, :error, error: "x")
  defp write(:loop_auto, key), do: GoalStore.configure_loop_auto(key, true)
  defp write(:continuation, key), do: GoalStore.record_continuation(key, "run_race")
  defp write(:verdict, key), do: GoalStore.record_loop_verdict(key, %{action: :continue})

  defp written?(:pause, goal), do: goal.status == "paused"
  defp written?(:resume, goal), do: goal.status == "active"
  defp written?(:loop_status, goal), do: goal.meta["goalLoop"]["status"] == "error"
  defp written?(:loop_auto, goal), do: goal.meta["goalLoop"]["auto"]["enabled"] == true
  defp written?(:continuation, goal), do: goal.last_run_id == "run_race"
  defp written?(:verdict, goal), do: goal.meta["goalLoop"]["verdictCount"] == 1

  defp race(funs) do
    store = Process.whereis(LemonCore.Store)
    :ok = :sys.suspend(store)

    tasks =
      try do
        tasks = Enum.map(funs, &Task.async/1)
        wait_until(fn -> Enum.all?(tasks, &queued_call?(store, &1.pid)) end)
        tasks
      after
        :ok = :sys.resume(store)
      end

    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp queued_call?(store, pid) do
    {:messages, messages} = Process.info(store, :messages)
    Enum.any?(messages, &match?({:"$gen_call", {^pid, _}, _}, &1))
  end

  defp wait_until(fun, attempts \\ 500) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("writers did not queue their reads")
      true -> Process.sleep(2) && wait_until(fun, attempts - 1)
    end
  end
end
