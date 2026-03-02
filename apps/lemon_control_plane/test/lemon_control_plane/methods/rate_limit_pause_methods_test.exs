defmodule LemonControlPlane.Methods.RateLimitPauseMethodsTest do
  @moduledoc """
  Tests for rate limit pause introspection API methods.
  """

  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    RateLimitPauseList,
    RateLimitPauseGet,
    RateLimitPauseStats
  }

  setup do
    # Clean up ETS table before each test
    table = :coding_agent_rate_limit_pauses
    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end
    :ok
  end

  describe "RateLimitPauseList" do
    test "lists all pauses for a session" do
      # Create test pauses
      {:ok, pause1} = CodingAgent.RateLimitPause.create("session_123", :anthropic, 60_000)
      {:ok, pause2} = CodingAgent.RateLimitPause.create("session_123", :openai, 30_000)
      {:ok, _pause3} = CodingAgent.RateLimitPause.create("session_456", :google, 45_000)

      assert {:ok, result} = RateLimitPauseList.handle(%{"sessionId" => "session_123"}, %{})

      assert result["sessionId"] == "session_123"
      assert result["total"] == 2
      assert length(result["pauses"]) == 2

      # Verify pause IDs are in the result
      pause_ids = Enum.map(result["pauses"], & &1["id"])
      assert pause1.id in pause_ids
      assert pause2.id in pause_ids
    end

    test "filters by pending status" do
      # Create pauses with short retry times so they can be resumed
      {:ok, pause1} = CodingAgent.RateLimitPause.create("session_123", :anthropic, 1)
      {:ok, pause2} = CodingAgent.RateLimitPause.create("session_123", :openai, 999_999)

      # Wait for pause1 to be ready and resume it
      Process.sleep(10)
      {:ok, _} = CodingAgent.RateLimitPause.resume(pause1.id)

      # List pending only
      assert {:ok, result} =
               RateLimitPauseList.handle(
                 %{"sessionId" => "session_123", "status" => "pending"},
                 %{}
               )

      assert result["total"] == 1
      assert [pause] = result["pauses"]
      assert pause["id"] == pause2.id
      assert pause["status"] == "paused"
    end

    test "returns error when sessionId is missing" do
      assert {:error, {:invalid_request, message, nil}} = RateLimitPauseList.handle(%{}, %{})
      assert message =~ "sessionId is required"
    end

    test "formats pause correctly" do
      {:ok, pause} =
        CodingAgent.RateLimitPause.create("session_123", :anthropic, 60_000,
          metadata: %{"error" => "Rate limit exceeded"}
        )

      assert {:ok, result} = RateLimitPauseList.handle(%{"sessionId" => "session_123"}, %{})
      assert [formatted] = result["pauses"]

      assert formatted["id"] == pause.id
      assert formatted["sessionId"] == "session_123"
      assert formatted["provider"] == "anthropic"
      assert formatted["status"] == "paused"
      assert formatted["retryAfterMs"] == 60_000
      assert formatted["pausedAt"] != nil
      assert formatted["resumeAt"] != nil
      assert formatted["resumedAt"] == nil
      assert formatted["metadata"] == %{"error" => "Rate limit exceeded"}
      assert is_boolean(formatted["readyToResume"])
    end

    test "accepts snake_case session_id" do
      {:ok, _} = CodingAgent.RateLimitPause.create("session_123", :anthropic, 60_000)

      assert {:ok, result} = RateLimitPauseList.handle(%{"session_id" => "session_123"}, %{})
      assert result["total"] == 1
    end
  end

  describe "RateLimitPauseGet" do
    test "gets a specific pause by ID" do
      {:ok, pause} = CodingAgent.RateLimitPause.create("session_123", :anthropic, 60_000)

      assert {:ok, result} = RateLimitPauseGet.handle(%{"pauseId" => pause.id}, %{})

      assert result["pause"]["id"] == pause.id
      assert result["pause"]["sessionId"] == "session_123"
      assert result["pause"]["provider"] == "anthropic"
    end

    test "returns error when pause not found" do
      assert {:error, {:not_found, message, details}} =
               RateLimitPauseGet.handle(%{"pauseId" => "nonexistent"}, %{})

      assert message =~ "not found"
      assert details["pauseId"] == "nonexistent"
    end

    test "returns error when pauseId is missing" do
      assert {:error, {:invalid_request, message, nil}} = RateLimitPauseGet.handle(%{}, %{})
      assert message =~ "pauseId is required"
    end

    test "accepts various id parameter names" do
      {:ok, pause} = CodingAgent.RateLimitPause.create("session_123", :anthropic, 60_000)

      # Test pause_id
      assert {:ok, _} = RateLimitPauseGet.handle(%{"pause_id" => pause.id}, %{})

      # Test id
      assert {:ok, _} = RateLimitPauseGet.handle(%{"id" => pause.id}, %{})
    end

    test "includes readyToResume flag" do
      # Create a pause with a very short retry time
      {:ok, pause} = CodingAgent.RateLimitPause.create("session_123", :anthropic, 100)

      # Wait for it to be ready
      Process.sleep(150)

      assert {:ok, result} = RateLimitPauseGet.handle(%{"pauseId" => pause.id}, %{})
      assert result["pause"]["readyToResume"] == true
    end
  end

  describe "RateLimitPauseStats" do
    test "returns aggregate statistics" do
      # Create some pauses
      {:ok, _} = CodingAgent.RateLimitPause.create("session_1", :anthropic, 60_000)
      {:ok, _} = CodingAgent.RateLimitPause.create("session_2", :anthropic, 60_000)
      {:ok, _} = CodingAgent.RateLimitPause.create("session_3", :openai, 60_000)

      assert {:ok, result} = RateLimitPauseStats.handle(%{}, %{})

      assert result["totalPauses"] == 3
      assert result["pendingPauses"] == 3
      assert result["resumedPauses"] == 0
      assert result["byProvider"]["anthropic"] == 2
      assert result["byProvider"]["openai"] == 1
    end

    test "counts resumed pauses correctly" do
      {:ok, pause1} = CodingAgent.RateLimitPause.create("session_1", :anthropic, 1)
      {:ok, pause2} = CodingAgent.RateLimitPause.create("session_2", :openai, 1)

      # Wait and resume
      Process.sleep(10)
      {:ok, _} = CodingAgent.RateLimitPause.resume(pause1.id)
      {:ok, _} = CodingAgent.RateLimitPause.resume(pause2.id)

      assert {:ok, result} = RateLimitPauseStats.handle(%{}, %{})

      assert result["totalPauses"] == 2
      assert result["pendingPauses"] == 0
      assert result["resumedPauses"] == 2
    end

    test "returns empty stats when no pauses exist" do
      assert {:ok, result} = RateLimitPauseStats.handle(%{}, %{})

      assert result["totalPauses"] == 0
      assert result["pendingPauses"] == 0
      assert result["resumedPauses"] == 0
      assert result["byProvider"] == %{}
    end

    test "converts provider atoms to strings" do
      {:ok, _} = CodingAgent.RateLimitPause.create("session_1", :anthropic, 60_000)

      assert {:ok, result} = RateLimitPauseStats.handle(%{}, %{})

      # Provider should be a string key
      assert Map.has_key?(result["byProvider"], "anthropic")
      assert is_integer(result["byProvider"]["anthropic"])
    end
  end
end
