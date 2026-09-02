defmodule LemonCore.PolicyStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.PolicyStore

  test "declares exact ownership of the existing policy tables" do
    assert Enum.map(PolicyStore.__store_tables__(), & &1.name) == [
             :agent_policies,
             :channel_policies,
             :session_policies,
             :runtime_policy
           ]

    assert Enum.all?(PolicyStore.__store_tables__(), fn table ->
             table.owner == PolicyStore and table.persistence == :durable and
               table.cached == false and table.retention == nil and table.version == 1
           end)
  end

  test "stores and fetches session policy through the typed wrapper" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    policy = %{model: "gpt-test", thinking_level: :high}

    assert :ok = PolicyStore.put_session(session_key, policy)
    assert PolicyStore.get_session(session_key) == policy
  end
end
