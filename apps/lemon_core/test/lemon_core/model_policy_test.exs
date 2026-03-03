defmodule LemonCore.ModelPolicyTest do
  @moduledoc false
  use ExUnit.Case

  alias LemonCore.ModelPolicy
  alias LemonCore.ModelPolicy.Route

  # Each test gets a clean store via the Test isolation
  setup do
    # Clean the model_policies table before each test
    cleanup_policies()
    :ok
  end

  defp cleanup_policies do
    # List all and delete them
    ModelPolicy.list()
    |> Enum.each(fn {route, _policy} ->
      ModelPolicy.clear(route)
    end)
  end

  describe "new_policy/2" do
    test "creates a basic policy" do
      policy = ModelPolicy.new_policy("claude-sonnet-4-20250514")

      assert policy.model_id == "claude-sonnet-4-20250514"
      assert policy.metadata.set_at_ms != nil
      assert is_integer(policy.metadata.set_at_ms)
    end

    test "creates a policy with thinking level" do
      policy = ModelPolicy.new_policy("claude-opus-4-6", thinking_level: :high)

      assert policy.model_id == "claude-opus-4-6"
      assert policy.thinking_level == :high
    end

    test "creates a policy with metadata" do
      policy =
        ModelPolicy.new_policy("gpt-4o",
          set_by: "admin",
          reason: "Cost optimization",
          metadata: %{custom_field: "value"}
        )

      assert policy.model_id == "gpt-4o"
      assert policy.metadata.set_by == "admin"
      assert policy.metadata.reason == "Cost optimization"
      assert policy.metadata.custom_field == "value"
    end

    test "normalizes thinking level strings" do
      policy = ModelPolicy.new_policy("model", thinking_level: "medium")
      assert policy.thinking_level == :medium

      policy = ModelPolicy.new_policy("model", thinking_level: "HIGH")
      assert policy.thinking_level == :high
    end

    test "rejects invalid thinking levels" do
      policy = ModelPolicy.new_policy("model", thinking_level: :invalid)
      assert not Map.has_key?(policy, :thinking_level)

      policy = ModelPolicy.new_policy("model", thinking_level: "unknown")
      assert not Map.has_key?(policy, :thinking_level)
    end
  end

  describe "set/2 and get/1" do
    test "sets and gets a policy" do
      route = Route.new("telegram", "default", "123", nil)
      policy = ModelPolicy.new_policy("claude-sonnet-4-20250514")

      assert :ok = ModelPolicy.set(route, policy)
      assert ModelPolicy.get(route) == policy
    end

    test "returns nil for unset route" do
      route = Route.new("unknown", "account", "peer", nil)
      assert ModelPolicy.get(route) == nil
    end

    test "overwrites existing policy" do
      route = Route.new("telegram", "default", "123", nil)

      policy1 = ModelPolicy.new_policy("model-1")
      policy2 = ModelPolicy.new_policy("model-2")

      ModelPolicy.set(route, policy1)
      ModelPolicy.set(route, policy2)

      assert ModelPolicy.get(route) == policy2
    end
  end

  describe "clear/1" do
    test "clears a set policy" do
      route = Route.new("telegram", "default", "123", nil)
      policy = ModelPolicy.new_policy("claude-sonnet-4-20250514")

      ModelPolicy.set(route, policy)
      assert ModelPolicy.get(route) != nil

      assert :ok = ModelPolicy.clear(route)
      assert ModelPolicy.get(route) == nil
    end

    test "clearing non-existent policy returns ok" do
      route = Route.new("unknown", "account", "peer", nil)
      assert :ok = ModelPolicy.clear(route)
    end
  end

  describe "resolve/1" do
    test "resolves exact match" do
      route = Route.new("telegram", "default", "123", "456")
      policy = ModelPolicy.new_policy("claude-sonnet-4-20250514")

      ModelPolicy.set(route, policy)

      assert {:ok, resolved} = ModelPolicy.resolve(route)
      assert resolved.model_id == "claude-sonnet-4-20250514"
    end

    test "resolves using precedence - thread falls back to peer" do
      # Set peer-level policy
      peer_route = Route.new("telegram", "default", "123", nil)
      peer_policy = ModelPolicy.new_policy("peer-model")
      ModelPolicy.set(peer_route, peer_policy)

      # Query thread-level (should find peer policy)
      thread_route = Route.new("telegram", "default", "123", "456")

      assert {:ok, resolved} = ModelPolicy.resolve(thread_route)
      assert resolved.model_id == "peer-model"
    end

    test "resolves using precedence - peer falls back to account" do
      # Set account-level policy
      account_route = Route.new("telegram", "default", nil, nil)
      account_policy = ModelPolicy.new_policy("account-model")
      ModelPolicy.set(account_route, account_policy)

      # Query peer-level (should find account policy)
      peer_route = Route.new("telegram", "default", "123", nil)

      assert {:ok, resolved} = ModelPolicy.resolve(peer_route)
      assert resolved.model_id == "account-model"
    end

    test "resolves using precedence - account falls back to channel" do
      # Set channel-level policy
      channel_route = Route.channel_wide("telegram")
      channel_policy = ModelPolicy.new_policy("channel-model")
      ModelPolicy.set(channel_route, channel_policy)

      # Query account-level (should find channel policy)
      account_route = Route.new("telegram", "default", nil, nil)

      assert {:ok, resolved} = ModelPolicy.resolve(account_route)
      assert resolved.model_id == "channel-model"
    end

    test "more specific route takes precedence over less specific" do
      # Set channel-level policy
      channel_route = Route.channel_wide("telegram")
      channel_policy = ModelPolicy.new_policy("channel-model")
      ModelPolicy.set(channel_route, channel_policy)

      # Set peer-level policy
      peer_route = Route.new("telegram", "default", "123", nil)
      peer_policy = ModelPolicy.new_policy("peer-model")
      ModelPolicy.set(peer_route, peer_policy)

      # Query peer-level should get peer policy, not channel policy
      assert {:ok, resolved} = ModelPolicy.resolve(peer_route)
      assert resolved.model_id == "peer-model"

      # Query different peer should get channel policy
      other_peer = Route.new("telegram", "default", "999", nil)
      assert {:ok, resolved} = ModelPolicy.resolve(other_peer)
      assert resolved.model_id == "channel-model"
    end

    test "returns not_found when no policy exists" do
      route = Route.new("unknown", "account", "peer", nil)
      assert {:error, :not_found} = ModelPolicy.resolve(route)
    end
  end

  describe "resolve_model_id/1" do
    test "returns model_id when policy exists" do
      route = Route.new("telegram", "default", "123", nil)
      policy = ModelPolicy.new_policy("claude-sonnet-4-20250514")
      ModelPolicy.set(route, policy)

      assert ModelPolicy.resolve_model_id(route) == "claude-sonnet-4-20250514"
    end

    test "returns nil when no policy exists" do
      route = Route.new("unknown", "account", "peer", nil)
      assert ModelPolicy.resolve_model_id(route) == nil
    end
  end

  describe "resolve_thinking_level/1" do
    test "returns thinking_level when policy has it" do
      route = Route.new("telegram", "default", "123", nil)
      policy = ModelPolicy.new_policy("claude-opus-4-6", thinking_level: :high)
      ModelPolicy.set(route, policy)

      assert ModelPolicy.resolve_thinking_level(route) == :high
    end

    test "returns nil when policy has no thinking_level" do
      route = Route.new("telegram", "default", "123", nil)
      policy = ModelPolicy.new_policy("gpt-4o")
      ModelPolicy.set(route, policy)

      assert ModelPolicy.resolve_thinking_level(route) == nil
    end

    test "returns nil when no policy exists" do
      route = Route.new("unknown", "account", "peer", nil)
      assert ModelPolicy.resolve_thinking_level(route) == nil
    end
  end

  describe "list/0" do
    test "returns empty list when no policies" do
      assert ModelPolicy.list() == []
    end

    test "returns all policies with their routes" do
      route1 = Route.new("telegram", "default", "123", nil)
      route2 = Route.new("discord", "bot1", "456", nil)

      policy1 = ModelPolicy.new_policy("model-1")
      policy2 = ModelPolicy.new_policy("model-2")

      ModelPolicy.set(route1, policy1)
      ModelPolicy.set(route2, policy2)

      results = ModelPolicy.list()
      assert length(results) == 2

      routes = Enum.map(results, fn {route, _policy} -> route end)
      assert route1 in routes
      assert route2 in routes
    end
  end

  describe "list/1" do
    test "filters by channel_id" do
      telegram_route = Route.new("telegram", "default", "123", nil)
      discord_route = Route.new("discord", "bot1", "456", nil)

      ModelPolicy.set(telegram_route, ModelPolicy.new_policy("telegram-model"))
      ModelPolicy.set(discord_route, ModelPolicy.new_policy("discord-model"))

      telegram_policies = ModelPolicy.list("telegram")
      assert length(telegram_policies) == 1
      assert elem(hd(telegram_policies), 0).channel_id == "telegram"
    end

    test "returns empty list for unknown channel" do
      assert ModelPolicy.list("unknown") == []
    end
  end

  describe "clear_channel/1" do
    test "clears all policies for a channel" do
      route1 = Route.new("telegram", "default", "123", nil)
      route2 = Route.new("telegram", "default", "456", nil)
      route3 = Route.new("discord", "bot1", "789", nil)

      ModelPolicy.set(route1, ModelPolicy.new_policy("model-1"))
      ModelPolicy.set(route2, ModelPolicy.new_policy("model-2"))
      ModelPolicy.set(route3, ModelPolicy.new_policy("model-3"))

      assert :ok = ModelPolicy.clear_channel("telegram")

      assert ModelPolicy.get(route1) == nil
      assert ModelPolicy.get(route2) == nil
      assert ModelPolicy.get(route3) != nil
    end
  end

  describe "exists?/1" do
    test "returns true for existing policy" do
      route = Route.new("telegram", "default", "123", nil)
      ModelPolicy.set(route, ModelPolicy.new_policy("model"))

      assert ModelPolicy.exists?(route) == true
    end

    test "returns false for non-existing policy" do
      route = Route.new("unknown", "account", "peer", nil)
      assert ModelPolicy.exists?(route) == false
    end
  end

  describe "update_metadata/2" do
    test "updates existing policy metadata" do
      route = Route.new("telegram", "default", "123", nil)
      policy = ModelPolicy.new_policy("model", set_by: "original")
      ModelPolicy.set(route, policy)

      assert :ok = ModelPolicy.update_metadata(route, set_by: "updated", reason: "testing")

      updated = ModelPolicy.get(route)
      assert updated.metadata.set_by == "updated"
      assert updated.metadata.reason == "testing"
      assert updated.metadata.updated_at_ms != nil
    end

    test "returns not_found for non-existing policy" do
      route = Route.new("unknown", "account", "peer", nil)
      assert {:error, :not_found} = ModelPolicy.update_metadata(route, set_by: "test")
    end
  end
end
