defmodule LemonControlPlane.Methods.GamesTokenMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{GamesTokenIssue, GamesTokenRevoke, GamesTokensList}

  setup do
    clear_table(:game_agent_tokens)
    :ok
  end

  test "games.token.issue issues a token with claims" do
    assert GamesTokenIssue.name() == "games.token.issue"
    assert GamesTokenIssue.scopes() == [:admin]

    {:ok, result} =
      GamesTokenIssue.handle(%{"agentId" => "agent-a", "ownerId" => "owner-a", "ttlHours" => 1}, %{})

    assert is_binary(result["token"])
    assert String.starts_with?(result["token"], "lgm_")
    assert is_binary(result["tokenHash"])
    assert result["claims"]["agent_id"] == "agent-a"
    assert result["claims"]["owner_id"] == "owner-a"
  end

  test "games.tokens.list returns issued tokens and revoke marks revoked" do
    {:ok, issued} = GamesTokenIssue.handle(%{"agentId" => "agent-b", "ownerId" => "owner-b"}, %{})

    {:ok, listed_before} = GamesTokensList.handle(%{}, %{})
    assert GamesTokensList.name() == "games.tokens.list"
    assert GamesTokensList.scopes() == [:admin]

    assert Enum.any?(listed_before["tokens"], fn token ->
             token["token_hash"] == issued["tokenHash"] and token["status"] == "active"
           end)

    assert GamesTokenRevoke.name() == "games.token.revoke"
    assert GamesTokenRevoke.scopes() == [:admin]
    assert {:ok, %{"revoked" => true}} = GamesTokenRevoke.handle(%{"tokenHash" => issued["tokenHash"]}, %{})

    {:ok, listed_after} = GamesTokensList.handle(%{}, %{})

    assert Enum.any?(listed_after["tokens"], fn token ->
             token["token_hash"] == issued["tokenHash"] and token["status"] == "revoked"
           end)
  end

  defp clear_table(table) do
    table
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(table, key) end)
  end
end
