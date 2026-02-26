defmodule LemonControlPlane.Methods.AgentEndpointsDelete do
  @moduledoc """
  Handler for the `agent.endpoints.delete` method.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agent.endpoints.delete"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    agent_id = get_param(params, "agentId") || "default"
    name = get_param(params, "name")

    cond do
      not (is_binary(agent_id) and String.trim(agent_id) != "") ->
        {:error, {:invalid_request, "agentId must be a non-empty string", nil}}

      not (is_binary(name) and String.trim(name) != "") ->
        {:error, {:invalid_request, "name is required", nil}}

      true ->
        case LemonRouter.delete_agent_endpoint(agent_id, name) do
          :ok ->
            {:ok,
             %{"ok" => true, "agentId" => String.trim(agent_id), "name" => String.trim(name)}}

          {:error, reason} ->
            {:error, {:invalid_request, "Failed to delete endpoint alias", inspect(reason)}}
        end
    end
  end

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
