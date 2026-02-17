defmodule CodingAgent.SessionOverflowRecoveryTest do
  use ExUnit.Case, async: true

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

    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery_in_progress: true,
          overflow_recovery_attempted: attempted,
          overflow_recovery_signature: signature,
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
end
