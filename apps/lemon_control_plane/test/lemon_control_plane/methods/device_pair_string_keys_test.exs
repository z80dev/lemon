defmodule LemonControlPlane.Methods.DevicePairStringKeysTest do
  @moduledoc """
  Tests for device pairing with string keys (simulating JSONL reload).

  After restart, JSONL reload converts atom keys to strings. These tests
  verify device pairing handlers work correctly with string-keyed maps.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{DevicePairApprove, DevicePairReject}

  @admin_ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  setup do
    # Clean up stores after each test
    on_exit(fn ->
      try do
        LemonCore.Store.list(:device_pairing) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:device_pairing, k)
        end)
        LemonCore.Store.list(:device_pairing_challenges) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:device_pairing_challenges, k)
        end)
        LemonCore.Store.list(:devices) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:devices, k)
        end)
      rescue
        _ -> :ok
      end
    end)
    :ok
  end

  describe "DevicePairApprove with string keys" do
    test "approves pairing with string-keyed map (JSONL reload)" do
      pairing_id = "string-key-pairing-#{System.unique_integer([:positive])}"

      # Store pairing with STRING keys (simulates JSONL reload)
      LemonCore.Store.put(:device_pairing, pairing_id, %{
        "status" => "pending",
        "device_type" => "mobile",
        "device_name" => "Test Phone",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000,
        "created_at_ms" => System.system_time(:millisecond)
      })

      {:ok, result} = DevicePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert result["success"] == true
      assert is_binary(result["deviceToken"])
      assert is_binary(result["challengeToken"])
    end

    test "rejects already resolved pairing with string keys" do
      pairing_id = "resolved-string-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:device_pairing, pairing_id, %{
        "status" => "approved",  # Already resolved
        "device_type" => "tablet",
        "device_name" => "Test Tablet",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:error, error} = DevicePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert {:conflict, _} = error
    end

    test "rejects expired pairing with string keys" do
      pairing_id = "expired-string-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:device_pairing, pairing_id, %{
        "status" => "pending",
        "device_type" => "mobile",
        "device_name" => "Expired Phone",
        "expires_at_ms" => System.system_time(:millisecond) - 1000  # Expired
      })

      {:error, error} = DevicePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert {:timeout, _} = error
    end

    test "handles mixed atom and string keys" do
      pairing_id = "mixed-key-pairing-#{System.unique_integer([:positive])}"

      # Mix of atom and string keys (edge case)
      LemonCore.Store.put(:device_pairing, pairing_id, %{
        :status => :pending,
        "device_type" => "mobile",
        :device_name => "Mixed Phone",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, result} = DevicePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert result["success"] == true
    end
  end

  describe "DevicePairReject with string keys" do
    test "rejects pairing with string-keyed map (JSONL reload)" do
      pairing_id = "reject-string-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:device_pairing, pairing_id, %{
        "status" => "pending",
        "device_type" => "mobile",
        "device_name" => "Reject Phone",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, result} = DevicePairReject.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert result["success"] == true

      # Verify status was updated
      updated = LemonCore.Store.get(:device_pairing, pairing_id)
      status = updated[:status] || updated["status"]
      assert status == :rejected
    end

    test "rejects already resolved pairing with string keys" do
      pairing_id = "resolved-reject-string-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:device_pairing, pairing_id, %{
        "status" => "rejected",  # Already resolved
        "device_type" => "tablet",
        "device_name" => "Already Rejected"
      })

      {:error, error} = DevicePairReject.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert {:conflict, _} = error
    end

    test "handles pending status as string" do
      pairing_id = "pending-string-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:device_pairing, pairing_id, %{
        "status" => "pending",  # String value
        "device_type" => "laptop",
        "device_name" => "Pending Laptop"
      })

      {:ok, result} = DevicePairReject.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      assert result["success"] == true
    end
  end

  describe "DevicePairApprove stores with correct fields" do
    test "stores device with correct fields from string-keyed pairing" do
      pairing_id = "store-fields-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:device_pairing, pairing_id, %{
        "status" => "pending",
        "device_type" => "smartwatch",
        "device_name" => "My Watch",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, result} = DevicePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      device_token = result["deviceToken"]

      # Verify device was stored with correct fields
      device = LemonCore.Store.get(:devices, device_token)
      assert device != nil

      device_type = device[:device_type] || device["device_type"]
      device_name = device[:device_name] || device["device_name"]

      assert device_type == "smartwatch"
      assert device_name == "My Watch"
    end

    test "stores challenge with correct fields from string-keyed pairing" do
      pairing_id = "challenge-fields-pairing-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:device_pairing, pairing_id, %{
        "status" => "pending",
        "device_type" => "tv",
        "device_name" => "Living Room TV",
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, result} = DevicePairApprove.handle(%{
        "pairingId" => pairing_id
      }, @admin_ctx)

      challenge_token = result["challengeToken"]

      # Verify challenge was stored with correct fields
      challenge = LemonCore.Store.get(:device_pairing_challenges, challenge_token)
      assert challenge != nil

      device_type = challenge[:device_type] || challenge["device_type"]
      device_name = challenge[:device_name] || challenge["device_name"]

      assert device_type == "tv"
      assert device_name == "Living Room TV"
    end
  end
end
