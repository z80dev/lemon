defmodule LemonControlPlane.Methods.NodePairStringKeysTest do
  @moduledoc """
  Tests for node pairing/registry with string keys (simulating JSONL reload).

  After restart, JSONL reload converts atom keys to strings. These tests
  verify all node-related handlers work correctly with string-keyed maps.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    NodePairApprove,
    NodePairReject,
    NodePairVerify,
    NodeList,
    NodeDescribe,
    NodeRename,
    NodeInvoke,
    NodeEvent,
    NodeInvokeResult
  }

  @admin_ctx %{conn_id: "test-conn", auth: %{role: :operator, scopes: [:admin, :pairing, :read, :write]}}
  @node_ctx %{conn_id: "test-conn", auth: %{role: :node, client_id: "test-node-id"}}

  setup do
    # Clean up stores after each test
    on_exit(fn ->
      try do
        LemonCore.Store.list(:nodes_pairing) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_pairing, k)
        end)
        LemonCore.Store.list(:nodes_pairing_by_code) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_pairing_by_code, k)
        end)
        LemonCore.Store.list(:nodes_registry) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:nodes_registry, k)
        end)
        LemonCore.Store.list(:node_challenges) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:node_challenges, k)
        end)
        LemonCore.Store.list(:node_invocations) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:node_invocations, k)
        end)
      rescue
        _ -> :ok
      end
    end)
    :ok
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

      {:ok, result} = NodePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert result["approved"] == true
      assert is_binary(result["nodeId"])
      assert is_binary(result["token"])
      assert is_binary(result["challengeToken"])
    end

    test "rejects already resolved pairing with string keys" do
      pairing_id = "resolved-node-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "approved",  # Already resolved
        "node_name" => "Resolved Node",
        "node_type" => "agent"
      })

      {:error, error} = NodePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      error_str = inspect(error)
      assert String.contains?(error_str, "pending")
    end

    test "rejects expired pairing with string keys" do
      pairing_id = "expired-node-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "pending",
        "node_name" => "Expired Node",
        "node_type" => "agent",
        "expires_at_ms" => System.system_time(:millisecond) - 1000  # Expired
      })

      {:error, error} = NodePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

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

      {:ok, result} = NodePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

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

      {:ok, result} = NodePairReject.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert result["rejected"] == true

      # Verify status was updated
      updated = LemonCore.Store.get(:nodes_pairing, pairing_id)
      # After update, new keys are atoms but old string keys remain
      status = updated[:status] || updated["status"]
      assert status == :rejected
    end

    test "rejects already resolved pairing with string keys" do
      pairing_id = "already-rejected-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "rejected",  # Already resolved
        "node_name" => "Already Rejected"
      })

      {:error, error} = NodePairReject.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      error_str = inspect(error)
      assert String.contains?(error_str, "pending")
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
    end

    test "returns expired error for expired pairing with string keys" do
      pairing_id = "verify-expired-#{System.unique_integer([:positive])}"
      code = "VERIFY-EXP-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_pairing, pairing_id, %{
        "status" => "pending",
        "expires_at_ms" => System.system_time(:millisecond) - 1000  # Expired
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
        "paired_at_ms" => 1000000,
        "last_seen_ms" => 2000000
      })

      {:ok, result} = NodeList.handle(%{}, @admin_ctx)

      assert is_list(result["nodes"])
      node = Enum.find(result["nodes"], &(&1["nodeId"] == node_id))

      assert node != nil
      assert node["name"] == "String Key Node"
      assert node["type"] == "agent"
      assert node["status"] == "online"
      assert node["pairedAtMs"] == 1000000
      assert node["lastSeenMs"] == 2000000
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
        "paired_at_ms" => 1000000,
        "last_seen_ms" => 2000000,
        "metadata" => %{"version" => "1.0"}
      })

      {:ok, result} = NodeDescribe.handle(%{"nodeId" => node_id}, @admin_ctx)

      assert result["nodeId"] == node_id
      assert result["name"] == "Describe Node"
      assert result["type"] == "agent"
      assert result["capabilities"] == %{"exec" => true}
      assert result["status"] == "online"
      assert result["pairedAtMs"] == 1000000
      assert result["lastSeenMs"] == 2000000
      assert result["metadata"] == %{"version" => "1.0"}
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

      {:ok, result} = NodeRename.handle(%{
        "nodeId" => node_id,
        "name" => "New Name"
      }, @admin_ctx)

      assert result["renamed"] == true
      assert result["name"] == "New Name"

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
      result = NodeRename.handle(%{
        "nodeId" => node_id,
        "name" => "No Crash"
      }, @admin_ctx)

      assert {:ok, _} = result
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

      {:ok, result} = NodeInvoke.handle(%{
        "nodeId" => node_id,
        "method" => "test.method",
        "args" => %{"foo" => "bar"}
      }, @admin_ctx)

      assert result["status"] == "pending"
      assert result["nodeId"] == node_id
      assert result["method"] == "test.method"
      assert is_binary(result["invokeId"])
    end

    test "returns unavailable for offline node with string keys" do
      node_id = "offline-invoke-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:nodes_registry, node_id, %{
        "id" => node_id,
        "name" => "Offline Node",
        "type" => "agent",
        "status" => "offline"  # String status
      })

      {:error, error} = NodeInvoke.handle(%{
        "nodeId" => node_id,
        "method" => "test.method"
      }, @admin_ctx)

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
        "last_seen_ms" => 1000000
      })

      # Create node context with matching client_id
      ctx = %{auth: %{role: :node, client_id: node_id}}

      {:ok, result} = NodeEvent.handle(%{
        "eventType" => "heartbeat",
        "payload" => %{}
      }, ctx)

      assert result["broadcast"] == true

      # Verify last_seen was updated
      updated = LemonCore.Store.get(:nodes_registry, node_id)
      last_seen = updated[:last_seen_ms] || updated["last_seen_ms"]
      assert last_seen > 1000000
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
      result = NodeEvent.handle(%{
        "eventType" => "status",
        "payload" => %{"online" => true}
      }, ctx)

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

      {:ok, result} = NodeInvokeResult.handle(%{
        "invokeId" => invoke_id,
        "result" => %{"data" => "success"}
      }, @node_ctx)

      assert result["invokeId"] == invoke_id
      assert result["received"] == true
    end
  end
end
