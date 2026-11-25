defmodule LemonControlPlane.Methods.NodeMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.NodeInvokeResult

  describe "NodeInvokeResult.handle/2" do
    test "returns forbidden when role is not node" do
      params = %{"invokeId" => "invoke-1", "result" => "success"}

      ctx = %{
        auth: %{role: :operator, scopes: [:read, :write], client_id: "op-1"},
        conn_id: "conn-1",
        conn_pid: self()
      }

      assert {:error, {:forbidden, _message}} = NodeInvokeResult.handle(params, ctx)
    end

    test "returns error when invokeId is missing" do
      ctx = %{auth: %{role: :node, client_id: "node-1"}, conn_pid: self()}
      params = %{"result" => "success"}

      assert {:error, {:invalid_request, _message}} = NodeInvokeResult.handle(params, ctx)
    end

    test "returns not_found when invocation doesn't exist" do
      ctx = %{auth: %{role: :node, client_id: "node-1"}, conn_pid: self()}
      params = %{"invokeId" => "nonexistent-#{System.unique_integer()}", "result" => "success"}

      assert {:error, {:not_found, _message}} = NodeInvokeResult.handle(params, ctx)
    end

    test "a legacy durable invocation row is neither settled nor rewritten" do
      invoke_id = "invoke-#{System.unique_integer([:positive])}"
      legacy = %{node_id: "node-1", method: "test", status: :pending}
      :ok = LemonCore.Store.put(:node_invocations, invoke_id, legacy)
      on_exit(fn -> LemonCore.Store.delete(:node_invocations, invoke_id) end)

      ctx = %{auth: %{role: :node, client_id: "node-1"}, conn_pid: self()}
      params = %{"invokeId" => invoke_id, "result" => %{"data" => "test"}}

      assert {:error, {:not_found, _message}} = NodeInvokeResult.handle(params, ctx)
      assert LemonCore.Store.get(:node_invocations, invoke_id) == legacy
    end

    test "delivers a live result to the recipient without persisting it" do
      node_id = "node-result-#{System.unique_integer([:positive])}"
      :ok = LemonAgent.NodeRegistry.register(node_id, node_id, self())
      on_exit(fn -> LemonAgent.NodeRegistry.unregister(node_id, self()) end)
      ctx = %{auth: %{role: :node, client_id: node_id}, conn_pid: self()}

      for {params, expected} <- [
            {%{"result" => %{"data" => "test"}}, {:ok, %{"data" => "test"}}},
            {%{"error" => "Something went wrong"}, {:error, {:remote, "Something went wrong"}}}
          ] do
        assert {:ok, invoke_id} =
                 LemonAgent.NodeRegistry.invoke_node(node_id, "test", %{}, recipient: self())

        assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

        assert {:ok, result} =
                 NodeInvokeResult.handle(Map.put(params, "invokeId", invoke_id), ctx)

        assert result["invokeId"] == invoke_id
        assert result["received"] == true
        assert result["summary"]["nodeId"] == node_id
        assert result["summary"]["ok"] == match?({:ok, _}, expected)
        assert result["summary"]["hasError"] == Map.has_key?(params, "error")
        assert result["summary"]["cleanup"]["includesResult"] == false
        assert result["summary"]["cleanup"]["includesError"] == false
        assert result["summary"]["cleanup"]["includesArgs"] == false
        assert_receive {:lemon_node_result, ^invoke_id, ^expected}
        assert LemonCore.Store.get(:node_invocations, invoke_id) == nil

        assert {:error, {:not_found, _}} =
                 NodeInvokeResult.handle(Map.put(params, "invokeId", invoke_id), ctx)
      end
    end
  end
end
