defmodule LemonControlPlane.NamedNodeIntegrationTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.Methods.{NodeInvoke, NodeInvokeResult, NodePairApprove, NodeRename}
  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.WS.Connection

  @operator_ctx %{
    conn_id: "named-node-operator",
    conn_pid: nil,
    auth: %{role: :operator, scopes: [:admin, :pairing, :read, :write]}
  }

  setup do
    clear_tables()

    on_exit(fn ->
      clear_live_nodes()
      clear_tables()
    end)

    :ok
  end

  test "node.invoke delivers only to the target and rejects a different node's result" do
    parent = self()
    target_pid = spawn_node(parent, :target)
    other_pid = spawn_node(parent, :other)
    target_id = unique("target")
    other_id = unique("other")

    put_node(target_id, "Target Node")
    put_node(other_id, "Other Node")
    :ok = LemonCore.NodeRegistry.register(target_id, "Target Node", target_pid)
    :ok = LemonCore.NodeRegistry.register(other_id, "Other Node", other_pid)

    ctx = %{@operator_ctx | conn_pid: self()}

    assert {:ok, invoke} =
             NodeInvoke.handle(
               %{
                 "nodeId" => target_id,
                 "method" => "work.run",
                 "args" => %{"value" => 7}
               },
               ctx
             )

    assert_receive {:target, {:node_event, "node.invoke.request", payload}}
    assert payload["invokeId"] == invoke["invokeId"]
    assert payload["nodeId"] == target_id
    refute_receive {:other, {:node_event, "node.invoke.request", _payload}}, 100

    assert {:error, {:forbidden, _message}} =
             NodeInvokeResult.handle(
               %{"invokeId" => invoke["invokeId"], "result" => %{"wrong" => true}},
               %{auth: %{role: :node, client_id: other_id}}
             )

    assert {:ok, %{"received" => true}} =
             NodeInvokeResult.handle(
               %{"invokeId" => invoke["invokeId"], "result" => %{"ok" => true}},
               %{auth: %{role: :node, client_id: target_id}}
             )

    assert_receive {:lemon_node_result, invoke_id, {:ok, %{"ok" => true}}}
    assert invoke_id == invoke["invokeId"]
    assert NodeStore.get_invocation(invoke_id).status == :completed

    Process.exit(target_pid, :kill)
    Process.exit(other_pid, :kill)
  end

  test "a coding-agent registry invocation completes without a durable control-plane record" do
    node_id = unique("registry-only")
    node_name = "Registry Only #{System.unique_integer([:positive])}"
    :ok = LemonCore.NodeRegistry.register(node_id, node_name, self())

    assert {:ok, invoke_id} =
             LemonCore.NodeRegistry.invoke(
               node_name,
               "coding_agent.run",
               %{"prompt" => "work"},
               recipient: self()
             )

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    assert NodeStore.get_invocation(invoke_id) == nil

    assert {:ok, %{"received" => true, "summary" => %{"nodeId" => ^node_id}}} =
             NodeInvokeResult.handle(
               %{"invokeId" => invoke_id, "result" => %{"ok" => true}},
               %{auth: %{role: :node, client_id: node_id}}
             )

    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => true}}}
  end

  test "authenticated node websocket owns live registration and targeted frames" do
    node_id = unique("ws-node")
    node_name = "WS Node #{System.unique_integer([:positive])}"
    token = unique("node-token")
    put_node(node_id, node_name)

    assert {:ok, _info} =
             TokenStore.store(token, %{"type" => "node", "nodeId" => node_id})

    assert {:ok, state} = Connection.init([])

    connect =
      Jason.encode!(%{
        "type" => "req",
        "id" => "connect-1",
        "method" => "connect",
        "params" => %{"auth" => %{"token" => token}}
      })

    assert {:push, {:text, hello}, connected_state} =
             Connection.handle_in({connect, [opcode: :text]}, state)

    assert Jason.decode!(hello)["type"] == "hello-ok"

    assert {:ok, %{id: ^node_id, name: ^node_name, pid: pid}} =
             LemonCore.NodeRegistry.resolve(node_name)

    assert pid == self()
    assert :ok = LemonCore.NodeRegistry.push(node_name, "node.config", %{"enabled" => true})
    assert_receive {:node_event, "node.config", %{"enabled" => true}} = event

    assert {:push, {:text, frame}, pushed_state} = Connection.handle_info(event, connected_state)
    decoded = Jason.decode!(frame)
    assert decoded["event"] == "node.config"
    assert decoded["payload"] == %{"enabled" => true}
    assert pushed_state.event_seq == connected_state.event_seq + 1

    assert :ok = Connection.terminate(:normal, connected_state)
    refute LemonCore.NodeRegistry.online?(node_id)
    assert node_status(NodeStore.get_node(node_id)) == :offline
  end

  test "pair approval and rename enforce unique durable names" do
    existing_id = unique("existing")
    existing_name = "Unique Name #{System.unique_integer([:positive])}"
    put_node(existing_id, existing_name)
    :ok = NodeStore.reserve_node_name(existing_name, existing_id)

    pairing_id = unique("pairing")

    :ok =
      NodeStore.put_pairing(pairing_id, %{
        status: :pending,
        node_name: existing_name,
        node_type: "worker",
        capabilities: %{},
        expires_at_ms: System.system_time(:millisecond) + 60_000
      })

    assert {:error, {:conflict, "Node name is already in use"}} =
             NodePairApprove.handle(%{"pairingId" => pairing_id}, @operator_ctx)

    rename_id = unique("rename")
    put_node(rename_id, "Rename Source #{System.unique_integer([:positive])}")

    assert {:error, {:conflict, "Node name is already in use"}} =
             NodeRename.handle(
               %{"nodeId" => rename_id, "name" => "  #{existing_name}  "},
               @operator_ctx
             )
  end

  test "renaming an online node updates live name without dropping invocations" do
    node_id = unique("rename-live")
    old_name = "Old Live #{System.unique_integer([:positive])}"
    new_name = "New Live #{System.unique_integer([:positive])}"
    put_node(node_id, old_name)
    :ok = NodeStore.reserve_node_name(old_name, node_id)
    :ok = LemonCore.NodeRegistry.register(node_id, old_name, self())

    assert {:ok, invoke_id} =
             LemonCore.NodeRegistry.invoke(old_name, "work.run", %{}, recipient: self())

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

    assert {:ok, %{"name" => ^new_name}} =
             NodeRename.handle(%{"nodeId" => node_id, "name" => new_name}, @operator_ctx)

    assert {:error, :not_found} = LemonCore.NodeRegistry.resolve(old_name)
    assert {:ok, %{id: ^node_id}} = LemonCore.NodeRegistry.resolve(new_name)
    assert :ok = LemonCore.NodeRegistry.complete(node_id, invoke_id, %{"done" => true})
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"done" => true}}}
  end

  defp put_node(node_id, name) do
    NodeStore.put_node(node_id, %{
      id: node_id,
      name: name,
      type: "worker",
      capabilities: %{},
      status: :offline
    })
  end

  defp spawn_node(parent, label) do
    spawn(fn -> node_loop(parent, label) end)
  end

  defp node_loop(parent, label) do
    receive do
      message ->
        send(parent, {label, message})
        node_loop(parent, label)
    end
  end

  defp node_status(node), do: Map.get(node, :status) || Map.get(node, "status")

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp clear_live_nodes do
    Enum.each(LemonCore.NodeRegistry.list(), fn node ->
      if Enum.any?(
           ["target-", "other-", "ws-node-", "rename-live-", "registry-only-"],
           &String.starts_with?(node.id, &1)
         ) do
        LemonCore.NodeRegistry.unregister(node.id, node.pid)
      end
    end)
  end

  defp clear_tables do
    Enum.each(
      [
        :nodes_pairing,
        :nodes_pairing_by_code,
        :nodes_registry,
        :nodes_by_name,
        :node_challenges,
        :node_invocations,
        :session_tokens
      ],
      fn table ->
        LemonCore.Store.list(table)
        |> Enum.each(fn {key, _value} -> LemonCore.Store.delete(table, key) end)
      end
    )
  end
end
