defmodule LemonControlPlane.AgentIdentityStoreTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.AgentIdentityStore

  test "stores and fetches persisted agent identities through the typed wrapper" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    identity = %{id: agent_id, name: "Test Agent"}

    assert :ok = AgentIdentityStore.put(agent_id, identity)
    assert AgentIdentityStore.get(agent_id) == identity

    assert :ok = AgentIdentityStore.delete(agent_id)
    assert AgentIdentityStore.get(agent_id) == nil
  end
end
