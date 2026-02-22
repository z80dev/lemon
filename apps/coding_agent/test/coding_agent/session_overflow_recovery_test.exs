defmodule CodingAgent.SessionOverflowRecoveryTest do
  use ExUnit.Case, async: false

  alias AgentCore.Test.Mocks
  alias CodingAgent.Session

  defp start_session(opts \\ []) do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "session_overflow_recovery_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(cwd)

    defaults = [
      cwd: cwd,
      model: Mocks.mock_model(),
      stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
    ]

    {:ok, session} = Session.start_link(Keyword.merge(defaults, opts))
    session
  end

  defp current_signature(state) do
    {
      state.session_manager.header.id,
      state.session_manager.leaf_id,
      length(state.session_manager.entries),
      state.turn_index,
      state.model.provider,
      state.model.id
    }
  end

  defp mark_overflow_recovery_state(session, signature, opts \\ []) do
    attempted = Keyword.get(opts, :attempted, true)
    reason = Keyword.get(opts, :reason, {:assistant_error, "context_length_exceeded"})
    partial_state = Keyword.get(opts, :partial_state, %{from: :test})
    monitor_ref = Keyword.get(opts, :monitor_ref, nil)
    task_pid = Keyword.get(opts, :task_pid, nil)

    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery_in_progress: true,
          overflow_recovery_attempted: attempted,
          overflow_recovery_signature: signature,
          overflow_recovery_task_pid: task_pid,
          overflow_recovery_task_monitor_ref: monitor_ref,
          overflow_recovery_error_reason: reason,
          overflow_recovery_partial_state: partial_state
      }
    end)
  end

  test "stale overflow recovery result is ignored while recovery remains in progress" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)
    mark_overflow_recovery_state(session, signature)

    send(session, {:overflow_recovery_result, :stale_signature, {:error, :cannot_compact}})

    state_after = Session.get_state(session)
    assert state_after.overflow_recovery_in_progress
    assert state_after.overflow_recovery_signature == signature
    assert state_after.overflow_recovery_attempted
  end

  test "failed overflow compaction finalizes session and clears recovery flags" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)
    mark_overflow_recovery_state(session, signature)

    send(session, {:overflow_recovery_result, signature, {:error, :cannot_compact}})

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery_in_progress
    refute state_after.overflow_recovery_attempted
    refute state_after.is_streaming
  end

  test "overflow errors are handled normally after retry already attempted" do
    session = start_session()

    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery_attempted: true
      }
    end)

    send(
      session,
      {:agent_event, {:error, {:assistant_error, "context_length_exceeded"}, %{from: :test}}}
    )

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery_in_progress
    refute state_after.overflow_recovery_attempted
    refute state_after.is_streaming
  end

  test "emits failure telemetry when overflow recovery fails" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)
    mark_overflow_recovery_state(session, signature)

    handler_id = "overflow-recovery-failure-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:coding_agent, :session, :overflow_recovery, :failure],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    send(session, {:overflow_recovery_result, signature, {:error, :cannot_compact}})

    assert_receive {:telemetry_event, [:coding_agent, :session, :overflow_recovery, :failure],
                    %{count: 1}, metadata},
                   1_000

    assert metadata.session_id == state.session_manager.header.id
    assert metadata.reason =~ "cannot_compact"
  end

  test "overflow recovery task timeout finalizes session and clears task tracking" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)
    task_pid = spawn(fn -> Process.sleep(:infinity) end)
    monitor_ref = Process.monitor(task_pid)
    mark_overflow_recovery_state(session, signature, task_pid: task_pid, monitor_ref: monitor_ref)

    send(session, {:overflow_recovery_task_timeout, monitor_ref})

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery_in_progress
    assert state_after.overflow_recovery_task_pid == nil
    assert state_after.overflow_recovery_task_monitor_ref == nil
    refute state_after.is_streaming
  end
end
