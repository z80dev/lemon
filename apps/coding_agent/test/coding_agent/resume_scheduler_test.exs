defmodule CodingAgent.ResumeSchedulerTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{RateLimitPause, ResumeScheduler}

  setup do
    # Ensure the RateLimitPause ETS table exists
    _ = RateLimitPause.stats()

    # Start the scheduler
    {:ok, pid} = ResumeScheduler.start_link(check_interval_ms: 100_000)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    {:ok, scheduler: pid}
  end

  describe "start_link/1" do
    test "starts the scheduler with custom options" do
      # Use a unique name to avoid conflicts
      {:ok, pid} = GenServer.start_link(CodingAgent.ResumeScheduler, [check_interval_ms: 50_000])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "stats/0" do
    test "returns initial stats" do
      stats = ResumeScheduler.stats()
      assert stats.checks_performed == 0
      assert stats.runs_resumed == 0
      assert stats.last_check_at == nil
    end

    test "stats increment after check" do
      # Trigger a check
      ResumeScheduler.check_and_resume()

      stats = ResumeScheduler.stats()
      assert stats.checks_performed == 1
      assert stats.last_check_at != nil
    end
  end

  describe "check_and_resume/0" do
    test "returns 0 when no pauses exist" do
      assert {:ok, 0} = ResumeScheduler.check_and_resume()
    end

    test "returns 0 when pauses are not ready to resume" do
      session_id = "test_session_#{System.unique_integer([:positive])}"

      # Create a pause with a long retry time
      {:ok, _pause} = RateLimitPause.create(session_id, :anthropic, 600_000)

      assert {:ok, 0} = ResumeScheduler.check_and_resume()
    end

    test "does not resume pauses that are not ready" do
      session_id = "test_session_#{System.unique_integer([:positive])}"

      # Create a pause with future resume time
      {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 600_000)

      # Try to resume it - should fail because not ready
      assert {:error, :not_ready} = ResumeScheduler.resume_pause(pause.id)

      # Verify pause is still pending
      assert {:ok, %{status: :paused}} = RateLimitPause.get(pause.id)
    end
  end

  describe "resume_pause/1" do
    test "returns error for non-existent pause" do
      assert {:error, :not_found} = ResumeScheduler.resume_pause("non_existent_id")
    end

    test "returns error when pause is not ready" do
      session_id = "test_session_#{System.unique_integer([:positive])}"
      {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 600_000)

      assert {:error, :not_ready} = ResumeScheduler.resume_pause(pause.id)
    end

    test "successfully resumes a ready pause" do
      session_id = "test_session_#{System.unique_integer([:positive])}"

      # Create a pause with a very short retry time (1ms)
      {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 1)

      # Wait for it to be ready
      Process.sleep(10)

      # Attempt to resume - will fail at run lookup but pause should be marked resumed
      result = ResumeScheduler.resume_pause(pause.id)

      # The pause should be marked as resumed even if run lookup fails
      assert {:ok, %{pause: %{status: :resumed}}} = result
    end
  end

  describe "scheduler process" do
    test "schedules periodic checks" do
      # Start a scheduler with a short interval (no name to avoid conflict)
      {:ok, pid} = GenServer.start_link(CodingAgent.ResumeScheduler, [check_interval_ms: 50])

      # Wait for at least one check to occur
      Process.sleep(100)

      stats = GenServer.call(pid, :stats)
      assert stats.checks_performed >= 1

      GenServer.stop(pid)
    end
  end

  describe "telemetry" do
    test "emits telemetry events when resuming" do
      session_id = "test_session_#{System.unique_integer([:positive])}"

      # Attach telemetry handler with string ID
      handler_id = "test-resume-scheduler-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:coding_agent, :rate_limit_pause, :resumed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_received, metadata})
        end,
        nil
      )

      # Create and resume a pause
      {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 1)
      Process.sleep(10)
      ResumeScheduler.resume_pause(pause.id)

      # Verify telemetry was received
      assert_receive {:telemetry_received, _metadata}, 1000

      :telemetry.detach(handler_id)
    end
  end
end
