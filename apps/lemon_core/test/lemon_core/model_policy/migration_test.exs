defmodule LemonCore.ModelPolicy.MigrationTest do
  @moduledoc false
  use ExUnit.Case

  alias LemonCore.ModelPolicy
  alias LemonCore.ModelPolicy.Migration
  alias LemonCore.ModelPolicy.Route

  setup do
    # Clean up before each test
    cleanup_all_policies()
    cleanup_legacy_storage()
    :ok
  end

  defp cleanup_all_policies do
    ModelPolicy.list()
    |> Enum.each(fn {route, _} -> ModelPolicy.clear(route) end)
  end

  defp cleanup_legacy_storage do
    # Clean up legacy storage
    LemonCore.Store.list(:telegram_default_model)
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(:telegram_default_model, key) end)

    LemonCore.Store.list(:telegram_default_thinking)
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(:telegram_default_thinking, key) end)
  rescue
    _ -> :ok
  end

  describe "migrate_telegram/1" do
    test "migrates model policies from legacy storage" do
      # Set up legacy data
      LemonCore.Store.put(:telegram_default_model, {"default", 123_456, nil}, %{
        model: "claude-sonnet-4-20250514",
        updated_at_ms: System.system_time(:millisecond)
      })

      result = Migration.migrate_telegram()

      assert result.migrated == 1
      assert result.errors == 0

      # Verify it was migrated
      route = Route.new("telegram", "default", "123456", nil)
      assert {:ok, policy} = ModelPolicy.resolve(route)
      assert policy.model_id == "claude-sonnet-4-20250514"
    end

    test "migrates multiple policies" do
      # Set up multiple legacy policies
      LemonCore.Store.put(:telegram_default_model, {"default", 111, nil}, %{model: "model-1"})
      LemonCore.Store.put(:telegram_default_model, {"default", 222, 333}, %{model: "model-2"})
      LemonCore.Store.put(:telegram_default_model, {"bot1", 444, nil}, %{model: "model-3"})

      result = Migration.migrate_telegram()

      assert result.migrated == 3
      assert result.errors == 0
    end

    test "skips policies that already exist in ModelPolicy" do
      # Set up existing ModelPolicy
      route = Route.new("telegram", "default", "123", nil)
      ModelPolicy.set(route, ModelPolicy.new_policy("existing-model"))

      # Set up legacy data for same route
      LemonCore.Store.put(:telegram_default_model, {"default", 123, nil}, %{model: "legacy-model"})

      result = Migration.migrate_telegram()

      assert result.migrated == 0
      assert result.skipped == 1

      # Verify existing policy was not overwritten
      assert {:ok, policy} = ModelPolicy.resolve(route)
      assert policy.model_id == "existing-model"
    end

    test "skips empty model values" do
      LemonCore.Store.put(:telegram_default_model, {"default", 123, nil}, %{model: ""})
      LemonCore.Store.put(:telegram_default_model, {"default", 456, nil}, nil)

      result = Migration.migrate_telegram()

      assert result.migrated == 0
      assert result.skipped == 2
    end

    test "dry_run does not modify data" do
      LemonCore.Store.put(:telegram_default_model, {"default", 123, nil}, %{model: "test-model"})

      result = Migration.migrate_telegram(dry_run: true)

      assert result.migrated == 1

      # Verify it was NOT actually migrated
      route = Route.new("telegram", "default", "123", nil)
      assert {:error, :not_found} = ModelPolicy.resolve(route)
    end

    test "merges thinking levels with existing model policies" do
      # First migrate the model
      LemonCore.Store.put(:telegram_default_model, {"default", 123, nil}, %{model: "test-model"})
      Migration.migrate_telegram()

      # Now add thinking preference
      LemonCore.Store.put(:telegram_default_thinking, {"default", 123, nil}, %{
        thinking_level: :high
      })

      result = Migration.migrate_telegram()

      assert result.migrated == 1

      # Verify thinking was merged
      route = Route.new("telegram", "default", "123", nil)
      assert {:ok, policy} = ModelPolicy.resolve(route)
      assert policy.model_id == "test-model"
      assert policy.thinking_level == :high
    end

    test "skips thinking-only policies without model" do
      LemonCore.Store.put(:telegram_default_thinking, {"default", 123, nil}, %{
        thinking_level: :high
      })

      result = Migration.migrate_telegram()

      assert result.migrated == 0
      assert result.skipped == 1
    end

    test "accepts valid string thinking levels without interning new atoms" do
      LemonCore.Store.put(:telegram_default_model, {"default", 123, nil}, %{model: "test-model"})
      Migration.migrate_telegram()

      LemonCore.Store.put(:telegram_default_thinking, {"default", 123, nil}, %{
        thinking_level: "high"
      })

      result = Migration.migrate_telegram()

      assert result.migrated == 1

      route = Route.new("telegram", "default", "123", nil)
      assert {:ok, policy} = ModelPolicy.resolve(route)
      assert policy.thinking_level == :high
    end

    test "ignores invalid string thinking levels" do
      LemonCore.Store.put(:telegram_default_model, {"default", 123, nil}, %{model: "test-model"})
      Migration.migrate_telegram()

      LemonCore.Store.put(:telegram_default_thinking, {"default", 123, nil}, %{
        thinking_level: "definitely_not_real"
      })

      result = Migration.migrate_telegram()

      assert result.migrated == 0
      assert result.skipped == 2

      route = Route.new("telegram", "default", "123", nil)
      assert {:ok, policy} = ModelPolicy.resolve(route)
      refute Map.has_key?(policy, :thinking_level)
    end

    test "uses custom channel_id" do
      LemonCore.Store.put(:telegram_default_model, {"default", 123, nil}, %{model: "test-model"})

      Migration.migrate_telegram(channel_id: "custom_telegram")

      route = Route.new("custom_telegram", "default", "123", nil)
      assert {:ok, policy} = ModelPolicy.resolve(route)
      assert policy.model_id == "test-model"
    end
  end

  describe "status/0" do
    test "returns counts of legacy and new policies" do
      # Set up legacy data
      LemonCore.Store.put(:telegram_default_model, {"default", 111, nil}, %{model: "m1"})
      LemonCore.Store.put(:telegram_default_model, {"default", 222, nil}, %{model: "m2"})

      LemonCore.Store.put(:telegram_default_thinking, {"default", 111, nil}, %{
        thinking_level: :high
      })

      # Set up new policy
      ModelPolicy.set(
        Route.new("telegram", "default", "333", nil),
        ModelPolicy.new_policy("m3")
      )

      status = Migration.status()

      assert status.telegram_models == 2
      assert status.telegram_thinking == 1
      assert status.model_policies == 1
    end

    test "returns zero counts for empty storage" do
      status = Migration.status()

      assert status.telegram_models == 0
      assert status.telegram_thinking == 0
      assert status.model_policies == 0
    end
  end

  describe "needs_migration?/0" do
    test "returns true when legacy policies exist" do
      LemonCore.Store.put(:telegram_default_model, {"default", 123, nil}, %{model: "test"})

      assert Migration.needs_migration?() == true
    end

    test "returns false when no legacy policies exist" do
      # Ensure clean state
      cleanup_legacy_storage()

      assert Migration.needs_migration?() == false
    end
  end
end
