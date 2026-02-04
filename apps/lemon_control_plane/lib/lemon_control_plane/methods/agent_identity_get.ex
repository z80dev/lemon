defmodule LemonControlPlane.Methods.AgentIdentityGet do
  @moduledoc """
  Handler for the agent.identity.get control plane method.

  Gets the identity/profile for an agent.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agent.identity.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    agent_id = params["agentId"] || params["agent_id"] || "default"

    # Try to get agent profile
    identity =
      cond do
        Code.ensure_loaded?(LemonRouter.AgentProfiles) ->
          case LemonRouter.AgentProfiles.get(agent_id) do
            nil -> default_identity(agent_id)
            profile -> profile_to_identity(profile)
          end

        true ->
          # Fallback: get from store
          case LemonCore.Store.get(:agents, agent_id) do
            nil -> default_identity(agent_id)
            agent -> agent_to_identity(agent)
          end
      end

    {:ok, identity}
  end

  defp default_identity(agent_id) do
    %{
      "agentId" => agent_id,
      "name" => agent_id,
      "description" => nil,
      "avatar" => nil,
      "defaultEngine" => "lemon",
      "capabilities" => %{
        "streaming" => true,
        "tools" => true,
        "vision" => false,
        "voice" => false
      }
    }
  end

  defp profile_to_identity(profile) do
    %{
      "agentId" => profile[:id] || profile[:agent_id],
      "name" => profile[:name] || profile[:id],
      "description" => profile[:description],
      "avatar" => profile[:avatar],
      "defaultEngine" => profile[:default_engine] || "lemon",
      "capabilities" => %{
        "streaming" => profile[:streaming] != false,
        "tools" => profile[:tools] != false,
        "vision" => profile[:vision] || false,
        "voice" => profile[:voice] || false
      }
    }
  end

  defp agent_to_identity(agent) do
    %{
      "agentId" => agent[:id] || agent["id"],
      "name" => agent[:name] || agent["name"] || agent[:id],
      "description" => agent[:description] || agent["description"],
      "avatar" => agent[:avatar] || agent["avatar"],
      "defaultEngine" => agent[:default_engine] || agent["defaultEngine"] || "lemon",
      "capabilities" => agent[:capabilities] || agent["capabilities"] || %{}
    }
  end
end
