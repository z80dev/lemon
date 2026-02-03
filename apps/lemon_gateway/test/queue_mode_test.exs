defmodule LemonGateway.QueueModeTest do
  use ExUnit.Case

  alias LemonGateway.Types.{ChatScope, Job}

  describe "Job struct" do
    test "default queue_mode is :collect" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      job = %Job{
        scope: scope,
        user_msg_id: 1,
        text: "test"
      }

      assert job.queue_mode == :collect
    end

    test "can set queue_mode to :followup" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      job = %Job{
        scope: scope,
        user_msg_id: 1,
        text: "test",
        queue_mode: :followup
      }

      assert job.queue_mode == :followup
    end

    test "can set queue_mode to :steer" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      job = %Job{
        scope: scope,
        user_msg_id: 1,
        text: "test",
        queue_mode: :steer
      }

      assert job.queue_mode == :steer
    end

    test "can set queue_mode to :interrupt" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      job = %Job{
        scope: scope,
        user_msg_id: 1,
        text: "test",
        queue_mode: :interrupt
      }

      assert job.queue_mode == :interrupt
    end
  end

  describe "ThreadWorker enqueue_by_mode logic" do
    # Test the queue manipulation logic by directly manipulating state
    # This avoids needing the full Scheduler infrastructure

    test "collect mode appends to queue" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      job1 = %Job{scope: scope, user_msg_id: 1, text: "first", queue_mode: :collect}
      job2 = %Job{scope: scope, user_msg_id: 2, text: "second", queue_mode: :collect}
      job3 = %Job{scope: scope, user_msg_id: 3, text: "third", queue_mode: :collect}

      state = enqueue_by_mode(job1, state)
      state = enqueue_by_mode(job2, state)
      state = enqueue_by_mode(job3, state)

      jobs = :queue.to_list(state.jobs)

      assert length(jobs) == 3
      assert Enum.at(jobs, 0).text == "first"
      assert Enum.at(jobs, 1).text == "second"
      assert Enum.at(jobs, 2).text == "third"
    end

    test "steer mode inserts at front of queue" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      job1 = %Job{scope: scope, user_msg_id: 1, text: "first", queue_mode: :collect}
      job2 = %Job{scope: scope, user_msg_id: 2, text: "second", queue_mode: :collect}
      job_steer = %Job{scope: scope, user_msg_id: 3, text: "urgent", queue_mode: :steer}

      state = enqueue_by_mode(job1, state)
      state = enqueue_by_mode(job2, state)
      state = enqueue_by_mode(job_steer, state)

      jobs = :queue.to_list(state.jobs)

      # steer job should be at front
      assert length(jobs) == 3
      assert Enum.at(jobs, 0).text == "urgent"
      assert Enum.at(jobs, 1).text == "first"
      assert Enum.at(jobs, 2).text == "second"
    end

    test "interrupt mode inserts at front of queue" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      job1 = %Job{scope: scope, user_msg_id: 1, text: "first", queue_mode: :collect}
      job2 = %Job{scope: scope, user_msg_id: 2, text: "second", queue_mode: :collect}

      job_interrupt = %Job{
        scope: scope,
        user_msg_id: 3,
        text: "interrupt",
        queue_mode: :interrupt
      }

      state = enqueue_by_mode(job1, state)
      state = enqueue_by_mode(job2, state)
      state = enqueue_by_mode(job_interrupt, state)

      jobs = :queue.to_list(state.jobs)

      # interrupt job should be at front
      assert length(jobs) == 3
      assert Enum.at(jobs, 0).text == "interrupt"
      assert Enum.at(jobs, 1).text == "first"
      assert Enum.at(jobs, 2).text == "second"
    end

    test "multiple steer jobs maintain LIFO order at front" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      job1 = %Job{scope: scope, user_msg_id: 1, text: "normal", queue_mode: :collect}
      steer1 = %Job{scope: scope, user_msg_id: 2, text: "steer1", queue_mode: :steer}
      steer2 = %Job{scope: scope, user_msg_id: 3, text: "steer2", queue_mode: :steer}

      state = enqueue_by_mode(job1, state)
      state = enqueue_by_mode(steer1, state)
      state = enqueue_by_mode(steer2, state)

      jobs = :queue.to_list(state.jobs)

      # steer2 should be first (LIFO for steer), then steer1, then normal
      assert length(jobs) == 3
      assert Enum.at(jobs, 0).text == "steer2"
      assert Enum.at(jobs, 1).text == "steer1"
      assert Enum.at(jobs, 2).text == "normal"
    end

    test "followup mode merges with previous followup within debounce window" do
      # Set a long debounce window for testing
      Application.put_env(:lemon_gateway, :followup_debounce_ms, 5000)

      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      followup1 = %Job{scope: scope, user_msg_id: 1, text: "part1", queue_mode: :followup}
      followup2 = %Job{scope: scope, user_msg_id: 2, text: "part2", queue_mode: :followup}

      state = enqueue_by_mode(followup1, state)
      # Enqueue immediately (within debounce window)
      state = enqueue_by_mode(followup2, state)

      jobs = :queue.to_list(state.jobs)

      # Should be merged into one job
      assert length(jobs) == 1
      assert Enum.at(jobs, 0).text == "part1\npart2"
    end

    test "followup mode does not merge outside debounce window" do
      # Set a very short debounce window
      Application.put_env(:lemon_gateway, :followup_debounce_ms, 1)

      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      followup1 = %Job{scope: scope, user_msg_id: 1, text: "part1", queue_mode: :followup}
      followup2 = %Job{scope: scope, user_msg_id: 2, text: "part2", queue_mode: :followup}

      state = enqueue_by_mode(followup1, state)
      # Outside debounce window (1ms)
      Process.sleep(10)
      state = enqueue_by_mode(followup2, state)

      jobs = :queue.to_list(state.jobs)

      # Should NOT be merged - two separate jobs
      assert length(jobs) == 2
      assert Enum.at(jobs, 0).text == "part1"
      assert Enum.at(jobs, 1).text == "part2"
    end

    test "followup does not merge with non-followup job" do
      Application.put_env(:lemon_gateway, :followup_debounce_ms, 5000)

      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      collect_job = %Job{scope: scope, user_msg_id: 1, text: "collect", queue_mode: :collect}
      followup = %Job{scope: scope, user_msg_id: 2, text: "followup", queue_mode: :followup}

      state = enqueue_by_mode(collect_job, state)
      state = enqueue_by_mode(followup, state)

      jobs = :queue.to_list(state.jobs)

      # Should NOT merge - different modes
      assert length(jobs) == 2
      assert Enum.at(jobs, 0).text == "collect"
      assert Enum.at(jobs, 1).text == "followup"
    end

    test "multiple followups merge consecutively" do
      Application.put_env(:lemon_gateway, :followup_debounce_ms, 5000)

      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      followup1 = %Job{scope: scope, user_msg_id: 1, text: "a", queue_mode: :followup}
      followup2 = %Job{scope: scope, user_msg_id: 2, text: "b", queue_mode: :followup}
      followup3 = %Job{scope: scope, user_msg_id: 3, text: "c", queue_mode: :followup}

      state = enqueue_by_mode(followup1, state)
      state = enqueue_by_mode(followup2, state)
      state = enqueue_by_mode(followup3, state)

      jobs = :queue.to_list(state.jobs)

      # All three should be merged
      assert length(jobs) == 1
      assert Enum.at(jobs, 0).text == "a\nb\nc"
    end
  end

  describe "mode interactions" do
    test "interrupt after steer - interrupt goes to front" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      job_normal = %Job{scope: scope, user_msg_id: 1, text: "normal", queue_mode: :collect}
      job_steer = %Job{scope: scope, user_msg_id: 2, text: "steer", queue_mode: :steer}

      job_interrupt = %Job{
        scope: scope,
        user_msg_id: 3,
        text: "interrupt",
        queue_mode: :interrupt
      }

      state = enqueue_by_mode(job_normal, state)
      state = enqueue_by_mode(job_steer, state)
      state = enqueue_by_mode(job_interrupt, state)

      jobs = :queue.to_list(state.jobs)

      # Order should be: interrupt, steer, normal
      assert length(jobs) == 3
      assert Enum.at(jobs, 0).text == "interrupt"
      assert Enum.at(jobs, 1).text == "steer"
      assert Enum.at(jobs, 2).text == "normal"
    end

    test "steer after interrupt - steer goes after interrupt" do
      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      job_normal = %Job{scope: scope, user_msg_id: 1, text: "normal", queue_mode: :collect}

      job_interrupt = %Job{
        scope: scope,
        user_msg_id: 2,
        text: "interrupt",
        queue_mode: :interrupt
      }

      job_steer = %Job{scope: scope, user_msg_id: 3, text: "steer", queue_mode: :steer}

      state = enqueue_by_mode(job_normal, state)
      state = enqueue_by_mode(job_interrupt, state)
      state = enqueue_by_mode(job_steer, state)

      jobs = :queue.to_list(state.jobs)

      # Order should be: steer, interrupt, normal (both went to front, steer last)
      assert length(jobs) == 3
      assert Enum.at(jobs, 0).text == "steer"
      assert Enum.at(jobs, 1).text == "interrupt"
      assert Enum.at(jobs, 2).text == "normal"
    end

    test "followup between collect jobs" do
      Application.put_env(:lemon_gateway, :followup_debounce_ms, 5000)

      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      job1 = %Job{scope: scope, user_msg_id: 1, text: "collect1", queue_mode: :collect}
      followup = %Job{scope: scope, user_msg_id: 2, text: "followup", queue_mode: :followup}
      job2 = %Job{scope: scope, user_msg_id: 3, text: "collect2", queue_mode: :collect}

      state = enqueue_by_mode(job1, state)
      state = enqueue_by_mode(followup, state)
      state = enqueue_by_mode(job2, state)

      jobs = :queue.to_list(state.jobs)

      # All appended in order (no merge because followup is after collect, not followup)
      assert length(jobs) == 3
      assert Enum.at(jobs, 0).text == "collect1"
      assert Enum.at(jobs, 1).text == "followup"
      assert Enum.at(jobs, 2).text == "collect2"
    end

    test "followup after steer does not merge" do
      Application.put_env(:lemon_gateway, :followup_debounce_ms, 5000)

      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      job_steer = %Job{scope: scope, user_msg_id: 1, text: "steer", queue_mode: :steer}
      followup = %Job{scope: scope, user_msg_id: 2, text: "followup", queue_mode: :followup}

      state = enqueue_by_mode(job_steer, state)
      state = enqueue_by_mode(followup, state)

      jobs = :queue.to_list(state.jobs)

      # No merge - steer is not a followup
      assert length(jobs) == 2
      assert Enum.at(jobs, 0).text == "steer"
      assert Enum.at(jobs, 1).text == "followup"
    end

    test "mixed mode complex scenario" do
      Application.put_env(:lemon_gateway, :followup_debounce_ms, 5000)

      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      state = %{
        jobs: :queue.new(),
        current_run: nil,
        last_followup_at: nil
      }

      # Sequence: collect1, followup1, followup2 (merge), steer, collect2
      collect1 = %Job{scope: scope, user_msg_id: 1, text: "collect1", queue_mode: :collect}
      followup1 = %Job{scope: scope, user_msg_id: 2, text: "follow1", queue_mode: :followup}
      followup2 = %Job{scope: scope, user_msg_id: 3, text: "follow2", queue_mode: :followup}
      steer = %Job{scope: scope, user_msg_id: 4, text: "steer", queue_mode: :steer}
      collect2 = %Job{scope: scope, user_msg_id: 5, text: "collect2", queue_mode: :collect}

      state = enqueue_by_mode(collect1, state)
      state = enqueue_by_mode(followup1, state)
      state = enqueue_by_mode(followup2, state)
      state = enqueue_by_mode(steer, state)
      state = enqueue_by_mode(collect2, state)

      jobs = :queue.to_list(state.jobs)

      # Expected order: steer, collect1, merged_followup, collect2
      assert length(jobs) == 4
      assert Enum.at(jobs, 0).text == "steer"
      assert Enum.at(jobs, 1).text == "collect1"
      assert Enum.at(jobs, 2).text == "follow1\nfollow2"
      assert Enum.at(jobs, 3).text == "collect2"
    end
  end

  # Helper functions to mirror the ThreadWorker logic for testing
  defp enqueue_by_mode(%Job{queue_mode: :collect} = job, state) do
    %{state | jobs: :queue.in(job, state.jobs)}
  end

  defp enqueue_by_mode(%Job{queue_mode: :followup} = job, state) do
    now = System.monotonic_time(:millisecond)
    debounce_ms = Application.get_env(:lemon_gateway, :followup_debounce_ms, 500)

    case state.last_followup_at do
      nil ->
        # No previous followup, just append
        %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}

      last_time when now - last_time < debounce_ms ->
        # Within debounce window, merge with last followup if possible
        case merge_with_last_followup(state.jobs, job) do
          {:merged, new_jobs} ->
            %{state | jobs: new_jobs, last_followup_at: now}

          :no_merge ->
            %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}
        end

      _last_time ->
        # Outside debounce window, just append
        %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}
    end
  end

  defp enqueue_by_mode(%Job{queue_mode: :steer} = job, state) do
    # Insert at front of queue (will be processed after current run completes)
    %{state | jobs: :queue.in_r(job, state.jobs)}
  end

  defp enqueue_by_mode(%Job{queue_mode: :interrupt} = job, state) do
    # Cancel current run if active (skip in test), then insert at front
    %{state | jobs: :queue.in_r(job, state.jobs)}
  end

  defp merge_with_last_followup(queue, new_job) do
    case :queue.out_r(queue) do
      {{:value, %Job{queue_mode: :followup} = last_job}, rest_queue} ->
        # Merge by concatenating text with newline separator
        merged_job = %{last_job | text: last_job.text <> "\n" <> new_job.text}
        {:merged, :queue.in(merged_job, rest_queue)}

      _ ->
        :no_merge
    end
  end
end
