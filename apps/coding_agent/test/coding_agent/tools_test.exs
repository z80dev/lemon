defmodule CodingAgent.ToolsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools
  alias AgentCore.Types.AgentTool

  @test_cwd "/tmp/test_cwd"

  # ============================================================================
  # coding_tools/2 Tests
  # ============================================================================

  describe "coding_tools/2" do
    test "returns a list of AgentTool structs" do
      tools = Tools.coding_tools(@test_cwd)

      assert is_list(tools)
      assert length(tools) > 0

      Enum.each(tools, fn tool ->
        assert %AgentTool{} = tool
      end)
    end

    test "includes all expected coding tools" do
      tools = Tools.coding_tools(@test_cwd)
      tool_names = Enum.map(tools, & &1.name)

      expected_tools = [
        "browser",
        "read",
        "write",
        "edit",
        "patch",
        "bash",
        "grep",
        "find",
        "ls",
        "webfetch",
        "websearch",
        "todo",
        "task",
        "agent",
        "tool_auth",
        "extensions_status",
        "post_to_x",
        "get_x_mentions"
      ]

      Enum.each(expected_tools, fn expected_name ->
        assert expected_name in tool_names, "Expected tool '#{expected_name}' not found"
      end)
    end

    test "returns exactly 18 tools" do
      tools = Tools.coding_tools(@test_cwd)
      assert length(tools) == 18
    end

    test "passes cwd to each tool" do
      cwd = "/custom/working/directory"
      tools = Tools.coding_tools(cwd)

      # Verify that tools have executable functions
      Enum.each(tools, fn tool ->
        assert is_function(tool.execute, 4)
      end)
    end

    test "passes options to tools" do
      opts = [max_lines: 100, timeout: 5000]
      tools = Tools.coding_tools(@test_cwd, opts)

      # Should not raise any errors
      assert is_list(tools)
      assert length(tools) == 18
    end
  end

  # ============================================================================
  # read_only_tools/2 Tests
  # ============================================================================

  describe "read_only_tools/2" do
    test "returns a list of AgentTool structs" do
      tools = Tools.read_only_tools(@test_cwd)

      assert is_list(tools)
      assert length(tools) > 0

      Enum.each(tools, fn tool ->
        assert %AgentTool{} = tool
      end)
    end

    test "includes only read-only exploration tools" do
      tools = Tools.read_only_tools(@test_cwd)
      tool_names = Enum.map(tools, & &1.name)

      expected_tools = ["read", "grep", "find", "ls"]

      assert Enum.sort(tool_names) == Enum.sort(expected_tools)
    end

    test "returns exactly 4 tools" do
      tools = Tools.read_only_tools(@test_cwd)
      assert length(tools) == 4
    end

    test "does not include write/edit tools" do
      tools = Tools.read_only_tools(@test_cwd)
      tool_names = Enum.map(tools, & &1.name)

      write_tools = ["write", "edit", "patch", "bash", "todo"]

      Enum.each(write_tools, fn write_tool ->
        refute write_tool in tool_names, "Should not include write tool '#{write_tool}'"
      end)
    end
  end

  # ============================================================================
  # all_tools/2 Tests
  # ============================================================================

  describe "all_tools/2" do
    test "returns a map of tools keyed by name" do
      tools_map = Tools.all_tools(@test_cwd)

      assert is_map(tools_map)

      Enum.each(tools_map, fn {name, tool} ->
        assert is_binary(name)
        assert %AgentTool{} = tool
        assert tool.name == name
      end)
    end

    test "includes all available tools" do
      tools_map = Tools.all_tools(@test_cwd)

      expected_tools = [
        "browser",
        "read",
        "write",
        "edit",
        "patch",
        "bash",
        "grep",
        "find",
        "ls",
        "webfetch",
        "websearch",
        "todo",
        "truncate",
        "task",
        "agent",
        "tool_auth",
        "extensions_status",
        "post_to_x",
        "get_x_mentions"
      ]

      Enum.each(expected_tools, fn expected_name ->
        assert Map.has_key?(tools_map, expected_name),
               "Expected tool '#{expected_name}' not found in all_tools"
      end)
    end

    test "returns 19 tools (includes truncate plus X tools)" do
      tools_map = Tools.all_tools(@test_cwd)
      assert map_size(tools_map) == 19
    end

    test "tool names match map keys" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {key, tool} ->
        assert key == tool.name
      end)
    end
  end

  # ============================================================================
  # get_tool/3 Tests
  # ============================================================================

  describe "get_tool/3" do
    test "returns tool by name" do
      tool = Tools.get_tool("read", @test_cwd)

      assert %AgentTool{} = tool
      assert tool.name == "read"
    end

    test "returns nil for unknown tool" do
      tool = Tools.get_tool("nonexistent_tool", @test_cwd)

      assert is_nil(tool)
    end

    test "returns different tools for different names" do
      read_tool = Tools.get_tool("read", @test_cwd)
      write_tool = Tools.get_tool("write", @test_cwd)

      assert read_tool.name == "read"
      assert write_tool.name == "write"
      refute read_tool.name == write_tool.name
    end

    test "passes options to tool" do
      opts = [max_lines: 50]
      tool = Tools.get_tool("read", @test_cwd, opts)

      assert %AgentTool{} = tool
      assert tool.name == "read"
    end

    test "can retrieve all known tools" do
      known_tools = [
        "browser",
        "read",
        "write",
        "edit",
        "patch",
        "bash",
        "grep",
        "find",
        "ls",
        "webfetch",
        "websearch",
        "todo",
        "truncate",
        "task",
        "agent",
        "tool_auth",
        "extensions_status",
        "post_to_x",
        "get_x_mentions"
      ]

      Enum.each(known_tools, fn name ->
        tool = Tools.get_tool(name, @test_cwd)
        assert %AgentTool{} = tool, "Failed to get tool '#{name}'"
        assert tool.name == name
      end)
    end
  end

  # ============================================================================
  # get_tools/3 Tests
  # ============================================================================

  describe "get_tools/3" do
    test "returns list of tools for given names" do
      names = ["read", "write", "edit"]
      tools = Tools.get_tools(names, @test_cwd)

      assert is_list(tools)
      assert length(tools) == 3

      tool_names = Enum.map(tools, & &1.name)
      assert "read" in tool_names
      assert "write" in tool_names
      assert "edit" in tool_names
    end

    test "returns empty list for empty names list" do
      tools = Tools.get_tools([], @test_cwd)

      assert tools == []
    end

    test "filters out unknown tool names" do
      names = ["read", "nonexistent", "write", "also_fake"]
      tools = Tools.get_tools(names, @test_cwd)

      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1.name)
      assert "read" in tool_names
      assert "write" in tool_names
    end

    test "preserves order of tools based on input names" do
      names = ["write", "read", "bash"]
      tools = Tools.get_tools(names, @test_cwd)

      tool_names = Enum.map(tools, & &1.name)
      assert tool_names == ["write", "read", "bash"]
    end

    test "returns all tools when all names are valid" do
      all_names = [
        "browser",
        "read",
        "write",
        "edit",
        "patch",
        "bash",
        "grep",
        "find",
        "ls",
        "webfetch",
        "websearch",
        "todo",
        "truncate",
        "task",
        "agent",
        "tool_auth",
        "extensions_status",
        "post_to_x",
        "get_x_mentions"
      ]

      tools = Tools.get_tools(all_names, @test_cwd)

      assert length(tools) == length(all_names)
    end

    test "handles duplicate names by returning duplicates" do
      names = ["read", "read", "write"]
      tools = Tools.get_tools(names, @test_cwd)

      # Current implementation will return duplicates
      tool_names = Enum.map(tools, & &1.name)
      assert tool_names == ["read", "read", "write"]
    end
  end

  # ============================================================================
  # Tool Definition Validity Tests
  # ============================================================================

  describe "tool definition validity" do
    test "all tools have non-empty names" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {_key, tool} ->
        assert tool.name != ""
        assert is_binary(tool.name)
      end)
    end

    test "all tools have non-empty descriptions" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        assert tool.description != "", "Tool '#{name}' has empty description"
        assert is_binary(tool.description)
      end)
    end

    test "all tools have non-empty labels" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        assert tool.label != "", "Tool '#{name}' has empty label"
        assert is_binary(tool.label)
      end)
    end

    test "all tools have execute functions with arity 4" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        assert is_function(tool.execute, 4), "Tool '#{name}' execute is not a function/4"
      end)
    end
  end

  # ============================================================================
  # Tool Parameter Schema Validity Tests
  # ============================================================================

  describe "tool parameter schema validity" do
    test "all tools have map parameters" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        assert is_map(tool.parameters), "Tool '#{name}' parameters is not a map"
      end)
    end

    test "all tools have type=object in parameters" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        assert tool.parameters["type"] == "object",
               "Tool '#{name}' parameters type is not 'object'"
      end)
    end

    test "all tools have properties in parameters" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        assert is_map(tool.parameters["properties"]),
               "Tool '#{name}' parameters missing properties"
      end)
    end

    test "all tools with required field have it as a list" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        case tool.parameters["required"] do
          nil ->
            :ok

          required ->
            assert is_list(required),
                   "Tool '#{name}' required field is not a list"
        end
      end)
    end

    test "all property definitions have type field" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        properties = tool.parameters["properties"]

        Enum.each(properties, fn {prop_name, prop_def} ->
          # Handle oneOf/anyOf which don't have direct type
          has_type = Map.has_key?(prop_def, "type")
          has_one_of = Map.has_key?(prop_def, "oneOf")
          has_any_of = Map.has_key?(prop_def, "anyOf")

          assert has_type or has_one_of or has_any_of,
                 "Tool '#{name}' property '#{prop_name}' missing type/oneOf/anyOf"
        end)
      end)
    end

    test "all property definitions have description field" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        properties = tool.parameters["properties"]

        Enum.each(properties, fn {prop_name, prop_def} ->
          assert Map.has_key?(prop_def, "description"),
                 "Tool '#{name}' property '#{prop_name}' missing description"
        end)
      end)
    end

    test "required properties exist in properties definition" do
      tools_map = Tools.all_tools(@test_cwd)

      Enum.each(tools_map, fn {name, tool} ->
        required = tool.parameters["required"] || []
        properties = tool.parameters["properties"]

        Enum.each(required, fn req_prop ->
          assert Map.has_key?(properties, req_prop),
                 "Tool '#{name}' required property '#{req_prop}' not in properties"
        end)
      end)
    end
  end

  # ============================================================================
  # Specific Tool Presence Tests
  # ============================================================================

  describe "specific tool definitions" do
    test "read tool has expected parameters" do
      tool = Tools.get_tool("read", @test_cwd)

      assert "path" in (tool.parameters["required"] || [])
      assert Map.has_key?(tool.parameters["properties"], "path")
      assert Map.has_key?(tool.parameters["properties"], "offset")
      assert Map.has_key?(tool.parameters["properties"], "limit")
    end

    test "write tool has expected parameters" do
      tool = Tools.get_tool("write", @test_cwd)

      assert Map.has_key?(tool.parameters["properties"], "path")
      assert Map.has_key?(tool.parameters["properties"], "content")
    end

    test "edit tool has expected parameters" do
      tool = Tools.get_tool("edit", @test_cwd)

      assert Map.has_key?(tool.parameters["properties"], "path")
      assert Map.has_key?(tool.parameters["properties"], "old_text")
      assert Map.has_key?(tool.parameters["properties"], "new_text")
    end

    test "bash tool has expected parameters" do
      tool = Tools.get_tool("bash", @test_cwd)

      assert Map.has_key?(tool.parameters["properties"], "command")
    end

    test "grep tool has expected parameters" do
      tool = Tools.get_tool("grep", @test_cwd)

      assert Map.has_key?(tool.parameters["properties"], "pattern")
    end

    test "find tool has expected parameters" do
      tool = Tools.get_tool("find", @test_cwd)

      properties = tool.parameters["properties"]
      # find tool should have some form of path/pattern parameters
      assert map_size(properties) > 0
    end

    test "ls tool has expected parameters" do
      tool = Tools.get_tool("ls", @test_cwd)

      assert Map.has_key?(tool.parameters["properties"], "path")
    end

    test "webfetch tool has expected parameters" do
      tool = Tools.get_tool("webfetch", @test_cwd)

      assert Map.has_key?(tool.parameters["properties"], "url")
    end

    test "websearch tool has expected parameters" do
      tool = Tools.get_tool("websearch", @test_cwd)

      assert Map.has_key?(tool.parameters["properties"], "query")
    end

    test "task tool has expected parameters" do
      tool = Tools.get_tool("task", @test_cwd)

      properties = tool.parameters["properties"]
      assert map_size(properties) > 0
    end

    test "truncate tool exists and has parameters" do
      tool = Tools.get_tool("truncate", @test_cwd)

      assert %AgentTool{} = tool
      assert tool.name == "truncate"
      assert is_map(tool.parameters)
    end

    test "todo tool has expected structure" do
      tool = Tools.get_tool("todo", @test_cwd)

      assert %AgentTool{} = tool
      assert tool.name == "todo"
      assert Map.has_key?(tool.parameters["properties"], "action")
    end

    test "extensions_status tool has expected structure" do
      tool = Tools.get_tool("extensions_status", @test_cwd)

      assert %AgentTool{} = tool
      assert tool.name == "extensions_status"
    end

    test "patch tool has expected parameters" do
      tool = Tools.get_tool("patch", @test_cwd)

      assert Map.has_key?(tool.parameters["properties"], "patch_text")
    end
  end

  # ============================================================================
  # Consistency Tests
  # ============================================================================

  describe "tool set consistency" do
    test "coding_tools is a subset of all_tools" do
      coding = Tools.coding_tools(@test_cwd)
      all = Tools.all_tools(@test_cwd)

      coding_names = Enum.map(coding, & &1.name) |> MapSet.new()
      all_names = Map.keys(all) |> MapSet.new()

      assert MapSet.subset?(coding_names, all_names)
    end

    test "read_only_tools is a subset of coding_tools" do
      read_only = Tools.read_only_tools(@test_cwd)
      coding = Tools.coding_tools(@test_cwd)

      read_only_names = Enum.map(read_only, & &1.name) |> MapSet.new()
      coding_names = Enum.map(coding, & &1.name) |> MapSet.new()

      assert MapSet.subset?(read_only_names, coding_names)
    end

    test "read_only_tools is a subset of all_tools" do
      read_only = Tools.read_only_tools(@test_cwd)
      all = Tools.all_tools(@test_cwd)

      read_only_names = Enum.map(read_only, & &1.name) |> MapSet.new()
      all_names = Map.keys(all) |> MapSet.new()

      assert MapSet.subset?(read_only_names, all_names)
    end

    test "truncate is in all_tools but not in coding_tools" do
      all = Tools.all_tools(@test_cwd)
      coding = Tools.coding_tools(@test_cwd)

      coding_names = Enum.map(coding, & &1.name)

      assert Map.has_key?(all, "truncate")
      refute "truncate" in coding_names
    end
  end
end
