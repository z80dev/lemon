defmodule LemonControlPlane.Methods.GamesTokenRevoke do
  @moduledoc """
  Handler for the `games.token.revoke` control plane method.

  Revokes a previously-issued games token by its hash, immediately
  invalidating it for all future requests. Requires the `:admin` scope.

  ## Required params

  - `tokenHash` — the hash of the token to revoke (as returned by `games.token.issue`)

  ## Returns

  - `revoked: true` on success
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "games.token.revoke"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, token_hash} <- LemonControlPlane.Method.require_param(params, "tokenHash") do
      :ok = LemonGames.Auth.revoke_token(token_hash)
      {:ok, %{"revoked" => true}}
    end
  end
end
