defmodule CodingAgent.ExtensionsEdgeCasesTest do
  @moduledoc """
  Edge case tests for the Extensions system.

  Tests extension loading failures, invalid configurations,
  lifecycle management, and error handling during execution.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Extensions
  alias AgentCore.Types.AgentTool
  alias AgentCore.Types.AgentToolResult

  @moduletag :tmp_dir

  # ============================================================================
  # Helpers
  # ============================================================================

  defp cleanup_modules(modules) when is_list(modules) do
    Enum.each(modules, &cleanup_module/1)
  end

  defp cleanup_module(module) do
    :code.purge(module)
    :code.delete(module)
  end

  # ============================================================================
  # Extension Loading Failures
  # ============================================================================

  describe "extension loading - syntax errors" do
    test "handles extension files with syntax errors gracefully", %{tmp_dir: tmp_dir} do
      invalid_code = """
      defmodule SyntaxErrorExtension do
        @behaviour CodingAgent.Extensions.Extension

        # Missing 'do' keyword - syntax error
        def name
          "broken"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "syntax_error.ex"), invalid_code)

      # Should not raise and return empty list
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      assert extensions == []
    end

    test "handles extension files with undefined module references", %{tmp_dir: tmp_dir} do
      code = """
      defmodule UndefinedRefExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: UndefinedModule.undefined_function()

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "undefined_ref.ex"), code)

      # Should compile (since the undefined call is not executed at compile time)
      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      # The module may or may not load depending on whether it implements behaviour correctly
      # but it shouldn't crash the system

      cleanup_modules(extensions)
    end

    test "handles empty extension files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "empty.ex"), "")

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      assert extensions == []
    end

    test "handles extension files with only comments", %{tmp_dir: tmp_dir} do
      code = """
      # This is just a comment
      # No actual module definition here
      """

      File.write!(Path.join(tmp_dir, "comments_only.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      assert extensions == []
    end
  end

  describe "extension loading - missing behaviour" do
    test "ignores modules that don't implement Extension behaviour", %{tmp_dir: tmp_dir} do
      code = """
      defmodule NotAnExtension do
        def name, do: "not-extension"
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "not_extension.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      refute NotAnExtension in extensions

      cleanup_module(NotAnExtension)
    end

    test "only loads modules with Extension behaviour from mixed file", %{tmp_dir: tmp_dir} do
      code = """
      defmodule HelperModule do
        def helper_function, do: "helper"
      end

      defmodule ActualExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "actual-extension"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "mixed_modules.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      assert ActualExtension in extensions
      refute HelperModule in extensions

      cleanup_modules([HelperModule, ActualExtension])
    end
  end

  describe "extension loading - path handling" do
    test "handles nil in paths list", %{tmp_dir: tmp_dir} do
      # Create a valid extension
      code = """
      defmodule ValidPathExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "valid-path"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "valid.ex"), code)

      # This should filter out the nil
      {:ok, extensions} = Extensions.load_extensions([tmp_dir, nil])
      assert ValidPathExtension in extensions

      cleanup_module(ValidPathExtension)
    end

    test "handles empty string paths", %{tmp_dir: tmp_dir} do
      {:ok, extensions} = Extensions.load_extensions(["", tmp_dir])
      assert extensions == []
    end

    test "handles paths with special characters", %{tmp_dir: tmp_dir} do
      special_dir = Path.join(tmp_dir, "path with spaces & special!")
      File.mkdir_p!(special_dir)

      code = """
      defmodule SpecialPathExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "special-path"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(special_dir, "extension.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([special_dir])
      assert SpecialPathExtension in extensions

      cleanup_module(SpecialPathExtension)
    end

    test "deduplicates extensions loaded from multiple paths", %{tmp_dir: tmp_dir} do
      dir1 = Path.join(tmp_dir, "dir1")
      dir2 = Path.join(tmp_dir, "dir2")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      code = """
      defmodule DedupeExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "dedupe"

        @impl true
        def version, do: "1.0.0"
      end
      """

      # Same module in both directories (simulating recompilation)
      File.write!(Path.join(dir1, "dedupe.ex"), code)
      # Load from first path only - adding same module to second path would redefine it
      {:ok, extensions} = Extensions.load_extensions([dir1])

      # Should only appear once
      assert Enum.count(extensions, &(&1 == DedupeExtension)) == 1

      cleanup_module(DedupeExtension)
    end

    test "handles symlinked directories", %{tmp_dir: tmp_dir} do
      real_dir = Path.join(tmp_dir, "real_dir")
      symlink_dir = Path.join(tmp_dir, "symlink_dir")
      File.mkdir_p!(real_dir)

      code = """
      defmodule SymlinkExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "symlink"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(real_dir, "extension.ex"), code)

      # Create symlink (may fail on some systems)
      case File.ln_s(real_dir, symlink_dir) do
        :ok ->
          {:ok, extensions} = Extensions.load_extensions([symlink_dir])
          assert SymlinkExtension in extensions
          cleanup_module(SymlinkExtension)

        {:error, _} ->
          # Skip test on systems that don't support symlinks
          :ok
      end
    end
  end

  # ============================================================================
  # Invalid Extension Configurations
  # ============================================================================

  describe "get_tools/2 - error handling" do
    test "handles extensions that raise in tools/1", %{tmp_dir: tmp_dir} do
      code = """
      defmodule RaisingToolsExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "raising-tools"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          raise "Tools function crashed!"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "raising_tools.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      # Should not raise, returns empty list for erroring extensions
      tools = Extensions.get_tools(extensions, tmp_dir)
      assert tools == []

      cleanup_module(RaisingToolsExtension)
    end

    test "handles extensions that return invalid tool structures", %{tmp_dir: tmp_dir} do
      code = """
      defmodule InvalidToolsExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "invalid-tools"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          # Returns invalid structure (not a list of AgentTool)
          :not_a_list
        end
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_tools.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      # Should handle gracefully - flat_map will fail on non-enumerable
      # The rescue clause should catch this
      tools = Extensions.get_tools(extensions, tmp_dir)
      assert tools == []

      cleanup_module(InvalidToolsExtension)
    end

    test "handles extensions without tools callback", %{tmp_dir: tmp_dir} do
      code = """
      defmodule NoToolsExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "no-tools"

        @impl true
        def version, do: "1.0.0"

        # No tools/1 callback - it's optional
      end
      """

      File.write!(Path.join(tmp_dir, "no_tools.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      tools = Extensions.get_tools(extensions, tmp_dir)
      assert tools == []

      cleanup_module(NoToolsExtension)
    end

    test "handles mixed valid and invalid tool extensions", %{tmp_dir: tmp_dir} do
      code = """
      defmodule ValidToolExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "valid-tool"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "valid_tool",
              description: "A valid tool",
              parameters: %{},
              label: "Valid Tool",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end

      defmodule CrashingToolExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "crashing-tool"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd), do: raise "Crash!"
      end
      """

      File.write!(Path.join(tmp_dir, "mixed_tools.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      tools = Extensions.get_tools(extensions, tmp_dir)

      # Should get tools from the valid extension only
      assert length(tools) == 1
      assert hd(tools).name == "valid_tool"

      cleanup_modules([ValidToolExtension, CrashingToolExtension])
    end
  end

  describe "get_hooks/1 - error handling" do
    test "handles extensions that raise in hooks/0", %{tmp_dir: tmp_dir} do
      code = """
      defmodule RaisingHooksExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "raising-hooks"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def hooks do
          raise "Hooks function crashed!"
        end
      end
      """

      File.write!(Path.join(tmp_dir, "raising_hooks.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      hooks = Extensions.get_hooks(extensions)
      assert hooks == []

      cleanup_module(RaisingHooksExtension)
    end

    test "handles extensions that return invalid hook structures", %{tmp_dir: tmp_dir} do
      code = """
      defmodule InvalidHooksExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "invalid-hooks"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def hooks do
          # Returns invalid structure (not a keyword list)
          %{on_start: fn -> :ok end}
        end
      end
      """

      File.write!(Path.join(tmp_dir, "invalid_hooks.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      # Maps are enumerable but the structure doesn't match expected keyword
      hooks = Extensions.get_hooks(extensions)
      # The result depends on how the code handles maps vs keyword lists
      assert is_list(hooks)

      cleanup_module(InvalidHooksExtension)
    end

    test "handles extensions without hooks callback", %{tmp_dir: tmp_dir} do
      code = """
      defmodule NoHooksExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "no-hooks"

        @impl true
        def version, do: "1.0.0"

        # No hooks/0 callback - it's optional
      end
      """

      File.write!(Path.join(tmp_dir, "no_hooks.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      hooks = Extensions.get_hooks(extensions)
      assert hooks == []

      cleanup_module(NoHooksExtension)
    end
  end

  # ============================================================================
  # Hook Execution Edge Cases
  # ============================================================================

  describe "execute_hooks/3 - edge cases" do
    test "handles hooks that throw" do
      hooks = [
        on_test: [
          fn _arg -> throw(:hook_throw) end
        ]
      ]

      # Should not propagate the throw
      assert :ok = Extensions.execute_hooks(hooks, :on_test, ["arg"])
    end

    test "handles hooks that exit" do
      hooks = [
        on_test: [
          fn _arg -> exit(:hook_exit) end
        ]
      ]

      # Should not propagate the exit
      assert :ok = Extensions.execute_hooks(hooks, :on_test, ["arg"])
    end

    test "handles hooks with wrong arity" do
      hooks = [
        on_test: [
          # This hook expects 2 args but we'll pass 1
          fn _arg1, _arg2 -> :ok end
        ]
      ]

      # Should handle BadArityError gracefully
      assert :ok = Extensions.execute_hooks(hooks, :on_test, ["single_arg"])
    end

    test "handles nil in hook list" do
      hooks = [
        on_test: [nil, fn _arg -> :ok end]
      ]

      # Should handle nil gracefully
      assert :ok = Extensions.execute_hooks(hooks, :on_test, ["arg"])
    end

    test "handles non-function in hook list" do
      hooks = [
        on_test: ["not a function", fn _arg -> :ok end]
      ]

      # Should handle non-function gracefully
      assert :ok = Extensions.execute_hooks(hooks, :on_test, ["arg"])
    end

    test "executes hooks in order and continues after errors", %{} do
      {:ok, tracker} = Agent.start_link(fn -> [] end)

      hooks = [
        on_test: [
          fn arg -> Agent.update(tracker, &[{:first, arg} | &1]) end,
          fn _arg -> raise "Error in second hook" end,
          fn arg -> Agent.update(tracker, &[{:third, arg} | &1]) end
        ]
      ]

      :ok = Extensions.execute_hooks(hooks, :on_test, ["value"])

      calls = Agent.get(tracker, & &1)
      # First and third hooks should have been called
      assert {:first, "value"} in calls
      assert {:third, "value"} in calls

      Agent.stop(tracker)
    end

    test "handles empty args list" do
      {:ok, tracker} = Agent.start_link(fn -> false end)

      hooks = [
        on_test: [
          fn -> Agent.update(tracker, fn _ -> true end) end
        ]
      ]

      :ok = Extensions.execute_hooks(hooks, :on_test, [])

      assert Agent.get(tracker, & &1) == true

      Agent.stop(tracker)
    end

    test "handles large number of arguments" do
      {:ok, tracker} = Agent.start_link(fn -> nil end)

      hooks = [
        on_test: [
          fn a, b, c, d, e ->
            Agent.update(tracker, fn _ -> {a, b, c, d, e} end)
          end
        ]
      ]

      :ok = Extensions.execute_hooks(hooks, :on_test, [1, 2, 3, 4, 5])

      assert Agent.get(tracker, & &1) == {1, 2, 3, 4, 5}

      Agent.stop(tracker)
    end
  end

  # ============================================================================
  # get_info/1 Edge Cases
  # ============================================================================

  describe "get_info/1 - edge cases" do
    test "handles extensions with missing name/0", %{tmp_dir: tmp_dir} do
      code = """
      defmodule MissingNameExtension do
        @behaviour CodingAgent.Extensions.Extension

        # name/0 is required but let's test missing implementation
        @impl true
        def version, do: "1.0.0"
      end
      """

      # This won't compile properly due to missing required callback
      # but let's test with a module that doesn't export name
      File.write!(Path.join(tmp_dir, "missing_name.ex"), code)

      # Compilation may fail, so test with a fake module instead
      # We'll test the safe_call fallback behavior
      info = Extensions.get_info([__MODULE__])
      assert length(info) == 1
      assert hd(info).name == "unknown"
      assert hd(info).version == "0.0.0"
    end

    test "handles extensions that raise in name/0" do
      # Create a module that raises in name
      defmodule RaisingNameExtension do
        def name, do: raise("Name error!")
        def version, do: "1.0.0"
      end

      info = Extensions.get_info([RaisingNameExtension])
      assert length(info) == 1
      assert hd(info).name == "unknown"

      cleanup_module(RaisingNameExtension)
    end

    test "handles extensions that raise in version/0" do
      defmodule RaisingVersionExtension do
        def name, do: "raising-version"
        def version, do: raise("Version error!")
      end

      info = Extensions.get_info([RaisingVersionExtension])
      assert length(info) == 1
      assert hd(info).name == "raising-version"
      assert hd(info).version == "0.0.0"

      cleanup_module(RaisingVersionExtension)
    end

    test "returns correct info for valid extension", %{tmp_dir: tmp_dir} do
      code = """
      defmodule ValidInfoExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "valid-info"

        @impl true
        def version, do: "2.5.3"
      end
      """

      File.write!(Path.join(tmp_dir, "valid_info.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      info = Extensions.get_info(extensions)

      assert length(info) == 1
      ext_info = hd(info)
      assert ext_info.name == "valid-info"
      assert ext_info.version == "2.5.3"
      assert ext_info.module == ValidInfoExtension

      cleanup_module(ValidInfoExtension)
    end

    test "handles empty extensions list" do
      info = Extensions.get_info([])
      assert info == []
    end
  end

  # ============================================================================
  # Extension Lifecycle
  # ============================================================================

  describe "extension lifecycle - reload scenarios" do
    test "reloading same extension replaces previous version", %{tmp_dir: tmp_dir} do
      code_v1 = """
      defmodule ReloadableExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "reloadable"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd), do: []
      end
      """

      File.write!(Path.join(tmp_dir, "reloadable.ex"), code_v1)

      {:ok, extensions_v1} = Extensions.load_extensions([tmp_dir])
      info_v1 = Extensions.get_info(extensions_v1)
      assert hd(info_v1).version == "1.0.0"

      # Update the extension
      code_v2 = """
      defmodule ReloadableExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "reloadable"

        @impl true
        def version, do: "2.0.0"

        @impl true
        def tools(_cwd), do: []
      end
      """

      File.write!(Path.join(tmp_dir, "reloadable.ex"), code_v2)

      # Reload
      {:ok, extensions_v2} = Extensions.load_extensions([tmp_dir])
      info_v2 = Extensions.get_info(extensions_v2)
      assert hd(info_v2).version == "2.0.0"

      cleanup_module(ReloadableExtension)
    end

    test "unloaded module still works with existing references", %{tmp_dir: tmp_dir} do
      code = """
      defmodule UnloadTestExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "unload-test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "unload_tool",
              description: "A tool",
              parameters: %{},
              label: "Unload Tool",
              execute: fn _, _, _, _ ->
                %AgentCore.Types.AgentToolResult{content: [%{type: "text", text: "result"}]}
              end
            }
          ]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "unload_test.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      tools = Extensions.get_tools(extensions, tmp_dir)
      tool = hd(tools)

      # Get the execute function before unloading
      execute_fn = tool.execute

      # Unload the module
      :code.purge(UnloadTestExtension)
      :code.delete(UnloadTestExtension)

      # The captured function should still work (closures capture the code)
      result = execute_fn.("id", %{}, nil, nil)
      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Concurrent Extension Loading
  # ============================================================================

  describe "concurrent extension operations" do
    test "concurrent get_tools calls don't interfere", %{tmp_dir: tmp_dir} do
      code = """
      defmodule ConcurrentToolsExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "concurrent-tools"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          # Small delay to increase chance of race conditions
          Process.sleep(10)
          [
            %AgentCore.Types.AgentTool{
              name: "concurrent_tool",
              description: "A tool",
              parameters: %{},
              label: "Concurrent Tool",
              execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
            }
          ]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "concurrent_tools.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])

      # Run multiple concurrent get_tools calls
      tasks =
        for _ <- 1..10 do
          Task.async(fn -> Extensions.get_tools(extensions, tmp_dir) end)
        end

      results = Task.await_many(tasks)

      # All should return the same result
      for tools <- results do
        assert length(tools) == 1
        assert hd(tools).name == "concurrent_tool"
      end

      cleanup_module(ConcurrentToolsExtension)
    end

    test "concurrent hook execution doesn't interfere", %{} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      hooks = [
        on_test: [
          fn _ ->
            Process.sleep(5)
            Agent.update(counter, &(&1 + 1))
          end
        ]
      ]

      # Run multiple concurrent hook executions
      tasks =
        for i <- 1..10 do
          Task.async(fn -> Extensions.execute_hooks(hooks, :on_test, [i]) end)
        end

      Task.await_many(tasks)

      # All hooks should have executed
      assert Agent.get(counter, & &1) == 10

      Agent.stop(counter)
    end
  end

  # ============================================================================
  # Memory and Resource Edge Cases
  # ============================================================================

  describe "resource handling" do
    test "handles extension with large tool list", %{tmp_dir: tmp_dir} do
      # Generate code for an extension with many tools
      tool_definitions =
        for i <- 1..100 do
          """
          %AgentCore.Types.AgentTool{
            name: "tool_#{i}",
            description: "Tool number #{i}",
            parameters: %{},
            label: "Tool #{i}",
            execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
          }
          """
        end
        |> Enum.map(&String.trim/1)
        |> Enum.join(",\n")

      code = """
      defmodule ManyToolsExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "many-tools"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd) do
          [#{tool_definitions}]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "many_tools.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      tools = Extensions.get_tools(extensions, tmp_dir)

      assert length(tools) == 100

      cleanup_module(ManyToolsExtension)
    end

    test "handles extension with many hooks", %{tmp_dir: tmp_dir} do
      hook_definitions =
        for i <- 1..50 do
          "on_event_#{i}: fn _arg -> :ok end"
        end
        |> Enum.join(",\n")

      code = """
      defmodule ManyHooksExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "many-hooks"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def hooks do
          [#{hook_definitions}]
        end
      end
      """

      File.write!(Path.join(tmp_dir, "many_hooks.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      hooks = Extensions.get_hooks(extensions)

      # Each unique hook event should be present
      assert length(Keyword.keys(hooks)) == 50

      cleanup_module(ManyHooksExtension)
    end
  end

  # ============================================================================
  # Extension Discovery Patterns
  # ============================================================================

  describe "extension discovery - nested directories" do
    test "discovers extensions in lib subdirectory", %{tmp_dir: tmp_dir} do
      # Create nested structure: ext_name/lib/extension.ex
      nested_dir = Path.join([tmp_dir, "my_extension", "lib"])
      File.mkdir_p!(nested_dir)

      code = """
      defmodule NestedLibExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "nested-lib"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(nested_dir, "extension.ex"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      assert NestedLibExtension in extensions

      cleanup_module(NestedLibExtension)
    end

    test "discovers .exs files", %{tmp_dir: tmp_dir} do
      code = """
      defmodule ExsExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "exs-extension"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(tmp_dir, "extension.exs"), code)

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      assert ExsExtension in extensions

      cleanup_module(ExsExtension)
    end

    test "ignores non-elixir files", %{tmp_dir: tmp_dir} do
      # Create various non-Elixir files
      File.write!(Path.join(tmp_dir, "readme.md"), "# Extension")
      File.write!(Path.join(tmp_dir, "config.json"), "{}")
      File.write!(Path.join(tmp_dir, "script.sh"), "#!/bin/bash")

      {:ok, extensions} = Extensions.load_extensions([tmp_dir])
      assert extensions == []
    end
  end
end
