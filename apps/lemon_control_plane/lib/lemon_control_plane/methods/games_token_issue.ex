defmodule LemonControlPlane.Methods.GamesTokenIssue do
  @moduledoc """
  Handler for the `games.token.issue` control plane method.

  Issues a signed games token for the given agent and owner, with an
  optional list of scopes and TTL. Requires the `:admin` scope.

  ## Required params

  - `agentId` — ID of the agent the token is issued to
  - `ownerId` — ID of the resource owner

  ## Optional params

  - `scopes` — list of permission scopes (default: `["games:read", "games:play"]`)
  - `ttlHours` — token lifetime in hours (default: implementation-defined)

  ## Returns

  - `token` — the signed token string
  - `tokenHash` — stable hash used to reference / revoke the token
  - `claims` — decoded claims embedded in the token
  """

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
