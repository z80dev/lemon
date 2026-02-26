defmodule LemonGames.AuthTest do
  use ExUnit.Case, async: false

  alias LemonGames.Auth

  test "issue_token returns plaintext, hash, and claims" do
    {:ok, result} = Auth.issue_token(%{"agent_id" => "a1", "owner_id" => "o1"})
    assert String.starts_with?(result.token, "lgm_")
    assert is_binary(result.token_hash)
    assert result.claims["agent_id"] == "a1"
    assert result.claims["status"] == "active"
  end

  test "validate_token accepts valid token" do
    {:ok, result} = Auth.issue_token(%{"agent_id" => "a2", "owner_id" => "o2"})
    assert {:ok, claims} = Auth.validate_token(result.token)
    assert claims["agent_id"] == "a2"
  end

  test "validate_token rejects unknown token" do
    assert {:error, :invalid_token} = Auth.validate_token("lgm_bogus_token")
  end

  test "validate_token rejects revoked token" do
    {:ok, result} = Auth.issue_token(%{"agent_id" => "a3", "owner_id" => "o3"})
    :ok = Auth.revoke_token(result.token_hash)
    assert {:error, :revoked_token} = Auth.validate_token(result.token)
  end

  test "validate_token rejects expired token" do
    {:ok, result} = Auth.issue_token(%{"agent_id" => "a4", "owner_id" => "o4", "ttl_hours" => 0})
    Process.sleep(5)
    assert {:error, :expired_token} = Auth.validate_token(result.token)
  end

  test "list_tokens returns issued tokens without plaintext" do
    {:ok, _} = Auth.issue_token(%{"agent_id" => "list_test", "owner_id" => "o5"})
    tokens = Auth.list_tokens()
    assert Enum.any?(tokens, fn t -> t["agent_id"] == "list_test" end)
    assert Enum.all?(tokens, fn t -> is_binary(t["token_hash"]) end)
  end

  test "has_scope? checks scope membership" do
    claims = %{"scopes" => ["games:read", "games:play"]}
    assert Auth.has_scope?(claims, "games:read")
    assert Auth.has_scope?(claims, "games:play")
    refute Auth.has_scope?(claims, "games:admin")
  end

  test "revoke_token is idempotent on nonexistent hash" do
    assert :ok = Auth.revoke_token("nonexistent_hash")
  end
end
