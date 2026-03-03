defmodule LemonMCP.WasmServerTest do
  use ExUnit.Case, async: false

  alias LemonMCP.WasmServer

  @moduletag :wasm

  setup do
    # Use test WASM tools directory
    wasm_paths = [Path.join([__DIR__, "..", "..", "..", "native", "wasm-tools"])]

    opts = [
      wasm_paths: wasm_paths,
      server_name: "Test WASM Server",
      default_memory_limit: 5 * 1024 * 1024,
      default_timeout_ms: 30_000
    ]

    {:ok, pid} = WasmServer.start_link(opts)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    {:ok, %{server: pid}}
  end

  describe "initialization" do
    test "starts with correct server info", %{server: server} do
      result = WasmServer.get_initialize_result(server)

      assert result.serverInfo.name == "Test WASM Server"
      assert result.serverInfo.version == "0.1.0"
      assert result.protocolVersion == "2024-11-05"
      assert result.capabilities.tools == true
    end

    test "starts uninitialized", %{server: server} do
      assert WasmServer.initialized?(server) == false
    end

    test "can be marked as initialized", %{server: server} do
      assert :ok = WasmServer.mark_initialized(server)
      assert WasmServer.initialized?(server) == true
    end
  end

  describe "tool discovery" do
    test "lists available WASM tools", %{server: server} do
      tools = WasmServer.list_tools(server)

      assert is_list(tools)
      # Should discover tools from native/wasm-tools
      assert length(tools) > 0

      # Each tool should have required fields
      for tool <- tools do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.inputSchema)
        assert tool.inputSchema["type"] == "object"
      end
    end

    test "tools have valid schemas", %{server: server} do
      tools = WasmServer.list_tools(server)

      for tool <- tools do
        schema = tool.inputSchema
        assert is_map(schema.get("properties")) || is_map(schema["properties"])
      end
    end
  end

  describe "tool invocation" do
    test "returns error for unknown tool", %{server: server} do
      result = WasmServer.call_tool(server, "nonexistent_tool", %{"arg" => "value"})
      assert result == {:error, :tool_not_found}
    end

    test "invokes WASM tool with valid arguments", %{server: server} do
      # Get available tools
      tools = WasmServer.list_tools(server)

      if length(tools) > 0 do
        tool = hd(tools)

        # Call with empty args (most tools accept this)
        result = WasmServer.call_tool(server, tool.name, %{})

        # Should return ok (may succeed or fail based on tool requirements)
        assert {:ok, tool_result} = result
        assert is_list(tool_result.content)
        assert is_boolean(tool_result.isError)
      end
    end

    test "returns structured error on tool failure", %{server: server} do
      tools = WasmServer.list_tools(server)

      if length(tools) > 0 do
        tool = hd(tools)

        # Call with potentially invalid arguments
        result = WasmServer.call_tool(server, tool.name, %{"invalid_param" => true})

        assert {:ok, tool_result} = result
        assert is_list(tool_result.content)
        # Tool may or may not error depending on validation
      end
    end
  end

  describe "capabilities" do
    test "returns server capabilities", %{server: server} do
      caps = WasmServer.get_capabilities(server)
      assert caps.tools == true
    end
  end

  describe "refresh" do
    test "can refresh tool discovery", %{server: server} do
      assert :ok = WasmServer.refresh_tools(server)

      # Should still have tools after refresh
      tools = WasmServer.list_tools(server)
      assert is_list(tools)
    end
  end

  describe "statistics" do
    test "returns server statistics", %{server: server} do
      stats = WasmServer.stats(server)

      assert is_map(stats)
      assert is_integer(stats.tools_discovered)
      assert is_integer(stats.tools_invoked)
      assert is_integer(stats.errors)
      assert is_integer(stats.total_execution_time_ms)
      assert is_integer(stats.tools_available)
      assert is_integer(stats.avg_execution_time_ms)
      assert is_boolean(stats.sidecar_alive)

      assert stats.tools_available >= 0
      assert stats.sidecar_alive == true
    end

    test "tracks tool invocations", %{server: server} do
      # Get initial stats
      initial_stats = WasmServer.stats(server)
      initial_count = initial_stats.tools_invoked

      # Invoke a tool
      tools = WasmServer.list_tools(server)

      if length(tools) > 0 do
        tool = hd(tools)
        WasmServer.call_tool(server, tool.name, %{})

        # Check updated stats
        new_stats = WasmServer.stats(server)
        assert new_stats.tools_invoked == initial_count + 1
      end
    end
  end

  describe "telemetry" do
    test "emits telemetry events on tool calls", %{server: server} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:lemon_mcp, :wasm, :tool_call]])

      tools = WasmServer.list_tools(server)

      if length(tools) > 0 do
        tool = hd(tools)
        WasmServer.call_tool(server, tool.name, %{})

        assert_receive {
          [:lemon_mcp, :wasm, :tool_call],
          ^ref,
          %{duration_ms: duration, success: success},
          %{tool_name: tool_name}
        }

        assert is_integer(duration)
        assert is_boolean(success)
        assert tool_name == tool.name
      end
    end
  end

  describe "edge cases" do
    test "handles empty arguments", %{server: server} do
      tools = WasmServer.list_tools(server)

      if length(tools) > 0 do
        tool = hd(tools)
        result = WasmServer.call_tool(server, tool.name, %{})

        assert {:ok, _} = result
      end
    end

    test "handles nil arguments gracefully", %{server: server} do
      tools = WasmServer.list_tools(server)

      if length(tools) > 0 do
        tool = hd(tools)
        result = WasmServer.call_tool(server, tool.name, nil)

        # Should handle nil as empty map
        assert {:ok, _} = result
      end
    end

    test "maintains state across calls", %{server: server} do
      # Multiple calls should work consistently
      tools = WasmServer.list_tools(server)

      if length(tools) > 0 do
        tool = hd(tools)

        result1 = WasmServer.call_tool(server, tool.name, %{})
        result2 = WasmServer.call_tool(server, tool.name, %{})

        assert {:ok, _} = result1
        assert {:ok, _} = result2
      end
    end
  end
end
