defmodule LemonRouter.SessionTransitionsTest do
  use ExUnit.Case, async: true

  alias LemonGateway.ExecutionRequest
  alias LemonRouter.{SessionState, SessionTransitions, Submission}

  test "idle submit queues work and requests start" do
    state = SessionState.new(conversation_key: {:session, "s1"})
    submission = submission("run1", "s1", :collect, "one")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, submission, 100)

    assert next_state.active == nil
    assert Enum.map(next_state.queue, & &1.run_id) == ["run1"]
    assert effects == [:maybe_start_next]
  end

  test "busy submit preserves active and queues the next run" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.submit(state, submission("run2", "s1", :collect, "two"), 100)

    assert next_state.active.run_id == "run1"
    assert Enum.map(next_state.queue, & &1.run_id) == ["run2"]
    assert effects == []
  end

  test "cancel clears queue and pending steers and emits cancel effect when active exists" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [submission("run2", "s1", :collect, "two")],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run3", "s1", :followup, "three"), :followup}]}
    }

    assert {:ok, next_state, effects} = SessionTransitions.cancel(state, :user_requested)

    assert next_state.queue == []
    assert next_state.pending_steers == %{}
    assert effects == [{:cancel_active, :user_requested}]
  end

  test "cancel_session only cancels matching active session and preserves queued work" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "session-a"},
      queue: [
        submission("run2", "session-a", :collect, "two"),
        submission("run3", "session-b", :collect, "three")
      ],
      last_followup_at_ms: nil,
      pending_steers: %{
        "run1" => [
          {submission("run4", "session-a", :followup, "four"), :followup},
          {submission("run5", "session-b", :collect, "five"), :collect}
        ]
      }
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.cancel_session(state, "session-a", :user_requested)

    assert next_state == state
    assert effects == [{:cancel_active, :user_requested}]
  end

  test "abort_session drops queued work and pending steers only for the matching session" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "session-a"},
      queue: [
        submission("run2", "session-a", :collect, "two"),
        submission("run3", "session-b", :collect, "three")
      ],
      last_followup_at_ms: nil,
      pending_steers: %{
        "run1" => [
          {submission("run4", "session-a", :followup, "four"), :followup},
          {submission("run5", "session-b", :collect, "five"), :collect}
        ]
      }
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.abort_session(state, "session-a", :user_requested)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run3"]

    assert next_state.pending_steers == %{
             "run1" => [{submission("run5", "session-b", :collect, "five"), :collect}]
           }

    assert effects == [{:cancel_active, :user_requested}]
  end

  test "active_down clears active, flushes pending steers, and requests next start" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1", pid: self(), mon_ref: make_ref()},
      queue: [submission("run2", "s1", :collect, "two")],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run3", "s1", :collect, "three"), :collect}]}
    }

    %{active: %{pid: pid, mon_ref: mon_ref}} = state

    assert {:ok, next_state, effects} = SessionTransitions.active_down(state, pid, mon_ref)

    assert next_state.active == nil
    assert Enum.map(next_state.queue, & &1.run_id) == ["run2", "run3"]
    assert Enum.at(next_state.queue, 1).meta[:suppress_router_phase_events] == true
    assert effects == [:maybe_start_next]
  end

  test "interrupt prepends and emits interrupted cancellation when active exists" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [submission("run2", "s1", :collect, "two")],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    interrupt = submission("run3", "s1", :interrupt, "urgent")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, interrupt, 100)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run3", "run2"]
    assert effects == [{:cancel_active, :interrupted}]
  end

  test "steer against an active run emits a typed dispatch_steer effect" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    steer = submission("run2", "s1", :steer, "two")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, steer, 100)

    assert next_state.pending_steers == %{"run1" => [{steer, :followup}]}
    assert effects == [{:dispatch_steer, "run1", :steer, steer, :followup}]
  end

  test "steer_backlog against an active run emits collect fallback dispatch" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    steer_backlog = submission("run2", "s1", :steer_backlog, "two")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, steer_backlog, 100)

    assert next_state.pending_steers == %{"run1" => [{steer_backlog, :collect}]}

    assert effects == [
           {:dispatch_steer, "run1", :steer_backlog, steer_backlog, :collect}
           ]
  end

  test "active task auto followups are promoted to steer with followup fallback" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    followup =
      submission("run2", "s1", :followup, "task done",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"}
      )

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, followup, 100)

    assert next_state.pending_steers == %{"run1" => [{%{followup | queue_mode: :steer}, :followup}]}

    assert effects == [
             {:dispatch_steer, "run1", :steer, %{followup | queue_mode: :steer}, :followup}
           ]
  end

  test "rejected steer fallback requeues and only requests start when resulting state is idle" do
    idle_state = %SessionState{
      conversation_key: {:session, "s1"},
      active: nil,
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :steer, "two"), :followup}]}
    }

    assert {:ok, idle_next_state, idle_effects} =
             SessionTransitions.dispatch_steer_failed(idle_state, "run2", 100)

    assert Enum.map(idle_next_state.queue, & &1.run_id) == ["run2"]
    assert hd(idle_next_state.queue).meta[:suppress_router_phase_events] == true
    assert idle_next_state.pending_steers == %{}
    assert idle_effects == [:maybe_start_next]

    busy_state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run3", "s1", :steer, "three"), :followup}]}
    }

    assert {:ok, busy_next_state, busy_effects} =
             SessionTransitions.dispatch_steer_failed(busy_state, "run3", 100)

    assert Enum.map(busy_next_state.queue, & &1.run_id) == ["run3"]
    assert busy_effects == []
  end

  test "regular followups keep scalar metadata merge behavior" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_id: "first", run_id: "run1", source: "left", keep: "left"},
        request_meta: %{task_id: "first", run_id: "run1", source: "left", keep: "left"}
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_id: "second", source: "right", extra: "right"},
        request_meta: %{task_id: "second", source: "right", extra: "right"}
      )

    merged = merge_followups(previous, current)

    assert merged.execution_request.prompt == "part1\npart2"

    assert merged.meta == %{
             task_id: "second",
             run_id: "run1",
             source: "right",
             keep: "left",
             extra: "right"
           }

    assert merged.execution_request.meta == %{
             task_id: "second",
             run_id: "run1",
             source: "right",
             keep: "left",
             extra: "right"
           }
  end

  test "two async followups stay separate within the debounce window" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"}
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"},
        request_meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"}
      )

    next_state = submit_followups(previous, current)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
    assert Enum.at(next_state.queue, 0).meta.task_id == "task-a"
    assert Enum.at(next_state.queue, 1).meta.task_id == "task-b"
  end

  test "async task followups do not merge within the debounce window" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"}
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"},
        request_meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"}
      )

    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: nil,
      queue: [previous],
      last_followup_at_ms: 100,
      pending_steers: %{}
    }

    assert {:ok, next_state, [:maybe_start_next]} = SessionTransitions.submit(state, current, 200)
    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
  end

  test "async delegated followups do not merge with regular followups" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{
          delegated_auto_followup: true,
          delegated_task_id: "task-a",
          delegated_run_id: "run-a",
          delegated_agent_id: "agent-a",
          delegated_session_key: "session-a",
          left: "value"
        },
        request_meta: %{
          delegated_auto_followup: true,
          delegated_task_id: "task-a",
          delegated_run_id: "run-a",
          delegated_agent_id: "agent-a",
          delegated_session_key: "session-a",
          left: "value"
        }
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{kind: "regular", right: "value"},
        request_meta: %{kind: "regular", right: "value"}
      )

    next_state = submit_followups(previous, current)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
    assert Enum.at(next_state.queue, 0).meta.left == "value"
    assert Enum.at(next_state.queue, 1).meta.kind == "regular"
    assert Enum.at(next_state.queue, 1).meta.right == "value"
  end

  test "async followups with duplicate task ids and nil values still stay separate" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: nil},
        request_meta: %{}
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-b"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-b"}
      )

    next_state = submit_followups(previous, current)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
    assert Enum.at(next_state.queue, 0).meta.run_id == nil
    assert Enum.at(next_state.queue, 1).meta.run_id == "run-b"
  end

  test "third async followup appends as a third queued followup" do
    first =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"}
      )

    second =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"},
        request_meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"}
      )

    first_state = submit_followups(first, second)

    third =
      submission("run3", "s1", :followup, "part3",
        meta: %{task_auto_followup: true, task_id: "task-c", run_id: "run-c"},
        request_meta: %{task_auto_followup: true, task_id: "task-c", run_id: "run-c"}
      )

    assert {:ok, next_state, [:maybe_start_next]} = SessionTransitions.submit(first_state, third, 300)
    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2", "run3"]
  end

  test "explicit async_followups metadata also prevents merge with later regular followups" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{
          "async_followups" => [
            %{
              source: :agent,
              task_id: "task-a",
              run_id: "run-a",
              agent_id: "agent-a",
              session_key: "session-a",
              delivery: :router
            }
          ],
          delegated_auto_followup: true,
          delegated_task_id: "task-a",
          delegated_run_id: "run-a",
          delegated_agent_id: "agent-a",
          delegated_session_key: "session-a"
        },
        request_meta: %{
          "async_followups" => [
            %{
              source: :agent,
              task_id: "task-a",
              run_id: "run-a",
              agent_id: "agent-a",
              session_key: "session-a",
              delivery: :router
            }
          ],
          delegated_auto_followup: true,
          delegated_task_id: "task-a",
          delegated_run_id: "run-a",
          delegated_agent_id: "agent-a",
          delegated_session_key: "session-a"
        }
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{kind: "regular"},
        request_meta: %{kind: "regular"}
      )

    next_state = submit_followups(previous, current)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
    assert Enum.at(next_state.queue, 0).meta["async_followups"] == [
             %{
               source: :agent,
               task_id: "task-a",
               run_id: "run-a",
               agent_id: "agent-a",
               session_key: "session-a",
               delivery: :router
             }
           ]
  end

  defp merge_followups(previous, current) do
    next_state = submit_followups(previous, current)
    assert [merged] = next_state.queue
    merged
  end

  defp submit_followups(previous, current) do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: nil,
      queue: [previous],
      last_followup_at_ms: 100,
      pending_steers: %{}
    }

    assert {:ok, next_state, [:maybe_start_next]} = SessionTransitions.submit(state, current, 200)
    next_state
  end

  defp submission(run_id, session_key, queue_mode, prompt, opts \\ []) do
    request = %ExecutionRequest{
      run_id: run_id,
      session_key: session_key,
      prompt: prompt,
      engine_id: "codex",
      conversation_key: {:session, session_key},
      meta: Keyword.get(opts, :request_meta, %{})
    }

    Submission.new!(%{
      run_id: run_id,
      session_key: session_key,
      conversation_key: {:session, session_key},
      queue_mode: queue_mode,
      execution_request: request,
      run_process_opts: %{},
      meta: Keyword.get(opts, :meta, %{})
    })
  end
end
