defmodule LemonControlPlane.Methods.NodeMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.NodeEvent
  alias LemonControlPlane.Methods.NodeInvokeResult

  describe "NodeEvent.handle/2" do
    test "returns forbidden when role is not node (auth in ctx.auth)" do
      params = %{"eventType" => "status", "payload" => %{}}

      # Simulate ctx from WS.Connection dispatcher - auth is passed as a struct under :auth key
      ctx = %{
        auth: %{role: :operator, scopes: [:read, :write], client_id: "op-1"},
        conn_id: "conn-1",
        conn_pid: self()
      }

      {:error, error} = NodeEvent.handle(params, ctx)
      # Error can be struct or tuple
      error_str = inspect(error)
      assert String.contains?(String.downcase(error_str), "forbidden") or
               (is_map(error) and error[:code] == "FORBIDDEN")
    end

    test "accepts event when role is node (auth as map under :auth key)" do
      params = %{"eventType" => "status", "payload" => %{"online" => true}}

      ctx = %{
        auth: %{role: :node, scopes: [], client_id: "node-1"},
        conn_id: "conn-1",
        conn_pid: self()
      }

      {:ok, result} = NodeEvent.handle(params, ctx)
      assert result["eventType"] == "status"
      assert result["broadcast"] == true
    end

    test "accepts event when auth has struct-like access" do
      # Simulate struct with field access
      auth = %{role: :node, scopes: [], client_id: "node-1"}

      ctx = %{
        auth: auth,
        conn_id: "conn-1",
        conn_pid: self()
      }

      params = %{"eventType" => "heartbeat"}

      {:ok, result} = NodeEvent.handle(params, ctx)
      assert result["eventType"] == "heartbeat"
    end

    test "returns error when eventType is missing" do
      ctx = %{auth: %{role: :node, client_id: "node-1"}}
      params = %{}

      {:error, error} = NodeEvent.handle(params, ctx)
      error_str = inspect(error)
      assert String.contains?(error_str, "eventType") or
               (is_map(error) and error[:code] == "INVALID_REQUEST")
    end

    test "returns error when eventType is empty string" do
      ctx = %{auth: %{role: :node, client_id: "node-1"}}
      params = %{"eventType" => ""}

      {:error, error} = NodeEvent.handle(params, ctx)
      error_str = inspect(error)
      assert String.contains?(error_str, "eventType") or
               (is_map(error) and error[:code] == "INVALID_REQUEST")
    end
  end

  describe "NodeInvokeResult.handle/2" do
    test "returns forbidden when role is not node" do
      params = %{"invokeId" => "invoke-1", "result" => "success"}

      ctx = %{
        auth: %{role: :operator, scopes: [:read, :write], client_id: "op-1"},
        conn_id: "conn-1",
        conn_pid: self()
      }

      {:error, error} = NodeInvokeResult.handle(params, ctx)
      error_str = inspect(error)
      assert String.contains?(String.downcase(error_str), "forbidden") or
               (is_map(error) and error[:code] == "FORBIDDEN")
    end

    test "returns error when invokeId is missing" do
      ctx = %{auth: %{role: :node, client_id: "node-1"}}
      params = %{"result" => "success"}

      {:error, error} = NodeInvokeResult.handle(params, ctx)
      error_str = inspect(error)
      assert String.contains?(error_str, "invokeId") or
               (is_map(error) and error[:code] == "INVALID_REQUEST")
    end

    test "returns not_found when invocation doesn't exist" do
      ctx = %{auth: %{role: :node, client_id: "node-1"}}
      params = %{"invokeId" => "nonexistent-#{System.unique_integer()}", "result" => "success"}

      {:error, error} = NodeInvokeResult.handle(params, ctx)
      error_str = String.downcase(inspect(error))
      assert String.contains?(error_str, "not found") or
               (is_map(error) and error[:code] == "NOT_FOUND")
    end

    test "processes result when invocation exists" do
      invoke_id = "invoke-#{System.unique_integer()}"

      # Store a mock invocation
      invocation = %{
        node_id: "node-1",
        method: "test",
        status: :pending,
        created_at_ms: System.system_time(:millisecond)
      }

      LemonCore.Store.put(:node_invocations, invoke_id, invocation)

      ctx = %{auth: %{role: :node, client_id: "node-1"}}
      params = %{"invokeId" => invoke_id, "result" => %{"data" => "test"}}

      {:ok, result} = NodeInvokeResult.handle(params, ctx)
      assert result["invokeId"] == invoke_id
      assert result["received"] == true

      # Verify invocation was updated
      updated = LemonCore.Store.get(:node_invocations, invoke_id)
      assert updated.status == :completed
      assert updated.result == %{"data" => "test"}

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

      ctx = %{auth: %{role: :node, client_id: "node-1"}}
      params = %{"invokeId" => invoke_id, "error" => "Something went wrong"}

      {:ok, result} = NodeInvokeResult.handle(params, ctx)
      assert result["invokeId"] == invoke_id

      # Verify invocation was updated with error
      updated = LemonCore.Store.get(:node_invocations, invoke_id)
      assert updated.status == :error
      assert updated.error == "Something went wrong"

      # Cleanup
      LemonCore.Store.delete(:node_invocations, invoke_id)
    end
  end
end
