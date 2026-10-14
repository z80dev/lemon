defmodule LemonCore.NodeRegistryDurableIDTest do
  use ExUnit.Case, async: false
  alias LemonCore.NodeRegistry

  test "ID-only resolution and dispatch never select another node with the victim ID as its name" do
    victim = "victim-#{System.unique_integer([:positive])}"
    attacker = "attacker-#{System.unique_integer([:positive])}"
    owner = self()
    attacker_pid = spawn(fn -> relay(owner) end)
    on_exit(fn ->
      NodeRegistry.unregister(victim, owner)
      NodeRegistry.unregister(attacker, attacker_pid)
      Process.exit(attacker_pid, :kill)
    end)
    assert :ok = NodeRegistry.register(victim, "victim-name-#{victim}", self())
    assert :ok = NodeRegistry.register(attacker, victim, attacker_pid)
    assert {:ok, %{id: ^victim}} = NodeRegistry.resolve_id(victim)
    assert {:ok, invoke_id} = NodeRegistry.invoke_node(victim, "node.secrets.set", %{"name" => "token", "value" => "private"})
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id, "nodeId" => ^victim}}
    refute_receive {:attacker_received, _}
    assert :ok = NodeRegistry.complete_session(victim, self(), 0, invoke_id, %{"set" => true})
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"set" => true}}}

    assert :ok = NodeRegistry.unregister(victim, self())
    assert {:error, :not_found} = NodeRegistry.resolve_id(victim)
    assert {:error, {:node_offline, ^victim}} = NodeRegistry.invoke_node(victim, "node.fs.read", %{"path" => "private"})
    assert {:error, {:node_offline, ^victim}} = NodeRegistry.invoke_node(victim, "node.shell.open", %{"cwd" => "."})
    refute_receive {:attacker_received, _}
  end

  test "native execution grants use their bounded item policy without widening unrelated methods or caller byte limits" do
    id = "large-policy-#{System.unique_integer([:positive])}"
    owner = self()
    assert :ok = NodeRegistry.register(id, id, owner)
    on_exit(fn -> NodeRegistry.unregister(id, owner) end)
    tools = Enum.map(1..16_384, &"mcp:fixture/tool-#{&1}")
    args = %{"version" => 1, "prompt" => "execute", "toolPolicy" => %{"allow" => tools}}
    assert {:ok, invocation} = NodeRegistry.invoke_node(id, "coding_agent.run", args, max_payload_bytes: 16_777_216)
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invocation, "args" => ^args}}
    assert :ok = NodeRegistry.complete_session(id, owner, 0, invocation, %{})
    assert_receive {:lemon_node_result, ^invocation, {:ok, %{}}}
    assert {:error, {:invalid_payload, {:max_items, _}}} =
      NodeRegistry.invoke_node(id, "node.fs.read", args, max_payload_bytes: 16_777_216)
    assert {:error, {:invalid_payload, {:max_bytes, 16_384}}} =
      NodeRegistry.invoke_node(id, "coding_agent.run", args, max_payload_bytes: 16_384)
  end

  defp relay(owner) do
    receive do
      event -> send(owner, {:attacker_received, event}); relay(owner)
    end
  end
end
