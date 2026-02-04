defmodule LemonControlPlane.Methods.ConnectChallengeTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    ConnectChallenge,
    DevicePairRequest,
    DevicePairApprove,
    NodePairRequest,
    NodePairApprove
  }

  @admin_ctx %{conn_id: "test-conn", auth: %{role: :operator}}
  @pairing_ctx %{conn_id: "test-conn", auth: %{role: :operator, scopes: [:pairing]}}
  @challenge_ctx %{conn_id: "test-conn"}

  setup do
    # Clean up stores after each test
    on_exit(fn ->
      try do
        # Clean up device pairing stores
        LemonCore.Store.list(:device_pairing) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:device_pairing, k)
        end)
        LemonCore.Store.list(:device_pairing_challenges) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:device_pairing_challenges, k)
        end)
        LemonCore.Store.list(:devices) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:devices, k)
        end)
        # Clean up node pairing stores
        LemonCore.Store.list(:nodes_pairing) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_pairing, k)
        end)
        LemonCore.Store.list(:nodes_pairing_by_code) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_pairing_by_code, k)
        end)
        LemonCore.Store.list(:node_challenges) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:node_challenges, k)
        end)
        LemonCore.Store.list(:nodes_registry) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_registry, k)
        end)
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
  end

  describe "device pairing flow with connect.challenge" do
    test "full device pairing flow produces valid challenge token" do
      # Step 1: Request device pairing
      {:ok, request_result} = DevicePairRequest.handle(%{
        "deviceType" => "mobile",
        "deviceName" => "Test Phone"
      }, @admin_ctx)

      pairing_id = request_result["pairingId"]
      assert is_binary(pairing_id)

      # Step 2: Approve the pairing (this creates the challenge)
      {:ok, approve_result} = DevicePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert approve_result["success"] == true
      challenge_token = approve_result["challengeToken"]
      assert is_binary(challenge_token)

      # Step 3: Verify challenge via connect.challenge
      {:ok, verify_result} = ConnectChallenge.handle(%{
        "challenge" => challenge_token
      }, @challenge_ctx)

      assert verify_result["verified"] == true
      assert verify_result["identity"]["type"] == "device"
      assert verify_result["identity"]["deviceName"] == "Test Phone"
      assert is_binary(verify_result["token"])
    end

    test "challenge token is one-time use" do
      # Setup pairing
      {:ok, request} = DevicePairRequest.handle(%{
        "deviceType" => "tablet",
        "deviceName" => "Test Tablet"
      }, @admin_ctx)

      {:ok, approve} = DevicePairApprove.handle(%{
        "pairingId" => request["pairingId"]
      }, @admin_ctx)

      challenge_token = approve["challengeToken"]

      # First use should succeed
      {:ok, _} = ConnectChallenge.handle(%{"challenge" => challenge_token}, @challenge_ctx)

      # Second use should fail (token consumed)
      {:error, error} = ConnectChallenge.handle(%{"challenge" => challenge_token}, @challenge_ctx)
      assert {:unauthorized, "Invalid challenge"} = error
    end

    test "expired challenge returns error" do
      # Manually create an expired challenge
      expired_challenge = "expired-device-challenge-123"
      LemonCore.Store.put(:device_pairing_challenges, expired_challenge, %{
        device_id: "dev-123",
        device_name: "Old Device",
        expires_at_ms: System.system_time(:millisecond) - 1000  # Expired 1 second ago
      })

      {:error, error} = ConnectChallenge.handle(%{"challenge" => expired_challenge}, @challenge_ctx)
      assert {:unauthorized, "Challenge expired"} = error

      # Challenge should be cleaned up after expiry check
      assert LemonCore.Store.get(:device_pairing_challenges, expired_challenge) == nil
    end
  end

  describe "node pairing flow with connect.challenge" do
    test "full node pairing flow produces valid challenge token" do
      # Step 1: Request node pairing
      {:ok, request_result} = NodePairRequest.handle(%{
        "nodeType" => "compute",
        "nodeName" => "Test Worker"
      }, @pairing_ctx)

      pairing_id = request_result["pairingId"]
      code = request_result["code"]
      assert is_binary(pairing_id)
      assert is_binary(code)

      # Step 2: Approve the pairing (this creates the challenge)
      {:ok, approve_result} = NodePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @pairing_ctx)

      assert approve_result["approved"] == true
      challenge_token = approve_result["challengeToken"]
      assert is_binary(challenge_token)
      assert is_binary(approve_result["nodeId"])
      assert is_binary(approve_result["token"])

      # Step 3: Verify challenge via connect.challenge
      {:ok, verify_result} = ConnectChallenge.handle(%{
        "challenge" => challenge_token
      }, @challenge_ctx)

      assert verify_result["verified"] == true
      assert verify_result["identity"]["type"] == "node"
      assert verify_result["identity"]["nodeName"] == "Test Worker"
      assert is_binary(verify_result["token"])
    end

    test "node challenge token is one-time use" do
      # Setup node pairing
      {:ok, request} = NodePairRequest.handle(%{
        "nodeType" => "storage",
        "nodeName" => "Storage Node"
      }, @pairing_ctx)

      {:ok, approve} = NodePairApprove.handle(%{
        "pairingId" => request["pairingId"]
      }, @pairing_ctx)

      challenge_token = approve["challengeToken"]

      # First use should succeed
      {:ok, _} = ConnectChallenge.handle(%{"challenge" => challenge_token}, @challenge_ctx)

      # Second use should fail
      {:error, error} = ConnectChallenge.handle(%{"challenge" => challenge_token}, @challenge_ctx)
      assert {:unauthorized, "Invalid challenge"} = error
    end

    test "expired node challenge returns error" do
      expired_challenge = "expired-node-challenge-456"
      LemonCore.Store.put(:node_challenges, expired_challenge, %{
        node_id: "node-456",
        node_name: "Old Node",
        expires_at_ms: System.system_time(:millisecond) - 1000
      })

      {:error, error} = ConnectChallenge.handle(%{"challenge" => expired_challenge}, @challenge_ctx)
      assert {:unauthorized, "Challenge expired"} = error

      # Challenge should be cleaned up
      assert LemonCore.Store.get(:node_challenges, expired_challenge) == nil
    end
  end

  describe "challenge token security" do
    test "challenge tokens are cryptographically random" do
      {:ok, r1} = DevicePairRequest.handle(%{"deviceType" => "a", "deviceName" => "A"}, @admin_ctx)
      {:ok, a1} = DevicePairApprove.handle(%{"pairingId" => r1["pairingId"]}, @admin_ctx)

      {:ok, r2} = DevicePairRequest.handle(%{"deviceType" => "b", "deviceName" => "B"}, @admin_ctx)
      {:ok, a2} = DevicePairApprove.handle(%{"pairingId" => r2["pairingId"]}, @admin_ctx)

      # Tokens should be different
      assert a1["challengeToken"] != a2["challengeToken"]

      # Tokens should be long enough for security
      assert byte_size(a1["challengeToken"]) >= 32
      assert byte_size(a2["challengeToken"]) >= 32
    end
  end

  describe "session token storage and validation" do
    alias LemonControlPlane.Auth.TokenStore
    alias LemonControlPlane.Auth.Authorize

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

    test "issued session token is stored in TokenStore" do
      # Setup device pairing and get a challenge token
      {:ok, request} = DevicePairRequest.handle(%{
        "deviceType" => "mobile",
        "deviceName" => "Token Test Device"
      }, @admin_ctx)

      {:ok, approve} = DevicePairApprove.handle(%{
        "pairingId" => request["pairingId"]
      }, @admin_ctx)

      # Verify the challenge - this should store the session token
      {:ok, verify_result} = ConnectChallenge.handle(%{
        "challenge" => approve["challengeToken"]
      }, @challenge_ctx)

      session_token = verify_result["token"]
      assert is_binary(session_token)

      # Verify token is stored
      token_info = TokenStore.get_info(session_token)
      assert token_info != nil
      assert token_info.identity["type"] == "device"
      assert token_info.identity["deviceName"] == "Token Test Device"
    end

    test "stored session token can be validated" do
      # Setup and get session token
      {:ok, request} = DevicePairRequest.handle(%{
        "deviceType" => "mobile",
        "deviceName" => "Validation Test"
      }, @admin_ctx)

      {:ok, approve} = DevicePairApprove.handle(%{
        "pairingId" => request["pairingId"]
      }, @admin_ctx)

      {:ok, verify_result} = ConnectChallenge.handle(%{
        "challenge" => approve["challengeToken"]
      }, @challenge_ctx)

      session_token = verify_result["token"]

      # Validate the token
      {:ok, identity} = TokenStore.validate(session_token)
      assert identity["type"] == "device"
      assert identity["deviceName"] == "Validation Test"
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
        identity: %{"type" => "device"},
        issued_at_ms: System.system_time(:millisecond) - 1_000_000,
        expires_at_ms: System.system_time(:millisecond) - 1000
      })

      {:error, :expired_token} = TokenStore.validate(expired_token)

      # Token should be cleaned up after validation failure
      assert TokenStore.get_info(expired_token) == nil
    end

    test "Authorize.from_params validates token and extracts identity" do
      # Setup and get session token
      {:ok, request} = DevicePairRequest.handle(%{
        "deviceType" => "mobile",
        "deviceName" => "Authorize Test"
      }, @admin_ctx)

      {:ok, approve} = DevicePairApprove.handle(%{
        "pairingId" => request["pairingId"]
      }, @admin_ctx)

      {:ok, verify_result} = ConnectChallenge.handle(%{
        "challenge" => approve["challengeToken"]
      }, @challenge_ctx)

      session_token = verify_result["token"]

      # Use Authorize.from_params with the token
      {:ok, auth_ctx} = Authorize.from_params(%{
        "auth" => %{"token" => session_token}
      })

      # Should have device role and scopes
      assert auth_ctx.role == :device
      assert :control in auth_ctx.scopes
      assert auth_ctx.identity["type"] == "device"
    end

    test "Authorize.from_params rejects invalid token" do
      {:error, {:unauthorized, _}} = Authorize.from_params(%{
        "auth" => %{"token" => "invalid-token-12345"}
      })
    end

    test "node tokens get correct role and scopes" do
      # Setup node pairing
      {:ok, request} = NodePairRequest.handle(%{
        "nodeType" => "browser",
        "nodeName" => "Browser Extension"
      }, @pairing_ctx)

      {:ok, approve} = NodePairApprove.handle(%{
        "pairingId" => request["pairingId"]
      }, @pairing_ctx)

      {:ok, verify_result} = ConnectChallenge.handle(%{
        "challenge" => approve["challengeToken"]
      }, @challenge_ctx)

      # Use token with Authorize
      {:ok, auth_ctx} = Authorize.from_params(%{
        "auth" => %{"token" => verify_result["token"]}
      })

      # Should have node role and scopes
      assert auth_ctx.role == :node
      assert :invoke in auth_ctx.scopes
      assert :event in auth_ctx.scopes
      assert auth_ctx.identity["type"] == "node"
    end

    test "token can be revoked" do
      # Setup and get session token
      {:ok, request} = DevicePairRequest.handle(%{
        "deviceType" => "mobile",
        "deviceName" => "Revoke Test"
      }, @admin_ctx)

      {:ok, approve} = DevicePairApprove.handle(%{
        "pairingId" => request["pairingId"]
      }, @admin_ctx)

      {:ok, verify_result} = ConnectChallenge.handle(%{
        "challenge" => approve["challengeToken"]
      }, @challenge_ctx)

      session_token = verify_result["token"]

      # Token should be valid initially
      {:ok, _} = TokenStore.validate(session_token)

      # Revoke the token
      :ok = TokenStore.revoke(session_token)

      # Token should now be invalid
      {:error, :invalid_token} = TokenStore.validate(session_token)
    end
  end
end
