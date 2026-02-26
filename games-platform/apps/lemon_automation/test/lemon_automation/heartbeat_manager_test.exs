defmodule LemonAutomation.HeartbeatManagerTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.HeartbeatManager
  alias LemonAutomation.CronJob

  describe "healthy_response?/1" do
    test "returns true for exact HEARTBEAT_OK" do
      assert HeartbeatManager.healthy_response?("HEARTBEAT_OK") == true
    end

    test "returns true for HEARTBEAT_OK with whitespace" do
      assert HeartbeatManager.healthy_response?("  HEARTBEAT_OK  ") == true
      assert HeartbeatManager.healthy_response?("\nHEARTBEAT_OK\n") == true
      assert HeartbeatManager.healthy_response?("\tHEARTBEAT_OK\t") == true
    end

    test "returns false for nil" do
      assert HeartbeatManager.healthy_response?(nil) == false
    end

    test "returns false for empty string" do
      assert HeartbeatManager.healthy_response?("") == false
    end

    test "returns false for case variations (parity requirement)" do
      # Per parity, only exact match is allowed
      assert HeartbeatManager.healthy_response?("heartbeat_ok") == false
      assert HeartbeatManager.healthy_response?("Heartbeat_Ok") == false
      assert HeartbeatManager.healthy_response?("HEARTBEAT_ok") == false
    end

    test "returns false for similar but different responses" do
      # These should NOT be suppressed per parity requirement
      assert HeartbeatManager.healthy_response?("HEARTBEAT: OK") == false
      assert HeartbeatManager.healthy_response?("HEARTBEAT OK") == false
      assert HeartbeatManager.healthy_response?("Status: OK") == false
      assert HeartbeatManager.healthy_response?("OK") == false
      assert HeartbeatManager.healthy_response?("HEARTBEAT_OK!") == false
      assert HeartbeatManager.healthy_response?("Agent HEARTBEAT_OK") == false
    end

    test "returns false for responses containing HEARTBEAT_OK" do
      # Must be exact match, not just contain
      assert HeartbeatManager.healthy_response?("Status: HEARTBEAT_OK") == false
      assert HeartbeatManager.healthy_response?("HEARTBEAT_OK - all good") == false
    end

    test "returns false for generic success messages" do
      assert HeartbeatManager.healthy_response?("success") == false
      assert HeartbeatManager.healthy_response?("healthy") == false
      assert HeartbeatManager.healthy_response?("alive") == false
    end
  end

  describe "heartbeat?/1" do
    defp make_job(name, opts \\ []) do
      CronJob.new(%{
        name: name,
        schedule: "* * * * *",
        agent_id: "agent-1",
        session_key: "session-1",
        prompt: "check",
        meta: Keyword.get(opts, :meta)
      })
    end

    test "returns true when name contains 'heartbeat' (case-insensitive)" do
      job = make_job("my-heartbeat-job")
      assert HeartbeatManager.heartbeat?(job) == true
    end

    test "returns true for various heartbeat name patterns" do
      assert HeartbeatManager.heartbeat?(make_job("HEARTBEAT")) == true
      assert HeartbeatManager.heartbeat?(make_job("Heartbeat Check")) == true
      assert HeartbeatManager.heartbeat?(make_job("daily-heartbeat")) == true
      assert HeartbeatManager.heartbeat?(make_job("agent_heartbeat_monitor")) == true
    end

    test "returns true when meta has heartbeat: true" do
      job = make_job("health-check", meta: %{heartbeat: true})
      assert HeartbeatManager.heartbeat?(job) == true
    end

    test "returns false for non-heartbeat jobs" do
      job = make_job("daily-backup")
      assert HeartbeatManager.heartbeat?(job) == false
    end

    test "returns false when meta has heartbeat: false" do
      job = make_job("regular-job", meta: %{heartbeat: false})
      assert HeartbeatManager.heartbeat?(job) == false
    end

    test "handles nil name gracefully" do
      job = make_job(nil)
      assert HeartbeatManager.heartbeat?(job) == false
    end

    test "handles nil meta gracefully" do
      job = make_job("regular-job", meta: nil)
      assert HeartbeatManager.heartbeat?(job) == false
    end
  end
end
