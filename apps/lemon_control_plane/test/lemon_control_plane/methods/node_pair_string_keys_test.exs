defmodule LemonControlPlane.Methods.NodePairStringKeysTest do
  @moduledoc """
  Tests for node pairing/registry with string keys (simulating JSONL reload).

  After restart, JSONL reload converts atom keys to strings. These tests
  verify all node-related handlers work correctly with string-keyed maps.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{NodePairRequest, NodePairApprove}

  @admin_ctx %{
    conn_id: "test-conn",
    auth: %{role: :operator, scopes: [:admin, :pairing, :read, :write]}
  }

  setup do
    # Clean up stores after each test
    on_exit(fn ->
      try do
        LemonCore.Store.list(:nodes_pairing)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_pairing, k)
        end)

        LemonCore.Store.list(:nodes_pairing_by_code)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_pairing_by_code, k)
        end)

        LemonCore.Store.list(:nodes_registry)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_registry, k)
        end)

        LemonCore.Store.list(:nodes_by_name)
        |> Enum.each(fn {k, _} -> LemonCore.Store.delete(:nodes_by_name, k) end)

        LemonCore.Store.list(:node_challenges)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:node_challenges, k)
        end)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "NodePairRequest" do
    test "returns bounded request summary while preserving pairing code delivery" do
      {:ok, result} =
        NodePairRequest.handle(
          %{
            "nodeName" => "Request Node",
            "nodeType" => "browser",
            "capabilities" => %{"dom" => true, "screenshot" => true}
          },
          @admin_ctx
        )

      assert is_binary(result["pairingId"])
      assert is_binary(result["code"])
      assert result["summary"]["pairingId"] == result["pairingId"]
      assert result["summary"]["nodeType"] == "browser"
      assert result["summary"]["capabilityCount"] == 2
      assert result["summary"]["credentialDelivery"]["includesPairingCode"] == true
      assert result["summary"]["cleanup"]["includesCapabilities"] == false
      assert result["summary"]["cleanup"]["includesApprovedTokens"] == false
      assert result["summary"]["cleanup"]["includesChallengeTokens"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "recovers a string-keyed durable node after restart without retaining the credential" do
      node_id = "restart-node-#{System.unique_integer([:positive])}"
      recovery_token = "restart-recovery-secret"
      current_name = "Renamed Restart Node"

      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => current_name,
        "type" => "coding_agent",
        "capabilities" => %{"coding_agent.run" => %{"version" => 1}},
        "token_hash" => sha256(recovery_token),
        "status" => "offline"
      })

      {:ok, result} =
        NodePairRequest.handle(
          %{
            "nodeId" => node_id,
            "nodeName" => "Stale Local Name",
            "nodeType" => "generic",
            "recoveryToken" => recovery_token
          },
          @admin_ctx
        )

      assert result["summary"]["recovered"] == true
      assert result["summary"]["nodeId"] == node_id
      assert result["summary"]["nodeType"] == "coding_agent"

      request = LemonCore.Store.get(:nodes_pairing, result["pairingId"])
      assert request.node_id == node_id
      assert request.node_name == current_name
      assert request.recovery_mode == :recovery_token
      refute inspect(request) =~ recovery_token
    end

    test "operator repair rotates recovery credentials for a legacy durable node" do
      node_id = "legacy-node-#{System.unique_integer([:positive])}"
      old_hash = sha256("obsolete-recovery-secret")

      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Legacy Repair Node",
        "type" => "coding_agent",
        "capabilities" => %{"coding_agent.run" => %{"version" => 1}},
        "token_hash" => old_hash,
        "status" => "offline"
      })

      LemonCore.Store.put(:nodes_by_name, "Legacy Repair Node", node_id)

      {:ok, requested} =
        NodePairRequest.handle(
          %{"nodeId" => node_id, "nodeName" => "stale-alias", "repair" => true},
          @admin_ctx
        )

      request = LemonCore.Store.get(:nodes_pairing, requested["pairingId"])
      assert request.recovery_mode == :operator_repair
      assert request.node_name == "Legacy Repair Node"

      {:ok, approved} =
        NodePairApprove.handle(%{"pairingId" => requested["pairingId"]}, @admin_ctx)

      assert approved["nodeId"] == node_id
      assert approved["summary"]["recovered"] == true
      assert approved["summary"]["credentialDelivery"]["includesNodeToken"] == true
      assert is_binary(approved["token"])
      refute approved["token"] == "obsolete-recovery-secret"

      repaired = LemonCore.Store.get(:nodes_registry, node_id)
      assert repaired[:token_hash] == sha256(approved["token"])
      refute repaired[:token_hash] == old_hash
      assert LemonCore.Store.list(:nodes_registry) |> Enum.count() == 1
    end
  end

  describe "NodePairApprove with string keys" do
    test "approves pairing with string-keyed map (JSONL reload)" do
      pairing_id = "string-node-pairing-#{System.unique_integer([:positive])}"
      code = "TEST-#{System.unique_integer([:positive])}"

      # Store pairing with STRING keys (simulates JSONL reload)
      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "pending",
        "node_name" => "Test Node",
        "node_type" => "agent",
        "capabilities" => %{"tools" => true},
        "expires_at_ms" => System.system_time(:millisecond) + 60_000,
        "created_at_ms" => System.system_time(:millisecond)
      })

      LemonCore.Store.put(:nodes_pairing_by_code, code, pairing_id)

      {:ok, result} =
        NodePairApprove.handle(
          %{
            "pairingId" => pairing_id
          },
          @admin_ctx
        )

      assert result["approved"] == true
      assert is_binary(result["nodeId"])
      assert is_binary(result["token"])
      assert is_binary(result["challengeToken"])
      assert result["summary"]["pairingId"] == pairing_id
      assert result["summary"]["nodeId"] == result["nodeId"]
      assert result["summary"]["approved"] == true
      assert result["summary"]["nodeType"] == "agent"
      assert result["summary"]["capabilityCount"] == 1
      assert result["summary"]["credentialDelivery"]["includesNodeToken"] == true
      assert result["summary"]["credentialDelivery"]["includesChallengeToken"] == true
      assert result["summary"]["cleanup"]["includesCapabilities"] == false
      assert result["summary"]["cleanup"]["includesMetadata"] == false
      assert result["summary"]["cleanup"]["includesStoredTokenHash"] == false
    end

    test "reissues a challenge for a resolved string-keyed recovery pairing" do
      pairing_id = "resolved-node-pairing-#{System.unique_integer([:positive])}"
      node_id = "resolved-node-#{System.unique_integer([:positive])}"
      node_name = "Resolved Node"
      recovery_token = "resolved-recovery-secret"

      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => node_name,
        "type" => "agent",
        "capabilities" => %{"tools" => true},
        "token_hash" => sha256(recovery_token),
        "status" => "offline"
      })

      LemonCore.Store.put(:nodes_by_name, node_name, node_id)

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "approved",
        "node_id" => node_id,
        "node_name" => node_name,
        "node_type" => "agent",
        "recovery_mode" => "recovery_token",
        "challenge_token" => "lost-challenge"
      })

      LemonCore.Store.put(:node_challenges, "lost-challenge", %{
        "node_id" => node_id,
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, recovered} =
        NodePairApprove.handle(
          %{
            "pairingId" => pairing_id
          },
          @admin_ctx
        )

      assert recovered["nodeId"] == node_id
      assert recovered["summary"]["recovered"] == true
      assert recovered["summary"]["credentialDelivery"]["includesNodeToken"] == false
      assert is_binary(recovered["challengeToken"])
      refute Map.has_key?(recovered, "token")
      assert LemonCore.Store.get(:node_challenges, "lost-challenge") == nil
      assert LemonCore.Store.get(:nodes_registry, node_id)["token_hash"] == sha256(recovery_token)
    end

    test "rejects expired pairing with string keys" do
      pairing_id = "expired-node-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "pending",
        "node_name" => "Expired Node",
        "node_type" => "agent",
        # Expired
        "expires_at_ms" => System.system_time(:millisecond) - 1000
      })

      {:error, error} =
        NodePairApprove.handle(
          %{
            "pairingId" => pairing_id
          },
          @admin_ctx
        )

      error_str = inspect(error)
      assert String.contains?(error_str, "expired")
    end

    test "stores node with correct fields from string-keyed pairing" do
      pairing_id = "fields-node-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "pending",
        "node_name" => "Field Test Node",
        "node_type" => "browser",
        "capabilities" => %{"screenshot" => true, "navigate" => true},
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, result} =
        NodePairApprove.handle(
          %{
            "pairingId" => pairing_id
          },
          @admin_ctx
        )

      node_id = result["nodeId"]

      # Verify node was stored with correct fields
      node = LemonCore.Store.get(:nodes_registry, node_id)
      assert node != nil

      # Node should have atom keys since we just created it
      assert node[:name] == "Field Test Node"
      assert node[:type] == "browser"
      assert node[:capabilities] == %{"screenshot" => true, "navigate" => true}
    end
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
