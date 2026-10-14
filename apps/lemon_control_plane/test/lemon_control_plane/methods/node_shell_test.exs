defmodule LemonControlPlane.Methods.NodeShellTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.{NodeShells, NodeStore}
  alias LemonControlPlane.Methods.{NodeShellEvent, NodeShellInput, NodeInvoke}
  alias LemonCore.NodeRegistry

  setup do
    if is_nil(Process.whereis(NodeShells)), do: start_supervised!(NodeShells)
    id = "shell-node-#{System.unique_integer([:positive])}"
    :ok = NodeStore.put_node(id, %{id: id, name: id, type: "coding_agent"})
    :ok = NodeRegistry.register_session(id, id, self(), 7)
    owner = self()
    other = spawn(fn -> relay(owner) end)
    on_exit(fn ->
      NodeRegistry.unregister(id, owner)
      LemonCore.Store.delete(:nodes_registry, id)
      Process.exit(other, :kill)
    end)
    %{node_id: id, other: other}
  end

  test "output and exit reach only opener; foreign input and stale frames fail closed", %{node_id: id, other: other} do
    owner = self()
    task = Task.async(fn -> NodeShells.open(%{"nodeId" => id}, %{conn_pid: owner}) end)
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => invoke_id, "args" => args}}, 1_000
    shell_id = args["shellId"]
    ctx = %{conn_pid: self(), auth: %{role: :node, client_id: id, identity: %{"sessionGeneration" => 7}}}

    assert {:ok, %{"received" => true}} = NodeShellEvent.handle(%{"invokeId" => invoke_id, "payload" => %{"type" => "ready"}}, ctx)
    assert {:ok, %{"shellId" => ^shell_id}} = Task.await(task)
    encoded = Base.encode64("private terminal output")
    assert {:ok, _} = NodeShellEvent.handle(%{"invokeId" => invoke_id,
      "payload" => %{"type" => "output", "dataBase64" => encoded, "seq" => 1}}, ctx)
    assert_receive {:event, "node.shell.output", %{"shellId" => ^shell_id, "dataBase64" => ^encoded, "seq" => 1}}
    refute_receive {:foreign, {:event, "node.shell.output", _}}

    assert {:error, _} = NodeShellInput.handle(%{"shellId" => shell_id, "dataBase64" => encoded}, %{conn_pid: other})
    assert {:error, _} = NodeShellEvent.handle(%{"invokeId" => invoke_id,
      "payload" => %{"type" => "ready"}}, %{ctx | conn_pid: other})
    assert {:ok, _} = NodeShellEvent.handle(%{"invokeId" => invoke_id, "payload" => %{"type" => "exit", "code" => 0}}, ctx)
    assert_receive {:event, "node.shell.exit", %{"shellId" => ^shell_id, "code" => 0}}
    refute_receive {:foreign, {:event, "node.shell.exit", _}}
    assert :ok = NodeRegistry.complete_session(id, self(), 7, invoke_id, %{"code" => 0})
    assert {:error, _} = NodeShellEvent.handle(%{"invokeId" => invoke_id,
      "payload" => %{"type" => "ready"}}, ctx)
  end

  test "generic invocation cannot bypass machine admin methods", %{node_id: id} do
    for method <- ["node.fs.read", "node.secrets.set", "node.shell.open"] do
      assert {:error, {:forbidden, _}} = NodeInvoke.handle(%{"nodeId" => id, "method" => method, "args" => %{}}, %{conn_pid: self()})
    end
  end

  test "disconnecting opener cancels destination terminal", %{node_id: id} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    task = Task.async(fn -> NodeShells.open(%{"nodeId" => id}, %{conn_pid: owner}) end)
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => invoke_id}}, 1_000
    ctx = %{conn_pid: self(), auth: %{role: :node, client_id: id, identity: %{"sessionGeneration" => 7}}}
    assert {:ok, _} = NodeShellEvent.handle(%{"invokeId" => invoke_id, "payload" => %{"type" => "ready"}}, ctx)
    assert {:ok, _} = Task.await(task)
    Process.exit(owner, :kill)
    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}, 1_000
  end

  defp relay(owner) do
    receive do
      message -> send(owner, {:foreign, message}); relay(owner)
    end
  end
end
