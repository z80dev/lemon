defmodule LemonControlPlane.Methods.AgentEndpointsSet do
  @moduledoc """
  Handler for the `agent.endpoints.set` method.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agent.endpoints.set"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    agent_id = get_param(params, "agentId") || "default"
    name = get_param(params, "name")

    target =
      get_param(params, "target") || get_param(params, "to") || get_param(params, "endpoint") ||
        get_param(params, "route")

    description = get_param(params, "description")
    account_id = get_param(params, "accountId")
    peer_kind = get_param(params, "peerKind")

    cond do
      not (is_binary(agent_id) and String.trim(agent_id) != "") ->
        {:error, {:invalid_request, "agentId must be a non-empty string", nil}}

      not (is_binary(name) and String.trim(name) != "") ->
        {:error, {:invalid_request, "name is required", nil}}

      is_nil(target) ->
        {:error, {:invalid_request, "target (or to/endpoint/route) is required", nil}}

      true ->
        opts =
          []
          |> maybe_put(:description, description)
          |> maybe_put(:account_id, account_id)
          |> maybe_put(:peer_kind, peer_kind)

        case LemonRouter.set_agent_endpoint(agent_id, name, target, opts) do
          {:ok, endpoint} ->
            {:ok, %{"endpoint" => format_endpoint(endpoint)}}

          {:error, reason} ->
            {:error, {:invalid_request, "Failed to set endpoint alias", inspect(reason)}}
        end
    end
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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
