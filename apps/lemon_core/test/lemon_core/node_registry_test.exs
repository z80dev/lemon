defmodule LemonCore.NodeRegistryTest do
  use ExUnit.Case, async: false

  alias LemonCore.NodeRegistry

  setup do
    for node <- NodeRegistry.list() do
      NodeRegistry.unregister(node.id, node.pid)
    end

    :ok
  end

  test "registers and resolves a live node by name or id" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self(), %{"gpu" => true})

    assert {:ok, %{id: "node-1", name: "newphy", metadata: %{"gpu" => true}}} =
             NodeRegistry.resolve("newphy")

    assert {:ok, %{name: "newphy"}} = NodeRegistry.resolve("node-1")
    assert NodeRegistry.online?("newphy")
  end

  test "requires unique live names" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = NodeRegistry.register("node-1", "gpu-box", first)

    assert {:error, {:name_taken, "gpu-box"}} =
             NodeRegistry.register("node-2", "gpu-box", second)

    Process.exit(first, :kill)
    Process.exit(second, :kill)
  end

  test "replaces an earlier connection for the same paired node" do
    parent = self()

    old = spawn(fn -> relay(parent, :old_connection) end)

    new = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = NodeRegistry.register("node-1", "ophy", old)
    assert {:ok, invoke_id} = NodeRegistry.invoke("ophy", "coding_agent.run", %{})

    assert_receive {:old_connection,
                    {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}}

    assert :ok = NodeRegistry.register("node-1", "ophy", new)

    assert_receive {:old_connection,
                    {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}}

    assert_receive {:lemon_node_result, ^invoke_id, {:error, {:node_disconnected, :reconnected}}}

    assert {:ok, %{pid: ^new}} = NodeRegistry.resolve("ophy")

    Process.exit(old, :kill)
    Process.exit(new, :kill)
  end

  test "renames a live node without dropping active invocations" do
    assert :ok = NodeRegistry.register("node-1", "old-name", self())
    assert {:ok, invoke_id} = NodeRegistry.invoke("old-name", "coding_agent.run", %{})
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

    assert :ok = NodeRegistry.rename("node-1", "new-name")
    assert {:error, :not_found} = NodeRegistry.resolve("old-name")
    assert {:ok, %{id: "node-1"}} = NodeRegistry.resolve("new-name")

    assert :ok = NodeRegistry.complete("node-1", invoke_id, %{"answer" => "done"})
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"answer" => "done"}}}
  end

  test "targets invocation requests and binds completion to the selected node" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())
    assert {:ok, invoke_id} = NodeRegistry.invoke("newphy", "coding_agent.run", %{"x" => 1})

    assert_receive {:node_event, "node.invoke.request", payload}
    assert payload["invokeId"] == invoke_id
    assert payload["nodeName"] == "newphy"

    assert {:error, :wrong_node} = NodeRegistry.complete("node-2", invoke_id, %{}, nil)
    refute_receive {:lemon_node_result, ^invoke_id, _}

    assert :ok = NodeRegistry.complete("node-1", invoke_id, %{"answer" => "done"}, nil)
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"answer" => "done"}}}
  end

  test "strict completion is bound to the receiving connection and generation" do
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = NodeRegistry.register_session("strict-node", "newphy", self(), 7)
    assert {:ok, invoke_id} = NodeRegistry.invoke("newphy", "coding_agent.run", %{})
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

    assert {:error, :stale_session} =
             NodeRegistry.complete_session(
               "strict-node",
               other,
               7,
               invoke_id,
               %{"wrong" => true}
             )

    assert {:error, :stale_session} =
             NodeRegistry.complete_session(
               "strict-node",
               self(),
               6,
               invoke_id,
               %{"old" => true}
             )

    assert :ok =
             NodeRegistry.complete_session(
               "strict-node",
               self(),
               7,
               invoke_id,
               %{"ok" => true}
             )

    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => true}}}
    Process.exit(other, :kill)
  end

  test "credential rotation revokes the live stale session immediately" do
    parent = self()
    stale = spawn(fn -> relay(parent, :stale_session) end)

    assert :ok = NodeRegistry.register_session("rotating-node", "newphy", stale, 3)
    assert {:ok, invoke_id} = NodeRegistry.invoke("newphy", "coding_agent.run", %{})

    assert_receive {:stale_session,
                    {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}}

    assert :ok = NodeRegistry.revoke_session("rotating-node", 4)
    assert_receive {:stale_session, {:node_session_revoked, "rotating-node", 4}}

    assert_receive {:lemon_node_result, ^invoke_id,
                    {:error, {:node_disconnected, :credential_rotated}}}

    refute NodeRegistry.online?("rotating-node")
    Process.exit(stale, :kill)
  end

  test "revoke before a delayed handshake retains the authorized generation floor" do
    assert :ok = NodeRegistry.revoke_session("delayed-handshake-node", 2)

    assert {:error, :stale_session} =
             NodeRegistry.register_session("delayed-handshake-node", "delayed", self(), 1)

    refute NodeRegistry.online?("delayed-handshake-node")
    assert :ok = NodeRegistry.register_session("delayed-handshake-node", "delayed", self(), 2)
    assert NodeRegistry.online?("delayed-handshake-node")
  end

  test "a lower generation cannot replace a higher live session" do
    parent = self()
    current = spawn(fn -> relay(parent, :current_session) end)
    stale = spawn(fn -> relay(parent, :stale_session) end)

    assert :ok = NodeRegistry.register_session("monotonic-node", "monotonic", current, 5)

    assert {:error, :stale_session} =
             NodeRegistry.register_session("monotonic-node", "monotonic", stale, 4)

    assert {:ok, %{pid: ^current}} = NodeRegistry.resolve("monotonic-node")
    refute_receive {:current_session, {:node_session_revoked, _, _}}

    Process.exit(current, :kill)
    Process.exit(stale, :kill)
  end

  test "rejects an invocation when the full request envelope exceeds maxPayload" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    assert {:error, {:invalid_payload, {:max_bytes, 160}}} =
             NodeRegistry.invoke(
               "newphy",
               "coding_agent.run",
               %{"prompt" => String.duplicate("x", 128)},
               max_payload_bytes: 160
             )

    refute_receive {:node_event, "node.invoke.request", _payload}
  end

  test "fails an active invocation when its node disconnects" do
    node = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = NodeRegistry.register("node-1", "newphy", node)
    assert {:ok, invoke_id} = NodeRegistry.invoke("newphy", "coding_agent.run", %{})

    Process.exit(node, :kill)

    assert_receive {:lemon_node_result, ^invoke_id,
                    {:error, {:node_disconnected, :disconnected}}},
                   1_000
  end

  test "times out invocations" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("newphy", "coding_agent.run", %{}, timeout_ms: 10)

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}
    assert_receive {:lemon_node_result, ^invoke_id, {:error, :timeout}}, 1_000
  end

  test "cancels destination work when the result recipient exits" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())
    recipient = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("newphy", "coding_agent.run", %{}, recipient: recipient)

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    Process.exit(recipient, :kill)

    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}, 1_000
  end

  test "cancel sends a targeted cancellation event" do
    assert :ok = NodeRegistry.register("node-1", "ophy", self())
    assert {:ok, invoke_id} = NodeRegistry.invoke("ophy", "coding_agent.run", %{})
    assert_receive {:node_event, "node.invoke.request", _}

    assert :ok = NodeRegistry.cancel(invoke_id, :user_requested)

    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}
    assert_receive {:lemon_node_result, ^invoke_id, {:error, :user_requested}}
  end

  defp relay(parent, tag) do
    receive do
      message ->
        send(parent, {tag, message})
        relay(parent, tag)
    end
  end
end
