defmodule CodingAgent.ExtensionLifecycleTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.Config
  alias CodingAgent.ExtensionLifecycle

  @moduletag :tmp_dir

  setup do
    # Keep extension cache isolated between tests.
    CodingAgent.ToolRegistry.invalidate_extension_cache()
    CodingAgent.Extensions.clear_extension_cache()
    :ok
  end

  describe "extension_paths/2" do
    test "merges settings paths before global and project paths", %{tmp_dir: tmp_dir} do
      settings_manager = %{extension_paths: ["/tmp/custom/a", "/tmp/custom/b"]}

      assert ExtensionLifecycle.extension_paths(tmp_dir, settings_manager) == [
               "/tmp/custom/a",
               "/tmp/custom/b",
               Config.extensions_dir(),
               Config.project_extensions_dir(tmp_dir)
             ]
    end
  end

  describe "initialize/1" do
    test "loads extensions and returns tools/hooks/status", %{tmp_dir: tmp_dir} do
      extension_module =
        create_extension_file(tmp_dir, "InitLifecycle#{System.unique_integer([:positive])}",
          tools: extension_tools_code("ext_lifecycle_tool"),
          hooks: extension_hooks_code()
        )

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: %{extension_paths: []},
          tool_opts: []
        )

      assert extension_module in result.extensions
      assert Keyword.has_key?(result.hooks, :on_message_start)
      assert is_map(result.extension_status_report)
      assert is_map(result.provider_registration)
      assert is_list(result.extension_paths)

      tool_names = Enum.map(result.tools, & &1.name)
      assert "read" in tool_names
      assert "ext_lifecycle_tool" in tool_names

      cleanup_module(extension_module)
    end

    test "merges custom, extension, and extra tools when custom tools are provided", %{
      tmp_dir: tmp_dir
    } do
      extension_module =
        create_extension_file(tmp_dir, "CustomLifecycle#{System.unique_integer([:positive])}",
          tools: extension_tools_code("ext_custom_tool")
        )

      custom_tool =
        %AgentTool{
          name: "custom_only_tool",
          description: "custom",
          parameters: %{},
          label: "custom",
          execute: fn _, _, _, _ -> %AgentToolResult{content: [], details: nil} end
        }

      extra_tool =
        %AgentTool{
          name: "extra_only_tool",
          description: "extra",
          parameters: %{},
          label: "extra",
          execute: fn _, _, _, _ -> %AgentToolResult{content: [], details: nil} end
        }

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: %{extension_paths: []},
          tool_opts: [],
          custom_tools: [custom_tool],
          extra_tools: [extra_tool]
        )

      tool_names = Enum.map(result.tools, & &1.name)
      assert "custom_only_tool" in tool_names
      assert "ext_custom_tool" in tool_names
      assert "extra_only_tool" in tool_names
      refute "read" in tool_names

      cleanup_module(extension_module)
    end
  end

  describe "reload/1" do
    test "reloads extensions and rebuilds tool list with extra tools", %{tmp_dir: tmp_dir} do
      first_module =
        create_extension_file(tmp_dir, "ReloadFirst#{System.unique_integer([:positive])}",
          tools: extension_tools_code("reload_tool_one")
        )

      initial =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: %{extension_paths: []},
          tool_opts: []
        )

      second_module =
        create_extension_file(tmp_dir, "ReloadSecond#{System.unique_integer([:positive])}",
          tools: extension_tools_code("reload_tool_two")
        )

      extra_tool =
        %AgentTool{
          name: "reload_extra_tool",
          description: "extra",
          parameters: %{},
          label: "extra",
          execute: fn _, _, _, _ -> %AgentToolResult{content: [], details: nil} end
        }

      reloaded =
        ExtensionLifecycle.reload(
          cwd: tmp_dir,
          settings_manager: %{extension_paths: []},
          tool_opts: [],
          extra_tools: [extra_tool],
          previous_status_report: initial.extension_status_report
        )

      assert first_module in reloaded.extensions
      assert second_module in reloaded.extensions
      assert is_map(reloaded.provider_registration)
      assert is_map(reloaded.extension_status_report)

      tool_names = Enum.map(reloaded.tools, & &1.name)
      assert "reload_tool_one" in tool_names
      assert "reload_tool_two" in tool_names
      assert "reload_extra_tool" in tool_names

      cleanup_module(first_module)
      cleanup_module(second_module)
    end
  end

  defp extension_tools_code(tool_name) do
    """
    [
      %AgentCore.Types.AgentTool{
        name: "#{tool_name}",
        description: "tool #{tool_name}",
        parameters: %{},
        label: "#{tool_name}",
        execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: [], details: nil} end
      }
    ]
    """
  end

  defp extension_hooks_code do
    """
    [
      on_message_start: fn _message -> :ok end
    ]
    """
  end

  defp create_extension_file(tmp_dir, module_name, opts) do
    tools = Keyword.get(opts, :tools, "[]")
    hooks = Keyword.get(opts, :hooks, "[]")

    extension_code = """
    defmodule #{module_name} do
      @behaviour CodingAgent.Extensions.Extension

      @impl true
      def name, do: "#{String.downcase(module_name)}"

      @impl true
      def version, do: "1.0.0"

      @impl true
      def tools(_cwd), do: #{tools}

      @impl true
      def hooks, do: #{hooks}
    end
    """

    ext_dir = Path.join(tmp_dir, ".lemon/extensions")
    File.mkdir_p!(ext_dir)
    file_path = Path.join(ext_dir, "#{String.downcase(module_name)}.ex")
    File.write!(file_path, extension_code)

    Module.concat([module_name])
  end

  defp cleanup_module(module) do
    :code.purge(module)
    :code.delete(module)
  end
end
