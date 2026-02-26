defmodule LemonControlPlane.Methods.GamesTokenMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{GamesTokenIssue, GamesTokenRevoke, GamesTokensList}

  setup do
    LemonCore.Store.list(:game_agent_tokens)
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(:game_agent_tokens, key) end)

    :ok
  end

  test "games.token.issue issues token with defaults" do
    assert GamesTokenIssue.name() == "games.token.issue"
    assert GamesTokenIssue.scopes() == [:admin]

    assert {:ok, result} =
             GamesTokenIssue.handle(%{"agentId" => "agent_1", "ownerId" => "owner_1"}, %{})

    assert String.starts_with?(result["token"], "lgm_")
    assert is_binary(result["tokenHash"])
    assert result["claims"]["agent_id"] == "agent_1"
    assert result["claims"]["owner_id"] == "owner_1"
    assert result["claims"]["scopes"] == ["games:read", "games:play"]
  end

  test "games.token.issue returns invalid request when required params missing" do
    assert {:error, {:invalid_request, _, _}} = GamesTokenIssue.handle(%{"ownerId" => "owner_1"}, %{})
    assert {:error, {:invalid_request, _, _}} = GamesTokenIssue.handle(%{"agentId" => "agent_1"}, %{})
  end

  test "games.tokens.list returns issued tokens without plaintext" do
    {:ok, _} = GamesTokenIssue.handle(%{"agentId" => "agent_1", "ownerId" => "owner_1"}, %{})
    {:ok, _} = GamesTokenIssue.handle(%{"agentId" => "agent_2", "ownerId" => "owner_2"}, %{})

    assert GamesTokensList.name() == "games.tokens.list"
    assert GamesTokensList.scopes() == [:admin]

    assert {:ok, %{"tokens" => tokens}} = GamesTokensList.handle(%{}, %{})
    assert length(tokens) == 2

    refute Enum.any?(tokens, &Map.has_key?(&1, "token"))
    assert Enum.all?(tokens, &is_binary(&1["token_hash"]))
  end

  test "games.token.revoke marks token revoked" do
    {:ok, issue} = GamesTokenIssue.handle(%{"agentId" => "agent_1", "ownerId" => "owner_1"}, %{})

    assert GamesTokenRevoke.name() == "games.token.revoke"
    assert GamesTokenRevoke.scopes() == [:admin]

    assert {:ok, %{"revoked" => true}} =
             GamesTokenRevoke.handle(%{"tokenHash" => issue["tokenHash"]}, %{})

    assert {:error, :revoked_token} = LemonGames.Auth.validate_token(issue["token"])
  end

  test "games.token.revoke requires tokenHash" do
    assert {:error, {:invalid_request, _, _}} = GamesTokenRevoke.handle(%{}, %{})
  end
end
