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

    test "returns empty defaults for extensions without capabilities/config_schema", %{
      tmp_dir: tmp_dir
    } do
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
      {:ok, extensions, errors, validation_errors} =
        Extensions.load_extensions_with_errors(["/nonexistent/path"])

      assert extensions == []
      assert errors == []
      assert validation_errors == []
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

      {:ok, extensions, errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert ValidExtensionWithErrors in extensions
      assert errors == []
      assert validation_errors == []

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

      {:ok, extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

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

      {:ok, extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

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

      {:ok, extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

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

      {:ok, extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

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

  describe "clear_extension_cache/0" do
    test "clears loaded extension modules", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule ClearCacheTestExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "clear-cache-test"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "clear_cache_test.ex"), extension_code)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      # Verify extension was loaded
      assert ClearCacheTestExtension in extensions
      assert Extensions.get_source_path(ClearCacheTestExtension) != nil

      # Clear the cache
      :ok = Extensions.clear_extension_cache()

      # Verify extension module was purged
      assert Extensions.get_source_path(ClearCacheTestExtension) == nil

      # Verify the module was deleted from code server
      # After purge+delete, the module should not be loaded
      refute Code.ensure_loaded?(ClearCacheTestExtension)
    end

    test "clears load errors cache", %{tmp_dir: tmp_dir} do
      # Create an invalid extension to generate an error
      invalid_code = """
      defmodule ClearCacheErrorTestBadExt do
        def missing_end
      """

      File.write!(Path.join(tmp_dir, "bad_for_clear_test.ex"), invalid_code)

      {:ok, _extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      # Verify we have errors
      assert length(errors) == 1

      # Verify errors are cached
      {cached_errors, loaded_at} = Extensions.last_load_errors()
      assert length(cached_errors) == 1
      assert is_integer(loaded_at)

      # Clear the cache
      :ok = Extensions.clear_extension_cache()

      # Verify errors cache was cleared
      {cached_errors_after, loaded_at_after} = Extensions.last_load_errors()
      assert cached_errors_after == []
      assert loaded_at_after == nil
    end

    test "is safe to call multiple times" do
      # Should not raise even when called multiple times
      :ok = Extensions.clear_extension_cache()
      :ok = Extensions.clear_extension_cache()
      :ok = Extensions.clear_extension_cache()
    end
  end

  describe "last_load_errors/0" do
    test "returns empty list and nil timestamp when no errors have been stored" do
      # Note: This test assumes the ETS table may or may not exist from other tests
      # We test the behavior when called - it should return {[], nil} or cached errors
      {errors, loaded_at} = Extensions.last_load_errors()
      assert is_list(errors)
      # loaded_at is either nil or an integer timestamp
      assert is_nil(loaded_at) or is_integer(loaded_at)
    end

    test "returns cached errors after load_extensions_with_errors", %{tmp_dir: tmp_dir} do
      # Create an invalid extension file to generate an error
      invalid_code = """
      defmodule LastLoadErrorsTestBadExt do
        def missing_end
      """

      bad_path = Path.join(tmp_dir, "bad_for_cache_test.ex")
      File.write!(bad_path, invalid_code)

      # Load extensions with errors - this should cache the errors
      {:ok, _extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      # Verify errors were returned from load
      assert length(errors) == 1
      assert hd(errors).source_path == bad_path

      # Now verify last_load_errors returns the cached errors
      {cached_errors, loaded_at} = Extensions.last_load_errors()
      assert length(cached_errors) == 1
      assert hd(cached_errors).source_path == bad_path
      assert is_integer(loaded_at)
      # Timestamp should be recent (within last minute)
      assert loaded_at > System.system_time(:millisecond) - 60_000
    end

    test "caches errors from both valid and invalid extensions", %{tmp_dir: tmp_dir} do
      valid_code = """
      defmodule LastLoadErrorsMixedValid do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "cache-mixed-valid"

        @impl true
        def version, do: "1.0.0"
      end
      """

      invalid_code = """
      defmodule LastLoadErrorsMixedBad do
        # Syntax error
        def foo, do: "unclosed
      """

      File.write!(Path.join(tmp_dir, "valid_cache.ex"), valid_code)
      bad_path = Path.join(tmp_dir, "invalid_cache.ex")
      File.write!(bad_path, invalid_code)

      {:ok, extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      # Verify we got one extension and one error
      assert LastLoadErrorsMixedValid in extensions
      assert length(errors) == 1

      # Verify cached errors
      {cached_errors, loaded_at} = Extensions.last_load_errors()
      assert length(cached_errors) == 1
      assert hd(cached_errors).source_path == bad_path
      assert is_integer(loaded_at)

      # Cleanup
      :code.purge(LastLoadErrorsMixedValid)
      :code.delete(LastLoadErrorsMixedValid)
    end

    test "updates cached errors on subsequent loads", %{tmp_dir: tmp_dir} do
      # First load with an error
      invalid_code = """
      defmodule FirstLoadBadExt do
        def missing
      """

      first_bad_path = Path.join(tmp_dir, "first_bad.ex")
      File.write!(first_bad_path, invalid_code)

      {:ok, _, _, _} = Extensions.load_extensions_with_errors([tmp_dir])
      {first_errors, first_timestamp} = Extensions.last_load_errors()
      assert length(first_errors) == 1
      assert hd(first_errors).source_path == first_bad_path

      # Small delay to ensure different timestamp
      Process.sleep(5)

      # Second load with a different error file
      File.rm!(first_bad_path)

      second_invalid = """
      defmodule SecondLoadBadExt do
        def also_missing
      """

      second_bad_path = Path.join(tmp_dir, "second_bad.ex")
      File.write!(second_bad_path, second_invalid)

      {:ok, _, _, _} = Extensions.load_extensions_with_errors([tmp_dir])
      {second_errors, second_timestamp} = Extensions.last_load_errors()

      # Should have new error, not old one
      assert length(second_errors) == 1
      assert hd(second_errors).source_path == second_bad_path
      assert second_timestamp >= first_timestamp
    end
  end

  describe "get_providers/1" do
    test "returns empty list for no extensions" do
      assert Extensions.get_providers([]) == []
    end

    test "collects providers from extensions", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule ProviderExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "provider-extension"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [
            %{
              type: :model,
              name: :test_model_provider,
              module: TestModelProvider,
              config: %{api_key_env: "TEST_API_KEY"}
            }
          ]
        end
      end

      defmodule TestModelProvider do
        # Mock provider module
      end
      """

      File.write!(Path.join(tmp_dir, "provider_extension.ex"), extension_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      providers = Extensions.get_providers(extensions)
      assert length(providers) == 1

      {spec, ext_module} = hd(providers)
      assert spec.type == :model
      assert spec.name == :test_model_provider
      assert spec.module == TestModelProvider
      assert ext_module == ProviderExtension

      # Cleanup
      :code.purge(ProviderExtension)
      :code.delete(ProviderExtension)
      :code.purge(TestModelProvider)
      :code.delete(TestModelProvider)
    end
  end

  describe "register_extension_providers/1" do
    setup do
      # Clear any previous state in the provider registry
      Ai.ProviderRegistry.init()
      on_exit(fn -> Ai.ProviderRegistry.clear() end)
      :ok
    end

    test "returns empty report for no extensions" do
      report = Extensions.register_extension_providers([])

      assert report == %{
               registered: [],
               conflicts: [],
               total_registered: 0,
               total_conflicts: 0
             }
    end

    test "registers model providers from extensions", %{tmp_dir: tmp_dir} do
      extension_code = """
      defmodule RegisterProviderExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "register-provider-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [
            %{
              type: :model,
              name: :ext_model_provider,
              module: ExtModelProvider
            }
          ]
        end
      end

      defmodule ExtModelProvider do
        # Mock provider module
      end
      """

      File.write!(Path.join(tmp_dir, "register_provider_ext.ex"), extension_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      assert report.total_registered == 1
      assert report.total_conflicts == 0

      registered = hd(report.registered)
      assert registered.type == :model
      assert registered.name == :ext_model_provider
      assert registered.module == ExtModelProvider
      assert registered.extension == RegisterProviderExt

      # Verify provider was actually registered
      assert Ai.ProviderRegistry.registered?(:ext_model_provider)
      assert {:ok, ExtModelProvider} == Ai.ProviderRegistry.get(:ext_model_provider)

      # Cleanup
      :code.purge(RegisterProviderExt)
      :code.delete(RegisterProviderExt)
      :code.purge(ExtModelProvider)
      :code.delete(ExtModelProvider)
    end

    test "detects conflicts when multiple extensions provide same provider name", %{
      tmp_dir: tmp_dir
    } do
      ext_a_code = """
      defmodule ConflictProviderExtA do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "conflict-provider-a"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :conflicting_model, module: ConflictModelA}]
        end
      end

      defmodule ConflictModelA do
      end
      """

      ext_b_code = """
      defmodule ConflictProviderExtB do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "conflict-provider-b"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :conflicting_model, module: ConflictModelB}]
        end
      end

      defmodule ConflictModelB do
      end
      """

      File.write!(Path.join(tmp_dir, "conflict_a.ex"), ext_a_code)
      File.write!(Path.join(tmp_dir, "conflict_b.ex"), ext_b_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      assert report.total_registered == 1
      assert report.total_conflicts == 1

      conflict = hd(report.conflicts)
      assert conflict.type == :model
      assert conflict.name == :conflicting_model
      # Winner is determined by alphabetical sort of module name
      assert conflict.winner in [ConflictProviderExtA, ConflictProviderExtB]
      assert length(conflict.shadowed) == 1

      # Cleanup
      :code.purge(ConflictProviderExtA)
      :code.delete(ConflictProviderExtA)
      :code.purge(ConflictProviderExtB)
      :code.delete(ConflictProviderExtB)
      :code.purge(ConflictModelA)
      :code.delete(ConflictModelA)
      :code.purge(ConflictModelB)
      :code.delete(ConflictModelB)
    end

    test "skips registration when provider already exists (built-in)", %{tmp_dir: tmp_dir} do
      # Pre-register a built-in provider
      Ai.ProviderRegistry.register(:existing_builtin, ExistingBuiltinProvider)

      extension_code = """
      defmodule OverrideBuiltinExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "override-builtin-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :existing_builtin, module: OverrideModule}]
        end
      end

      defmodule OverrideModule do
      end
      """

      File.write!(Path.join(tmp_dir, "override_builtin.ex"), extension_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      # Extension provider should NOT be registered (built-in wins)
      assert report.total_registered == 0

      # Verify built-in is still there
      assert {:ok, ExistingBuiltinProvider} == Ai.ProviderRegistry.get(:existing_builtin)

      # Cleanup
      :code.purge(OverrideBuiltinExt)
      :code.delete(OverrideBuiltinExt)
      :code.purge(OverrideModule)
      :code.delete(OverrideModule)
    end
  end

  describe "unregister_extension_providers/1" do
    setup do
      Ai.ProviderRegistry.init()
      on_exit(fn -> Ai.ProviderRegistry.clear() end)
      :ok
    end

    test "unregisters previously registered providers" do
      # Manually register a provider
      Ai.ProviderRegistry.register(:temp_provider, TempProviderModule)
      assert Ai.ProviderRegistry.registered?(:temp_provider)

      # Create a fake registration report
      report = %{
        registered: [
          %{type: :model, name: :temp_provider, module: TempProviderModule, extension: SomeExt}
        ],
        conflicts: [],
        total_registered: 1,
        total_conflicts: 0
      }

      # Unregister
      :ok = Extensions.unregister_extension_providers(report)

      # Verify it's gone
      refute Ai.ProviderRegistry.registered?(:temp_provider)
    end

    test "handles nil gracefully" do
      assert :ok == Extensions.unregister_extension_providers(nil)
    end

    test "handles empty report gracefully" do
      report = %{registered: [], conflicts: [], total_registered: 0, total_conflicts: 0}
      assert :ok == Extensions.unregister_extension_providers(report)
    end
  end

  describe "build_status_report with provider_registration" do
    test "includes provider_registration when provided" do
      provider_report = %{
        registered: [%{type: :model, name: :test, module: TestMod, extension: TestExt}],
        conflicts: [],
        total_registered: 1,
        total_conflicts: 0
      }

      report = Extensions.build_status_report([], [], provider_registration: provider_report)

      assert report.provider_registration == provider_report
    end

    test "provider_registration is nil when not provided" do
      report = Extensions.build_status_report([], [], [])

      assert report.provider_registration == nil
    end
  end

  # ============================================================================
  # Provider Conflict Resolution Tests
  # ============================================================================

  describe "provider conflict detection" do
    setup do
      Ai.ProviderRegistry.init()
      on_exit(fn -> Ai.ProviderRegistry.clear() end)
      :ok
    end

    test "detects conflict when three extensions provide same provider name", %{tmp_dir: tmp_dir} do
      ext_a_code = """
      defmodule ThreeWayConflictExtA do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "three-way-a"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :shared_provider, module: ThreeWayModuleA}]
        end
      end

      defmodule ThreeWayModuleA do
      end
      """

      ext_b_code = """
      defmodule ThreeWayConflictExtB do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "three-way-b"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :shared_provider, module: ThreeWayModuleB}]
        end
      end

      defmodule ThreeWayModuleB do
      end
      """

      ext_c_code = """
      defmodule ThreeWayConflictExtC do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "three-way-c"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :shared_provider, module: ThreeWayModuleC}]
        end
      end

      defmodule ThreeWayModuleC do
      end
      """

      File.write!(Path.join(tmp_dir, "three_way_a.ex"), ext_a_code)
      File.write!(Path.join(tmp_dir, "three_way_b.ex"), ext_b_code)
      File.write!(Path.join(tmp_dir, "three_way_c.ex"), ext_c_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      # Only one should be registered, two should be shadowed
      assert report.total_registered == 1
      assert report.total_conflicts == 1

      conflict = hd(report.conflicts)
      assert conflict.name == :shared_provider
      assert length(conflict.shadowed) == 2

      # Cleanup
      :code.purge(ThreeWayConflictExtA)
      :code.delete(ThreeWayConflictExtA)
      :code.purge(ThreeWayConflictExtB)
      :code.delete(ThreeWayConflictExtB)
      :code.purge(ThreeWayConflictExtC)
      :code.delete(ThreeWayConflictExtC)
      :code.purge(ThreeWayModuleA)
      :code.delete(ThreeWayModuleA)
      :code.purge(ThreeWayModuleB)
      :code.delete(ThreeWayModuleB)
      :code.purge(ThreeWayModuleC)
      :code.delete(ThreeWayModuleC)
    end

    test "multiple independent provider names don't conflict", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule MultiProviderExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "multi-provider"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [
            %{type: :model, name: :provider_one, module: ProviderOne},
            %{type: :model, name: :provider_two, module: ProviderTwo}
          ]
        end
      end

      defmodule ProviderOne do
      end

      defmodule ProviderTwo do
      end
      """

      File.write!(Path.join(tmp_dir, "multi_provider.ex"), ext_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      assert report.total_registered == 2
      assert report.total_conflicts == 0
      assert report.conflicts == []

      # Cleanup
      :code.purge(MultiProviderExt)
      :code.delete(MultiProviderExt)
      :code.purge(ProviderOne)
      :code.delete(ProviderOne)
      :code.purge(ProviderTwo)
      :code.delete(ProviderTwo)
    end
  end

  describe "built-in provider shadowing scenarios" do
    setup do
      Ai.ProviderRegistry.init()
      on_exit(fn -> Ai.ProviderRegistry.clear() end)
      :ok
    end

    test "built-in provider shadows single extension provider", %{tmp_dir: tmp_dir} do
      # Pre-register a built-in provider
      Ai.ProviderRegistry.register(:builtin_model, BuiltinModelModule)

      ext_code = """
      defmodule ShadowedByBuiltinExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "shadowed-by-builtin"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :builtin_model, module: ExtensionModelModule}]
        end
      end

      defmodule ExtensionModelModule do
      end
      """

      File.write!(Path.join(tmp_dir, "shadowed_ext.ex"), ext_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      # Extension provider should NOT be registered
      assert report.total_registered == 0

      # Built-in should still be there
      assert {:ok, BuiltinModelModule} == Ai.ProviderRegistry.get(:builtin_model)

      # Cleanup
      :code.purge(ShadowedByBuiltinExt)
      :code.delete(ShadowedByBuiltinExt)
      :code.purge(ExtensionModelModule)
      :code.delete(ExtensionModelModule)
    end

    test "built-in provider shadows multiple extension providers and creates conflict", %{
      tmp_dir: tmp_dir
    } do
      # Pre-register a built-in provider
      Ai.ProviderRegistry.register(:shared_builtin, SharedBuiltinModule)

      ext_a_code = """
      defmodule BuiltinShadowExtA do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "builtin-shadow-a"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :shared_builtin, module: ShadowModuleA}]
        end
      end

      defmodule ShadowModuleA do
      end
      """

      ext_b_code = """
      defmodule BuiltinShadowExtB do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "builtin-shadow-b"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :shared_builtin, module: ShadowModuleB}]
        end
      end

      defmodule ShadowModuleB do
      end
      """

      File.write!(Path.join(tmp_dir, "builtin_shadow_a.ex"), ext_a_code)
      File.write!(Path.join(tmp_dir, "builtin_shadow_b.ex"), ext_b_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      # No extensions should be registered
      assert report.total_registered == 0

      # Should have one conflict with :builtin as winner
      assert report.total_conflicts == 1
      conflict = hd(report.conflicts)
      assert conflict.winner == :builtin
      assert length(conflict.shadowed) == 2

      # Cleanup
      :code.purge(BuiltinShadowExtA)
      :code.delete(BuiltinShadowExtA)
      :code.purge(BuiltinShadowExtB)
      :code.delete(BuiltinShadowExtB)
      :code.purge(ShadowModuleA)
      :code.delete(ShadowModuleA)
      :code.purge(ShadowModuleB)
      :code.delete(ShadowModuleB)
    end
  end

  describe "deterministic ordering for conflicts" do
    setup do
      Ai.ProviderRegistry.init()
      on_exit(fn -> Ai.ProviderRegistry.clear() end)
      :ok
    end

    test "winner is determined by alphabetical module name", %{tmp_dir: tmp_dir} do
      # Create extensions with specific module names to test ordering
      # "AAA" should come before "ZZZ" alphabetically
      ext_z_code = """
      defmodule ZZZConflictExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "zzz-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :ordered_provider, module: ZZZModule}]
        end
      end

      defmodule ZZZModule do
      end
      """

      ext_a_code = """
      defmodule AAAConflictExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "aaa-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :ordered_provider, module: AAAModule}]
        end
      end

      defmodule AAAModule do
      end
      """

      # Write Z file first to ensure file order doesn't matter
      File.write!(Path.join(tmp_dir, "zzz_ext.ex"), ext_z_code)
      File.write!(Path.join(tmp_dir, "aaa_ext.ex"), ext_a_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      assert report.total_registered == 1
      assert report.total_conflicts == 1

      # AAA should win because "Elixir.AAAConflictExt" < "Elixir.ZZZConflictExt"
      conflict = hd(report.conflicts)
      assert conflict.winner == AAAConflictExt
      assert conflict.shadowed == [ZZZConflictExt]

      # Verify AAA's module was registered
      assert {:ok, AAAModule} == Ai.ProviderRegistry.get(:ordered_provider)

      # Cleanup
      :code.purge(AAAConflictExt)
      :code.delete(AAAConflictExt)
      :code.purge(ZZZConflictExt)
      :code.delete(ZZZConflictExt)
      :code.purge(AAAModule)
      :code.delete(AAAModule)
      :code.purge(ZZZModule)
      :code.delete(ZZZModule)
    end

    test "ordering is consistent across multiple runs", %{tmp_dir: tmp_dir} do
      ext_m_code = """
      defmodule MMiddleConflictExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "m-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :consistent_provider, module: MMiddleModule}]
        end
      end

      defmodule MMiddleModule do
      end
      """

      ext_b_code = """
      defmodule BBeforeConflictExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "b-ext"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :model, name: :consistent_provider, module: BBeforeModule}]
        end
      end

      defmodule BBeforeModule do
      end
      """

      File.write!(Path.join(tmp_dir, "m_ext.ex"), ext_m_code)
      File.write!(Path.join(tmp_dir, "b_ext.ex"), ext_b_code)

      # Run multiple times to ensure consistency
      results =
        for _ <- 1..5 do
          Ai.ProviderRegistry.clear()

          {:ok, extensions, _errors, _validation_errors} =
            Extensions.load_extensions_with_errors([tmp_dir])

          report = Extensions.register_extension_providers(extensions)

          case report.conflicts do
            [%{winner: winner} | _] ->
              winner

            [] ->
              case Ai.ProviderRegistry.get(:consistent_provider) do
                {:ok, BBeforeModule} -> BBeforeConflictExt
                {:ok, MMiddleModule} -> MMiddleConflictExt
                _ -> nil
              end
          end
        end

      # All runs should have the same winner
      assert Enum.all?(results, fn winner -> winner == BBeforeConflictExt end)

      # Cleanup
      :code.purge(MMiddleConflictExt)
      :code.delete(MMiddleConflictExt)
      :code.purge(BBeforeConflictExt)
      :code.delete(BBeforeConflictExt)
      :code.purge(MMiddleModule)
      :code.delete(MMiddleModule)
      :code.purge(BBeforeModule)
      :code.delete(BBeforeModule)
    end
  end

  describe "non-:model provider type handling" do
    setup do
      Ai.ProviderRegistry.init()
      on_exit(fn -> Ai.ProviderRegistry.clear() end)
      :ok
    end

    test "skips :storage type providers", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule StorageProviderExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "storage-provider"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :storage, name: :custom_storage, module: CustomStorageModule}]
        end
      end

      defmodule CustomStorageModule do
      end
      """

      File.write!(Path.join(tmp_dir, "storage_ext.ex"), ext_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      # Storage providers should be skipped (not registered)
      assert report.total_registered == 0
      assert report.total_conflicts == 0

      # Provider should NOT be in the registry
      refute Ai.ProviderRegistry.registered?(:custom_storage)

      # Cleanup
      :code.purge(StorageProviderExt)
      :code.delete(StorageProviderExt)
      :code.purge(CustomStorageModule)
      :code.delete(CustomStorageModule)
    end

    test "skips :tool_executor type providers", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule ToolExecutorProviderExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "tool-executor-provider"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :tool_executor, name: :custom_executor, module: CustomExecutorModule}]
        end
      end

      defmodule CustomExecutorModule do
      end
      """

      File.write!(Path.join(tmp_dir, "tool_executor_ext.ex"), ext_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      assert report.total_registered == 0
      refute Ai.ProviderRegistry.registered?(:custom_executor)

      # Cleanup
      :code.purge(ToolExecutorProviderExt)
      :code.delete(ToolExecutorProviderExt)
      :code.purge(CustomExecutorModule)
      :code.delete(CustomExecutorModule)
    end

    test "mixes model and non-model providers correctly", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule MixedTypeProviderExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "mixed-type-provider"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [
            %{type: :model, name: :my_model, module: MyModelModule},
            %{type: :storage, name: :my_storage, module: MyStorageModule},
            %{type: :tool_executor, name: :my_executor, module: MyExecutorModule}
          ]
        end
      end

      defmodule MyModelModule do
      end

      defmodule MyStorageModule do
      end

      defmodule MyExecutorModule do
      end
      """

      File.write!(Path.join(tmp_dir, "mixed_type_ext.ex"), ext_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      # Only model provider should be registered
      assert report.total_registered == 1
      assert hd(report.registered).name == :my_model
      assert Ai.ProviderRegistry.registered?(:my_model)
      refute Ai.ProviderRegistry.registered?(:my_storage)
      refute Ai.ProviderRegistry.registered?(:my_executor)

      # Cleanup
      :code.purge(MixedTypeProviderExt)
      :code.delete(MixedTypeProviderExt)
      :code.purge(MyModelModule)
      :code.delete(MyModelModule)
      :code.purge(MyStorageModule)
      :code.delete(MyStorageModule)
      :code.purge(MyExecutorModule)
      :code.delete(MyExecutorModule)
    end

    test "handles custom/unknown provider types", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule UnknownTypeProviderExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "unknown-type-provider"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          [%{type: :custom_type, name: :custom_provider, module: CustomTypeModule}]
        end
      end

      defmodule CustomTypeModule do
      end
      """

      File.write!(Path.join(tmp_dir, "unknown_type_ext.ex"), ext_code)

      {:ok, extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.register_extension_providers(extensions)

      # Unknown types should be skipped
      assert report.total_registered == 0
      assert report.total_conflicts == 0

      # Cleanup
      :code.purge(UnknownTypeProviderExt)
      :code.delete(UnknownTypeProviderExt)
      :code.purge(CustomTypeModule)
      :code.delete(CustomTypeModule)
    end
  end

  describe "callbacks raising exceptions during validation" do
    test "validates extension with providers/0 that raises", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule RaisingProvidersExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "raising-providers"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          raise "Providers callback crashed!"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "raising_providers.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      # Extension should fail validation
      assert extensions == []
      assert length(validation_errors) == 1
      assert hd(validation_errors).module == RaisingProvidersExt

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "providers/0 raised an error")
             )

      # Cleanup
      :code.purge(RaisingProvidersExt)
      :code.delete(RaisingProvidersExt)
    end

    test "validates extension with name/0 that raises", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule RaisingNameValidationExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name do
          raise "Name callback crashed!"
        end

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "raising_name.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "name/0 raised an error")
             )

      # Cleanup
      :code.purge(RaisingNameValidationExt)
      :code.delete(RaisingNameValidationExt)
    end

    test "validates extension with version/0 that raises", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule RaisingVersionValidationExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "raising-version"

        @impl true
        def version do
          raise "Version callback crashed!"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "raising_version.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "version/0 raised an error")
             )

      # Cleanup
      :code.purge(RaisingVersionValidationExt)
      :code.delete(RaisingVersionValidationExt)
    end

    test "validates extension with capabilities/0 that raises", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule RaisingCapabilitiesExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "raising-capabilities"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def capabilities do
          raise "Capabilities callback crashed!"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "raising_capabilities.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "capabilities/0 raised an error")
             )

      # Cleanup
      :code.purge(RaisingCapabilitiesExt)
      :code.delete(RaisingCapabilitiesExt)
    end

    test "validates extension with config_schema/0 that raises", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule RaisingConfigSchemaExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "raising-config-schema"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def config_schema do
          raise "Config schema callback crashed!"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "raising_config_schema.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "config_schema/0 raised an error")
             )

      # Cleanup
      :code.purge(RaisingConfigSchemaExt)
      :code.delete(RaisingConfigSchemaExt)
    end

    test "validates extension with tools/1 that raises", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule RaisingToolsValidationExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "raising-tools-validation"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          raise "Tools callback crashed!"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "raising_tools.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "tools/1 raised an error")
             )

      # Cleanup
      :code.purge(RaisingToolsValidationExt)
      :code.delete(RaisingToolsValidationExt)
    end

    test "validates extension with hooks/0 that raises", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule RaisingHooksValidationExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "raising-hooks-validation"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def hooks do
          raise "Hooks callback crashed!"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "raising_hooks.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "hooks/0 raised an error")
             )

      # Cleanup
      :code.purge(RaisingHooksValidationExt)
      :code.delete(RaisingHooksValidationExt)
    end
  end

  describe "invalid return types from callbacks" do
    test "rejects extension where name/0 returns non-string", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule InvalidNameTypeExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: :not_a_string

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_name_type.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "name/0 must return a string")
             )

      # Cleanup
      :code.purge(InvalidNameTypeExt)
      :code.delete(InvalidNameTypeExt)
    end

    test "rejects extension where version/0 returns non-string", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule InvalidVersionTypeExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "invalid-version"

        @impl true
        def version, do: 100
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_version_type.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "version/0 must return a string")
             )

      # Cleanup
      :code.purge(InvalidVersionTypeExt)
      :code.delete(InvalidVersionTypeExt)
    end

    test "rejects extension where tools/1 returns non-list", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule InvalidToolsTypeExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "invalid-tools"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd), do: :not_a_list
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_tools_type.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "tools/1 must return a list")
             )

      # Cleanup
      :code.purge(InvalidToolsTypeExt)
      :code.delete(InvalidToolsTypeExt)
    end

    test "rejects extension where hooks/0 returns non-keyword-list", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule InvalidHooksTypeExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "invalid-hooks"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def hooks, do: "not a keyword list"
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_hooks_type.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "hooks/0 must return a keyword list")
             )

      # Cleanup
      :code.purge(InvalidHooksTypeExt)
      :code.delete(InvalidHooksTypeExt)
    end

    test "rejects extension where capabilities/0 returns non-list", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule InvalidCapabilitiesTypeExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "invalid-capabilities"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def capabilities, do: :not_a_list
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_capabilities_type.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "capabilities/0 must return a list")
             )

      # Cleanup
      :code.purge(InvalidCapabilitiesTypeExt)
      :code.delete(InvalidCapabilitiesTypeExt)
    end

    test "rejects extension where config_schema/0 returns non-map", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule InvalidConfigSchemaTypeExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "invalid-config-schema"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def config_schema, do: []
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_config_schema_type.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "config_schema/0 must return a map")
             )

      # Cleanup
      :code.purge(InvalidConfigSchemaTypeExt)
      :code.delete(InvalidConfigSchemaTypeExt)
    end

    test "rejects extension where providers/0 returns non-list", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule InvalidProvidersTypeExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "invalid-providers"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers, do: %{invalid: :structure}
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_providers_type.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1

      assert Enum.any?(
               hd(validation_errors).errors,
               &String.contains?(&1, "providers/0 must return a list")
             )

      # Cleanup
      :code.purge(InvalidProvidersTypeExt)
      :code.delete(InvalidProvidersTypeExt)
    end

    test "collects multiple validation errors in single extension", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule MultipleInvalidExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: 123

        @impl true
        def version, do: :atom

        @impl true
        def tools(_cwd), do: "string"

        @impl true
        def hooks, do: :atom
      end
      """

      File.write!(Path.join(tmp_dir, "multiple_invalid.ex"), ext_code)

      {:ok, extensions, _errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      assert extensions == []
      assert length(validation_errors) == 1
      errors = hd(validation_errors).errors

      # Should have all four validation errors
      assert length(errors) == 4
      assert Enum.any?(errors, &String.contains?(&1, "name/0 must return a string"))
      assert Enum.any?(errors, &String.contains?(&1, "version/0 must return a string"))
      assert Enum.any?(errors, &String.contains?(&1, "tools/1 must return a list"))
      assert Enum.any?(errors, &String.contains?(&1, "hooks/0 must return a keyword list"))

      # Cleanup
      :code.purge(MultipleInvalidExt)
      :code.delete(MultipleInvalidExt)
    end
  end

  describe "cache clearing and ETS table management" do
    test "clear_extension_cache clears source path table", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule CacheSourcePathExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "cache-source-path"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "cache_source_path.ex"), ext_code)
      {:ok, _extensions} = Extensions.load_extensions([tmp_dir])

      # Verify source path is tracked
      assert Extensions.get_source_path(CacheSourcePathExt) != nil

      # Clear cache
      :ok = Extensions.clear_extension_cache()

      # Source path should be gone
      assert Extensions.get_source_path(CacheSourcePathExt) == nil
    end

    test "clear_extension_cache removes modules from code server", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule CacheCodeServerExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "cache-code-server"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "cache_code_server.ex"), ext_code)
      {:ok, _extensions} = Extensions.load_extensions([tmp_dir])

      # Module should be loaded
      assert Code.ensure_loaded?(CacheCodeServerExt)

      # Clear cache
      :ok = Extensions.clear_extension_cache()

      # Module should be unloaded
      refute Code.ensure_loaded?(CacheCodeServerExt)
    end

    test "clear_extension_cache clears load errors table", %{tmp_dir: tmp_dir} do
      # Create an invalid file to generate errors
      invalid_code = """
      defmodule CacheLoadErrorsExt do
        def missing_end
      """

      File.write!(Path.join(tmp_dir, "cache_load_errors.ex"), invalid_code)

      {:ok, _extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      # Should have errors
      assert length(errors) == 1

      # Verify errors are cached
      {cached_errors, timestamp} = Extensions.last_load_errors()
      assert length(cached_errors) == 1
      assert is_integer(timestamp)

      # Clear cache
      :ok = Extensions.clear_extension_cache()

      # Errors should be cleared
      {cleared_errors, cleared_timestamp} = Extensions.last_load_errors()
      assert cleared_errors == []
      assert cleared_timestamp == nil
    end

    test "ETS tables are recreated after clear and reload", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule ETSRecreateExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "ets-recreate"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "ets_recreate.ex"), ext_code)

      # First load
      {:ok, extensions1} = Extensions.load_extensions([tmp_dir])
      assert ETSRecreateExt in extensions1

      # Clear
      :ok = Extensions.clear_extension_cache()

      # Reload (need to recompile the file)
      {:ok, extensions2} = Extensions.load_extensions([tmp_dir])
      assert ETSRecreateExt in extensions2

      # Source path should be tracked again
      assert Extensions.get_source_path(ETSRecreateExt) != nil

      # Cleanup
      :code.purge(ETSRecreateExt)
      :code.delete(ETSRecreateExt)
    end

    test "list_extensions returns empty after clear", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule ListAfterClearExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "list-after-clear"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "list_after_clear.ex"), ext_code)
      {:ok, _extensions} = Extensions.load_extensions([tmp_dir])

      # Should be in list
      all = Extensions.list_extensions()
      assert Enum.any?(all, &(&1.name == "list-after-clear"))

      # Clear
      :ok = Extensions.clear_extension_cache()

      # Should not be in list anymore
      all_after = Extensions.list_extensions()
      refute Enum.any?(all_after, &(&1.name == "list-after-clear"))
    end
  end

  describe "last_load_errors persistence" do
    test "errors persist across multiple queries", %{tmp_dir: tmp_dir} do
      invalid_code = """
      defmodule PersistErrorExt do
        def missing
      """

      File.write!(Path.join(tmp_dir, "persist_error.ex"), invalid_code)

      {:ok, _extensions, _errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      # Query multiple times
      {errors1, ts1} = Extensions.last_load_errors()
      {errors2, ts2} = Extensions.last_load_errors()
      {errors3, ts3} = Extensions.last_load_errors()

      # All should be the same
      assert errors1 == errors2
      assert errors2 == errors3
      assert ts1 == ts2
      assert ts2 == ts3
    end

    test "errors are replaced on subsequent load", %{tmp_dir: tmp_dir} do
      # First error
      invalid_code1 = """
      defmodule FirstPersistExt do
        def missing
      """

      File.write!(Path.join(tmp_dir, "first_persist.ex"), invalid_code1)
      {:ok, _, _, _} = Extensions.load_extensions_with_errors([tmp_dir])

      {errors1, _ts1} = Extensions.last_load_errors()
      assert length(errors1) == 1
      assert String.contains?(hd(errors1).source_path, "first_persist.ex")

      # Delete first, create second error
      File.rm!(Path.join(tmp_dir, "first_persist.ex"))

      invalid_code2 = """
      defmodule SecondPersistExt do
        def also_missing
      """

      File.write!(Path.join(tmp_dir, "second_persist.ex"), invalid_code2)
      {:ok, _, _, _} = Extensions.load_extensions_with_errors([tmp_dir])

      {errors2, _ts2} = Extensions.last_load_errors()
      assert length(errors2) == 1
      assert String.contains?(hd(errors2).source_path, "second_persist.ex")
    end

    test "timestamp is updated on each load", %{tmp_dir: tmp_dir} do
      valid_code = """
      defmodule TimestampExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "timestamp-ext"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "timestamp_ext.ex"), valid_code)

      {:ok, _, _, _} = Extensions.load_extensions_with_errors([tmp_dir])
      {_errors1, ts1} = Extensions.last_load_errors()

      Process.sleep(10)

      {:ok, _, _, _} = Extensions.load_extensions_with_errors([tmp_dir])
      {_errors2, ts2} = Extensions.last_load_errors()

      # Second timestamp should be later
      assert ts2 > ts1

      # Cleanup
      :code.purge(TimestampExt)
      :code.delete(TimestampExt)
    end

    test "empty errors list persists with timestamp", %{tmp_dir: tmp_dir} do
      valid_code = """
      defmodule EmptyErrorsExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "empty-errors"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "empty_errors.ex"), valid_code)

      {:ok, _extensions, errors, _validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      # No errors
      assert errors == []

      # But timestamp should still be set
      {cached_errors, timestamp} = Extensions.last_load_errors()
      assert cached_errors == []
      assert is_integer(timestamp)

      # Cleanup
      :code.purge(EmptyErrorsExt)
      :code.delete(EmptyErrorsExt)
    end

    test "get_providers handles exceptions gracefully during collection", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule GetProvidersRaisingExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "get-providers-raising"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def providers do
          raise "Crash during get_providers!"
        end
      end
      """

      # Note: This extension would fail validation, but we can test get_providers directly
      # by creating a module that implements providers/0 but raises
      File.write!(Path.join(tmp_dir, "get_providers_raising.ex"), ext_code)

      # Load without validation for this test
      {:ok, _extensions} = Extensions.load_extensions([tmp_dir])

      # get_providers should handle the exception gracefully
      providers = Extensions.get_providers([GetProvidersRaisingExt])
      assert providers == []

      # Cleanup
      :code.purge(GetProvidersRaisingExt)
      :code.delete(GetProvidersRaisingExt)
    end
  end

  describe "validation_errors persistence in last_load_errors" do
    test "validation errors are stored separately from load errors", %{tmp_dir: tmp_dir} do
      ext_code = """
      defmodule ValidationErrorPersistExt do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: :not_a_string

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "validation_persist.ex"), ext_code)

      {:ok, extensions, load_errors, validation_errors} =
        Extensions.load_extensions_with_errors([tmp_dir])

      # No load errors (file compiled fine)
      assert load_errors == []

      # But validation errors
      assert length(validation_errors) == 1
      assert extensions == []

      # Check that last_load_errors returns load errors (not validation errors)
      {cached_load_errors, timestamp} = Extensions.last_load_errors()
      assert cached_load_errors == []
      assert is_integer(timestamp)

      # Cleanup
      :code.purge(ValidationErrorPersistExt)
      :code.delete(ValidationErrorPersistExt)
    end
  end
end
