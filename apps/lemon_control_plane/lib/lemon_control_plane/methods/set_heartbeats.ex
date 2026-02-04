defmodule LemonControlPlane.Methods.SetHeartbeats do
  @moduledoc """
  Handler for the set-heartbeats control plane method.

  Configures heartbeat settings for an agent.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "set-heartbeats"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    agent_id = params["agentId"] || params["agent_id"] || "default"
    enabled = params["enabled"]
    interval_ms = params["intervalMs"] || params["interval_ms"]
    prompt = params["prompt"]

    cond do
      is_nil(enabled) ->
        {:error, Errors.invalid_request("enabled is required")}

      true ->
        config = %{
          agent_id: agent_id,
          enabled: enabled,
          interval_ms: interval_ms || 60_000,
          prompt: prompt || "HEARTBEAT",
          updated_at_ms: System.system_time(:millisecond)
        }

        # Store heartbeat config
        LemonCore.Store.put(:heartbeat_config, agent_id, config)

        # Notify HeartbeatManager if available
        if Code.ensure_loaded?(LemonAutomation.HeartbeatManager) do
          LemonAutomation.HeartbeatManager.update_config(agent_id, config)
        end

        {:ok, %{
          "agentId" => agent_id,
          "enabled" => enabled,
          "intervalMs" => config.interval_ms
        }}
    end
  end
end
