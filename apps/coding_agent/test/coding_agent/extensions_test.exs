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
  end
end
