defmodule LemonControlPlane.Methods.GamesTokensList do
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
