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

    test "processes result when invocation exists" do
      invoke_id = "invoke-#{System.unique_integer()}"
      :ok = LemonCore.Bus.subscribe("nodes")

      # Store a mock invocation
      invocation = %{
        node_id: "node-1",
        method: "test",
        args: %{"private" => "legacy durable args"},
        status: :pending,
        created_at_ms: System.system_time(:millisecond)
      }

      LemonCore.Store.put(:node_invocations, invoke_id, invocation)

      ctx = %{auth: %{role: :node, client_id: "node-1"}, conn_pid: self()}
      params = %{"invokeId" => invoke_id, "result" => %{"data" => "test"}}

      {:ok, result} = NodeInvokeResult.handle(params, ctx)
      assert result["invokeId"] == invoke_id
      assert result["received"] == true
      assert result["summary"]["invokeId"] == invoke_id
      assert result["summary"]["nodeId"] == "node-1"
      assert result["summary"]["status"] == "completed"
      assert result["summary"]["ok"] == true
      assert result["summary"]["hasResult"] == true
      assert result["summary"]["hasError"] == false
      assert result["summary"]["cleanup"]["includesResult"] == false
      assert result["summary"]["cleanup"]["includesArgs"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

      # Verify invocation was updated
      updated = LemonCore.Store.get(:node_invocations, invoke_id)
      assert updated.status == :completed
      refute Map.has_key?(updated, :args)
      refute Map.has_key?(updated, :result)
      assert updated.result_summary.present == true
      assert updated.result_summary.kind == :object

      assert_receive %LemonCore.Event{type: :node_invoke_completed, payload: event_payload}
      refute Map.has_key?(event_payload, :result)
      refute Map.has_key?(event_payload, :error)
      assert event_payload.result_summary.kind == :object

      # Cleanup
      LemonCore.Store.delete(:node_invocations, invoke_id)
    end

    test "sets error status when error is provided" do
      invoke_id = "invoke-#{System.unique_integer()}"

      invocation = %{
        node_id: "node-1",
        method: "test",
        status: :pending,
        created_at_ms: System.system_time(:millisecond)
      }

      LemonCore.Store.put(:node_invocations, invoke_id, invocation)

      ctx = %{auth: %{role: :node, client_id: "node-1"}, conn_pid: self()}
      params = %{"invokeId" => invoke_id, "error" => "Something went wrong"}

      {:ok, result} = NodeInvokeResult.handle(params, ctx)
      assert result["invokeId"] == invoke_id
      assert result["summary"]["status"] == "error"
      assert result["summary"]["ok"] == false
      assert result["summary"]["hasResult"] == false
      assert result["summary"]["hasError"] == true
      assert result["summary"]["cleanup"]["includesError"] == false

      # Verify invocation was updated with error
      updated = LemonCore.Store.get(:node_invocations, invoke_id)
      assert updated.status == :error
      refute Map.has_key?(updated, :error)
      assert updated.error_summary.present == true
      assert updated.error_summary.kind == :string

      # Cleanup
      LemonCore.Store.delete(:node_invocations, invoke_id)
    end
  end
end
