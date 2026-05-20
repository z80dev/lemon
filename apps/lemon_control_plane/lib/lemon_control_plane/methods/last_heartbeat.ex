defmodule LemonControlPlane.Methods.LastHeartbeat do
  @moduledoc """
  Handler for the last-heartbeat control plane method.

  Gets the last heartbeat status for an agent.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.HeartbeatStore

  @impl true
  def name, do: "last-heartbeat"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    agent_id = params["agentId"] || params["agent_id"] || "default"

    # Get heartbeat config
    config = HeartbeatStore.get_config(agent_id)

    # Get last heartbeat result
    last_result = HeartbeatStore.get_last(agent_id)
    last_run = format_last_run(last_result)

    {:ok,
     %{
       "agentId" => agent_id,
       "enabled" => (config && config[:enabled]) || false,
       "intervalMs" => config && config[:interval_ms],
       "lastRun" => last_run,
       "summary" => summary(config, last_run)
     }}
  end

  defp format_last_run(nil), do: nil

  defp format_last_run(last_result) do
    response = get_field(last_result, :response)

    %{
      "timestamp" => get_field(last_result, :timestamp_ms),
      "status" => to_string(get_field(last_result, :status) || :unknown),
      "response" => redact_response(response),
      "suppressed" => get_field(last_result, :suppressed) || false
    }
  end

  defp summary(config, last_run) do
    %{
      "configured" => is_map(config),
      "enabled" => (config && get_field(config, :enabled)) || false,
      "intervalMs" => config && get_field(config, :interval_ms),
      "hasLastRun" => is_map(last_run),
      "lastStatus" => last_run && last_run["status"],
      "lastSuppressed" => (last_run && last_run["suppressed"]) || false,
      "lastResponseLength" => response_length(last_run),
      "cleanup" => %{
        "includesResponse" => is_map(last_run),
        "redactsSensitiveResponse" => true,
        "includesPrompt" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp response_length(nil), do: 0

  defp response_length(%{"response" => response}) when is_binary(response),
    do: String.length(response)

  defp response_length(_), do: 0

  defp redact_response(response) when is_binary(response) do
    if sensitive_response?(response) do
      "[redacted]"
    else
      response
    end
  end

  defp redact_response(response), do: response

  defp sensitive_response?(response) do
    normalized = String.downcase(response)

    Enum.any?(["token", "secret", "password", "api_key", "apikey", "credential", "cookie"], fn
      marker -> String.contains?(normalized, marker)
    end)
  end

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
