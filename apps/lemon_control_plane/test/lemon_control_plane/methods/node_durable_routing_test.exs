defmodule LemonControlPlane.Methods.NodeDurableRoutingTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.{NodeIO, NodeShells, NodeStore}
  alias LemonCore.NodeRegistry

  test "file, secret and PTY RPCs use exact durable identity even when another node claims its name" do
    if is_nil(Process.whereis(NodeShells)), do: start_supervised!(NodeShells)
    a = "machine-a-#{System.unique_integer([:positive])}"
    b = "machine-b-#{System.unique_integer([:positive])}"
    owner = self()
    attacker = spawn(fn -> relay(owner) end)
    NodeStore.put_node(a, %{id: a, name: "owner-#{a}"})
    NodeStore.put_node(b, %{id: b, name: a})
    assert :ok = NodeRegistry.register(a, "owner-#{a}", self())
    assert :ok = NodeRegistry.register(b, a, attacker)

    on_exit(fn ->
      NodeRegistry.unregister(a, owner)
      NodeRegistry.unregister(b, attacker)
      Process.exit(attacker, :kill)
      LemonCore.Store.delete(:nodes_registry, a)
      LemonCore.Store.delete(:nodes_registry, b)
    end)

    for {method, args} <- [
          {"node.secrets.set", %{"name" => "token", "value" => "private"}},
          {"node.fs.read", %{"path" => "private.txt"}}
        ] do
      task = Task.async(fn -> NodeIO.invoke(a, method, args, %{conn_pid: owner}) end)

      assert_receive {:node_event, "node.invoke.request",
                      %{"nodeId" => ^a, "invokeId" => invocation, "method" => ^method}},
                     1_000

      assert :ok = NodeRegistry.complete_session(a, self(), 0, invocation, %{"received" => true})
      assert {:ok, %{"received" => true}} = Task.await(task)
      refute_receive {:attacker, _}
    end

    task = Task.async(fn -> NodeShells.open(%{"nodeId" => a}, %{conn_pid: owner}) end)

    assert_receive {:node_event, "node.invoke.request",
                    %{"nodeId" => ^a, "invokeId" => invocation, "method" => "node.shell.open"}},
                   1_000

    assert :ok = NodeRegistry.shell_event_session(a, self(), 0, invocation, %{"type" => "ready"})
    assert {:ok, %{"shellId" => shell_id}} = Task.await(task)

    assert :ok =
             NodeRegistry.shell_event_session(a, self(), 0, invocation, %{
               "type" => "exit",
               "code" => 0
             })

    assert_receive {:event, "node.shell.exit", %{"shellId" => ^shell_id, "code" => 0}}
    assert :ok = NodeRegistry.complete_session(a, self(), 0, invocation, %{"code" => 0})
    refute_receive {:attacker, _}

    assert :ok = NodeRegistry.unregister(a, self())

    assert {:error, _} =
             NodeIO.invoke(a, "node.secrets.set", %{"name" => "token", "value" => "private"}, %{
               conn_pid: owner
             })

    assert {:error, _} =
             NodeIO.invoke(a, "node.fs.read", %{"path" => "private.txt"}, %{conn_pid: owner})

    assert {:error, _} = NodeShells.open(%{"nodeId" => a}, %{conn_pid: owner})
    refute_receive {:attacker, _}
  end

  defp relay(owner) do
    receive do
      message ->
        send(owner, {:attacker, message})
        relay(owner)
    end
  end
end
