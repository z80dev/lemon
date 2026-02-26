defmodule CodingAgent.Wasm.ToolFactoryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Wasm.ToolFactory
  alias AgentCore.Types.AgentTool

  describe "build_inventory/3" do
    test "builds inventory entries from discovered tools" do
      # Use self() as a placeholder pid (execute fn is a closure, not called here)
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "hello_tool",
          description: "Says hello",
          schema_json: ~s({"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}),
          path: "/tools/hello.wasm",
          warnings: [],
          capabilities: %{http: false, tool_invoke: false},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert [{name, agent_tool, source}] = result
      assert name == "hello_tool"
      assert %AgentTool{} = agent_tool
      assert agent_tool.name == "hello_tool"
      assert agent_tool.description == "Says hello"
      assert agent_tool.label == "WASM: hello_tool"
      assert is_function(agent_tool.execute, 4)
      assert agent_tool.parameters == %{
               "type" => "object",
               "properties" => %{"name" => %{"type" => "string"}},
               "required" => ["name"]
             }

      assert {:wasm, metadata} = source
      assert metadata.path == "/tools/hello.wasm"
      assert metadata.source == :wasm
    end

    test "handles multiple discovered tools" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "tool_a",
          description: "Tool A",
          schema_json: "{}",
          path: "/a.wasm",
          warnings: [],
          capabilities: %{},
          auth: nil
        },
        %{
          name: "tool_b",
          description: "Tool B",
          schema_json: "{}",
          path: "/b.wasm",
          warnings: ["some warning"],
          capabilities: %{http: true},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert length(result) == 2
      names = Enum.map(result, fn {name, _, _} -> name end)
      assert "tool_a" in names
      assert "tool_b" in names
    end

    test "returns empty list for empty discovered tools" do
      result = ToolFactory.build_inventory(self(), [])
      assert result == []
    end

    test "handles invalid schema_json by falling back to empty object schema" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "bad_schema_tool",
          description: "Has bad schema",
          schema_json: "not valid json",
          path: "/bad.wasm",
          warnings: [],
          capabilities: %{},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert [{_name, agent_tool, _source}] = result
      assert agent_tool.parameters == %{"type" => "object", "properties" => %{}, "required" => []}
    end

    test "handles nil schema_json" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "nil_schema",
          description: "Nil schema",
          schema_json: nil,
          path: "/nil.wasm",
          warnings: [],
          capabilities: %{},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert [{_name, agent_tool, _source}] = result
      assert agent_tool.parameters == %{"type" => "object", "properties" => %{}, "required" => []}
    end

    test "passes cwd and session_id opts through to metadata" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "ctx_tool",
          description: "Context tool",
          schema_json: "{}",
          path: "/ctx.wasm",
          warnings: ["w1"],
          capabilities: %{http: true, secrets: true},
          auth: %{secret_name: "MY_KEY"}
        }
      ]

      result =
        ToolFactory.build_inventory(sidecar_pid, discovered_tools,
          cwd: "/my/project",
          session_id: "sess_123"
        )

      assert [{_name, _agent_tool, {:wasm, metadata}}] = result
      assert metadata.warnings == ["w1"]
      assert metadata.capabilities == %{http: true, secrets: true}
      assert metadata.auth == %{secret_name: "MY_KEY"}
    end

    test "schema_json with non-object JSON falls back to empty object schema" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "array_schema",
          description: "Array schema",
          schema_json: "[1,2,3]",
          path: "/arr.wasm",
          warnings: [],
          capabilities: %{},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert [{_name, agent_tool, _source}] = result
      assert agent_tool.parameters == %{"type" => "object", "properties" => %{}, "required" => []}
    end
  end
end
