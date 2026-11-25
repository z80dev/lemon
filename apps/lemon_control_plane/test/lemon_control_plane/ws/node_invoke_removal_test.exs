defmodule LemonControlPlane.WS.NodeInvokeRemovalTest do
  @moduledoc """
  The raw operator `node.invoke` RPC is removed: no operator credential can
  route an arbitrary method to a live node, and no request leaves a durable
  node invocation record behind.
  """

  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Schemas
  alias LemonControlPlane.WS.Connection

  @operator_token "test-node-invoke-removal-operator-secret"

  # Node methods whose dedicated control-plane RPCs are admin-only (or that have
  # no operator RPC at all) and must never be reachable by a `:write` credential.
  @privileged_node_methods [
    "memory.add",
    "memory.delete",
    "memory.transfer.apply",
    "memory.transfer.snapshot",
    "node.mcp.discover",
    "node.profile.sync",
    "coding_agent.tool",
    "coding_agent.run",
    "node.host.info"
  ]

  setup do
    previous = Application.get_env(:lemon_control_plane, :operator_token)
    Application.put_env(:lemon_control_plane, :operator_token, @operator_token)
    node_id = "node-invoke-removal-#{System.unique_integer([:positive])}"
    parent = self()
    node_pid = spawn(fn -> forward(parent) end)

    :ok =
      NodeStore.put_node(node_id, %{
        id: node_id,
        name: node_id,
        type: "worker",
        capabilities: %{},
        status: :online
      })

    :ok = LemonAgent.NodeRegistry.register(node_id, node_id, node_pid)
    clear_invocations()

    on_exit(fn ->
      LemonAgent.NodeRegistry.unregister(node_id, node_pid)
      Process.exit(node_pid, :kill)
      LemonCore.Store.delete(:nodes_registry, node_id)
      clear_invocations()

      if is_nil(previous),
        do: Application.delete_env(:lemon_control_plane, :operator_token),
        else: Application.put_env(:lemon_control_plane, :operator_token, previous)
    end)

    %{node_id: node_id}
  end

  test "node.invoke is not advertised, registered or schema-described" do
    refute "node.invoke" in Registry.list_methods()
    assert Schemas.get("node.invoke") == nil

    {:ok, state} = Connection.init(peer: {203, 0, 113, 40})
    {hello, _state} = connect(state, ["operator.admin", "operator.write"])
    assert "node.invoke.result" in hello["features"]["methods"]
    refute "node.invoke" in hello["features"]["methods"]
  end

  test "a write-only operator cannot route privileged node methods to a live node",
       %{node_id: node_id} do
    {:ok, state} = Connection.init(peer: {203, 0, 113, 41})
    {hello, state} = connect(state, ["operator.write"])
    assert hello["auth"]["scopes"] == ["write"]

    Enum.reduce(@privileged_node_methods, state, fn method, state ->
      {response, state} =
        request(state, "invoke-#{method}", "node.invoke", %{
          "nodeId" => node_id,
          "method" => method,
          "args" => %{"sessionKey" => "agent:x:main", "content" => "x"}
        })

      assert response["ok"] == false, "#{method} reached the node: #{inspect(response)}"
      refute_receive {:node_message, {:node_event, "node.invoke.request", _}}, 50
      state
    end)

    for {method, params} <- [
          {"memory.add", %{"profileId" => "default", "text" => "x"}},
          {"memory.delete", %{"profileId" => "default", "id" => "m1", "confirm" => "m1"}}
        ] do
      {response, _state} = request(state, "dedicated-#{method}", method, params)
      assert %{"ok" => false, "error" => %{"code" => "FORBIDDEN"}} = response
    end

    refute_receive {:node_message, {:node_event, "node.invoke.request", _}}, 50
    assert LemonCore.Store.list(:node_invocations) == []
  end

  test "an admin operator cannot use node.invoke and no invocation record is retained",
       %{node_id: node_id} do
    {:ok, state} = Connection.init(peer: {203, 0, 113, 42})
    {_hello, state} = connect(state, ["operator.admin", "operator.write"])

    {response, state} =
      request(state, "admin-invoke", "node.invoke", %{
        "nodeId" => node_id,
        "method" => "work.run",
        "args" => %{}
      })

    assert %{"ok" => false, "error" => %{"code" => "METHOD_NOT_FOUND"}} = response
    refute_receive {:node_message, {:node_event, "node.invoke.request", _}}, 50
    assert LemonCore.Store.list(:node_invocations) == []

    # A late registry result for any invocation is inert for the operator socket.
    assert {:ok, ^state} =
             Connection.handle_info({:lemon_node_result, "late-1", {:ok, %{}}}, state)

    assert LemonCore.Store.list(:node_invocations) == []
  end

  test "spelling variants and node-only invocation methods give operators no route",
       %{node_id: node_id} do
    {:ok, state} = Connection.init(peer: {203, 0, 113, 43})
    {_hello, state} = connect(state, ["operator.admin", "operator.write"])
    params = %{"nodeId" => node_id, "method" => "memory.add", "args" => %{}}

    state =
      Enum.reduce(["node.invoke ", "Node.Invoke", "node_invoke"], state, fn
        method, state ->
          {response, state} = request(state, "variant", method, params)
          assert %{"ok" => false, "error" => %{"code" => "METHOD_NOT_FOUND"}} = response
          state
      end)

    for method <- [
          "node.invoke.result",
          "node.invoke.active",
          "node.invoke.event",
          "node.invoke.control.result"
        ] do
      {response, _state} =
        request(state, "node-only", method, %{
          "invokeId" => "x",
          "seq" => 1,
          "event" => %{},
          "controlId" => "c",
          "runId" => "r",
          "accepted" => true,
          "invokeIds" => []
        })

      assert response["ok"] == false
      assert response["error"]["code"] in ["FORBIDDEN", "UNAUTHORIZED"]
    end

    refute_receive {:node_message, {:node_event, "node.invoke.request", _}}, 50
  end

  defp forward(parent) do
    receive do
      message ->
        send(parent, {:node_message, message})
        forward(parent)
    end
  end

  defp connect(state, scopes) do
    frame =
      Jason.encode!(%{
        "type" => "req",
        "id" => "connect",
        "method" => "connect",
        "params" => %{
          "role" => "operator",
          "scopes" => scopes,
          "auth" => %{"token" => @operator_token}
        }
      })

    assert {:push, {:text, hello}, state} = Connection.handle_in({frame, [opcode: :text]}, state)
    hello = Jason.decode!(hello)
    assert hello["type"] == "hello-ok"
    {hello, state}
  end

  defp request(state, id, method, params) do
    frame =
      Jason.encode!(%{"type" => "req", "id" => id, "method" => method, "params" => params})

    case Connection.handle_in({frame, [opcode: :text]}, state) do
      {:push, {:text, response}, state} ->
        {Jason.decode!(response), state}

      {:ok, state} ->
        assert_receive {:method_result, _token, _result} = message, 5_000
        assert {:push, {:text, response}, state} = Connection.handle_info(message, state)
        {Jason.decode!(response), state}
    end
  end

  defp clear_invocations do
    LemonCore.Store.list(:node_invocations)
    |> Enum.each(fn {key, _value} -> LemonCore.Store.delete(:node_invocations, key) end)
  end
end
