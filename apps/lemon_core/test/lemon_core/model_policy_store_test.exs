defmodule LemonCore.ModelPolicyStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.ModelPolicyStore

  test "stores and lists model policies through the typed wrapper" do
    route_key = "telegram:default:peer:#{System.unique_integer([:positive])}"
    policy = %{model_id: "claude-sonnet-test"}

    assert :ok = ModelPolicyStore.put(route_key, policy)
    assert ModelPolicyStore.get(route_key) == policy
    assert {route_key, policy} in ModelPolicyStore.list()

    assert :ok = ModelPolicyStore.delete(route_key)
    assert ModelPolicyStore.get(route_key) == nil
  end
end
