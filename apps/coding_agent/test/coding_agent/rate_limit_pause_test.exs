defmodule CodingAgent.RateLimitPauseTest do
  use ExUnit.Case, async: false

  alias CodingAgent.RateLimitPause

  setup do
    # Clean up the ETS table before each test
    if :ets.whereis(:coding_agent_rate_limit_pauses) != :undefined do
      :ets.delete_all_objects(:coding_agent_rate_limit_pauses)
    end

    :ok
  end

  describe "create/4" do
    test "creates a pause record with correct fields" do
      session_id = "session_#{System.unique_integer([:positive])}"
      provider = :anthropic
      retry_after_ms = 60_000

      assert {:ok, pause} = RateLimitPause.create(session_id, provider, retry_after_ms)

      assert pause.session_id == session_id
      assert pause.provider == provider
      assert pause.retry_after_ms == retry_after_ms
      assert pause.status == :paused
      assert is_binary(pause.id)
      assert %DateTime{} = pause.paused_at
      assert %DateTime{} = pause.resume_at
    end

    test "calculates resume_at based on retry_after_ms" do
      session_id = "session_#{System.unique_integer([:positive])}"
      retry_after_ms = 30_000

      before_create = DateTime.utc_now()
      assert {:ok, pause} = RateLimitPause.create(session_id, :openai, retry_after_ms)
      after_create = DateTime.utc_now()

      # resume_at should be approximately retry_after_ms in the future
      diff_ms = DateTime.diff(pause.resume_at, pause.paused_at, :millisecond)
      assert diff_ms >= 29_000 and diff_ms <= 31_000
    end

    test "accepts metadata option" do
      session_id = "session_#{System.unique_integer([:positive])}"
      metadata = %{error_message: "Rate limit exceeded", headers: %{"retry-after" => "60"}}

      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 60_000, metadata: metadata)
      assert pause.metadata == metadata
    end

    test "emits telemetry event" do
      session_id = "session_#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        "test-create-telemetry",
        [[:coding_agent, :rate_limit_pause, :paused]],
        fn event, measurements, metadata, _ ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      assert {:ok, _pause} = RateLimitPause.create(session_id, :anthropic, 60_000)

      assert_receive {:telemetry, [:coding_agent, :rate_limit_pause, :paused], measurements, metadata}
      assert measurements.retry_after_ms == 60_000
      assert metadata.session_id == session_id
      assert metadata.provider == :anthropic
      assert is_binary(metadata.pause_id)

      :telemetry.detach("test-create-telemetry")
    end
  end

  describe "ready_to_resume?/1" do
    test "returns false when pause time has not elapsed" do
      session_id = "session_#{System.unique_integer([:positive])}"
      # Set a long retry time
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 600_000)

      refute RateLimitPause.ready_to_resume?(pause.id)
    end

    test "returns true when pause time has elapsed" do
      session_id = "session_#{System.unique_integer([:positive])}"
      # Set a very short retry time (1ms)
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 1)

      # Small delay to ensure time has passed
      Process.sleep(10)

      assert RateLimitPause.ready_to_resume?(pause.id)
    end

    test "returns false for non-existent pause" do
      refute RateLimitPause.ready_to_resume?("non_existent_id")
    end

    test "returns false for already resumed pause" do
      session_id = "session_#{System.unique_integer([:positive])}"
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 1)
      Process.sleep(10)

      assert {:ok, _} = RateLimitPause.resume(pause.id)
      refute RateLimitPause.ready_to_resume?(pause.id)
    end
  end

  describe "resume/1" do
    test "resumes a ready pause" do
      session_id = "session_#{System.unique_integer([:positive])}"
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 1)
      Process.sleep(10)

      assert {:ok, resumed} = RateLimitPause.resume(pause.id)
      assert resumed.id == pause.id
      assert resumed.status == :resumed
      assert %DateTime{} = resumed.resumed_at
    end

    test "returns error when pause is not ready" do
      session_id = "session_#{System.unique_integer([:positive])}"
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 600_000)

      assert {:error, :not_ready} = RateLimitPause.resume(pause.id)
    end

    test "returns error for non-existent pause" do
      assert {:error, :not_found} = RateLimitPause.resume("non_existent_id")
    end

    test "emits telemetry event" do
      session_id = "session_#{System.unique_integer([:positive])}"
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 1)
      Process.sleep(10)

      :telemetry.attach_many(
        "test-resume-telemetry",
        [[:coding_agent, :rate_limit_pause, :resumed]],
        fn event, measurements, metadata, _ ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      assert {:ok, _} = RateLimitPause.resume(pause.id)

      assert_receive {:telemetry, [:coding_agent, :rate_limit_pause, :resumed], measurements, metadata}
      assert measurements.retry_after_ms == 1
      assert metadata.session_id == session_id
      assert metadata.provider == :anthropic

      :telemetry.detach("test-resume-telemetry")
    end
  end

  describe "get/1" do
    test "returns pause by id" do
      session_id = "session_#{System.unique_integer([:positive])}"
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 60_000)

      assert {:ok, fetched} = RateLimitPause.get(pause.id)
      assert fetched.id == pause.id
      assert fetched.session_id == session_id
    end

    test "returns error for non-existent id" do
      assert {:error, :not_found} = RateLimitPause.get("non_existent_id")
    end
  end

  describe "list_pending/1" do
    test "returns only pending pauses for session" do
      session_id = "session_#{System.unique_integer([:positive])}"

      # Create two pauses
      assert {:ok, pause1} = RateLimitPause.create(session_id, :anthropic, 600_000)
      assert {:ok, pause2} = RateLimitPause.create(session_id, :openai, 600_000)

      # Resume one
      Process.sleep(1)
      :ets.insert(:coding_agent_rate_limit_pauses, {
        pause1.id,
        %{pause1 | status: :resumed, resumed_at: DateTime.utc_now()}
      })

      pending = RateLimitPause.list_pending(session_id)
      assert length(pending) == 1
      assert hd(pending).id == pause2.id
    end

    test "returns empty list when no pending pauses" do
      session_id = "session_#{System.unique_integer([:positive])}"
      assert RateLimitPause.list_pending(session_id) == []
    end
  end

  describe "list_all/1" do
    test "returns all pauses regardless of status" do
      session_id = "session_#{System.unique_integer([:positive])}"

      assert {:ok, pause1} = RateLimitPause.create(session_id, :anthropic, 600_000)
      assert {:ok, pause2} = RateLimitPause.create(session_id, :openai, 600_000)

      # Resume one
      Process.sleep(1)
      :ets.insert(:coding_agent_rate_limit_pauses, {
        pause1.id,
        %{pause1 | status: :resumed, resumed_at: DateTime.utc_now()}
      })

      all = RateLimitPause.list_all(session_id)
      assert length(all) == 2
    end
  end

  describe "stats/0" do
    test "returns aggregate statistics" do
      # Clean slate
      if :ets.whereis(:coding_agent_rate_limit_pauses) != :undefined do
        :ets.delete_all_objects(:coding_agent_rate_limit_pauses)
      end

      # Create pauses for different providers
      assert {:ok, _} = RateLimitPause.create("session1", :anthropic, 600_000)
      assert {:ok, _} = RateLimitPause.create("session2", :anthropic, 600_000)
      assert {:ok, _} = RateLimitPause.create("session3", :openai, 600_000)

      stats = RateLimitPause.stats()

      assert stats.total_pauses == 3
      assert stats.pending_pauses == 3
      assert stats.resumed_pauses == 0
      assert stats.by_provider[:anthropic] == 2
      assert stats.by_provider[:openai] == 1
    end
  end

  describe "cleanup_expired/1" do
    test "removes old pause records" do
      session_id = "session_#{System.unique_integer([:positive])}"

      # Create a pause
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 60_000)

      # Manually make it old
      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      :ets.insert(:coding_agent_rate_limit_pauses, {
        pause.id,
        %{pause | paused_at: old_time}
      })

      # Cleanup with 1 minute max age
      count = RateLimitPause.cleanup_expired(60_000)
      assert count == 1

      # Verify it's gone
      assert {:error, :not_found} = RateLimitPause.get(pause.id)
    end

    test "keeps recent pause records" do
      session_id = "session_#{System.unique_integer([:positive])}"
      assert {:ok, pause} = RateLimitPause.create(session_id, :anthropic, 60_000)

      # Cleanup with 1 hour max age - should not remove
      count = RateLimitPause.cleanup_expired(3600_000)
      assert count == 0

      # Verify it's still there
      assert {:ok, _} = RateLimitPause.get(pause.id)
    end
  end
end
