defmodule LemonControlPlane.Methods.AgentEndpointsList do
  @moduledoc """
  Handler for the `agent.endpoints.list` method.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agent.endpoints.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    agent_id = get_param(params, "agentId")
    limit = normalize_limit(get_param(params, "limit"))

    endpoints =
      LemonRouter.list_agent_endpoints(agent_id: agent_id, limit: limit)
      |> Enum.map(&format_endpoint/1)

    {:ok, %{"endpoints" => endpoints, "total" => length(endpoints)}}
  rescue
    e ->
      {:error, {:internal_error, "Failed to list endpoints", Exception.message(e)}}
  end

  defp format_endpoint(endpoint) do
    route = endpoint[:route] || %{}

    %{
      "id" => endpoint[:id],
      "agentId" => endpoint[:agent_id],
      "name" => endpoint[:name],
      "description" => endpoint[:description],
      "target" => endpoint[:target],
      "sessionKey" => endpoint[:session_key],
      "createdAtMs" => endpoint[:created_at_ms],
      "updatedAtMs" => endpoint[:updated_at_ms],
      "route" => %{
        "channelId" => route[:channel_id],
        "accountId" => route[:account_id],
        "peerKind" => route[:peer_kind] && to_string(route[:peer_kind]),
        "peerId" => route[:peer_id],
        "threadId" => route[:thread_id]
      }
    }
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_limit(_), do: nil

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
