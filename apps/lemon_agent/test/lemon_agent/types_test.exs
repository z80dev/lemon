defmodule LemonAgent.TypesTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.{AgentTool, ToolSchemaSnapshot}

  describe "ToolSchemaSnapshot" do
    test "captures tool names and stable fingerprint inputs" do
      tools = [
        %AgentTool{name: "read", description: "Read", parameters: %{"type" => "object"}},
        %AgentTool{name: "write", description: "Write", parameters: %{"type" => "object"}}
      ]

      snapshot = ToolSchemaSnapshot.new(tools)

      assert snapshot.tools == tools
      assert snapshot.tool_names == ["read", "write"]
      assert ToolSchemaSnapshot.new(tools).fingerprint == snapshot.fingerprint
      changed_tools = [%{hd(tools) | parameters: %{"type" => "string"}} | tl(tools)]
      refute ToolSchemaSnapshot.new(changed_tools).fingerprint == snapshot.fingerprint
    end
  end
end
