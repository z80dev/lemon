defmodule LemonRouter.SessionTransitionsTest do
  use ExUnit.Case, async: true

  alias LemonGateway.ExecutionRequest
  alias LemonRouter.{SessionState, SessionTransitions}

  test "submit while idle queues work and requests start" do
    state = SessionState.new(conversation_key: {:session, "s1"})
    submission = submission("run1", "s1", :collect, "one")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, submission, 100)

    assert next_state.active == nil
    assert Enum.map(next_state.queue, & &1.run_id) == ["run1"]
    assert effects == [:maybe_start_next]
  end

  test "submit while busy preserves active and queues the next run" do
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

  test "cancel clears queue and pending steers and requests active cancellation" do
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

  test "abort_session only removes matching session work" do
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
    assert effects == [:maybe_start_next]
  end

  test "active_down with a different pid or monitor ref is a noop" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1", pid: self(), mon_ref: make_ref()},
      queue: [submission("run2", "s1", :collect, "two")],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    assert {:ok, next_state, effects} = SessionTransitions.active_down(state, self(), make_ref())

    assert next_state == state
    assert effects == [:noop]
  end

  test "rejected steer falls back into the queue and requests next start when idle" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: nil,
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :steer, "two"), :followup}]}
    }

    assert {:ok, next_state, effects} = SessionTransitions.steer_rejected(state, "run2")

    assert Enum.map(next_state.queue, & &1.run_id) == ["run2"]
    assert next_state.pending_steers == %{}
    assert effects == [:maybe_start_next]
  end

  defp submission(run_id, session_key, queue_mode, prompt) do
    request = %ExecutionRequest{
      run_id: run_id,
      session_key: session_key,
      prompt: prompt,
      engine_id: "codex",
      conversation_key: {:session, session_key},
      meta: %{}
    }

    %{
      run_id: run_id,
      session_key: session_key,
      queue_mode: queue_mode,
      execution_request: request,
      run_process_opts: %{},
      meta: %{}
    }
  end
end
