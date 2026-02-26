defmodule LemonControlPlane.Methods.GamesTokenIssue do
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "games.token.issue"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, agent_id} <- LemonControlPlane.Method.require_param(params, "agentId"),
         {:ok, owner_id} <- LemonControlPlane.Method.require_param(params, "ownerId") do
      {:ok, result} = LemonGames.Auth.issue_token(%{
        "agent_id" => agent_id,
        "owner_id" => owner_id,
        "scopes" => params["scopes"] || ["games:read", "games:play"],
        "ttl_hours" => params["ttlHours"]
      })

      {:ok, %{
        "token" => result.token,
        "tokenHash" => result.token_hash,
        "claims" => result.claims
      }}
    end
  end
end
