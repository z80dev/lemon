defmodule CodingAgent.SessionOverflowRecoveryTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Test.Mocks
  alias CodingAgent.Session
  alias CodingAgent.Session.OverflowRecovery
  alias CodingAgent.SessionManager

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
      length(SessionManager.entries(state.session_manager)),
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
          overflow_recovery: %OverflowRecovery.State{
            in_progress: true,
            attempted: attempted,
            signature: signature,
            task_pid: task_pid,
            task_monitor_ref: monitor_ref,
            error_reason: reason,
            partial_state: partial_state
          }
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
    assert state_after.overflow_recovery.in_progress
    assert state_after.overflow_recovery.signature == signature
    assert state_after.overflow_recovery.attempted
  end

  test "failed overflow compaction finalizes session and clears recovery flags" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)
    mark_overflow_recovery_state(session, signature)

    send(session, {:overflow_recovery_result, signature, {:error, :cannot_compact}})

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery.in_progress
    refute state_after.overflow_recovery.attempted
    refute state_after.is_streaming
  end

  test "Chinese context overflow errors are handled normally after retry already attempted" do
    session = start_session()

    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery: %{state.overflow_recovery | attempted: true}
      }
    end)

    send(
      session,
      {:agent_event, {:error, {:assistant_error, "输入过长，超出最大长度"}, %{from: :test}}}
    )

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery.in_progress
    refute state_after.overflow_recovery.attempted
    refute state_after.is_streaming
  end

  test "overflow errors are handled normally after retry already attempted" do
    session = start_session()

    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery: %{state.overflow_recovery | attempted: true}
      }
    end)

    send(
      session,
      {:agent_event, {:error, {:assistant_error, "context_length_exceeded"}, %{from: :test}}}
    )

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery.in_progress
    refute state_after.overflow_recovery.attempted
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
    refute state_after.overflow_recovery.in_progress
    assert state_after.overflow_recovery.task_pid == nil
    assert state_after.overflow_recovery.task_monitor_ref == nil
    refute state_after.is_streaming
  end

  test "reset cancels overflow recovery and makes late task messages stale" do
    session = start_session()
    state = Session.get_state(session)
    task_pid = spawn(fn -> Process.sleep(:infinity) end)
    task_monitor = Process.monitor(task_pid)
    stale_monitor_ref = make_ref()

    :sys.replace_state(session, fn session_state ->
      %{
        session_state
        | overflow_recovery: %OverflowRecovery.State{
            in_progress: true,
            attempted: true,
            signature: current_signature(state),
            task_pid: task_pid,
            task_monitor_ref: stale_monitor_ref,
            task_timeout_ref: make_ref(),
            started_at_ms: 12,
            error_reason: :overflow,
            partial_state: %{from: :old_session}
          }
      }
    end)

    assert :ok = Session.reset(session)
    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, {:shutdown, :session_reset}}, 1_000

    assert Session.get_state(session).overflow_recovery == %OverflowRecovery.State{}

    send(session, {:overflow_recovery_task_timeout, stale_monitor_ref})
    assert Session.get_state(session).overflow_recovery == %OverflowRecovery.State{}
  end

  test "session termination cancels an active overflow recovery task" do
    session = start_session()
    task_pid = spawn(fn -> Process.sleep(:infinity) end)
    task_monitor = Process.monitor(task_pid)

    :sys.replace_state(session, fn state ->
      %{
        state
        | overflow_recovery: %OverflowRecovery.State{
            in_progress: true,
            task_pid: task_pid,
            task_monitor_ref: make_ref(),
            task_timeout_ref: make_ref()
          }
      }
    end)

    assert :ok = GenServer.stop(session)

    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, {:shutdown, :session_terminated}},
                   1_000
  end
end
