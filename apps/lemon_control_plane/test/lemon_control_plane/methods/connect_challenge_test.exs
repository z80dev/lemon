defmodule LemonControlPlane.Methods.ConnectChallengeTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{ConnectChallenge, NodePairRequest, NodePairApprove}

  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.NodeStore

  @pairing_ctx %{conn_id: "test-conn", auth: %{role: :operator, scopes: [:pairing]}}
  @challenge_ctx %{conn_id: "test-conn"}

  setup do
    # Clean up stores after each test
    on_exit(fn ->
      try do
        # Clean up node pairing stores
        LemonCore.Store.list(:nodes_pairing)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_pairing, k)
        end)

        LemonCore.Store.list(:nodes_pairing_by_code)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_pairing_by_code, k)
        end)

        LemonCore.Store.list(:node_challenges)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:node_challenges, k)
        end)

        LemonCore.Store.list(:nodes_registry)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_registry, k)
        end)

        LemonCore.Store.list(:nodes_by_name)
        |> Enum.each(fn {k, _} -> LemonCore.Store.delete(:nodes_by_name, k) end)

        LemonCore.Store.list(:session_tokens)
        |> Enum.each(fn {k, _} -> LemonCore.Store.delete(:session_tokens, k) end)

        LemonCore.Store.list(:session_token_heads)
        |> Enum.each(fn {k, _} -> LemonCore.Store.delete(:session_token_heads, k) end)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "ConnectChallenge" do
    test "requires challenge parameter" do
      {:error, error} = ConnectChallenge.handle(%{}, @challenge_ctx)

      assert {:invalid_request, "challenge is required"} = error
    end

    test "returns error for invalid challenge" do
      {:error, error} = ConnectChallenge.handle(%{"challenge" => "invalid-token"}, @challenge_ctx)

      assert {:unauthorized, "Invalid challenge"} = error
    end

    test "has no auth scopes required" do
      assert ConnectChallenge.scopes() == []
    end

    test "a leftover device pairing challenge no longer authenticates" do
      challenge = "legacy-device-challenge-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:device_pairing_challenges, challenge, %{
        device_id: "device-legacy",
        device_name: "Legacy Device",
        expires_at_ms: System.system_time(:millisecond) + 60_000
      })

      on_exit(fn -> LemonCore.Store.delete(:device_pairing_challenges, challenge) end)

      assert {:error, {:unauthorized, "Invalid challenge"}} =
               ConnectChallenge.handle(%{"challenge" => challenge}, @challenge_ctx)
    end
  end

  describe "node pairing flow with connect.challenge" do
    test "full node pairing flow produces valid challenge token" do
      # Step 1: Request node pairing
      {:ok, request_result} =
        NodePairRequest.handle(
          %{
            "nodeType" => "compute",
            "nodeName" => "Test Worker"
          },
          @pairing_ctx
        )

      pairing_id = request_result["pairingId"]
      code = request_result["code"]
      assert is_binary(pairing_id)
      assert is_binary(code)

      # Step 2: Approve the pairing (this creates the challenge)
      {:ok, approve_result} =
        NodePairApprove.handle(
          %{
            "pairingId" => pairing_id
          },
          @pairing_ctx
        )

      assert approve_result["approved"] == true
      challenge_token = approve_result["challengeToken"]
      assert is_binary(challenge_token)
      assert is_binary(approve_result["nodeId"])
      assert is_binary(approve_result["token"])

      # Step 3: Verify challenge via connect.challenge
      {:ok, verify_result} =
        ConnectChallenge.handle(
          %{
            "challenge" => challenge_token
          },
          @challenge_ctx
        )

      assert verify_result["verified"] == true
      assert verify_result["identity"]["type"] == "node"
      assert verify_result["identity"]["nodeName"] == "Test Worker"
      assert is_binary(verify_result["token"])
      assert verify_result["summary"]["verified"] == true
      assert verify_result["summary"]["identityType"] == "node"
      assert verify_result["summary"]["identityId"] == verify_result["identity"]["nodeId"]
      assert verify_result["summary"]["credentialDelivery"]["includesSessionToken"] == true
      assert verify_result["summary"]["cleanup"]["includesChallenge"] == false
      assert verify_result["summary"]["cleanup"]["includesChallengeToken"] == false
      assert verify_result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "node challenge token is one-time use" do
      # Setup node pairing
      {:ok, request} =
        NodePairRequest.handle(
          %{
            "nodeType" => "storage",
            "nodeName" => "Storage Node"
          },
          @pairing_ctx
        )

      {:ok, approve} =
        NodePairApprove.handle(
          %{
            "pairingId" => request["pairingId"]
          },
          @pairing_ctx
        )

      challenge_token = approve["challengeToken"]

      # First use should succeed
      {:ok, _} = ConnectChallenge.handle(%{"challenge" => challenge_token}, @challenge_ctx)

      # Second use should fail
      {:error, error} = ConnectChallenge.handle(%{"challenge" => challenge_token}, @challenge_ctx)
      assert {:unauthorized, "Invalid challenge"} = error
    end

    test "concurrent exchanges atomically consume a node challenge once" do
      {:ok, request} =
        NodePairRequest.handle(
          %{"nodeType" => "coding_agent", "nodeName" => "Concurrent Challenge Node"},
          @pairing_ctx
        )

      {:ok, approved} =
        NodePairApprove.handle(%{"pairingId" => request["pairingId"]}, @pairing_ctx)

      results =
        1..12
        |> Enum.map(fn index ->
          Task.async(fn ->
            ConnectChallenge.handle(
              %{"challenge" => approved["challengeToken"]},
              %{conn_id: "concurrent-#{index}"}
            )
          end)
        end)
        |> Enum.map(&Task.await(&1, 2_000))

      assert Enum.count(results, &match?({:ok, %{"verified" => true}}, &1)) == 1

      assert Enum.count(results, &match?({:error, {:unauthorized, "Invalid challenge"}}, &1)) ==
               11

      assert NodeStore.get_challenge(approved["challengeToken"]) == nil
    end

    test "expired node challenge returns error" do
      expired_challenge = "expired-node-challenge-456"

      LemonCore.Store.put(:node_challenges, expired_challenge, %{
        node_id: "node-456",
        node_name: "Old Node",
        expires_at_ms: System.system_time(:millisecond) - 1000
      })

      {:error, error} =
        ConnectChallenge.handle(%{"challenge" => expired_challenge}, @challenge_ctx)

      assert {:unauthorized, "Challenge expired"} = error

      # Challenge should be cleaned up
      assert LemonCore.Store.get(:node_challenges, expired_challenge) == nil
    end

    test "expired seven-day session rotates on the same durable node and revokes older sessions" do
      {:ok, request} =
        NodePairRequest.handle(
          %{"nodeType" => "coding_agent", "nodeName" => "Rotating Worker"},
          @pairing_ctx
        )

      {:ok, approved} =
        NodePairApprove.handle(%{"pairingId" => request["pairingId"]}, @pairing_ctx)

      node_id = approved["nodeId"]
      recovery_token = approved["token"]

      {:ok, first} =
        ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, @challenge_ctx)

      first_info = TokenStore.get_info(first["token"])
      assert first_info.expires_at_ms - first_info.issued_at_ms == 7 * 24 * 60 * 60 * 1_000

      LemonCore.Store.put(
        :session_tokens,
        first["token"],
        Map.put(first_info, :expires_at_ms, System.system_time(:millisecond) - 1)
      )

      assert {:error, :expired_token} = TokenStore.validate(first["token"])

      {:ok, _old_active} =
        TokenStore.store(
          "older-active-session",
          %{"type" => "node", "nodeId" => node_id, "nodeName" => "Rotating Worker"},
          ttl_ms: 60_000
        )

      {:ok, recovery} =
        NodePairRequest.handle(
          %{
            "nodeId" => node_id,
            "nodeName" => "Rotating Worker",
            "nodeType" => "coding_agent",
            "recoveryToken" => recovery_token
          },
          @pairing_ctx
        )

      {:ok, rotated} =
        NodePairApprove.handle(%{"pairingId" => recovery["pairingId"]}, @pairing_ctx)

      assert rotated["nodeId"] == node_id
      assert rotated["summary"]["recovered"] == true
      refute Map.has_key?(rotated, "token")

      {:ok, second} =
        ConnectChallenge.handle(%{"challenge" => rotated["challengeToken"]}, @challenge_ctx)

      assert {:ok, %{"nodeId" => ^node_id}} = TokenStore.validate(second["token"])
      assert {:error, :invalid_token} = TokenStore.validate("older-active-session")
      assert length(NodeStore.list_nodes()) == 1
    end
  end

  describe "challenge token security" do
    test "challenge tokens are cryptographically random" do
      token_a = node_challenge_token("Random A")
      token_b = node_challenge_token("Random B")

      # Tokens should be different
      assert token_a != token_b

      # Tokens should be long enough for security
      assert byte_size(token_a) >= 32
      assert byte_size(token_b) >= 32
    end
  end

  describe "session token storage and validation" do
    alias LemonControlPlane.Auth.Authorize

    setup do
      # Clean up token store after each test
      on_exit(fn ->
        try do
          LemonCore.Store.list(:session_tokens)
          |> Enum.each(fn {k, _} ->
            LemonCore.Store.delete(:session_tokens, k)
          end)
        rescue
          _ -> :ok
        end
      end)

      :ok
    end

    test "issued session token is stored in TokenStore" do
      # Verify the challenge - this should store the session token
      {:ok, verify_result} =
        ConnectChallenge.handle(
          %{"challenge" => node_challenge_token("Token Test Node")},
          @challenge_ctx
        )

      session_token = verify_result["token"]
      assert is_binary(session_token)

      # Verify token is stored
      token_info = TokenStore.get_info(session_token)
      assert token_info != nil
      assert token_info.identity["type"] == "node"
      assert token_info.identity["nodeName"] == "Token Test Node"
    end

    test "stored session token can be validated" do
      {:ok, verify_result} =
        ConnectChallenge.handle(
          %{"challenge" => node_challenge_token("Validation Test")},
          @challenge_ctx
        )

      session_token = verify_result["token"]

      # Validate the token
      {:ok, identity} = TokenStore.validate(session_token)
      assert identity["type"] == "node"
      assert identity["nodeName"] == "Validation Test"
    end

    test "invalid token returns error on validation" do
      {:error, :invalid_token} = TokenStore.validate("nonexistent-token")
      {:error, :invalid_token} = TokenStore.validate(nil)
      {:error, :invalid_token} = TokenStore.validate("")
    end

    test "expired token returns error on validation" do
      # Manually create an expired token
      expired_token = "expired-session-token-test"

      LemonCore.Store.put(:session_tokens, expired_token, %{
        token: expired_token,
        identity: %{"type" => "node", "nodeId" => "node-expired"},
        issued_at_ms: System.system_time(:millisecond) - 1_000_000,
        expires_at_ms: System.system_time(:millisecond) - 1000
      })

      {:error, :expired_token} = TokenStore.validate(expired_token)

      # Token should be cleaned up after validation failure
      assert TokenStore.get_info(expired_token) == nil
    end

    test "Authorize.from_params rejects invalid token" do
      {:error, {:unauthorized, _, _}} =
        Authorize.from_params(%{
          "auth" => %{"token" => "invalid-token-12345"}
        })
    end

    test "node tokens get correct role and scopes" do
      # Setup node pairing
      {:ok, request} =
        NodePairRequest.handle(
          %{
            "nodeType" => "browser",
            "nodeName" => "Browser Extension"
          },
          @pairing_ctx
        )

      {:ok, approve} =
        NodePairApprove.handle(
          %{
            "pairingId" => request["pairingId"]
          },
          @pairing_ctx
        )

      {:ok, verify_result} =
        ConnectChallenge.handle(
          %{
            "challenge" => approve["challengeToken"]
          },
          @challenge_ctx
        )

      # Use token with Authorize
      {:ok, auth_ctx} =
        Authorize.from_params(%{
          "auth" => %{"token" => verify_result["token"]}
        })

      # Should have node role and scopes
      assert auth_ctx.role == :node
      assert :invoke in auth_ctx.scopes
      assert :event in auth_ctx.scopes
      assert auth_ctx.identity["type"] == "node"
    end

    test "token can be revoked" do
      {:ok, verify_result} =
        ConnectChallenge.handle(
          %{"challenge" => node_challenge_token("Revoke Test")},
          @challenge_ctx
        )

      session_token = verify_result["token"]

      # Token should be valid initially
      {:ok, _} = TokenStore.validate(session_token)

      # Revoke the token
      :ok = TokenStore.revoke(session_token)

      # Token should now be invalid
      {:error, :invalid_token} = TokenStore.validate(session_token)
    end
  end

  defp node_challenge_token(node_name) do
    {:ok, request} =
      NodePairRequest.handle(%{"nodeType" => "compute", "nodeName" => node_name}, @pairing_ctx)

    {:ok, approve} = NodePairApprove.handle(%{"pairingId" => request["pairingId"]}, @pairing_ctx)
    approve["challengeToken"]
  end
end
