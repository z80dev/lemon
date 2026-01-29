defmodule CodingAgent.SessionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session
  alias CodingAgent.SessionManager
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

  defp echo_tool do
    %AgentTool{
      name: "echo",
      description: "Echoes the input text back",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{"type" => "string", "description" => "The text to echo"}
        },
        "required" => ["text"]
      },
      label: "Echo",
      execute: fn _id, %{"text" => text}, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "Echo: #{text}"}],
          details: nil
        }
      end
    }
  end

  defp add_tool do
    %AgentTool{
      name: "add",
      description: "Adds two numbers together",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number", "description" => "First number"},
          "b" => %{"type" => "number", "description" => "Second number"}
        },
        "required" => ["a", "b"]
      },
      label: "Add",
      execute: fn _id, %{"a" => a, "b" => b}, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "#{a + b}"}],
          details: %{sum: a + b}
        }
      end
    }
  end

  defp default_opts(overrides) do
    Keyword.merge(
      [
        cwd: System.tmp_dir!(),
        model: mock_model(),
        # Use a mock stream function that returns a simple response
        stream_fn: mock_stream_fn_single(assistant_message("Hello!"))
      ],
      overrides
    )
  end

  defp start_session(opts \\ []) do
    opts = default_opts(opts)
    {:ok, session} = Session.start_link(opts)
    session
  end

  defp wait_for_streaming_complete(session) do
    # Poll until not streaming
    state = Session.get_state(session)

    if state.is_streaming do
      Process.sleep(10)
      wait_for_streaming_complete(session)
    else
      :ok
    end
  end

  # ============================================================================
  # Initialization Tests
  # ============================================================================

  describe "start_link/1 with required opts" do
    test "starts with cwd and model" do
      session = start_session()
      state = Session.get_state(session)

      assert state.cwd == System.tmp_dir!()
      assert state.model.id == "mock-model-1"
    end

    test "fails without cwd" do
      # Session.start_link crashes the spawned process, so we need to catch the exit
      Process.flag(:trap_exit, true)
      result = Session.start_link(model: mock_model())

      case result do
        {:error, {:key_not_found, :cwd}} ->
          :ok

        {:error, _reason} ->
          :ok

        {:ok, pid} ->
          # Should receive EXIT if process crashed during init
          assert_receive {:EXIT, ^pid, _reason}, 100
      end

      Process.flag(:trap_exit, false)
    end

    test "fails without model" do
      # Model is resolved from settings; if not in settings, it raises ArgumentError
      Process.flag(:trap_exit, true)
      result = Session.start_link(cwd: System.tmp_dir!())

      case result do
        {:error, _reason} ->
          :ok

        {:ok, pid} ->
          # Should receive EXIT if process crashed during init
          assert_receive {:EXIT, ^pid, _reason}, 100
      end

      Process.flag(:trap_exit, false)
    end

    test "starts with custom GenServer name" do
      name = :"test_session_#{:erlang.unique_integer()}"
      opts = default_opts(name: name)
      {:ok, _pid} = Session.start_link(opts)

      state = Session.get_state(name)
      assert state.cwd == System.tmp_dir!()
    end
  end

  describe "start_link/1 with optional opts" do
    test "accepts custom system_prompt" do
      session = start_session(system_prompt: "You are a test assistant.")
      state = Session.get_state(session)

      # Custom system_prompt is included (may also have loaded CLAUDE.md content)
      assert String.contains?(state.system_prompt, "You are a test assistant.")
    end

    test "accepts custom thinking_level" do
      session = start_session(thinking_level: :high)
      state = Session.get_state(session)

      assert state.thinking_level == :high
    end

    test "accepts custom tools" do
      custom_tools = [echo_tool(), add_tool()]
      session = start_session(tools: custom_tools)
      state = Session.get_state(session)

      assert length(state.tools) == 2
      tool_names = Enum.map(state.tools, & &1.name)
      assert "echo" in tool_names
      assert "add" in tool_names
    end

    test "defaults thinking_level to :off" do
      session = start_session()
      state = Session.get_state(session)

      assert state.thinking_level == :off
    end

    test "system_prompt is a string (may include loaded CLAUDE.md)" do
      session = start_session()
      state = Session.get_state(session)

      # System prompt is now composed from ResourceLoader, so it may contain
      # CLAUDE.md content from the home directory or project
      assert is_binary(state.system_prompt)
    end

    test "builds default tools when none provided" do
      session = start_session()
      state = Session.get_state(session)

      # Default tools are read, write, edit, bash
      assert length(state.tools) == 4
      tool_names = Enum.map(state.tools, & &1.name)
      assert "read" in tool_names
      assert "write" in tool_names
      assert "edit" in tool_names
      assert "bash" in tool_names
    end
  end

  describe "start_link/1 loading from session file" do
    @tag :tmp_dir
    test "loads existing session from file", %{tmp_dir: tmp_dir} do
      # Create and save a session with some messages
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{"role" => "user", "content" => "Hello", "timestamp" => 1})
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Hi there!"}],
          "timestamp" => 2
        })

      session_file = Path.join(tmp_dir, "test_session.jsonl")
      :ok = SessionManager.save_to_file(session_file, session_manager)

      # Start session from the file
      session = start_session(session_file: session_file, cwd: tmp_dir)
      messages = Session.get_messages(session)

      assert length(messages) == 2
    end

    @tag :tmp_dir
    test "creates new session if file doesn't exist", %{tmp_dir: tmp_dir} do
      non_existent_file = Path.join(tmp_dir, "non_existent.jsonl")

      session = start_session(session_file: non_existent_file, cwd: tmp_dir)
      messages = Session.get_messages(session)

      assert messages == []
    end

    @tag :tmp_dir
    test "creates new session if file is invalid", %{tmp_dir: tmp_dir} do
      invalid_file = Path.join(tmp_dir, "invalid.jsonl")
      File.write!(invalid_file, "not valid json")

      session = start_session(session_file: invalid_file, cwd: tmp_dir)
      messages = Session.get_messages(session)

      assert messages == []
    end
  end

  describe "start_link/1 settings manager integration" do
    test "loads settings from cwd" do
      session = start_session()
      state = Session.get_state(session)

      # Settings manager should be loaded
      assert state.settings_manager != nil
      assert %SettingsManager{} = state.settings_manager
    end

    test "accepts custom settings_manager for testing" do
      custom_settings = %SettingsManager{
        default_thinking_level: :medium,
        compaction_enabled: false
      }

      session = start_session(settings_manager: custom_settings)
      state = Session.get_state(session)

      assert state.settings_manager.default_thinking_level == :medium
      assert state.settings_manager.compaction_enabled == false
    end
  end

  # ============================================================================
  # Prompt/Streaming Tests
  # ============================================================================

  describe "prompt/3" do
    test "sending a prompt starts streaming" do
      session = start_session()

      :ok = Session.prompt(session, "Hello!")

      # Immediately check streaming state
      state = Session.get_state(session)
      # Note: streaming might complete very quickly with mocks
      assert state.is_streaming == true or length(Session.get_messages(session)) > 0
    end

    test "returns error when already streaming" do
      # Use a slow response to ensure we're still streaming
      slow_stream_fn = fn model, context, options ->
        Process.sleep(100)
        mock_stream_fn_single(assistant_message("Slow response")).(model, context, options)
      end

      session = start_session(stream_fn: slow_stream_fn)

      :ok = Session.prompt(session, "First prompt")
      result = Session.prompt(session, "Second prompt")

      assert result == {:error, :already_streaming}
    end

    test "can send prompt with images" do
      session = start_session()

      images = [
        %{data: "base64data", mime_type: "image/png"}
      ]

      :ok = Session.prompt(session, "What's in this image?", images: images)
      wait_for_streaming_complete(session)

      messages = Session.get_messages(session)
      assert length(messages) >= 1
    end

    test "increments turn_index on prompt" do
      session = start_session()
      state_before = Session.get_state(session)

      :ok = Session.prompt(session, "Hello!")
      state_after = Session.get_state(session)

      assert state_after.turn_index == state_before.turn_index + 1
    end
  end

  describe "event broadcasting" do
    test "events are broadcast to subscribers" do
      session = start_session()
      _unsub = Session.subscribe(session)

      :ok = Session.prompt(session, "Hello!")

      # Should receive at least one event
      assert_receive {:session_event, _event}, 1000
    end

    test "multiple subscribers receive events" do
      session = start_session()

      # Subscribe from test process
      _unsub = Session.subscribe(session)

      # Subscribe from another process
      parent = self()

      spawn(fn ->
        _unsub2 = Session.subscribe(session)
        send(parent, :subscribed)

        receive do
          {:session_event, event} ->
            send(parent, {:other_received, event})
        after
          1000 -> send(parent, :timeout)
        end
      end)

      # Wait for spawn to subscribe
      assert_receive :subscribed, 500

      :ok = Session.prompt(session, "Hello!")

      # Both should receive events
      assert_receive {:session_event, _event}, 1000
      assert_receive {:other_received, _event}, 1000
    end
  end

  # ============================================================================
  # Steering and Follow-up Tests
  # ============================================================================

  describe "steer/2" do
    test "steering messages are queued" do
      session = start_session()

      :ok = Session.steer(session, "Stop what you're doing")
      state = Session.get_state(session)

      # Queue should have one message
      assert :queue.len(state.steering_queue) == 1
    end

    test "multiple steering messages are queued" do
      session = start_session()

      :ok = Session.steer(session, "First steer")
      :ok = Session.steer(session, "Second steer")
      state = Session.get_state(session)

      assert :queue.len(state.steering_queue) == 2
    end
  end

  describe "follow_up/2" do
    test "follow-up messages are queued" do
      session = start_session()

      :ok = Session.follow_up(session, "When you're done, do this")
      state = Session.get_state(session)

      assert :queue.len(state.follow_up_queue) == 1
    end

    test "multiple follow-up messages are queued" do
      session = start_session()

      :ok = Session.follow_up(session, "First follow-up")
      :ok = Session.follow_up(session, "Second follow-up")
      state = Session.get_state(session)

      assert :queue.len(state.follow_up_queue) == 2
    end
  end

  describe "queue consumption on agent_end" do
    test "steering queue is cleared after agent ends" do
      session = start_session()

      # Start a prompt first
      :ok = Session.prompt(session, "Hello!")

      wait_for_streaming_complete(session)
      state = Session.get_state(session)

      # Steering queue should be empty after run completes
      # (steering is cleared in handle_agent_event for :agent_end)
      assert :queue.len(state.steering_queue) == 0
    end
  end

  # ============================================================================
  # Subscription Tests
  # ============================================================================

  describe "subscribe/1" do
    test "returns unsubscribe function" do
      session = start_session()
      unsubscribe = Session.subscribe(session)

      assert is_function(unsubscribe, 0)
    end

    test "unsubscribe stops events" do
      session = start_session()
      unsubscribe = Session.subscribe(session)

      # Unsubscribe
      :ok = unsubscribe.()

      # Now send a prompt
      :ok = Session.prompt(session, "Hello!")

      # Should not receive events
      refute_receive {:session_event, _event}, 100
    end

    test "dead subscribers are cleaned up" do
      session = start_session()

      # Spawn a process that subscribes then dies
      parent = self()

      pid =
        spawn(fn ->
          _unsub = Session.subscribe(session)
          send(parent, :subscribed)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :subscribed, 500

      # Get initial listener count
      state_before = Session.get_state(session)
      initial_count = length(state_before.event_listeners)

      # Kill the subscriber
      send(pid, :die)
      Process.sleep(50)

      # Trigger cleanup by sending a message that causes handle_info(:DOWN, ...)
      # The cleanup happens automatically when process dies
      state_after = Session.get_state(session)

      assert length(state_after.event_listeners) < initial_count
    end
  end

  # ============================================================================
  # Compaction Tests
  # ============================================================================

  describe "compact/2" do
    @tag :tmp_dir
    test "manual compaction with custom summary", %{tmp_dir: tmp_dir} do
      # Create a session with some messages first
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => String.duplicate("a", 4000),
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => String.duplicate("b", 4000)}],
          "timestamp" => 2
        })
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => String.duplicate("c", 4000),
          "timestamp" => 3
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => String.duplicate("d", 4000)}],
          "timestamp" => 4
        })

      session_file = Path.join(tmp_dir, "compact_test.jsonl")
      :ok = SessionManager.save_to_file(session_file, session_manager)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Compaction may fail if not enough tokens - that's acceptable
      result = Session.compact(session, summary: "Custom summary", force: true)

      case result do
        :ok ->
          state = Session.get_state(session)
          # After compaction, session_manager should have a compaction entry
          assert state.session_manager != nil

        {:error, :cannot_compact} ->
          # This is acceptable if not enough content to compact
          :ok

        {:error, {:unknown_api, :mock}} ->
          # This is acceptable in test environment with mock API
          :ok
      end
    end

    test "compact returns error when not enough content" do
      session = start_session()
      # Fresh session with no messages
      result = Session.compact(session, force: true)

      assert result == {:error, :cannot_compact}
    end
  end

  # ============================================================================
  # Tree Navigation Tests
  # ============================================================================

  describe "navigate_tree/3" do
    @tag :tmp_dir
    test "navigates to different entry", %{tmp_dir: tmp_dir} do
      # Create a session with entries
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "First message",
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "First response"}],
          "timestamp" => 2
        })

      [first_entry, _second_entry] = session_manager.entries

      session_file = Path.join(tmp_dir, "nav_test.jsonl")
      :ok = SessionManager.save_to_file(session_file, session_manager)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Navigate to first entry
      :ok = Session.navigate_tree(session, first_entry.id)

      state = Session.get_state(session)
      assert state.session_manager.leaf_id == first_entry.id
    end

    @tag :tmp_dir
    test "messages are rebuilt from new position", %{tmp_dir: tmp_dir} do
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "First",
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Second"}],
          "timestamp" => 2
        })
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "Third",
          "timestamp" => 3
        })

      [first_entry, _second_entry, _third_entry] = session_manager.entries

      session_file = Path.join(tmp_dir, "rebuild_test.jsonl")
      :ok = SessionManager.save_to_file(session_file, session_manager)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Initially should have 3 messages
      initial_messages = Session.get_messages(session)
      assert length(initial_messages) == 3

      # Navigate to first entry - should rebuild with only 1 message
      :ok = Session.navigate_tree(session, first_entry.id)

      messages = Session.get_messages(session)
      assert length(messages) == 1
    end

    test "returns error on invalid entry_id" do
      session = start_session()

      result = Session.navigate_tree(session, "nonexistent-entry-id")

      assert result == {:error, :entry_not_found}
    end
  end

  # ============================================================================
  # State Management Tests
  # ============================================================================

  describe "get_state/1" do
    test "returns current state" do
      session = start_session()
      state = Session.get_state(session)

      assert %Session{} = state
      assert state.cwd == System.tmp_dir!()
      assert state.is_streaming == false
    end
  end

  describe "get_stats/1" do
    test "returns statistics" do
      session = start_session()
      stats = Session.get_stats(session)

      assert is_map(stats)
      assert Map.has_key?(stats, :message_count)
      assert Map.has_key?(stats, :turn_count)
      assert Map.has_key?(stats, :is_streaming)
      assert Map.has_key?(stats, :session_id)
      assert Map.has_key?(stats, :cwd)
      assert Map.has_key?(stats, :model)
      assert Map.has_key?(stats, :thinking_level)
    end

    test "message_count reflects actual messages" do
      session = start_session()

      stats_before = Session.get_stats(session)
      assert stats_before.message_count == 0

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      stats_after = Session.get_stats(session)
      assert stats_after.message_count > 0
    end
  end

  describe "reset/1" do
    test "clears state" do
      session = start_session()

      # Add a message
      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      messages_before = Session.get_messages(session)
      assert length(messages_before) > 0

      # Reset
      :ok = Session.reset(session)

      messages_after = Session.get_messages(session)
      assert messages_after == []

      state = Session.get_state(session)
      assert state.turn_index == 0
      assert state.is_streaming == false
    end

    test "clears steering and follow-up queues" do
      session = start_session()

      :ok = Session.steer(session, "Steer")
      :ok = Session.follow_up(session, "Follow-up")

      :ok = Session.reset(session)
      state = Session.get_state(session)

      assert :queue.len(state.steering_queue) == 0
      assert :queue.len(state.follow_up_queue) == 0
    end
  end

  describe "save/1" do
    @tag :tmp_dir
    test "persists session to disk", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      # Add some content
      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      # Save
      :ok = Session.save(session)

      state = Session.get_state(session)
      assert state.session_file != nil
      assert File.exists?(state.session_file)
    end

    @tag :tmp_dir
    test "uses session_file if already set", %{tmp_dir: tmp_dir} do
      session_file = Path.join(tmp_dir, "explicit_session.jsonl")
      # Create an empty session file first
      File.write!(session_file, "")

      session = start_session(cwd: tmp_dir, session_file: session_file)

      :ok = Session.save(session)

      assert File.exists?(session_file)
      # File should have content now
      content = File.read!(session_file)
      assert String.length(content) > 0
    end
  end

  # ============================================================================
  # Model/Thinking Level Tests
  # ============================================================================

  describe "switch_model/2" do
    test "changes the model" do
      session = start_session()

      new_model = mock_model(id: "new-model-id", name: "New Model")
      :ok = Session.switch_model(session, new_model)

      state = Session.get_state(session)
      assert state.model.id == "new-model-id"
    end

    test "records model change in session manager" do
      session = start_session()

      new_model = mock_model(id: "changed-model")
      :ok = Session.switch_model(session, new_model)

      state = Session.get_state(session)

      # Should have a model_change entry
      model_changes =
        Enum.filter(state.session_manager.entries, &(&1.type == :model_change))

      assert length(model_changes) == 1
    end
  end

  describe "set_thinking_level/2" do
    test "changes the thinking level" do
      session = start_session(thinking_level: :off)

      :ok = Session.set_thinking_level(session, :high)

      state = Session.get_state(session)
      assert state.thinking_level == :high
    end

    test "records thinking level change in session manager" do
      session = start_session()

      :ok = Session.set_thinking_level(session, :medium)

      state = Session.get_state(session)

      thinking_changes =
        Enum.filter(state.session_manager.entries, &(&1.type == :thinking_level_change))

      assert length(thinking_changes) == 1
      assert hd(thinking_changes).thinking_level == :medium
    end
  end

  # ============================================================================
  # Abort Tests
  # ============================================================================

  describe "abort/1" do
    test "abort can be called without error" do
      session = start_session()

      # Should not raise even when not streaming
      :ok = Session.abort(session)
    end

    test "abort stops streaming" do
      # Use a slow stream to ensure we can abort it
      slow_stream_fn = fn model, context, options ->
        Process.sleep(500)
        mock_stream_fn_single(assistant_message("Slow response")).(model, context, options)
      end

      session = start_session(stream_fn: slow_stream_fn)

      :ok = Session.prompt(session, "Hello!")
      # Give it time to start
      Process.sleep(50)

      :ok = Session.abort(session)

      # Wait a bit and check streaming stopped
      Process.sleep(100)

      # After abort, is_streaming should eventually be false
      # (may need to wait for cleanup)
      wait_for_streaming_complete(session)
      final_state = Session.get_state(session)
      assert final_state.is_streaming == false
    end
  end

  # ============================================================================
  # get_messages/1 Tests
  # ============================================================================

  describe "get_messages/1" do
    test "returns empty list for new session" do
      session = start_session()
      messages = Session.get_messages(session)

      assert messages == []
    end

    test "returns messages after prompting" do
      session = start_session()

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      messages = Session.get_messages(session)
      # Should have at least one message (user message is included in prompt call,
      # assistant response may or may not be added depending on stream completion)
      assert length(messages) >= 1
    end
  end

  # ============================================================================
  # UI Notification Tests
  # ============================================================================

  describe "compact/2 UI notifications" do
    @tag :tmp_dir
    test "shows working message during compaction", %{tmp_dir: tmp_dir} do
      # Start a mock UI tracker with unique name (for parallel test execution)
      tracker_name = :"ui_compact_#{:erlang.unique_integer()}"
      tracker = CodingAgent.Test.MockUI.start_tracker(tracker_name)
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      # Create UI context with mock
      ui_context = CodingAgent.UI.Context.new(CodingAgent.Test.MockUI)

      # Create a session with some messages first
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => String.duplicate("a", 4000),
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => String.duplicate("b", 4000)}],
          "timestamp" => 2
        })
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => String.duplicate("c", 4000),
          "timestamp" => 3
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => String.duplicate("d", 4000)}],
          "timestamp" => 4
        })

      session_file = Path.join(tmp_dir, "ui_compact_test.jsonl")
      :ok = SessionManager.save_to_file(session_file, session_manager)

      session = start_session(session_file: session_file, cwd: tmp_dir, ui_context: ui_context)

      # Attempt compaction (may fail if not enough tokens, that's ok)
      _result = Session.compact(session, summary: "Test summary", force: true)

      # Check UI calls were made
      calls = CodingAgent.Test.MockUI.get_calls(tracker)

      # Should have called set_working_message with "Compacting context..."
      assert {:set_working_message, ["Compacting context..."]} in calls

      # Should have called set_working_message with nil (to clear it)
      assert {:set_working_message, [nil]} in calls

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end

    @tag :tmp_dir
    test "notifies on successful compaction", %{tmp_dir: tmp_dir} do
      tracker_name = :"ui_compact_notify_#{:erlang.unique_integer()}"
      tracker = CodingAgent.Test.MockUI.start_tracker(tracker_name)
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      ui_context = CodingAgent.UI.Context.new(CodingAgent.Test.MockUI)

      # Create a session with some messages
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => String.duplicate("a", 4000),
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => String.duplicate("b", 4000)}],
          "timestamp" => 2
        })
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => String.duplicate("c", 4000),
          "timestamp" => 3
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => String.duplicate("d", 4000)}],
          "timestamp" => 4
        })

      session_file = Path.join(tmp_dir, "ui_compact_notify_test.jsonl")
      :ok = SessionManager.save_to_file(session_file, session_manager)

      session = start_session(session_file: session_file, cwd: tmp_dir, ui_context: ui_context)

      result = Session.compact(session, summary: "Test summary", force: true)

      calls = CodingAgent.Test.MockUI.get_calls(tracker)

      case result do
        :ok ->
          # On success, should notify with info
          assert {:notify, ["Context compacted", :info]} in calls

        {:error, :cannot_compact} ->
          # On cannot_compact, no notify but working message should be cleared
          assert {:set_working_message, [nil]} in calls

        {:error, _reason} ->
          # On other errors, should notify with error
          error_calls = Enum.filter(calls, fn
            {:notify, [msg, :error]} when is_binary(msg) -> String.contains?(msg, "Compaction failed")
            _ -> false
          end)
          assert length(error_calls) > 0
      end

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end

    test "clears working message when compaction fails (cannot compact)" do
      tracker_name = :"ui_compact_fail_#{:erlang.unique_integer()}"
      tracker = CodingAgent.Test.MockUI.start_tracker(tracker_name)
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      ui_context = CodingAgent.UI.Context.new(CodingAgent.Test.MockUI)

      # Fresh session with no messages - compaction will fail
      session = start_session(ui_context: ui_context)
      result = Session.compact(session, force: true)

      assert result == {:error, :cannot_compact}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)

      # Should have shown working message
      assert {:set_working_message, ["Compacting context..."]} in calls

      # Should have cleared working message
      assert {:set_working_message, [nil]} in calls

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end
  end

  describe "summarize_current_branch/2 UI notifications" do
    @tag :tmp_dir
    test "shows working message during branch summarization", %{tmp_dir: tmp_dir} do
      tracker_name = :"ui_summarize_#{:erlang.unique_integer()}"
      tracker = CodingAgent.Test.MockUI.start_tracker(tracker_name)
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      ui_context = CodingAgent.UI.Context.new(CodingAgent.Test.MockUI)

      # Create a session with messages to summarize
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "Hello, how are you?",
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "I'm doing well, thanks!"}],
          "timestamp" => 2
        })

      session_file = Path.join(tmp_dir, "ui_summarize_test.jsonl")
      :ok = SessionManager.save_to_file(session_file, session_manager)

      session = start_session(session_file: session_file, cwd: tmp_dir, ui_context: ui_context)

      # Attempt to summarize branch (may fail due to API, that's ok for this test)
      _result = Session.summarize_current_branch(session)

      calls = CodingAgent.Test.MockUI.get_calls(tracker)

      # Should have called set_working_message with "Summarizing branch..."
      assert {:set_working_message, ["Summarizing branch..."]} in calls

      # Should have cleared working message (either on success or failure)
      assert {:set_working_message, [nil]} in calls

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end

    test "returns error without UI notification for empty branch" do
      tracker_name = :"ui_summarize_empty_#{:erlang.unique_integer()}"
      tracker = CodingAgent.Test.MockUI.start_tracker(tracker_name)
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      ui_context = CodingAgent.UI.Context.new(CodingAgent.Test.MockUI)

      # Fresh session with no messages
      session = start_session(ui_context: ui_context)
      result = Session.summarize_current_branch(session)

      assert result == {:error, :empty_branch}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)

      # Should NOT have shown working message for empty branch
      # (we return early before showing the message)
      refute {:set_working_message, ["Summarizing branch..."]} in calls

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end
  end
end
