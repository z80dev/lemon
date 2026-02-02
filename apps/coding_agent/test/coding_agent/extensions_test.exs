defmodule CodingAgent.ExtensionsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Extensions

  @moduletag :tmp_dir

  describe "load_extensions/1" do
    test "returns ok with empty list for non-existent paths" do
      result = Extensions.load_extensions(["/nonexistent/path"])
      assert result == {:ok, []}
    end

    test "returns ok with empty list for empty directory", %{tmp_dir: tmp_dir} do
      result = Extensions.load_extensions([tmp_dir])
      assert result == {:ok, []}
    end

    test "loads extension modules from directory", %{tmp_dir: tmp_dir} do
      # Create a simple extension file
      extension_code = """
      defmodule TestExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "test-extension"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd), do: []

        @impl true
        def hooks, do: []
      end
      """

      File.write!(Path.join(tmp_dir, "test_extension.ex"), extension_code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      assert TestExtension in extensions

      # Cleanup
      :code.purge(TestExtension)
      :code.delete(TestExtension)
    end
  end

  describe "get_tools/2" do
    test "returns empty list for no extensions" do
      result = Extensions.get_tools([], "/tmp")
      assert result == []
    end

    test "collects tools from extensions", %{tmp_dir: tmp_dir} do
      # Create an extension with tools
      extension_code = """
      defmodule ToolExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "tool-extension"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "test_tool",
              description: "A test tool",
              parameters: %{},
              label: "Test Tool",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "tool_extension.ex"), extension_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      tools = Extensions.get_tools(extensions, tmp_dir)
      assert length(tools) == 1
      assert hd(tools).name == "test_tool"

      # Cleanup
      :code.purge(ToolExtension)
      :code.delete(ToolExtension)
    end
  end

  describe "get_hooks/1" do
    test "returns empty keyword list for no extensions" do
      result = Extensions.get_hooks([])
      assert result == []
    end

    test "collects and groups hooks from extensions", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule HookExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "hook-extension"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def hooks do
          [
            on_message_start: fn _msg -> :ok end,
            on_agent_end: fn _msgs -> :ok end
          ]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "hook_extension.ex"), extension_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      hooks = Extensions.get_hooks(extensions)
      assert Keyword.has_key?(hooks, :on_message_start)
      assert Keyword.has_key?(hooks, :on_agent_end)
      assert is_list(hooks[:on_message_start])

      # Cleanup
      :code.purge(HookExtension)
      :code.delete(HookExtension)
    end
  end

  describe "execute_hooks/3" do
    test "executes all hooks for an event" do
      # Track hook calls with agent
      {:ok, agent} = Agent.start_link(fn -> [] end)

      hooks = [
        on_test: [
          fn arg -> Agent.update(agent, &[{:hook1, arg} | &1]) end,
          fn arg -> Agent.update(agent, &[{:hook2, arg} | &1]) end
        ]
      ]

      Extensions.execute_hooks(hooks, :on_test, ["test_arg"])

      calls = Agent.get(agent, & &1)
      assert {:hook1, "test_arg"} in calls
      assert {:hook2, "test_arg"} in calls

      Agent.stop(agent)
    end

    test "handles missing events gracefully" do
      # Should not raise
      assert :ok = Extensions.execute_hooks([], :nonexistent, [])
    end

    test "handles hook errors gracefully" do
      hooks = [
        on_error: [
          fn _ -> raise "Hook error!" end
        ]
      ]

      # Should not raise, just log
      assert :ok = Extensions.execute_hooks(hooks, :on_error, ["arg"])
    end
  end

  describe "get_info/1" do
    test "returns info for loaded extensions", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule InfoExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "info-extension"

        @impl true
        def version, do: "2.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "info_extension.ex"), extension_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      info = Extensions.get_info(extensions)
      assert length(info) == 1

      ext_info = hd(info)
      assert ext_info.name == "info-extension"
      assert ext_info.version == "2.0.0"
      assert ext_info.module == InfoExtension

      # Cleanup
      :code.purge(InfoExtension)
      :code.delete(InfoExtension)
    end

    test "includes source_path for loaded extensions", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule SourcePathExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "source-path-ext"

        @impl true
        def version, do: "1.0.0"
      end
      """

      ext_path = Path.join(tmp_dir, "source_path_extension.ex")
      File.write!(ext_path, extension_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      info = Extensions.get_info(extensions)
      ext_info = hd(info)

      assert ext_info.source_path == ext_path

      # Cleanup
      :code.purge(SourcePathExtension)
      :code.delete(SourcePathExtension)
    end

    test "includes capabilities and config_schema for extensions", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule RichMetadataExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "rich-metadata-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def capabilities, do: [:tools, :hooks]

        @impl true
        def config_schema do
          %{
            "type" => "object",
            "properties" => %{
              "api_key" => %{"type" => "string", "description" => "API key", "secret" => true},
              "timeout" => %{"type" => "integer", "default" => 5000}
            },
            "required" => ["api_key"]
          }
        end
      end
      """

      File.write!(Path.join(tmp_dir, "rich_metadata_extension.ex"), extension_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      info = Extensions.get_info(extensions)
      ext_info = hd(info)

      assert ext_info.name == "rich-metadata-ext"
      assert ext_info.capabilities == [:tools, :hooks]
      assert ext_info.config_schema["type"] == "object"
      assert ext_info.config_schema["properties"]["api_key"]["secret"] == true
      assert ext_info.config_schema["required"] == ["api_key"]

      # Cleanup
      :code.purge(RichMetadataExtension)
      :code.delete(RichMetadataExtension)
    end

    test "returns empty defaults for extensions without capabilities/config_schema", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule MinimalExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "minimal-ext"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "minimal_extension.ex"), extension_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      info = Extensions.get_info(extensions)
      ext_info = hd(info)

      assert ext_info.capabilities == []
      assert ext_info.config_schema == %{}

      # Cleanup
      :code.purge(MinimalExtension)
      :code.delete(MinimalExtension)
    end
  end

  describe "get_source_path/1" do
    test "returns source path for loaded extension", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule PathTrackExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "path-track-ext"

        @impl true
        def version, do: "1.0.0"
      end
      """

      ext_path = Path.join(tmp_dir, "path_track_extension.ex")
      File.write!(ext_path, extension_code)
      {:ok, _extensions} = Extensions.load_extensions([tmp_dir])

      assert Extensions.get_source_path(PathTrackExtension) == ext_path

      # Cleanup
      :code.purge(PathTrackExtension)
      :code.delete(PathTrackExtension)
    end

    test "returns nil for unknown module" do
      assert Extensions.get_source_path(UnknownModule) == nil
    end
  end

  describe "list_extensions/0" do
    test "returns all loaded extensions", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule ListExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "list-ext"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "list_extension.ex"), extension_code)
      {:ok, _extensions} = Extensions.load_extensions([tmp_dir])

      all = Extensions.list_extensions()
      list_ext = Enum.find(all, fn e -> e.name == "list-ext" end)

      assert list_ext != nil
      assert list_ext.version == "1.0.0"
      assert list_ext.module == ListExtension
      assert list_ext.source_path != nil

      # Cleanup
      :code.purge(ListExtension)
      :code.delete(ListExtension)
    end

    test "does not include non-extension modules from extension files", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule ListMainExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "list-main-ext"

        @impl true
        def version, do: "1.0.0"
      end

      defmodule ListHelperModule do
        def ok, do: :ok
      end
      """

      File.write!(Path.join(tmp_dir, "list_main_extension.ex"), extension_code)
      {:ok, _extensions} = Extensions.load_extensions([tmp_dir])

      all = Extensions.list_extensions()

      assert Enum.any?(all, fn e -> e.module == ListMainExtension end)
      refute Enum.any?(all, fn e -> e.module == ListHelperModule end)

      # Cleanup
      :code.purge(ListMainExtension)
      :code.delete(ListMainExtension)
      :code.purge(ListHelperModule)
      :code.delete(ListHelperModule)
    end
  end

  describe "find_duplicate_tools/2" do
    test "returns empty map for no duplicates", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule NoDuplicatesExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "no-dups-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "unique_tool_a",
              description: "Unique A",
              parameters: %{},
              label: "Unique A",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "no_duplicates_extension.ex"), extension_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      duplicates = Extensions.find_duplicate_tools(extensions, tmp_dir)
      assert duplicates == %{}

      # Cleanup
      :code.purge(NoDuplicatesExtension)
      :code.delete(NoDuplicatesExtension)
    end

    test "detects duplicate tool names across extensions", %{tmp_dir: tmp_dir} do
      ext_a_code = """
      defmodule DupToolExtA do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "dup-tool-a"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "dup_tool",
              description: "From A",
              parameters: %{},
              label: "Dup A",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      ext_b_code = """
      defmodule DupToolExtB do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "dup-tool-b"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "dup_tool",
              description: "From B",
              parameters: %{},
              label: "Dup B",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "dup_tool_ext_a.ex"), ext_a_code)
      File.write!(Path.join(tmp_dir, "dup_tool_ext_b.ex"), ext_b_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      duplicates = Extensions.find_duplicate_tools(extensions, tmp_dir)
      assert Map.has_key?(duplicates, "dup_tool")
      assert length(duplicates["dup_tool"]) == 2
      assert DupToolExtA in duplicates["dup_tool"]
      assert DupToolExtB in duplicates["dup_tool"]

      # Cleanup
      :code.purge(DupToolExtA)
      :code.delete(DupToolExtA)
      :code.purge(DupToolExtB)
      :code.delete(DupToolExtB)
    end

    test "returns empty map for no extensions" do
      duplicates = Extensions.find_duplicate_tools([], "/tmp")
      assert duplicates == %{}
    end
  end

  describe "load_extensions_with_errors/1" do
    test "returns ok with empty lists for non-existent paths" do
      {:ok, extensions, errors} = Extensions.load_extensions_with_errors(["/nonexistent/path"])
      assert extensions == []
      assert errors == []
    end

    test "loads extensions and returns empty errors for valid files", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule ValidExtensionWithErrors do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "valid-ext-errors"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "valid_extension.ex"), extension_code)

      {:ok, extensions, errors} = Extensions.load_extensions_with_errors([tmp_dir])
      assert ValidExtensionWithErrors in extensions
      assert errors == []

      # Cleanup
      :code.purge(ValidExtensionWithErrors)
      :code.delete(ValidExtensionWithErrors)
    end

    test "captures compile errors for invalid files", %{tmp_dir: tmp_dir} do
      # Create a file with a syntax error
      invalid_code = """
      defmodule BadExtension do
        def foo do
          # Missing end
      """

      bad_path = Path.join(tmp_dir, "bad_extension.ex")
      File.write!(bad_path, invalid_code)

      {:ok, extensions, errors} = Extensions.load_extensions_with_errors([tmp_dir])
      assert extensions == []
      assert length(errors) == 1

      error = hd(errors)
      assert error.source_path == bad_path
      assert is_binary(error.error_message)

      # The error should mention the issue
      assert error.error_message =~ "error" or error.error_message =~ "end"
    end

    test "returns both valid extensions and errors", %{tmp_dir: tmp_dir} do
      valid_code = """
      defmodule MixedValidExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "mixed-valid"

        @impl true
        def version, do: "1.0.0"
      end
      """

      invalid_code = """
      defmodule MixedBadExtension do
        # Syntax error - unclosed string
        def foo, do: "unclosed
      """

      File.write!(Path.join(tmp_dir, "valid.ex"), valid_code)
      File.write!(Path.join(tmp_dir, "invalid.ex"), invalid_code)

      {:ok, extensions, errors} = Extensions.load_extensions_with_errors([tmp_dir])
      assert MixedValidExtension in extensions
      assert length(errors) == 1

      # Cleanup
      :code.purge(MixedValidExtension)
      :code.delete(MixedValidExtension)
    end
  end

  describe "build_status_report/3" do
    test "builds a complete status report", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule StatusReportExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "status-report-ext"

        @impl true
        def version, do: "2.0.0"

        @impl true
        def capabilities, do: [:tools]
      end
      """

      File.write!(Path.join(tmp_dir, "status_report_extension.ex"), extension_code)
      {:ok, extensions, errors} = Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.build_status_report(extensions, errors, cwd: tmp_dir)

      assert is_map(report)
      assert report.total_loaded == 1
      assert report.total_errors == 0
      assert is_integer(report.loaded_at)
      assert is_list(report.extensions)
      assert is_list(report.load_errors)

      # Check extension metadata
      ext_info = hd(report.extensions)
      assert ext_info.name == "status-report-ext"
      assert ext_info.version == "2.0.0"
      assert ext_info.capabilities == [:tools]

      # Cleanup
      :code.purge(StatusReportExtension)
      :code.delete(StatusReportExtension)
    end

    test "includes load errors in report", %{tmp_dir: tmp_dir} do
      # Create an invalid extension
      bad_code = """
      defmodule ReportBadExtension do
        def missing_end
      """

      File.write!(Path.join(tmp_dir, "bad.ex"), bad_code)
      {:ok, extensions, errors} = Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.build_status_report(extensions, errors, cwd: tmp_dir)

      assert report.total_loaded == 0
      assert report.total_errors == 1
      assert length(report.load_errors) == 1

      error = hd(report.load_errors)
      assert String.ends_with?(error.source_path, "bad.ex")
      assert is_binary(error.error_message)
    end

    test "includes tool conflicts when cwd provided", %{tmp_dir: tmp_dir} do
      report = Extensions.build_status_report([], [], cwd: tmp_dir)

      assert is_map(report.tool_conflicts)
      assert Map.has_key?(report.tool_conflicts, :conflicts)
      assert Map.has_key?(report.tool_conflicts, :total_tools)
    end

    test "tool_conflicts is nil when no cwd provided" do
      report = Extensions.build_status_report([], [], [])

      assert report.tool_conflicts == nil
    end

    test "accepts precomputed tool_conflict_report" do
      fake_conflict_report = %{
        conflicts: [],
        total_tools: 5,
        builtin_count: 5,
        extension_count: 0,
        shadowed_count: 0
      }

      report = Extensions.build_status_report([], [], tool_conflict_report: fake_conflict_report)

      assert report.tool_conflicts == fake_conflict_report
    end
  end
end
