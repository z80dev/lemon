defmodule CodingAgent.Session.OverflowRecoveryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.OverflowRecovery

  describe "maybe_start/5" do
    test "returns :no_recovery when not streaming" do
      state = build_state(is_streaming: false)

      assert :no_recovery =
               OverflowRecovery.maybe_start(
                 state,
                 "context_length_exceeded",
                 nil,
                 &noop_working/2,
                 &noop_notify/3
               )
    end

    test "returns :no_recovery when overflow recovery already in progress" do
      state = build_state(overflow_recovery_in_progress: true)

      assert :no_recovery =
               OverflowRecovery.maybe_start(
                 state,
                 "context_length_exceeded",
                 nil,
                 &noop_working/2,
                 &noop_notify/3
               )
    end

    test "returns :no_recovery when overflow recovery already attempted" do
      state = build_state(overflow_recovery_attempted: true)

      assert :no_recovery =
               OverflowRecovery.maybe_start(
                 state,
                 "context_length_exceeded",
                 nil,
                 &noop_working/2,
                 &noop_notify/3
               )
    end

    test "returns :no_recovery when error is not context length exceeded" do
      state = build_state()

      assert :no_recovery =
               OverflowRecovery.maybe_start(
                 state,
                 "some other error",
                 nil,
                 &noop_working/2,
                 &noop_notify/3
               )
    end

    test "returns :no_recovery for timeout errors" do
      state = build_state()

      assert :no_recovery =
               OverflowRecovery.maybe_start(
                 state,
                 :timeout,
                 nil,
                 &noop_working/2,
                 &noop_notify/3
               )
    end
  end

  describe "handle_task_down/2" do
    test "returns state unchanged when not in overflow recovery" do
      state = build_state(overflow_recovery_in_progress: false)
      state = put_task_tracking(state)

      result = OverflowRecovery.handle_task_down(state, &noop_notify/3)

      refute result.overflow_recovery_error_reason
    end

    test "sets failure reason when overflow recovery in progress" do
      state =
        build_state(overflow_recovery_in_progress: true)
        |> put_task_tracking()

      result = OverflowRecovery.handle_task_down(state, &noop_notify/3)

      assert result.overflow_recovery_error_reason == :overflow_recovery_task_down
    end
  end

  # ---- Helpers ----

  defp build_state(overrides \\ []) do
    defaults = %{
      is_streaming: true,
      overflow_recovery_in_progress: false,
      overflow_recovery_attempted: false,
      overflow_recovery_signature: nil,
      overflow_recovery_task_pid: nil,
      overflow_recovery_task_monitor_ref: nil,
      overflow_recovery_task_timeout_ref: nil,
      overflow_recovery_started_at_ms: nil,
      overflow_recovery_error_reason: nil,
      overflow_recovery_partial_state: nil,
      session_manager: %{header: %{id: "test_session"}, leaf_id: nil},
      model: %{provider: :test, id: "test-model", context_window: 100_000},
      turn_index: 1,
      settings_manager: nil
    }

    Enum.into(overrides, defaults)
  end

  defp put_task_tracking(state) do
    %{
      state
      | overflow_recovery_task_pid: nil,
        overflow_recovery_task_monitor_ref: nil,
        overflow_recovery_task_timeout_ref: nil
    }
  end

  defp noop_working(_state, _msg), do: :ok
  defp noop_notify(_state, _msg, _type), do: :ok
end
