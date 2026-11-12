defmodule LemonControlPlane.NodeIOTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.{NodeIO, NodeStore}
  alias LemonCore.NodeRegistry

  @read %{
    "preDispatch" => false,
    "retrySafe" => true,
    "mutationMayHaveApplied" => false
  }

  setup do
    node_id = "node-io-#{System.unique_integer([:positive])}"
    node = self()
    NodeStore.put_node(node_id, %{id: node_id, name: node_id})
    assert :ok = NodeRegistry.register(node_id, node_id, node)

    on_exit(fn ->
      NodeRegistry.unregister(node_id, node)
      LemonCore.Store.delete(:nodes_registry, node_id)
    end)

    %{node_id: node_id}
  end

  test "unanswered passive inspections are retry-safe reads, not uncertain mutations", %{
    node_id: node_id
  } do
    for method <- ["node.capabilities.get", "node.runtime.features", "node.host.info"] do
      assert {:error, {:unavailable, _message, @read}} =
               NodeIO.invoke(node_id, method, %{}, %{conn_pid: self()}, timeout_ms: 20)

      assert_receive {:node_event, "node.invoke.request",
                      %{"invokeId" => invoke_id, "method" => ^method}}

      assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}
    end
  end

  test "an unclassified destination failure of an inspection is an unavailable read", %{
    node_id: node_id
  } do
    owner = self()

    task =
      Task.async(fn ->
        NodeIO.invoke(node_id, "node.capabilities.get", %{}, %{conn_pid: owner})
      end)

    assert_receive {:node_event, "node.invoke.request",
                    %{"invokeId" => invoke_id, "method" => "node.capabilities.get"}},
                   1_000

    assert :ok = NodeRegistry.complete_session(node_id, self(), 0, invoke_id, nil, "unexpected")

    assert {:error, {:unavailable, _message, @read}} = Task.await(task)
  end

  test "an unanswered mutation stays duplicate-risk", %{node_id: node_id} do
    args = %{"path" => "note.txt", "dataBase64" => "", "offset" => 0, "truncate" => true}

    assert {:error, {:unavailable, message, details}} =
             NodeIO.invoke(node_id, "node.fs.write", args, %{conn_pid: self()}, timeout_ms: 20)

    assert message =~ "mutation outcome may be unknown"

    assert details == %{
             "preDispatch" => false,
             "retrySafe" => false,
             "mutationMayHaveApplied" => true
           }
  end
end
