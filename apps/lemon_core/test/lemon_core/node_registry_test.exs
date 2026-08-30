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
