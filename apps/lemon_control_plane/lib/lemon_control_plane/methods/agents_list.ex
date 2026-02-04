defmodule LemonControlPlane.Methods.AgentsList do
  @moduledoc """
  Handler for the agents.list method.

  Returns a list of configured agents.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agents.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    agents = get_agents()
    {:ok, %{"agents" => agents}}
  end

  defp get_agents do
    # Get from LemonRouter.AgentProfiles if available
    if Code.ensure_loaded?(LemonRouter.AgentProfiles) and
       function_exported?(LemonRouter.AgentProfiles, :list, 0) do
      LemonRouter.AgentProfiles.list()
      |> Enum.map(&format_agent/1)
    else
      # Fallback: get from store
      get_agents_from_store()
    end
  rescue
    _ -> get_agents_from_store()
  end

  defp get_agents_from_store do
    case LemonCore.Store.list(:agents) do
      entries when is_list(entries) ->
        Enum.map(entries, fn {_key, agent} -> format_agent(agent) end)
      _ ->
        # Return default agent
        [%{
          "id" => "default",
          "name" => "Default Agent",
          "status" => "active",
          "model" => nil,
          "createdAtMs" => nil
        }]
    end
  rescue
    _ -> [%{"id" => "default", "name" => "Default Agent", "status" => "active"}]
  end

  defp format_agent(agent) when is_map(agent) do
    %{
      "id" => agent[:id] || agent["id"] || "default",
      "name" => agent[:name] || agent["name"] || "Unnamed Agent",
      "status" => to_string(agent[:status] || agent["status"] || :active),
      "model" => agent[:model] || agent["model"],
      "createdAtMs" => agent[:created_at_ms] || agent["createdAtMs"]
    }
  end
end
