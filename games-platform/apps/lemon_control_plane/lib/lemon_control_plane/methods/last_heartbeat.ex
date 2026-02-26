defmodule LemonControlPlane.Methods.LastHeartbeat do
  @moduledoc """
  Handler for the last-heartbeat control plane method.

  Gets the last heartbeat status for an agent.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "last-heartbeat"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    agent_id = params["agentId"] || params["agent_id"] || "default"

    # Get heartbeat config
    config = LemonCore.Store.get(:heartbeat_config, agent_id)

    # Get last heartbeat result
    last_result = LemonCore.Store.get(:heartbeat_last, agent_id)

    {:ok, %{
      "agentId" => agent_id,
      "enabled" => config && config[:enabled] || false,
      "intervalMs" => config && config[:interval_ms],
      "lastRun" =>
        if last_result do
          %{
            "timestamp" => last_result[:timestamp_ms],
            "status" => to_string(last_result[:status] || :unknown),
            "response" => last_result[:response],
            "suppressed" => last_result[:suppressed] || false
          }
        else
          nil
        end
    }}
  end
end
