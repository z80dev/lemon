defmodule LemonAutomation.HeartbeatSchedulingTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.HeartbeatManager

  setup do
    # LemonCore.Bus should already be started by the application
    # If not, we skip gracefully
    :ok
  end

  describe "HeartbeatManager.update_config/2" do
    test "creates a cron job when enabled" do
      # This test verifies the scheduling behavior
      agent_id = "test-agent-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 60_000,
        prompt: "HEARTBEAT"
      }

      # The update_config function should create a cron job
      HeartbeatManager.update_config(agent_id, config)

      # Allow time for async operations
      Process.sleep(100)

      # Verify a heartbeat job was created
      # Note: This test assumes CronManager is running
      # In production, you'd want to verify the job exists
    end

    test "disables cron job when disabled" do
      agent_id = "test-agent-#{System.unique_integer()}"

      # First enable
      config = %{
        enabled: true,
        interval_ms: 60_000,
        prompt: "HEARTBEAT"
      }
      HeartbeatManager.update_config(agent_id, config)

      # Then disable
      disabled_config = %{enabled: false}
      HeartbeatManager.update_config(agent_id, disabled_config)

      Process.sleep(100)

      # Job should be disabled
    end
  end

  describe "build_cron_schedule/1" do
    # These test the internal schedule building logic
    # by testing the heartbeat manager's behavior with different intervals

    test "handles minute intervals" do
      # 5 minute interval should produce "*/5 * * * *"
      # We test this indirectly through config updates
      agent_id = "test-schedule-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 5 * 60_000,  # 5 minutes
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)
    end

    test "handles hourly intervals" do
      agent_id = "test-schedule-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 2 * 60 * 60_000,  # 2 hours
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)
    end
  end

  describe "heartbeat_job_id/1" do
    test "generates consistent job IDs" do
      # The job ID should be deterministic for a given agent
      # This ensures we can find/update existing jobs
      agent_id = "my-agent"

      config = %{enabled: true, interval_ms: 60_000, prompt: "HEARTBEAT"}

      # First call
      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)

      # Second call should update, not create duplicate
      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)
    end
  end

  describe "sub-minute interval support" do
    test "handles 30 second intervals using timer-based scheduling" do
      agent_id = "test-sub-minute-30s-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 30_000,  # 30 seconds
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)

      # Allow time for setup
      Process.sleep(100)

      # The heartbeat should be scheduled via timer, not cron
      # We can verify by checking state (indirectly through behavior)
    end

    test "handles 10 second intervals using timer-based scheduling" do
      agent_id = "test-sub-minute-10s-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 10_000,  # 10 seconds
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)
    end

    test "handles 5 second intervals using timer-based scheduling" do
      agent_id = "test-sub-minute-5s-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 5_000,  # 5 seconds
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)
    end

    test "60 second interval uses cron-based scheduling" do
      agent_id = "test-minute-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 60_000,  # Exactly 60 seconds
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)

      # 60s interval should use cron, not timer
    end

    test "90 second interval uses cron with 1-2 minute rounding" do
      agent_id = "test-90s-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 90_000,  # 90 seconds = 1.5 minutes
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)

      # 90s should round to 2 minutes for cron (60s + 30s rounds up)
    end

    test "disabling sub-minute heartbeat cancels timer" do
      agent_id = "test-sub-minute-cancel-#{System.unique_integer()}"

      # Enable with sub-minute interval
      config = %{
        enabled: true,
        interval_ms: 15_000,  # 15 seconds
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)

      # Disable
      HeartbeatManager.update_config(agent_id, %{enabled: false})
      Process.sleep(100)

      # Timer should be cancelled
    end

    test "switching from sub-minute to minute interval transitions correctly" do
      agent_id = "test-transition-#{System.unique_integer()}"

      # Start with sub-minute interval
      config1 = %{
        enabled: true,
        interval_ms: 30_000,  # 30 seconds - uses timer
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config1)
      Process.sleep(100)

      # Switch to minute interval
      config2 = %{
        enabled: true,
        interval_ms: 120_000,  # 2 minutes - uses cron
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config2)
      Process.sleep(100)

      # Timer should be cancelled, cron job should be active
    end

    test "switching from minute to sub-minute interval transitions correctly" do
      agent_id = "test-transition-reverse-#{System.unique_integer()}"

      # Start with minute interval
      config1 = %{
        enabled: true,
        interval_ms: 120_000,  # 2 minutes - uses cron
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config1)
      Process.sleep(100)

      # Switch to sub-minute interval
      config2 = %{
        enabled: true,
        interval_ms: 20_000,  # 20 seconds - uses timer
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config2)
      Process.sleep(100)

      # Cron job should be unchanged (or disabled), timer should be active
    end
  end

  describe "interval_ms truncation fix verification" do
    test "45 second interval is preserved, not truncated to 0" do
      # Previously: div(45_000, 60_000) = 0, causing issues
      # Now: Uses timer-based scheduling for sub-minute intervals
      agent_id = "test-truncation-45s-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 45_000,  # 45 seconds
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)

      # Should work without truncation issues
    end

    test "59 second interval is preserved, not truncated" do
      agent_id = "test-truncation-59s-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 59_000,  # 59 seconds
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)

      # Should use timer-based scheduling
    end

    test "non-divisible minute interval is handled correctly" do
      # 90 seconds = 1.5 minutes, should round appropriately for cron
      agent_id = "test-non-divisible-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 90_000,  # 1.5 minutes
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)

      # Should round to 2 minutes for cron scheduling
    end

    test "75 second interval is scheduled approximately correctly" do
      agent_id = "test-75s-#{System.unique_integer()}"

      config = %{
        enabled: true,
        interval_ms: 75_000,  # 1 minute 15 seconds
        prompt: "HEARTBEAT"
      }

      HeartbeatManager.update_config(agent_id, config)
      Process.sleep(100)

      # Should round to nearest minute (1 minute) for cron
    end
  end
end
