defmodule LemonMCP.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonMCP.Protocol
  alias LemonMCP.ToolAdapter

  defmodule ErrorTool do
    def tool(_cwd, _opts) do
      %AgentTool{
        name: "error_tool",
        description: "returns an error tuple",
        parameters: [],
        label: "Error Tool",
        execute: fn _id, _params, _signal, _on_update -> {:error, "tool failed"} end
      }
    end
  end

  defmodule CrashTool do
    def tool(_cwd, _opts) do
      %AgentTool{
        name: "crash_tool",
        description: "raises during execution",
        parameters: [],
        label: "Crash Tool",
        execute: fn _id, _params, _signal, _on_update -> raise "boom" end
      }
    end
  end

  defmodule ResultTool do
    def tool(_cwd, _opts) do
      %AgentTool{
        name: "result_tool",
        description: "returns an AgentToolResult",
        parameters: [],
        label: "Result Tool",
        execute: fn _id, _params, _signal, _on_update ->
          %AgentToolResult{
            content: [%{type: "text", text: "hello from tool"}]
          }
        end
      }
    end
  end

  test "marks tool error tuples as MCP tool errors" do
    adapter = %ToolAdapter{
      cwd: "/tmp",
      tool_opts: [],
      tool_modules: %{"error_tool" => ErrorTool}
    }

    assert {:ok, %Protocol.ToolCallResult{} = result} =
             ToolAdapter.call_tool(adapter, "error_tool", %{})

    assert result.isError == true
    assert [%{type: "text", text: "tool failed"}] = result.content
  end

  test "returns an error tuple for tool crashes" do
    adapter = %ToolAdapter{
      cwd: "/tmp",
      tool_opts: [],
      tool_modules: %{"crash_tool" => CrashTool}
    }

    assert {:error, {:tool_crash, "boom"}} = ToolAdapter.call_tool(adapter, "crash_tool", %{})
  end

  test "preserves successful AgentToolResult content" do
    adapter = %ToolAdapter{
      cwd: "/tmp",
      tool_opts: [],
      tool_modules: %{"result_tool" => ResultTool}
    }

    assert {:ok, %Protocol.ToolCallResult{} = result} =
             ToolAdapter.call_tool(adapter, "result_tool", %{})

    assert result.isError == false
    assert [%{type: "text", text: "hello from tool"}] = result.content
  end
end
