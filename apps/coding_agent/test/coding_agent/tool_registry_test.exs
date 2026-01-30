defmodule CodingAgent.ToolRegistryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ToolRegistry

  @moduletag :tmp_dir

  describe "get_tools/2" do
    test "returns built-in tools", %{tmp_dir: tmp_dir} do
      tools = ToolRegistry.get_tools(tmp_dir)

      names = Enum.map(tools, & &1.name)
      assert "read" in names
      assert "write" in names
      assert "edit" in names
      assert "bash" in names
      assert "glob" in names
      assert "grep" in names
    end

    test "all tools have required fields", %{tmp_dir: tmp_dir} do
      tools = ToolRegistry.get_tools(tmp_dir)

      for tool <- tools do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_function(tool.execute, 4)
      end
    end

    test "respects disabled option", %{tmp_dir: tmp_dir} do
      tools = ToolRegistry.get_tools(tmp_dir, disabled: ["bash", "write"])

      names = Enum.map(tools, & &1.name)
      refute "bash" in names
      refute "write" in names
      assert "read" in names
    end

    test "respects enabled_only option", %{tmp_dir: tmp_dir} do
      tools = ToolRegistry.get_tools(tmp_dir, enabled_only: ["read", "write"])

      names = Enum.map(tools, & &1.name)
      assert length(names) == 2
      assert "read" in names
      assert "write" in names
    end

    test "can exclude extension tools", %{tmp_dir: tmp_dir} do
      tools = ToolRegistry.get_tools(tmp_dir, include_extensions: false)

      # Should only have built-in tools
      builtin_names = ToolRegistry.builtin_tool_names() |> Enum.map(&Atom.to_string/1)

      for tool <- tools do
        assert tool.name in builtin_names
      end
    end
  end

  describe "get_tool/3" do
    test "returns tool by name", %{tmp_dir: tmp_dir} do
      assert {:ok, tool} = ToolRegistry.get_tool(tmp_dir, "read")
      assert tool.name == "read"
    end

    test "returns error for unknown tool", %{tmp_dir: tmp_dir} do
      assert {:error, :not_found} = ToolRegistry.get_tool(tmp_dir, "nonexistent")
    end

    test "respects disabled option", %{tmp_dir: tmp_dir} do
      assert {:error, :not_found} =
               ToolRegistry.get_tool(tmp_dir, "bash", disabled: ["bash"])
    end
  end

  describe "has_tool?/2" do
    test "returns true for existing tool", %{tmp_dir: tmp_dir} do
      assert ToolRegistry.has_tool?(tmp_dir, "read")
      assert ToolRegistry.has_tool?(tmp_dir, "bash")
    end

    test "returns false for nonexistent tool", %{tmp_dir: tmp_dir} do
      refute ToolRegistry.has_tool?(tmp_dir, "nonexistent")
    end
  end

  describe "list_tool_names/2" do
    test "returns list of tool names", %{tmp_dir: tmp_dir} do
      names = ToolRegistry.list_tool_names(tmp_dir)

      assert is_list(names)
      assert "read" in names
      assert "write" in names
      assert Enum.all?(names, &is_binary/1)
    end

    test "respects filtering options", %{tmp_dir: tmp_dir} do
      names = ToolRegistry.list_tool_names(tmp_dir, enabled_only: ["read"])
      assert names == ["read"]
    end
  end

  describe "format_tool_descriptions/2" do
    test "returns formatted descriptions", %{tmp_dir: tmp_dir} do
      result = ToolRegistry.format_tool_descriptions(tmp_dir)

      assert is_binary(result)
      assert String.contains?(result, "- read:")
      assert String.contains?(result, "- write:")
    end
  end

  describe "builtin_tool_names/0" do
    test "returns list of atoms" do
      names = ToolRegistry.builtin_tool_names()

      assert is_list(names)
      assert :read in names
      assert :write in names
      assert :edit in names
      assert :bash in names
      assert Enum.all?(names, &is_atom/1)
    end
  end
end
