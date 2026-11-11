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
        LemonCore.Store.list(:session_tokens)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:session_tokens, k)
        end)

        LemonCore.Store.list(:session_token_heads)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:session_token_heads, k)
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
      identity = %{"type" => "node", "nodeId" => "node-123"}

      # Store with atom keys (normal case)
      LemonCore.Store.put(:session_tokens, token, %{
        token: token,
        identity: identity,
        issued_at_ms: System.system_time(:millisecond),
        expires_at_ms: System.system_time(:millisecond) + 60_000
      })

      {:ok, retrieved_identity} = TokenStore.validate(token)
      assert retrieved_identity["type"] == "node"
      assert retrieved_identity["nodeId"] == "node-123"
    end

    test "rejects expired token with atom keys" do
      token = "expired-atom-token-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:session_tokens, token, %{
        token: token,
        identity: %{"type" => "node"},
        issued_at_ms: System.system_time(:millisecond) - 60_000,
        # Expired
        expires_at_ms: System.system_time(:millisecond) - 1000
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
        "identity" => %{"type" => "node"},
        "issued_at_ms" => System.system_time(:millisecond) - 60_000,
        # Expired
        "expires_at_ms" => System.system_time(:millisecond) - 1000
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
        "identity" => %{"type" => "node"},
        :issued_at_ms => System.system_time(:millisecond),
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, retrieved_identity} = TokenStore.validate(token)
      assert retrieved_identity["type"] == "node"
    end
  end

  describe "cleanup_expired/0" do
    test "returns count of expired tokens removed (not total count)" do
      # Create 3 valid tokens
      valid_tokens =
        for i <- 1..3 do
          token = "valid-token-#{i}-#{System.unique_integer([:positive])}"

          LemonCore.Store.put(:session_tokens, token, %{
            token: token,
            identity: %{"type" => "node"},
            issued_at_ms: System.system_time(:millisecond),
            expires_at_ms: System.system_time(:millisecond) + 60_000
          })

          token
        end

      # Create 2 expired tokens
      expired_tokens =
        for i <- 1..2 do
          token = "expired-token-#{i}-#{System.unique_integer([:positive])}"

          LemonCore.Store.put(:session_tokens, token, %{
            token: token,
            identity: %{"type" => "node"},
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
        identity: %{"type" => "node"},
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
        "identity" => %{"type" => "node"},
        "issued_at_ms" => System.system_time(:millisecond) - 60_000,
        "expires_at_ms" => System.system_time(:millisecond) - 1000
      })

      {:ok, expired_count} = TokenStore.cleanup_expired()
      assert expired_count == 1

      assert LemonCore.Store.get(:session_tokens, token) == nil
    end
  end

  describe "atomic node session replacement" do
    test "concurrent replacements leave exactly one accepted credential" do
      node_id = "atomic-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}

      replacements =
        1..12
        |> Enum.map(fn index ->
          token = "atomic-token-#{index}-#{System.unique_integer([:positive])}"

          Task.async(fn ->
            {token, TokenStore.replace_node_session(token, identity, ttl_ms: 60_000)}
          end)
        end)
        |> Enum.map(&Task.await(&1, 2_000))

      assert Enum.all?(replacements, fn {_token, result} -> match?({:ok, _}, result) end)

      accepted =
        Enum.filter(replacements, fn {token, _result} ->
          match?({:ok, _identity}, TokenStore.validate(token))
        end)

      assert [{accepted_token, {:ok, accepted_info}}] = accepted
      generation = accepted_info.identity["sessionGeneration"]
      assert generation == TokenStore.current_node_generation(node_id)
      assert generation == 12
      accepted_identity = accepted_info.identity
      assert {:ok, ^accepted_identity} = TokenStore.validate(accepted_token)
    end

    test "replacement switches directly from old token to new generation" do
      node_id = "rotated-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}

      assert {:ok, first} =
               TokenStore.replace_node_session("first-token", identity, ttl_ms: 60_000)

      first_identity = first.identity
      assert {:ok, ^first_identity} = TokenStore.validate("first-token")

      assert {:ok, second} =
               TokenStore.replace_node_session("second-token", identity, ttl_ms: 60_000)

      assert second.identity["sessionGeneration"] == first.identity["sessionGeneration"] + 1
      assert {:error, :invalid_token} = TokenStore.validate("first-token")
      second_identity = second.identity
      assert {:ok, ^second_identity} = TokenStore.validate("second-token")
    end
  end

  describe "list_active/0" do
    test "filters out expired tokens with string keys" do
      # Create valid token with string keys
      valid_token = "active-string-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:session_tokens, valid_token, %{
        "token" => valid_token,
        "identity" => %{"type" => "node"},
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
      assert active != []

      tokens =
        Enum.map(active, fn info ->
          info[:token] || info["token"]
        end)

      assert valid_token in tokens
      refute expired_token in tokens
    end
  end

  describe "node_session_ttl_ms/0" do
    test "returns 7 days in milliseconds" do
      assert TokenStore.node_session_ttl_ms() == 7 * 24 * 60 * 60 * 1000
    end
  end

  describe "touch_node_session/3" do
    test "extends current head token when gain exceeds min_extension_ms" do
      node_id = "touch-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token = "touch-token-#{System.unique_integer([:positive])}"

      assert {:ok, initial} =
               TokenStore.replace_node_session(token, identity, ttl_ms: 3 * 24 * 60 * 60 * 1000)

      # Two days after issue the session is still valid, and a touch slides it
      # to a full canonical TTL measured from the touch, not from issue.
      touch_time = initial.issued_at_ms + 2 * 24 * 60 * 60 * 1000
      expected_expiry = touch_time + TokenStore.node_session_ttl_ms()

      assert {:ok, ^expected_expiry} =
               TokenStore.touch_node_session(node_id, 1, now_ms: touch_time)

      assert LemonCore.Store.get(:session_tokens, token).expires_at_ms == expected_expiry
    end

    test "no-op when gain is below min_extension_ms" do
      node_id = "noop-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token = "noop-token-#{System.unique_integer([:positive])}"

      assert {:ok, initial} =
               TokenStore.replace_node_session(token, identity,
                 ttl_ms: TokenStore.node_session_ttl_ms()
               )

      # Ten minutes after issue the gain would be ten minutes, under the hour.
      touch_time = initial.issued_at_ms + 10 * 60 * 1000
      initial_expiry = initial.expires_at_ms

      assert {:ok, ^initial_expiry} =
               TokenStore.touch_node_session(node_id, 1, now_ms: touch_time)

      assert LemonCore.Store.get(:session_tokens, token).expires_at_ms == initial_expiry
    end

    test "writes once the gain reaches exactly min_extension_ms" do
      node_id = "boundary-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token = "boundary-token-#{System.unique_integer([:positive])}"

      assert {:ok, initial} =
               TokenStore.replace_node_session(token, identity,
                 ttl_ms: TokenStore.node_session_ttl_ms()
               )

      touch_time = initial.issued_at_ms + 3_600_000
      expected_expiry = touch_time + TokenStore.node_session_ttl_ms()

      assert {:ok, ^expected_expiry} =
               TokenStore.touch_node_session(node_id, 1, now_ms: touch_time)

      assert LemonCore.Store.get(:session_tokens, token).expires_at_ms == expected_expiry
    end

    test "refuses old generation" do
      node_id = "gen-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token1 = "gen-token-1-#{System.unique_integer([:positive])}"
      token2 = "gen-token-2-#{System.unique_integer([:positive])}"

      assert {:ok, _} = TokenStore.replace_node_session(token1, identity, ttl_ms: 60_000)
      assert {:ok, second} = TokenStore.replace_node_session(token2, identity, ttl_ms: 60_000)
      assert second.identity["sessionGeneration"] == 2

      assert {:error, :not_current} = TokenStore.touch_node_session(node_id, 1)
      assert {:error, :invalid_token} = TokenStore.validate(token1)
    end

    test "refuses revoked head" do
      node_id = "revoked-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token = "revoked-token-#{System.unique_integer([:positive])}"

      assert {:ok, _} = TokenStore.replace_node_session(token, identity, ttl_ms: 60_000)
      assert {:ok, 1} = TokenStore.revoke_identity("node", node_id)
      assert TokenStore.node_session_state(node_id) == :revoked

      assert {:error, :not_current} = TokenStore.touch_node_session(node_id, 1)
    end

    test "refuses expired token" do
      node_id = "expired-touch-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token = "expired-touch-token-#{System.unique_integer([:positive])}"

      assert {:ok, initial} =
               TokenStore.replace_node_session(token, identity, ttl_ms: 10_000)

      assert {:error, :expired} =
               TokenStore.touch_node_session(node_id, 1, now_ms: initial.expires_at_ms)

      assert {:error, :expired} =
               TokenStore.touch_node_session(node_id, 1, now_ms: initial.expires_at_ms + 10_000)
    end

    test "refuses a token record whose identity carries no session generation" do
      node_id = "no-generation-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token = "no-generation-token-#{System.unique_integer([:positive])}"

      assert {:ok, initial} =
               TokenStore.replace_node_session(token, identity, ttl_ms: 60_000)

      # A malformed reload drops sessionGeneration from the stored identity.
      LemonCore.Store.put(:session_tokens, token, %{
        initial
        | identity: Map.delete(initial.identity, "sessionGeneration")
      })

      assert {:error, :not_current} = TokenStore.touch_node_session(node_id, 1)
    end

    test "refuses a token record bound to a different node" do
      node_id = "bound-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token = "bound-token-#{System.unique_integer([:positive])}"

      assert {:ok, initial} =
               TokenStore.replace_node_session(token, identity, ttl_ms: 60_000)

      LemonCore.Store.put(:session_tokens, token, %{
        initial
        | identity: Map.put(initial.identity, "nodeId", node_id <> "-other")
      })

      assert {:error, :not_current} = TokenStore.touch_node_session(node_id, 1)
    end

    test "refuses when node has no head" do
      node_id = "nonexistent-node-#{System.unique_integer([:positive])}"
      assert {:error, :not_current} = TokenStore.touch_node_session(node_id, 1)
    end

    test "refuses malformed arguments without touching the store" do
      assert {:error, :not_current} = TokenStore.touch_node_session("", 1)
      assert {:error, :not_current} = TokenStore.touch_node_session(nil, 1)
      assert {:error, :not_current} = TokenStore.touch_node_session("node", nil)
      assert {:error, :not_current} = TokenStore.touch_node_session("node", -1)
    end

    test "handles string keys in token record" do
      node_id = "string-key-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      token = "string-key-token-#{System.unique_integer([:positive])}"

      assert {:ok, initial} =
               TokenStore.replace_node_session(token, identity, ttl_ms: 24 * 60 * 60 * 1000)

      # JSONL reload turns every key into a string.
      LemonCore.Store.put(:session_tokens, token, %{
        "token" => initial.token,
        "identity" => %{
          "type" => "node",
          "nodeId" => node_id,
          "sessionGeneration" => 1
        },
        "issued_at_ms" => initial.issued_at_ms,
        "expires_at_ms" => initial.expires_at_ms,
        "conn_id" => initial.conn_id
      })

      touch_time = initial.issued_at_ms + 12 * 60 * 60 * 1000
      expected_expiry = touch_time + TokenStore.node_session_ttl_ms()

      assert {:ok, ^expected_expiry} =
               TokenStore.touch_node_session(node_id, 1, now_ms: touch_time)

      updated = LemonCore.Store.get(:session_tokens, token)
      assert updated["expires_at_ms"] == expected_expiry
      refute Map.has_key?(updated, :expires_at_ms)
    end

    test "a rotation racing a touch never revives the superseded credential" do
      node_id = "cas-node-#{System.unique_integer([:positive])}"
      identity = %{"type" => "node", "nodeId" => node_id}
      first = "cas-token-1-#{System.unique_integer([:positive])}"
      second = "cas-token-2-#{System.unique_integer([:positive])}"

      assert {:ok, initial} =
               TokenStore.replace_node_session(first, identity, ttl_ms: 24 * 60 * 60 * 1000)

      touch_time = initial.issued_at_ms + 12 * 60 * 60 * 1000

      rotation =
        Task.async(fn ->
          TokenStore.replace_node_session(second, identity, ttl_ms: 24 * 60 * 60 * 1000)
        end)

      touch =
        Task.async(fn ->
          TokenStore.touch_node_session(node_id, 1, now_ms: touch_time)
        end)

      assert {:ok, rotated} = Task.await(rotation, 2_000)
      touch_result = Task.await(touch, 2_000)

      assert match?({:ok, _}, touch_result) or touch_result == {:error, :not_current}

      # Whatever the interleaving, only the new generation authenticates and the
      # superseded record is gone, so a touch can never resurrect it.
      assert rotated.identity["sessionGeneration"] == 2
      assert TokenStore.current_node_generation(node_id) == 2
      assert {:error, :invalid_token} = TokenStore.validate(first)
      rotated_identity = rotated.identity
      assert {:ok, ^rotated_identity} = TokenStore.validate(second)
      assert {:error, :not_current} = TokenStore.touch_node_session(node_id, 1)
    end
  end
end
