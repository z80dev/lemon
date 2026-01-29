defmodule CodingAgent.SessionExtensionsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session
  alias CodingAgent.SettingsManager

  alias Ai.Types.{
    AssistantMessage,
    TextContent,
    ToolCall,
    Usage,
    Cost,
    Model,
    ModelCost
  }

  alias AgentCore.Types.{AgentTool, AgentToolResult}

  @moduletag :tmp_dir

  # ============================================================================
  # Test Mocks and Helpers
  # ============================================================================

  defp mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-1"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: Keyword.get(opts, :base_url, "https://api.mock.test"),
      reasoning: Keyword.get(opts, :reasoning, false),
      input: Keyword.get(opts, :input, [:text]),
      cost: Keyword.get(opts, :cost, %ModelCost{input: 0.01, output: 0.03}),
      context_window: Keyword.get(opts, :context_window, 128_000),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      headers: Keyword.get(opts, :headers, %{}),
      compat: Keyword.get(opts, :compat, nil)
    }
  end

  defp mock_usage(opts \\ []) do
    %Usage{
      input: Keyword.get(opts, :input, 100),
      output: Keyword.get(opts, :output, 50),
      cache_read: Keyword.get(opts, :cache_read, 0),
      cache_write: Keyword.get(opts, :cache_write, 0),
      total_tokens: Keyword.get(opts, :total_tokens, 150),
      cost: Keyword.get(opts, :cost, %Cost{input: 0.001, output: 0.0015, total: 0.0025})
    }
  end

  defp assistant_message(text, opts \\ []) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      model: Keyword.get(opts, :model, "mock-model-1"),
      usage: Keyword.get(opts, :usage, mock_usage()),
      stop_reason: Keyword.get(opts, :stop_reason, :stop),
      error_message: Keyword.get(opts, :error_message, nil),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    }
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      # Emit start event
      Ai.EventStream.push(stream, {:start, response})

      # Emit text deltas for each text content
      response.content
      |> Enum.with_index()
      |> Enum.each(fn {content, idx} ->
        case content do
          %TextContent{text: text} ->
            Ai.EventStream.push(stream, {:text_start, idx, response})
            Ai.EventStream.push(stream, {:text_delta, idx, text, response})
            Ai.EventStream.push(stream, {:text_end, idx, response})

          %ToolCall{} = tool_call ->
            Ai.EventStream.push(stream, {:tool_call_start, idx, tool_call, response})
            Ai.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})

          _ ->
            :ok
        end
      end)

      # Emit done event
      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end

  defp mock_stream_fn_single(response) do
    fn _model, _context, _options ->
      {:ok, response_to_event_stream(response)}
    end
  end

  defp default_opts(overrides) do
    Keyword.merge(
      [
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("Hello!"))
      ],
      overrides
    )
  end

  defp start_session(opts) do
    opts = default_opts(opts)
    {:ok, session} = Session.start_link(opts)
    session
  end

  defp wait_for_streaming_complete(session) do
    state = Session.get_state(session)

    if state.is_streaming do
      Process.sleep(10)
      wait_for_streaming_complete(session)
    else
      :ok
    end
  end

  defp create_extension_file(tmp_dir, module_name, opts \\ []) do
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
      def tools(_cwd) do
        #{tools}
      end

      @impl true
      def hooks do
        #{hooks}
      end
    end
    """

    ext_dir = Path.join(tmp_dir, ".lemon/extensions")
    File.mkdir_p!(ext_dir)
    file_path = Path.join(ext_dir, "#{String.downcase(module_name)}.ex")
    File.write!(file_path, extension_code)

    # Return the module - use Module.concat to get the proper Elixir module atom
    Module.concat([module_name])
  end

  defp cleanup_module(module) do
    :code.purge(module)
    :code.delete(module)
  end

  # ============================================================================
  # Extension Loading Tests
  # ============================================================================

  describe "extensions loading on session start" do
    test "loads extensions from project extensions directory", %{tmp_dir: tmp_dir} do
      module = create_extension_file(tmp_dir, "TestLoadingExtension")

      session = start_session(cwd: tmp_dir)
      state = Session.get_state(session)

      assert is_list(state.extensions)
      assert module in state.extensions

      cleanup_module(module)
    end

    test "state includes hooks from loaded extensions", %{tmp_dir: tmp_dir} do
      hooks_code = """
      [
        on_message_start: fn _msg -> :ok end,
        on_agent_end: fn _msgs -> :ok end
      ]
      """

      module = create_extension_file(tmp_dir, "TestHooksExtension", hooks: hooks_code)

      session = start_session(cwd: tmp_dir)
      state = Session.get_state(session)

      assert is_list(state.hooks)
      assert Keyword.has_key?(state.hooks, :on_message_start)
      assert Keyword.has_key?(state.hooks, :on_agent_end)

      cleanup_module(module)
    end

    test "session starts with empty extensions list when no extensions exist", %{tmp_dir: tmp_dir} do
      # tmp_dir has no extensions
      session = start_session(cwd: tmp_dir)
      state = Session.get_state(session)

      assert state.extensions == []
      assert state.hooks == []
    end
  end

  # ============================================================================
  # Extension Tools Integration Tests
  # ============================================================================

  describe "extension tools integration" do
    test "extension tools are merged into session tools list", %{tmp_dir: tmp_dir} do
      tools_code = """
      [
        %AgentCore.Types.AgentTool{
          name: "ext_tool",
          description: "An extension tool",
          parameters: %{},
          label: "Extension Tool",
          execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
        }
      ]
      """

      module = create_extension_file(tmp_dir, "TestToolsExtension", tools: tools_code)

      session = start_session(cwd: tmp_dir)
      state = Session.get_state(session)

      tool_names = Enum.map(state.tools, & &1.name)

      # Default tools should still be present
      assert "read" in tool_names
      assert "write" in tool_names
      assert "edit" in tool_names
      assert "bash" in tool_names

      # Extension tool should be added
      assert "ext_tool" in tool_names

      cleanup_module(module)
    end

    test "custom tools option takes precedence for base tools", %{tmp_dir: tmp_dir} do
      # Extension adds a tool
      tools_code = """
      [
        %AgentCore.Types.AgentTool{
          name: "ext_tool",
          description: "An extension tool",
          parameters: %{},
          label: "Extension Tool",
          execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{content: []} end
        }
      ]
      """

      module = create_extension_file(tmp_dir, "TestCustomToolsExtension", tools: tools_code)

      # Create a custom tool
      custom_tool = %AgentTool{
        name: "custom_only",
        description: "A custom tool",
        parameters: %{},
        label: "Custom Only",
        execute: fn _, _, _, _ -> %AgentToolResult{content: []} end
      }

      session = start_session(cwd: tmp_dir, tools: [custom_tool])
      state = Session.get_state(session)

      tool_names = Enum.map(state.tools, & &1.name)

      # Custom tool should be present
      assert "custom_only" in tool_names

      # Extension tool should still be added
      assert "ext_tool" in tool_names

      # Default tools should NOT be present (replaced by custom)
      refute "read" in tool_names

      cleanup_module(module)
    end
  end

  # ============================================================================
  # Hook Execution Tests
  # ============================================================================

  describe "hook execution on agent events" do
    test "hooks are loaded from extensions and stored in session state", %{tmp_dir: tmp_dir} do
      hooks_code = """
      [
        on_message_start: fn _msg -> :ok end,
        on_message_end: fn _msg -> :ok end,
        on_tool_execution_start: fn _id, _name, _args -> :ok end,
        on_tool_execution_end: fn _id, _name, _result, _error -> :ok end,
        on_agent_end: fn _messages -> :ok end
      ]
      """

      module = create_extension_file(tmp_dir, "TestAllHooksExtension", hooks: hooks_code)

      session = start_session(cwd: tmp_dir)
      state = Session.get_state(session)

      # Verify all hooks are present in state
      assert Keyword.has_key?(state.hooks, :on_message_start)
      assert Keyword.has_key?(state.hooks, :on_message_end)
      assert Keyword.has_key?(state.hooks, :on_tool_execution_start)
      assert Keyword.has_key?(state.hooks, :on_tool_execution_end)
      assert Keyword.has_key?(state.hooks, :on_agent_end)

      # Each hook should be a list of functions
      assert is_list(state.hooks[:on_message_start])
      assert length(state.hooks[:on_message_start]) == 1

      cleanup_module(module)
    end

    test "multiple extensions can register hooks for the same event", %{tmp_dir: tmp_dir} do
      hooks_code1 = """
      [
        on_message_end: fn _msg -> :first end
      ]
      """

      hooks_code2 = """
      [
        on_message_end: fn _msg -> :second end
      ]
      """

      module1 = create_extension_file(tmp_dir, "TestHook1Extension", hooks: hooks_code1)

      # Create second extension
      ext_dir = Path.join(tmp_dir, ".lemon/extensions")
      extension_code2 = """
      defmodule TestHook2Extension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "testhook2extension"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(_cwd), do: []

        @impl true
        def hooks do
          #{hooks_code2}
        end
      end
      """
      File.write!(Path.join(ext_dir, "testhook2extension.ex"), extension_code2)
      module2 = Module.concat(["TestHook2Extension"])

      session = start_session(cwd: tmp_dir)
      state = Session.get_state(session)

      # Should have two on_message_end hooks
      assert length(state.hooks[:on_message_end]) == 2

      cleanup_module(module1)
      cleanup_module(module2)
    end

    test "Extensions.execute_hooks handles errors gracefully" do
      # Test the execute_hooks function directly
      hooks = [
        on_test: [
          fn _arg -> raise "Boom!" end,
          fn _arg -> :ok end
        ]
      ]

      # Should not raise
      assert :ok = CodingAgent.Extensions.execute_hooks(hooks, :on_test, ["arg"])
    end

    test "Extensions.execute_hooks calls all hooks for an event" do
      {:ok, tracker} = Agent.start_link(fn -> [] end)

      hooks = [
        on_test: [
          fn arg -> Agent.update(tracker, &[{:hook1, arg} | &1]) end,
          fn arg -> Agent.update(tracker, &[{:hook2, arg} | &1]) end
        ]
      ]

      :ok = CodingAgent.Extensions.execute_hooks(hooks, :on_test, ["test_value"])

      calls = Agent.get(tracker, & &1)
      assert {:hook1, "test_value"} in calls
      assert {:hook2, "test_value"} in calls

      Agent.stop(tracker)
    end

    test "hook errors do not crash the session", %{tmp_dir: tmp_dir} do
      hooks_code = """
      [
        on_message_end: fn _msg -> raise "Hook error!" end
      ]
      """

      module = create_extension_file(tmp_dir, "TestErrorHookExtension", hooks: hooks_code)

      session = start_session(cwd: tmp_dir)

      # This should not crash despite the hook error
      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      # Session should still be functional
      state = Session.get_state(session)
      assert state.is_streaming == false

      cleanup_module(module)
    end
  end

  # ============================================================================
  # Extension Paths from Settings Tests
  # ============================================================================

  describe "extension paths from settings" do
    test "loads extensions from settings_manager.extension_paths", %{tmp_dir: tmp_dir} do
      # Create an extension in a custom directory
      custom_ext_dir = Path.join(tmp_dir, "custom_extensions")
      File.mkdir_p!(custom_ext_dir)

      extension_code = """
      defmodule CustomPathExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "custom-path-extension"

        @impl true
        def version, do: "1.0.0"
      end
      """

      File.write!(Path.join(custom_ext_dir, "custom_path_extension.ex"), extension_code)

      # Create settings with custom extension path
      settings = %SettingsManager{
        extension_paths: [custom_ext_dir]
      }

      session = start_session(cwd: tmp_dir, settings_manager: settings)
      state = Session.get_state(session)

      assert CustomPathExtension in state.extensions

      cleanup_module(CustomPathExtension)
    end
  end
end
