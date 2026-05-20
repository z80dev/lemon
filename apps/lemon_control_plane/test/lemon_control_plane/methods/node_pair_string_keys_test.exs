defmodule LemonControlPlane.Methods.NodePairStringKeysTest do
  @moduledoc """
  Tests for node pairing/registry with string keys (simulating JSONL reload).

  After restart, JSONL reload converts atom keys to strings. These tests
  verify all node-related handlers work correctly with string-keyed maps.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    NodePairRequest,
    NodePairApprove,
    NodePairReject,
    NodePairVerify,
    NodeList,
    NodeDescribe,
    NodeRename,
    NodeInvoke,
    NodeEvent,
    NodePairList,
    NodeInvokeResult
  }

  @admin_ctx %{
    conn_id: "test-conn",
    auth: %{role: :operator, scopes: [:admin, :pairing, :read, :write]}
  }
  @node_ctx %{conn_id: "test-conn", auth: %{role: :node, client_id: "test-node-id"}}

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

        LemonCore.Store.list(:node_challenges)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:node_challenges, k)
        end)

        LemonCore.Store.list(:node_invocations)
        |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:node_invocations, k)
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

    test "rejects already resolved pairing with string keys" do
      pairing_id = "resolved-node-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        # Already resolved
        "status" => "approved",
        "node_name" => "Resolved Node",
        "node_type" => "agent"
      })

      {:error, error} =
        NodePairApprove.handle(
          %{
            "pairingId" => pairing_id
          },
          @admin_ctx
        )

      error_str = inspect(error)
      assert String.contains?(error_str, "pending")
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

  describe "NodePairReject with string keys" do
    test "rejects pairing with string-keyed map (JSONL reload)" do
      pairing_id = "reject-node-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "pending",
        "node_name" => "Reject Node",
        "node_type" => "agent",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, result} =
        NodePairReject.handle(
          %{
            "pairingId" => pairing_id
          },
          @admin_ctx
        )

      assert result["rejected"] == true
      assert result["summary"]["pairingId"] == pairing_id
      assert result["summary"]["rejected"] == true
      assert result["summary"]["cleanup"]["includesPairingCode"] == false
      assert result["summary"]["cleanup"]["includesCapabilities"] == false
      assert result["summary"]["cleanup"]["includesApprovedTokens"] == false
      assert result["summary"]["cleanup"]["includesChallengeTokens"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

      # Verify status was updated
      updated = LemonCore.Store.get(:nodes_pairing, pairing_id)
      # After update, new keys are atoms but old string keys remain
      status = updated[:status] || updated["status"]
      assert status == :rejected
    end

    test "rejects already resolved pairing with string keys" do
      pairing_id = "already-rejected-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        # Already resolved
        "status" => "rejected",
        "node_name" => "Already Rejected"
      })

      {:error, error} =
        NodePairReject.handle(
          %{
            "pairingId" => pairing_id
          },
          @admin_ctx
        )

      error_str = inspect(error)
      assert String.contains?(error_str, "pending")
    end
  end

  describe "NodePairList with string keys" do
    test "lists pending string-keyed pairings with summary and cleanup flags" do
      pairing_id = "list-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "id" => pairing_id,
        "code" => "PAIR-#{System.unique_integer([:positive])}",
        "status" => "pending",
        "node_name" => "List Pairing Node",
        "node_type" => "browser",
        "capabilities" => %{"screenshot" => true},
        "expires_at_ms" => System.system_time(:millisecond) + 60_000,
        "created_at_ms" => System.system_time(:millisecond)
      })

      {:ok, result} = NodePairList.handle(%{}, @admin_ctx)

      request = Enum.find(result["requests"], &(&1["pairingId"] == pairing_id))

      assert request["nodeName"] == "List Pairing Node"
      assert request["nodeType"] == "browser"
      assert request["capabilities"] == %{"screenshot" => true}
      assert result["summary"]["pendingCount"] == length(result["requests"])
      assert result["summary"]["nodeTypeCounts"]["browser"] >= 1
      assert result["summary"]["capabilityCounts"]["screenshot"] >= 1
      assert result["summary"]["cleanup"]["includesPairingCodes"] == true
      assert result["summary"]["cleanup"]["includesApprovedTokens"] == false
      assert result["summary"]["cleanup"]["includesChallengeTokens"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "omits expired and resolved pairings from the summary" do
      LemonCore.Store.put(:nodes_pairing, "expired", %{
        "id" => "expired",
        "status" => "pending",
        "node_type" => "agent",
        "expires_at_ms" => System.system_time(:millisecond) - 1
      })

      LemonCore.Store.put(:nodes_pairing, "approved", %{
        "id" => "approved",
        "status" => "approved",
        "node_type" => "agent",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, result} = NodePairList.handle(%{}, @admin_ctx)

      refute Enum.any?(result["requests"], &(&1["pairingId"] == "expired"))
      refute Enum.any?(result["requests"], &(&1["pairingId"] == "approved"))
      assert result["summary"]["pendingCount"] == length(result["requests"])
    end
  end

  describe "NodePairVerify with string keys" do
    test "verifies pending pairing with string keys" do
      pairing_id = "verify-pending-#{System.unique_integer([:positive])}"
      code = "VERIFY-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "pending",
        "node_name" => "Verify Node",
        "node_type" => "agent",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      LemonCore.Store.put(:nodes_pairing_by_code, code, pairing_id)

      {:ok, result} = NodePairVerify.handle(%{"code" => code}, %{})

      assert result["valid"] == true
      assert result["status"] == "pending"
      assert result["pairingId"] == pairing_id
      assert result["summary"]["valid"] == true
      assert result["summary"]["status"] == "pending"
      assert result["summary"]["hasPairingId"] == true
      assert result["summary"]["cleanup"]["includesPairingCode"] == false
      assert result["summary"]["cleanup"]["includesApprovedTokens"] == false
      assert result["summary"]["cleanup"]["includesChallengeTokens"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "returns rejected status for rejected pairing with string keys" do
      pairing_id = "verify-rejected-#{System.unique_integer([:positive])}"
      code = "VERIFY-REJ-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "rejected",
        "node_name" => "Rejected Node"
      })

      LemonCore.Store.put(:nodes_pairing_by_code, code, pairing_id)

      {:ok, result} = NodePairVerify.handle(%{"code" => code}, %{})

      assert result["valid"] == false
      assert result["status"] == "rejected"
      assert result["summary"]["valid"] == false
      assert result["summary"]["status"] == "rejected"
      assert result["summary"]["hasPairingId"] == false
      refute Map.has_key?(result, "pairingId")
    end

    test "returns approved status for approved pairing with string keys" do
      pairing_id = "verify-approved-#{System.unique_integer([:positive])}"
      code = "VERIFY-APP-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "approved",
        "node_name" => "Approved Node"
      })

      LemonCore.Store.put(:nodes_pairing_by_code, code, pairing_id)

      {:ok, result} = NodePairVerify.handle(%{"code" => code}, %{})

      assert result["valid"] == true
      assert result["status"] == "approved"
      assert result["pairingId"] == pairing_id
      assert result["summary"]["valid"] == true
      assert result["summary"]["status"] == "approved"
      assert result["summary"]["hasPairingId"] == true
    end

    test "returns expired error for expired pairing with string keys" do
      pairing_id = "verify-expired-#{System.unique_integer([:positive])}"
      code = "VERIFY-EXP-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "pending",
        # Expired
        "expires_at_ms" => System.system_time(:millisecond) - 1000
      })

      LemonCore.Store.put(:nodes_pairing_by_code, code, pairing_id)

      {:error, error} = NodePairVerify.handle(%{"code" => code}, %{})

      error_str = inspect(error)
      assert String.contains?(error_str, "expired")
    end
  end

  describe "NodeList with string keys" do
    test "lists nodes with string-keyed maps (JSONL reload)" do
      node_id = "list-node-#{System.unique_integer([:positive])}"

      # Store node with STRING keys (simulates JSONL reload)
      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "String Key Node",
        "type" => "agent",
        "capabilities" => %{"tools" => true},
        "status" => "online",
        "paired_at_ms" => 1_000_000,
        "last_seen_ms" => 2_000_000
      })

      {:ok, result} = NodeList.handle(%{}, @admin_ctx)

      assert is_list(result["nodes"])
      node = Enum.find(result["nodes"], &(&1["nodeId"] == node_id))

      assert node != nil
      assert node["name"] == "String Key Node"
      assert node["type"] == "agent"
      assert node["status"] == "online"
      assert node["pairedAtMs"] == 1_000_000
      assert node["lastSeenMs"] == 2_000_000
      assert result["summary"]["nodeCount"] == length(result["nodes"])
      assert result["summary"]["statusCounts"]["online"] >= 1
      assert result["summary"]["typeCounts"]["agent"] >= 1
      assert result["summary"]["capabilityCounts"]["tools"] >= 1
      assert result["summary"]["cleanup"]["includesCapabilities"] == true
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "handles mixed atom and string keys" do
      node_id = "mixed-node-#{System.unique_integer([:positive])}"

      # Store node with mixed keys
      LemonCore.Store.put(:nodes_registry, node_id, %{
        :id => node_id,
        "name" => "Mixed Key Node",
        :type => "browser",
        "status" => "offline"
      })

      {:ok, result} = NodeList.handle(%{}, @admin_ctx)

      node = Enum.find(result["nodes"], &(&1["nodeId"] == node_id))

      assert node != nil
      assert node["name"] == "Mixed Key Node"
      assert node["type"] == "browser"
      assert node["status"] == "offline"
    end
  end

  describe "NodeDescribe with string keys" do
    test "describes node with string-keyed map (JSONL reload)" do
      node_id = "describe-node-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Describe Node",
        "type" => "agent",
        "capabilities" => %{"exec" => true},
        "status" => "online",
        "paired_at_ms" => 1_000_000,
        "last_seen_ms" => 2_000_000,
        "metadata" => %{"version" => "1.0"}
      })

      {:ok, result} = NodeDescribe.handle(%{"nodeId" => node_id}, @admin_ctx)

      assert result["nodeId"] == node_id
      assert result["name"] == "Describe Node"
      assert result["type"] == "agent"
      assert result["capabilities"] == %{"exec" => true}
      assert result["status"] == "online"
      assert result["pairedAtMs"] == 1_000_000
      assert result["lastSeenMs"] == 2_000_000
      assert result["metadata"] == %{"version" => "1.0"}
      assert result["summary"]["status"] == "online"
      assert result["summary"]["type"] == "agent"
      assert result["summary"]["capabilityCount"] == 1
      assert result["summary"]["metadataKeyCount"] == 1
      assert result["summary"]["cleanup"]["includesCapabilities"] == true
      assert result["summary"]["cleanup"]["includesMetadata"] == true
      assert result["summary"]["cleanup"]["redactsMetadataSecretKeys"] == true
      assert result["summary"]["cleanup"]["includesInvocationResults"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "redacts sensitive metadata keys" do
      node_id = "describe-redacted-node-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_registry, node_id, %{
        id: node_id,
        name: "Redacted Node",
        type: "agent",
        capabilities: %{},
        status: :online,
        metadata: %{
          "version" => "1.0",
          "api_key" => "should-not-leak",
          nested: %{"password" => "also-secret"}
        }
      })

      {:ok, result} = NodeDescribe.handle(%{"nodeId" => node_id}, @admin_ctx)

      assert result["metadata"]["version"] == "1.0"
      assert result["metadata"]["api_key"] == %{"redacted" => true, "kind" => "secret"}
      assert result["metadata"]["nested"]["password"] == %{"redacted" => true, "kind" => "secret"}
      refute inspect(result) =~ "should-not-leak"
      refute inspect(result) =~ "also-secret"
    end
  end

  describe "NodeRename with string keys" do
    test "renames node with string-keyed map (JSONL reload)" do
      node_id = "rename-node-#{System.unique_integer([:positive])}"

      # Store node with STRING keys (simulates JSONL reload)
      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Old Name",
        "type" => "agent",
        "status" => "online"
      })

      {:ok, result} =
        NodeRename.handle(
          %{
            "nodeId" => node_id,
            "name" => "New Name"
          },
          @admin_ctx
        )

      assert result["renamed"] == true
      assert result["name"] == "New Name"
      assert result["summary"]["nodeId"] == node_id
      assert result["summary"]["renamed"] == true
      assert result["summary"]["nameChanged"] == true
      assert result["summary"]["cleanup"]["includesPreviousName"] == false
      assert result["summary"]["cleanup"]["includesCapabilities"] == false
      assert result["summary"]["cleanup"]["includesMetadata"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

      # Verify node was updated
      updated = LemonCore.Store.get(:nodes_registry, node_id)
      name = updated[:name] || updated["name"]
      assert name == "New Name"
    end

    test "does not crash with string-keyed map" do
      node_id = "rename-crash-test-#{System.unique_integer([:positive])}"

      # This would crash with %{node | name: ...} if keys are strings
      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Crash Test",
        "type" => "agent"
      })

      # Should not raise
      result =
        NodeRename.handle(
          %{
            "nodeId" => node_id,
            "name" => "No Crash"
          },
          @admin_ctx
        )

      assert {:ok, _} = result
    end

    test "reports unchanged rename without exposing previous name" do
      node_id = "rename-unchanged-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Same Name",
        "metadata" => %{"api_key" => "should-not-leak"}
      })

      {:ok, result} =
        NodeRename.handle(
          %{
            "nodeId" => node_id,
            "name" => "Same Name"
          },
          @admin_ctx
        )

      assert result["summary"]["nameChanged"] == false
      refute inspect(result) =~ "should-not-leak"
      refute result["summary"]["cleanup"]["includesPreviousName"]
    end
  end

  describe "NodeInvoke with string keys" do
    test "invokes method on node with string-keyed map (JSONL reload)" do
      node_id = "invoke-node-#{System.unique_integer([:positive])}"

      # Store node with STRING keys (simulates JSONL reload)
      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Invoke Node",
        "type" => "agent",
        "status" => "online"
      })

      {:ok, result} =
        NodeInvoke.handle(
          %{
            "nodeId" => node_id,
            "method" => "test.method",
            "args" => %{"foo" => "bar"}
          },
          @admin_ctx
        )

      assert result["status"] == "pending"
      assert result["nodeId"] == node_id
      assert result["method"] == "test.method"
      assert is_binary(result["invokeId"])
      assert result["summary"]["nodeId"] == node_id
      assert result["summary"]["method"] == "test.method"
      assert result["summary"]["status"] == "pending"
      assert result["summary"]["argKeyCount"] == 1
      assert result["summary"]["cleanup"]["includesArgs"] == false
      assert result["summary"]["cleanup"]["includesResult"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "returns unavailable for offline node with string keys" do
      node_id = "offline-invoke-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Offline Node",
        "type" => "agent",
        # String status
        "status" => "offline"
      })

      {:error, error} =
        NodeInvoke.handle(
          %{
            "nodeId" => node_id,
            "method" => "test.method"
          },
          @admin_ctx
        )

      error_str = inspect(error)

      assert String.contains?(String.downcase(error_str), "online") or
               String.contains?(String.downcase(error_str), "unavailable")
    end
  end

  describe "NodeEvent with string keys" do
    test "updates last_seen with string-keyed node (JSONL reload)" do
      node_id = "event-node-#{System.unique_integer([:positive])}"

      # Store node with STRING keys (simulates JSONL reload)
      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Event Node",
        "type" => "agent",
        "status" => "online",
        "last_seen_ms" => 1_000_000
      })

      # Create node context with matching client_id
      ctx = %{auth: %{role: :node, client_id: node_id}}

      {:ok, result} =
        NodeEvent.handle(
          %{
            "eventType" => "heartbeat",
            "payload" => %{}
          },
          ctx
        )

      assert result["broadcast"] == true
      assert result["summary"]["eventType"] == "heartbeat"
      assert result["summary"]["nodeId"] == node_id
      assert result["summary"]["payloadKeyCount"] == 0
      assert result["summary"]["cleanup"]["includesPayload"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

      # Verify last_seen was updated
      updated = LemonCore.Store.get(:nodes_registry, node_id)
      last_seen = updated[:last_seen_ms] || updated["last_seen_ms"]
      assert last_seen > 1_000_000
    end

    test "does not crash when updating string-keyed node" do
      node_id = "event-crash-#{System.unique_integer([:positive])}"

      # This would crash with %{node | last_seen_ms: ...} if keys are strings
      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Event Crash Test",
        "status" => "online"
      })

      ctx = %{auth: %{role: :node, client_id: node_id}}

      # Should not raise
      result =
        NodeEvent.handle(
          %{
            "eventType" => "status",
            "payload" => %{"online" => true}
          },
          ctx
        )

      assert {:ok, _} = result
    end
  end

  describe "NodeInvokeResult with string keys" do
    test "processes result with string-keyed invocation (JSONL reload)" do
      invoke_id = "invoke-result-#{System.unique_integer([:positive])}"

      # Store invocation with STRING keys (simulates JSONL reload)
      LemonCore.Store.put(:node_invocations, invoke_id, %{
        "node_id" => "test-node",
        "method" => "test.method",
        "status" => "pending",
        "created_at_ms" => System.system_time(:millisecond)
      })

      {:ok, result} =
        NodeInvokeResult.handle(
          %{
            "invokeId" => invoke_id,
            "result" => %{"data" => "success"}
          },
          @node_ctx
        )

      assert result["invokeId"] == invoke_id
      assert result["received"] == true
      assert result["summary"]["invokeId"] == invoke_id
      assert result["summary"]["nodeId"] == "test-node"
      assert result["summary"]["status"] == "completed"
      assert result["summary"]["ok"] == true
      assert result["summary"]["hasResult"] == true
      assert result["summary"]["hasError"] == false
      assert result["summary"]["cleanup"]["includesResult"] == false
      assert result["summary"]["cleanup"]["includesError"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end
  end
end
