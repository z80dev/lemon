defmodule LemonControlPlane.Methods.GamesTokensList do
  @moduledoc """
  Handler for the `games.tokens.list` control plane method.

  Returns all active games tokens known to `LemonGames.Auth`. Useful for
  auditing issued tokens or finding the hash of a token to revoke.
  Requires the `:admin` scope. Takes no parameters.

  ## Returns

  - `tokens` — list of token records as returned by `LemonGames.Auth.list_tokens/0`
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "games.tokens.list"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(_params, _ctx) do
    tokens = LemonGames.Auth.list_tokens()
    {:ok, %{"tokens" => tokens}}
  end
end
