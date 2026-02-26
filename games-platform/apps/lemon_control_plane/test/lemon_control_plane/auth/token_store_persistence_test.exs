defmodule LemonControlPlane.Auth.TokenStorePersistenceTest do
  @moduledoc """
  Tests for TokenStore persistence across restart (string vs atom keys).

  After JSONL reload, keys become strings. These tests verify the TokenStore
  handles both atom and string keys correctly.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.TokenStore

  setup do
    # Clean up token store after each test
    on_exit(fn ->
      try do
        LemonCore.Store.list(:session_tokens) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:session_tokens, k)
        end)
      rescue
        _ -> :ok
      end
    end)
    :ok
  end

  describe "validate/1 with atom keys" do
    test "validates token with atom keys" do
      token = "atom-key-token-#{System.unique_integer([:positive])}"
      identity = %{"type" => "device", "deviceId" => "dev-123"}

      # Store with atom keys (normal case)
      LemonCore.Store.put(:session_tokens, token, %{
        token: token,
        identity: identity,
        issued_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 60_000
      })

      {:ok, retrieved_identity} = TokenStore.validate(token)
      assert retrieved_identity["type"] == "device"
      assert retrieved_identity["deviceId"] == "dev-123"
    end

    test "rejects expired token with atom keys" do
      token = "expired-atom-token-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:session_tokens, token, %{
        token: token,
        identity: %{"type" => "device"},
        issued_at_ms: System.system_time(:millisecond) - 60_000,
        expires_at_ms: System.system_time(:millisecond) - 1000  # Expired
      })

      {:error, :expired_token} = TokenStore.validate(token)

      # Token should be cleaned up
      assert LemonCore.Store.get(:session_tokens, token) == nil
    end
  end

  describe "validate/1 with string keys (JSONL reload)" do
    test "validates token with string keys" do
      token = "string-key-token-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => "node-456"}

      # Store with string keys (simulates JSONL reload)
      LemonCore.Store.put(:session_tokens, token, %{
        "token" => token,
        "identity" => identity,
        "issued_at_ms" => System.system_time(:millisecond),
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, retrieved_identity} = TokenStore.validate(token)
      assert retrieved_identity["type"] == "node"
      assert retrieved_identity["nodeId"] == "node-456"
    end

    test "rejects expired token with string keys" do
      token = "expired-string-token-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:session_tokens, token, %{
        "token" => token,
        "identity" => %{"type" => "device"},
        "issued_at_ms" => System.system_time(:millisecond) - 60_000,
        "expires_at_ms" => System.system_time(:millisecond) - 1000  # Expired
      })

      {:error, :expired_token} = TokenStore.validate(token)

      # Token should be cleaned up
      assert LemonCore.Store.get(:session_tokens, token) == nil
    end

    test "handles mixed atom and string keys" do
      token = "mixed-key-token-#{System.unique_integer([:positive])}"

      # Mix of atom and string keys (edge case)
      LemonCore.Store.put(:session_tokens, token, %{
        :token => token,
        "identity" => %{"type" => "device"},
        :issued_at_ms => System.system_time(:millisecond),
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, retrieved_identity} = TokenStore.validate(token)
      assert retrieved_identity["type"] == "device"
    end
  end

  describe "cleanup_expired/0" do
    test "returns count of expired tokens removed (not total count)" do
      # Create 3 valid tokens
      valid_tokens = for i <- 1..3 do
        token = "valid-token-#{i}-#{System.unique_integer([:positive])}"
        LemonCore.Store.put(:session_tokens, token, %{
          token: token,
          identity: %{"type" => "device"},
          issued_at_ms: System.system_time(:millisecond),
          expires_at_ms: System.system_time(:millisecond) + 60_000
        })
        token
      end

      # Create 2 expired tokens
      expired_tokens = for i <- 1..2 do
        token = "expired-token-#{i}-#{System.unique_integer([:positive])}"
        LemonCore.Store.put(:session_tokens, token, %{
          token: token,
          identity: %{"type" => "device"},
          issued_at_ms: System.system_time(:millisecond) - 60_000,
          expires_at_ms: System.system_time(:millisecond) - 1000
        })
        token
      end

      {:ok, expired_count} = TokenStore.cleanup_expired()

      # Should return 2 (number of expired tokens removed), not 5 (total)
      assert expired_count == 2

      # Valid tokens should still exist
      for token <- valid_tokens do
        assert LemonCore.Store.get(:session_tokens, token) != nil
      end

      # Expired tokens should be removed
      for token <- expired_tokens do
        assert LemonCore.Store.get(:session_tokens, token) == nil
      end
    end

    test "returns 0 when no tokens are expired" do
      token = "not-expired-#{System.unique_integer([:positive])}"
      LemonCore.Store.put(:session_tokens, token, %{
        token: token,
        identity: %{"type" => "device"},
        issued_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 60_000
      })

      {:ok, expired_count} = TokenStore.cleanup_expired()
      assert expired_count == 0
    end

    test "handles string keys when cleaning up" do
      # Create expired token with string keys
      token = "expired-string-cleanup-#{System.unique_integer([:positive])}"
      LemonCore.Store.put(:session_tokens, token, %{
        "token" => token,
        "identity" => %{"type" => "device"},
        "issued_at_ms" => System.system_time(:millisecond) - 60_000,
        "expires_at_ms" => System.system_time(:millisecond) - 1000
      })

      {:ok, expired_count} = TokenStore.cleanup_expired()
      assert expired_count == 1

      assert LemonCore.Store.get(:session_tokens, token) == nil
    end
  end

  describe "list_active/0" do
    test "filters out expired tokens with string keys" do
      # Create valid token with string keys
      valid_token = "active-string-#{System.unique_integer([:positive])}"
      LemonCore.Store.put(:session_tokens, valid_token, %{
        "token" => valid_token,
        "identity" => %{"type" => "device"},
        "issued_at_ms" => System.system_time(:millisecond),
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      # Create expired token with string keys
      expired_token = "inactive-string-#{System.unique_integer([:positive])}"
      LemonCore.Store.put(:session_tokens, expired_token, %{
        "token" => expired_token,
        "identity" => %{"type" => "node"},
        "issued_at_ms" => System.system_time(:millisecond) - 60_000,
        "expires_at_ms" => System.system_time(:millisecond) - 1000
      })

      active = TokenStore.list_active()

      # Should only return the active token
      assert length(active) >= 1
      tokens = Enum.map(active, fn info ->
        info[:token] || info["token"]
      end)
      assert valid_token in tokens
      refute expired_token in tokens
    end
  end
end
