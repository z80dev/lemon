defmodule CodingAgent.ToolRegistryTest do
  # Uses `capture_log/1` in a few tests; run synchronously to avoid
  # cross-test log interference in umbrella `mix test`.
  use ExUnit.Case, async: false

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
      assert "todo" in names
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

  describe "extension_paths option" do
    test "loads extensions from specified paths", %{tmp_dir: tmp_dir} do
      # Create a custom extension path
      custom_ext_dir = Path.join(tmp_dir, "custom_extensions")
      File.mkdir_p!(custom_ext_dir)

      # Create an extension in the custom path
      extension_code = """
      defmodule CustomPathExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "custom-path-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "custom_path_tool",
              description: "A tool from custom path",
              parameters: %{},
              label: "Custom Path Tool",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(custom_ext_dir, "custom_path_extension.ex"), extension_code)

      # Load tools with custom extension_paths
      tools = ToolRegistry.get_tools(tmp_dir, extension_paths: [custom_ext_dir])

      names = Enum.map(tools, & &1.name)
      assert "custom_path_tool" in names

      # Cleanup
      :code.purge(CustomPathExtension)
      :code.delete(CustomPathExtension)
    end

    test "ignores default paths when extension_paths is provided", %{tmp_dir: tmp_dir} do
      # Create extension in default .lemon/extensions path
      default_ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      File.mkdir_p!(default_ext_dir)

      extension_code = """
      defmodule DefaultPathExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "default-path-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "default_path_tool",
              description: "A tool from default path",
              parameters: %{},
              label: "Default Path Tool",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(default_ext_dir, "default_path_extension.ex"), extension_code)

      # Create a different custom path (empty)
      custom_ext_dir = Path.join(tmp_dir, "other_extensions")
      File.mkdir_p!(custom_ext_dir)

      # Load tools with custom extension_paths (not the default .lemon/extensions)
      tools = ToolRegistry.get_tools(tmp_dir, extension_paths: [custom_ext_dir])

      names = Enum.map(tools, & &1.name)
      # Should NOT include tool from default path
      refute "default_path_tool" in names

      # But should include built-in tools
      assert "read" in names

      # Cleanup
      :code.purge(DefaultPathExtension)
      :code.delete(DefaultPathExtension)
    end
  end

  describe "tool conflict detection" do
    import ExUnit.CaptureLog

    test "warns when extension tool shadows builtin tool", %{tmp_dir: tmp_dir} do
      # Create extension dir
      ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      File.mkdir_p!(ext_dir)

      # Create an extension with a tool named "read" (conflicts with builtin)
      extension_code = """
      defmodule ConflictBuiltinExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "conflict-builtin-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "read",
              description: "A conflicting read tool",
              parameters: %{},
              label: "Conflict Read",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(ext_dir, "conflict_builtin_extension.ex"), extension_code)

      log =
        capture_log(fn ->
          tools = ToolRegistry.get_tools(tmp_dir)
          # Builtin tool should win - verify only one "read" tool
          read_tools = Enum.filter(tools, fn t -> t.name == "read" end)
          assert length(read_tools) == 1
          # The description should be from builtin, not the extension
          refute hd(read_tools).description == "A conflicting read tool"
        end)

      assert log =~ "Tool name conflict"
      assert log =~ "read"
      assert log =~ "ConflictBuiltinExtension"
      assert log =~ "shadowed by built-in tool"

      # Cleanup
      :code.purge(ConflictBuiltinExtension)
      :code.delete(ConflictBuiltinExtension)
    end

    test "warns when extension tool shadows another extension tool", %{tmp_dir: tmp_dir} do
      # Create extension dir
      ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      File.mkdir_p!(ext_dir)

      # Create two extensions with the same tool name
      # Extensions are loaded alphabetically, so "a_extension" loads before "b_extension"
      extension_a_code = """
      defmodule AConflictExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "a-conflict-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "custom_tool",
              description: "Tool from A extension",
              parameters: %{},
              label: "Custom A",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      extension_b_code = """
      defmodule BConflictExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "b-conflict-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "custom_tool",
              description: "Tool from B extension",
              parameters: %{},
              label: "Custom B",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(ext_dir, "a_conflict_extension.ex"), extension_a_code)
      File.write!(Path.join(ext_dir, "b_conflict_extension.ex"), extension_b_code)

      log =
        capture_log(fn ->
          tools = ToolRegistry.get_tools(tmp_dir)
          # First extension should win - verify only one "custom_tool"
          custom_tools = Enum.filter(tools, fn t -> t.name == "custom_tool" end)
          assert length(custom_tools) == 1
          # The description should be from A extension (loaded first)
          assert hd(custom_tools).description == "Tool from A extension"
        end)

      assert log =~ "Tool name conflict"
      assert log =~ "custom_tool"
      assert log =~ "BConflictExtension"
      assert log =~ "shadowed by earlier extension"

      # Cleanup
      :code.purge(AConflictExtension)
      :code.delete(AConflictExtension)
      :code.purge(BConflictExtension)
      :code.delete(BConflictExtension)
    end

    test "no warning when tools have unique names", %{tmp_dir: tmp_dir} do
      # Create extension dir
      ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      File.mkdir_p!(ext_dir)

      # Create an extension with a unique tool name
      extension_code = """
      defmodule UniqueToolExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "unique-tool-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "my_unique_tool",
              description: "A unique tool",
              parameters: %{},
              label: "Unique Tool",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(ext_dir, "unique_tool_extension.ex"), extension_code)

      log =
        capture_log(fn ->
          tools = ToolRegistry.get_tools(tmp_dir)
          # Should have the unique tool
          names = Enum.map(tools, & &1.name)
          assert "my_unique_tool" in names
        end)

      refute log =~ "Tool name conflict"

      # Cleanup
      :code.purge(UniqueToolExtension)
      :code.delete(UniqueToolExtension)
    end
  end

  describe "tool_conflict_report/2" do
    test "returns empty conflicts for no extensions", %{tmp_dir: tmp_dir} do
      report = ToolRegistry.tool_conflict_report(tmp_dir, include_extensions: false)

      assert report.conflicts == []
      assert report.shadowed_count == 0
      assert report.builtin_count == length(ToolRegistry.builtin_tool_names())
      assert report.extension_count == 0
      assert report.total_tools == report.builtin_count
    end

    test "detects builtin shadowing conflicts", %{tmp_dir: tmp_dir} do
      ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      File.mkdir_p!(ext_dir)

      extension_code = """
      defmodule ConflictReportBuiltinExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "conflict-report-builtin"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "read",
              description: "Conflicting read",
              parameters: %{},
              label: "Read",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(ext_dir, "conflict_report_builtin_ext.ex"), extension_code)

      report = ToolRegistry.tool_conflict_report(tmp_dir)

      assert length(report.conflicts) == 1
      conflict = hd(report.conflicts)
      assert conflict.tool_name == "read"
      assert conflict.winner == :builtin
      assert length(conflict.shadowed) == 1
      assert {:extension, ConflictReportBuiltinExt} in conflict.shadowed
      assert report.shadowed_count == 1

      # Cleanup
      :code.purge(ConflictReportBuiltinExt)
      :code.delete(ConflictReportBuiltinExt)
    end

    test "detects extension-to-extension conflicts", %{tmp_dir: tmp_dir} do
      ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      File.mkdir_p!(ext_dir)

      extension_a_code = """
      defmodule ConflictReportExtA do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "conflict-report-a"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "shared_tool",
              description: "From A",
              parameters: %{},
              label: "Shared A",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      extension_b_code = """
      defmodule ConflictReportExtB do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "conflict-report-b"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "shared_tool",
              description: "From B",
              parameters: %{},
              label: "Shared B",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(ext_dir, "conflict_report_ext_a.ex"), extension_a_code)
      File.write!(Path.join(ext_dir, "conflict_report_ext_b.ex"), extension_b_code)

      report = ToolRegistry.tool_conflict_report(tmp_dir)

      assert length(report.conflicts) == 1
      conflict = hd(report.conflicts)
      assert conflict.tool_name == "shared_tool"
      # Winner should be extension (first one loaded)
      assert {:extension, _winner_module} = conflict.winner
      assert length(conflict.shadowed) == 1
      assert report.shadowed_count == 1

      # Cleanup
      :code.purge(ConflictReportExtA)
      :code.delete(ConflictReportExtA)
      :code.purge(ConflictReportExtB)
      :code.delete(ConflictReportExtB)
    end

    test "returns correct counts", %{tmp_dir: tmp_dir} do
      ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      File.mkdir_p!(ext_dir)

      extension_code = """
      defmodule ConflictReportCountExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "count-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "unique_count_tool",
              description: "Unique tool",
              parameters: %{},
              label: "Unique",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(ext_dir, "conflict_report_count_ext.ex"), extension_code)

      report = ToolRegistry.tool_conflict_report(tmp_dir)

      assert report.conflicts == []
      assert report.builtin_count == length(ToolRegistry.builtin_tool_names())
      assert report.extension_count == 1
      assert report.total_tools == report.builtin_count + report.extension_count
      assert report.shadowed_count == 0

      # Cleanup
      :code.purge(ConflictReportCountExt)
      :code.delete(ConflictReportCountExt)
    end

    test "captures extension load errors", %{tmp_dir: tmp_dir} do
      ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      File.mkdir_p!(ext_dir)

      # Create a valid extension
      valid_code = """
      defmodule ValidExtForErrorTest do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "valid-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd), do: []
      end
      """

      # Create a broken extension (syntax error)
      broken_code = """
      defmodule BrokenExtForErrorTest do
        @behaviour CodingAgent.Extensions.Extension

        # Missing closing bracket will cause syntax error
        def name, do: "broken-ext"
        def version, do: "1.0.0"
        def tools(_cwd) do
          [
      end
      """

      File.write!(Path.join(ext_dir, "valid_ext.ex"), valid_code)
      File.write!(Path.join(ext_dir, "broken_ext.ex"), broken_code)

      report = ToolRegistry.tool_conflict_report(tmp_dir)

      # Should have load errors from broken extension
      assert length(report.load_errors) >= 1

      broken_error =
        Enum.find(report.load_errors, fn err ->
          String.contains?(err.source_path, "broken_ext.ex")
        end)

      assert broken_error != nil
      assert is_binary(broken_error.error_message)
      assert broken_error.error != nil

      # Cleanup
      :code.purge(ValidExtForErrorTest)
      :code.delete(ValidExtForErrorTest)
    end

    test "returns empty load_errors when all extensions load successfully", %{tmp_dir: tmp_dir} do
      report = ToolRegistry.tool_conflict_report(tmp_dir, include_extensions: false)

      assert report.load_errors == []
    end
  end
end
