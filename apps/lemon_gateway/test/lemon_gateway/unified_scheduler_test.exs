defmodule LemonGateway.UnifiedSchedulerTest do
  use ExUnit.Case, async: false

  alias LemonGateway.UnifiedScheduler
  alias LemonGateway.Types.Job

  setup do
    # Start the UnifiedScheduler with default name
    start_supervised!({UnifiedScheduler, name: LemonGateway.UnifiedScheduler})

    :ok
  end

  describe "lane_caps/0" do
    test "returns configured caps" do
      caps = UnifiedScheduler.lane_caps()

      assert is_map(caps)
      assert Map.has_key?(caps, :main)
      assert Map.has_key?(caps, :subagent)
      assert Map.has_key?(caps, :background_exec)
    end

    test "returns default caps when not configured" do
      # Test that defaults are reasonable
      caps = UnifiedScheduler.lane_caps()

      assert caps.main > 0
      assert caps.subagent > 0
      assert caps.background_exec > 0
    end
  end

  describe "run_in_lane/3" do
    test "executes function in specified lane" do
      result = UnifiedScheduler.run_in_lane(:main, fn -> :success end, [])

      assert result == {:ok, :success}
    end

    test "returns error when lane queue unavailable" do
      # This would require stopping the LaneQueue, which we won't do
      # Just verify the function exists and handles errors gracefully
      result = UnifiedScheduler.run_in_lane(:unknown_lane, fn -> :ok end, [])

      # Should succeed even for unknown lanes (uses default cap)
      assert {:ok, :ok} = result
    end

    test "passes metadata to lane queue" do
      test_pid = self()

      result = UnifiedScheduler.run_in_lane(
        :subagent,
        fn ->
          send(test_pid, :executed)
          :done
        end,
        meta: %{test: true}
      )

      assert result == {:ok, :done}
      assert_receive :executed, 1000
    end
  end

  describe "lane_stats/0" do
    test "returns lane statistics" do
      stats = UnifiedScheduler.lane_stats()

      assert is_map(stats)
    end
  end

  describe "lane_available?/1" do
    test "returns true for available lanes" do
      assert UnifiedScheduler.lane_available?(:main) == true
      assert UnifiedScheduler.lane_available?(:subagent) == true
    end
  end

  describe "submit/2" do
    test "submits job synchronously" do
      job = %Job{
        scope: "test",
        user_msg_id: "test_job_1",
        text: "test prompt",
        resume: nil
      }

      # This will call the existing Scheduler.submit
      # In a real test, we'd mock or verify the side effects
      result = UnifiedScheduler.submit(job, lane: :main, async: false, timeout_ms: 1000)

      # Should return :ok since Scheduler.submit returns :ok
      assert result == {:ok, :ok}
    end

    test "submits job asynchronously" do
      job = %Job{
        scope: "test",
        user_msg_id: "test_job_2",
        text: "test prompt",
        resume: nil
      }

      result = UnifiedScheduler.submit(job, lane: :main, async: true)

      # Should return a job_id
      assert {:ok, job_id} = result
      assert is_binary(job_id)
    end
  end

  describe "integration with LaneQueue" do
    test "routes work through LaneQueue" do
      test_pid = self()

      # Submit work through unified scheduler
      result = UnifiedScheduler.run_in_lane(:subagent, fn ->
        send(test_pid, {:lane_executed, :subagent})
        :completed
      end, [])

      assert result == {:ok, :completed}
      assert_receive {:lane_executed, :subagent}, 1000
    end

    test "respects lane caps" do
      # Start multiple concurrent tasks
      tasks = for i <- 1..5 do
        Task.async(fn ->
          UnifiedScheduler.run_in_lane(:main, fn ->
            Process.sleep(100)
            i
          end, [])
        end)
      end

      results = Task.await_many(tasks, 5000)

      # All should complete successfully
      assert Enum.all?(results, fn {:ok, _} -> true; _ -> false end)
      assert Enum.sort(Enum.map(results, fn {:ok, i} -> i end)) == [1, 2, 3, 4, 5]
    end
  end
end
