defmodule LemonControlPlane.Methods.GamesTokenRevoke do
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
