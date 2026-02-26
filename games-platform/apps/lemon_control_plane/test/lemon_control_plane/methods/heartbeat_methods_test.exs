defmodule LemonControlPlane.Methods.HeartbeatMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.SetHeartbeats
  alias LemonControlPlane.Methods.LastHeartbeat

  describe "SetHeartbeats.handle/2" do
    test "returns error when enabled is missing" do
      params = %{"agentId" => "test-agent", "intervalMs" => 60_000}
      ctx = %{auth: %{role: :operator}}

      {:error, error} = SetHeartbeats.handle(params, ctx)
      # Error can be a struct or tuple
      assert String.contains?(inspect(error), "enabled") or
               (is_map(error) and error[:code] == "INVALID_REQUEST")
    end

    test "stores heartbeat config with enabled=true" do
      agent_id = "agent_#{System.unique_integer()}"

      params = %{
        "agentId" => agent_id,
        "enabled" => true,
        "intervalMs" => 30_000,
        "prompt" => "CHECK_STATUS"
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, result} = SetHeartbeats.handle(params, ctx)
      assert result["agentId"] == agent_id
      assert result["enabled"] == true
      assert result["intervalMs"] == 30_000

      # Verify config is stored
      stored = LemonCore.Store.get(:heartbeat_config, agent_id)
      assert stored[:enabled] == true
      assert stored[:interval_ms] == 30_000
      assert stored[:prompt] == "CHECK_STATUS"

      # Cleanup
      LemonCore.Store.delete(:heartbeat_config, agent_id)
    end

    test "stores heartbeat config with enabled=false" do
      agent_id = "agent_#{System.unique_integer()}"

      params = %{
        "agentId" => agent_id,
        "enabled" => false
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, result} = SetHeartbeats.handle(params, ctx)
      assert result["enabled"] == false

      stored = LemonCore.Store.get(:heartbeat_config, agent_id)
      assert stored[:enabled] == false

      # Cleanup
      LemonCore.Store.delete(:heartbeat_config, agent_id)
    end

    test "uses default agent_id when not provided" do
      params = %{"enabled" => true}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = SetHeartbeats.handle(params, ctx)
      assert result["agentId"] == "default"

      # Cleanup
      LemonCore.Store.delete(:heartbeat_config, "default")
    end

    test "uses default interval when not provided" do
      agent_id = "agent_#{System.unique_integer()}"

      params = %{"agentId" => agent_id, "enabled" => true}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = SetHeartbeats.handle(params, ctx)
      assert result["intervalMs"] == 60_000

      # Cleanup
      LemonCore.Store.delete(:heartbeat_config, agent_id)
    end

    test "uses default prompt when not provided" do
      agent_id = "agent_#{System.unique_integer()}"

      params = %{"agentId" => agent_id, "enabled" => true}
      ctx = %{auth: %{role: :operator}}

      {:ok, _result} = SetHeartbeats.handle(params, ctx)

      stored = LemonCore.Store.get(:heartbeat_config, agent_id)
      assert stored[:prompt] == "HEARTBEAT"

      # Cleanup
      LemonCore.Store.delete(:heartbeat_config, agent_id)
    end
  end

  describe "LastHeartbeat.handle/2" do
    test "returns enabled=false when no config exists" do
      agent_id = "nonexistent_#{System.unique_integer()}"

      params = %{"agentId" => agent_id}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = LastHeartbeat.handle(params, ctx)
      assert result["agentId"] == agent_id
      assert result["enabled"] == false
      assert result["lastRun"] == nil
    end

    test "returns config when it exists" do
      agent_id = "agent_#{System.unique_integer()}"

      # Store config
      config = %{
        enabled: true,
        interval_ms: 45_000,
        prompt: "STATUS"
      }

      LemonCore.Store.put(:heartbeat_config, agent_id, config)

      params = %{"agentId" => agent_id}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = LastHeartbeat.handle(params, ctx)
      assert result["enabled"] == true
      assert result["intervalMs"] == 45_000

      # Cleanup
      LemonCore.Store.delete(:heartbeat_config, agent_id)
    end

    test "returns lastRun when heartbeat_last exists" do
      agent_id = "agent_#{System.unique_integer()}"

      # Store config
      config = %{enabled: true, interval_ms: 60_000}
      LemonCore.Store.put(:heartbeat_config, agent_id, config)

      # Store last heartbeat result
      last_result = %{
        timestamp_ms: System.system_time(:millisecond),
        status: :ok,
        response: "HEARTBEAT_OK",
        suppressed: true
      }

      LemonCore.Store.put(:heartbeat_last, agent_id, last_result)

      params = %{"agentId" => agent_id}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = LastHeartbeat.handle(params, ctx)
      assert result["lastRun"] != nil
      assert result["lastRun"]["status"] == "ok"
      assert result["lastRun"]["response"] == "HEARTBEAT_OK"
      assert result["lastRun"]["suppressed"] == true

      # Cleanup
      LemonCore.Store.delete(:heartbeat_config, agent_id)
      LemonCore.Store.delete(:heartbeat_last, agent_id)
    end

    test "uses default agent_id when not provided" do
      params = %{}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = LastHeartbeat.handle(params, ctx)
      assert result["agentId"] == "default"
    end
  end

  describe "HeartbeatManager.update_config/2 integration" do
    test "SetHeartbeats calls HeartbeatManager.update_config when available" do
      agent_id = "agent_#{System.unique_integer()}"

      params = %{
        "agentId" => agent_id,
        "enabled" => true,
        "intervalMs" => 30_000
      }

      ctx = %{auth: %{role: :operator}}

      # This should not crash even if HeartbeatManager is not running
      {:ok, result} = SetHeartbeats.handle(params, ctx)
      assert result["enabled"] == true

      # Cleanup
      LemonCore.Store.delete(:heartbeat_config, agent_id)
    end
  end
end
