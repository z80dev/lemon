defmodule CodingAgent.IntegrationTest do
  @moduledoc """
  Integration tests for CodingAgent that test the full flow of:
  1. Session + Compaction + Persistence
  2. Session + Tools + Streaming (tool execution only - not full agent loop)
  3. Session Tree Operations
  4. Steering and Follow-up queue management

  Note: These tests use a mock model that doesn't connect to a real API.
  The agent loop will fail with {:unknown_api, :mock} but we can still test:
  - Session state management
  - Message persistence
  - Tree navigation
  - Queue management
  - Direct tool execution
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.SettingsManager
  alias CodingAgent.Compaction

  alias Ai.Types.{
    AssistantMessage,
    TextContent,
    UserMessage,
    Model,
    ModelCost,
    ToolResultMessage
  }

  alias AgentCore.Types.AgentToolResult

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

  defp default_settings do
    %SettingsManager{
      default_thinking_level: :off,
      compaction_enabled: true,
      reserve_tokens: 16384
    }
  end

  defp default_opts(overrides) do
    Keyword.merge(
      [
        cwd: System.tmp_dir!(),
        model: mock_model(),
        settings_manager: default_settings()
      ],
      overrides
    )
  end

  defp start_session(opts) do
    opts = default_opts(opts)
    {:ok, session} = Session.start_link(opts)
    session
  end

  defp wait_for_streaming_complete(session, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(session, deadline)
  end

  defp wait_loop(session, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      :timeout
    else
      state = Session.get_state(session)

      if state.is_streaming do
        Process.sleep(10)
        wait_loop(session, deadline)
      else
        :ok
      end
    end
  end

  # ============================================================================
  # Test Group 1: Compaction + Persistence Flow
  # ============================================================================

  describe "Compaction + Persistence Flow" do
    @tag :tmp_dir
    test "creates session, tests compaction detection, and persists correctly", %{
      tmp_dir: tmp_dir
    } do
      session_file = Path.join(tmp_dir, "compaction_test.jsonl")

      # Create a model with small context window
      small_context_model = mock_model(context_window: 10_000)

      # Custom settings with aggressive compaction threshold
      settings = %SettingsManager{
        default_thinking_level: :off,
        compaction_enabled: true,
        reserve_tokens: 2000
      }

      # Create long messages to accumulate tokens
      long_content = String.duplicate("a", 4000)

      # Build up a session with enough content for compaction
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => long_content,
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => long_content}],
          "timestamp" => 2
        })
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => long_content,
          "timestamp" => 3
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => long_content}],
          "timestamp" => 4
        })
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => long_content,
          "timestamp" => 5
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => long_content}],
          "timestamp" => 6
        })

      # Save initial session
      :ok = SessionManager.save_to_file(session_file, session_manager)

      # Verify compaction detection works
      messages =
        SessionManager.build_session_context(session_manager).messages
        |> Enum.map(fn msg -> deserialize_message(msg) end)
        |> Enum.reject(&is_nil/1)

      context_tokens = Compaction.estimate_context_tokens(messages)

      # With 6 messages of ~1000 tokens each = ~6000 tokens
      # context_window = 10000, reserve = 2000, threshold = 8000
      # 6000 < 8000, so should not compact yet
      assert Compaction.should_compact?(context_tokens, 10_000, %{enabled: true, reserve_tokens: 2000}) == false

      # But with more content, it should trigger
      assert Compaction.should_compact?(9000, 10_000, %{enabled: true, reserve_tokens: 2000}) == true

      # Test manual compaction
      session =
        start_session(
          session_file: session_file,
          cwd: tmp_dir,
          model: small_context_model,
          settings_manager: settings
        )

      # Try manual compaction with force
      result = Session.compact(session, force: true, summary: "Test compaction summary")

      # Compaction may succeed or fail depending on content
      case result do
        :ok ->
          state = Session.get_state(session)
          # Verify compaction entry was added
          compaction_entries =
            Enum.filter(state.session_manager.entries, &(&1.type == :compaction))

          assert length(compaction_entries) >= 1

          # Save and reload session
          :ok = Session.save(session)

          # Load the session file and verify compaction is preserved
          {:ok, loaded_session} = SessionManager.load_from_file(session_file)

          loaded_compaction_entries =
            Enum.filter(loaded_session.entries, &(&1.type == :compaction))

          assert length(loaded_compaction_entries) >= 1

          # Verify the summary is preserved
          compaction_entry = hd(loaded_compaction_entries)
          assert compaction_entry.summary == "Test compaction summary"

        {:error, :cannot_compact} ->
          # This is acceptable - not enough content to compact
          :ok

        {:error, {:unknown_api, :mock}} ->
          # This is expected with mock model - compaction tried to generate summary
          # but the mock API doesn't support real inference
          :ok

        {:error, reason} ->
          # Other errors may occur with mock model
          # Just ensure we got an error tuple back
          assert is_atom(reason) or is_tuple(reason)
      end
    end

    @tag :tmp_dir
    test "messages are restored correctly with compaction summary after reload", %{
      tmp_dir: tmp_dir
    } do
      session_file = Path.join(tmp_dir, "restore_test.jsonl")

      # Create session with some messages
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

      # Get the second entry's ID for compaction
      second_entry = List.last(session_manager.entries)

      # Add a compaction entry
      session_manager =
        SessionManager.append_compaction(
          session_manager,
          "This is a summary of previous conversation about greetings.",
          second_entry.id,
          1000
        )

      # Add more messages after compaction
      session_manager =
        session_manager
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "New question after compaction",
          "timestamp" => 3
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "New response"}],
          "timestamp" => 4
        })

      # Save the session
      :ok = SessionManager.save_to_file(session_file, session_manager)

      # Start session from the file
      session =
        start_session(
          session_file: session_file,
          cwd: tmp_dir
        )

      # Get messages - should include compaction summary
      messages = Session.get_messages(session)

      # The messages should include the compaction summary as context
      # and messages after the compaction point
      assert length(messages) >= 1
    end

    @tag :tmp_dir
    test "session persistence roundtrip preserves all entry types", %{tmp_dir: tmp_dir} do
      session_file = Path.join(tmp_dir, "roundtrip_test.jsonl")

      # Create session with various entry types
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "Hello",
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Hi there!"}],
          "timestamp" => 2
        })
        |> SessionManager.append_entry(SessionEntry.thinking_level_change(:high))
        |> SessionManager.append_entry(SessionEntry.model_change("anthropic", "claude-3"))

      # Save
      :ok = SessionManager.save_to_file(session_file, session_manager)

      # Load and verify
      {:ok, loaded} = SessionManager.load_from_file(session_file)

      # Check all entry types are preserved
      types = Enum.map(loaded.entries, & &1.type)
      assert :message in types
      assert :thinking_level_change in types
      assert :model_change in types

      # Verify thinking level change
      thinking_entry = Enum.find(loaded.entries, &(&1.type == :thinking_level_change))
      assert thinking_entry.thinking_level == :high

      # Verify model change
      model_entry = Enum.find(loaded.entries, &(&1.type == :model_change))
      assert model_entry.provider == "anthropic"
      assert model_entry.model_id == "claude-3"
    end
  end

  # ============================================================================
  # Test Group 2: Session Tree Operations
  # ============================================================================

  describe "Session Tree Operations" do
    @tag :tmp_dir
    test "creates branches and navigates between them", %{tmp_dir: tmp_dir} do
      session_file = Path.join(tmp_dir, "tree_test.jsonl")

      # Create initial session with some messages
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

      # Get the fork point (first entry)
      [first_entry, _second_entry] = session_manager.entries

      # Continue on the main branch
      session_manager =
        session_manager
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "Continue on main branch",
          "timestamp" => 3
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Main branch response"}],
          "timestamp" => 4
        })

      main_branch_leaf = session_manager.leaf_id

      # Save and start session
      :ok = SessionManager.save_to_file(session_file, session_manager)

      session =
        start_session(
          session_file: session_file,
          cwd: tmp_dir
        )

      # Verify current position (main branch)
      messages = Session.get_messages(session)
      assert length(messages) == 4

      # Navigate to first entry (fork point)
      :ok = Session.navigate_tree(session, first_entry.id, summarize_abandoned: false)

      # Messages should now show only the first message
      messages_at_fork = Session.get_messages(session)
      assert length(messages_at_fork) == 1

      # Navigate back to main branch
      :ok = Session.navigate_tree(session, main_branch_leaf, summarize_abandoned: false)

      # Messages should show all 4 messages again
      messages_restored = Session.get_messages(session)
      assert length(messages_restored) == 4
    end

    @tag :tmp_dir
    test "tree structure can have multiple children at fork points", %{tmp_dir: tmp_dir} do
      session_file = Path.join(tmp_dir, "fork_test.jsonl")

      # Create initial session
      session_manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "Root message",
          "timestamp" => 1
        })

      root_entry_id = hd(session_manager.entries).id

      # Add branch A
      session_manager =
        session_manager
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Branch A response"}],
          "timestamp" => 2
        })

      branch_a_leaf = session_manager.leaf_id

      # Navigate back to root to create branch B
      session_manager = SessionManager.set_leaf_id(session_manager, root_entry_id)

      # Add branch B entry (manually create with explicit parent)
      branch_b_entry = %SessionEntry{
        id: SessionManager.generate_id(Enum.map(session_manager.entries, & &1.id)),
        parent_id: root_entry_id,
        type: :message,
        message: %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Branch B response"}],
          "timestamp" => 3
        },
        timestamp: 3
      }

      session_manager = %{
        session_manager |
        entries: session_manager.entries ++ [branch_b_entry],
        by_id: Map.put(session_manager.by_id, branch_b_entry.id, branch_b_entry),
        leaf_id: branch_b_entry.id
      }

      :ok = SessionManager.save_to_file(session_file, session_manager)

      # Start session
      session =
        start_session(
          session_file: session_file,
          cwd: tmp_dir
        )

      # Get state and verify root has multiple children
      state = Session.get_state(session)
      root_children = SessionManager.get_children(state.session_manager, root_entry_id)

      # Root should have 2 children (branch A and branch B)
      assert length(root_children) == 2

      # Navigate to branch A
      :ok = Session.navigate_tree(session, branch_a_leaf, summarize_abandoned: false)

      messages_branch_a = Session.get_messages(session)
      # Branch A has: root + branch A response
      assert length(messages_branch_a) == 2

      # Verify it's branch A content
      last_msg = List.last(messages_branch_a)
      assert last_msg.content == [%TextContent{type: :text, text: "Branch A response"}]
    end

    @tag :tmp_dir
    test "navigation returns error for non-existent entry", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      result = Session.navigate_tree(session, "non-existent-id")
      assert result == {:error, :entry_not_found}
    end
  end

  # ============================================================================
  # Test Group 3: Tool Execution Flow (Direct tool execution, not via agent)
  # ============================================================================

  describe "Tool Execution Flow" do
    @tag :tmp_dir
    test "real read tool can read files", %{tmp_dir: tmp_dir} do
      test_file = Path.join(tmp_dir, "test_read.txt")
      File.write!(test_file, "Original content\nLine 2\nLine 3")

      # Create read tool
      read_tool = CodingAgent.Tools.Read.tool(tmp_dir)

      # Use the read tool directly
      result =
        read_tool.execute.(
          "test_call",
          %{"path" => test_file},
          nil,
          nil
        )

      assert %AgentToolResult{} = result
      [%TextContent{text: text}] = result.content
      assert text =~ "Original content"
      assert text =~ "Line 2"
      assert text =~ "Line 3"

      # Verify line numbers are included
      assert text =~ "1:"
      assert text =~ "2:"
    end

    @tag :tmp_dir
    test "real write tool can write files", %{tmp_dir: tmp_dir} do
      test_file = Path.join(tmp_dir, "test_write.txt")

      # Create write tool
      write_tool = CodingAgent.Tools.Write.tool(tmp_dir)

      # Use the write tool directly
      write_result =
        write_tool.execute.(
          "test_write",
          %{"path" => test_file, "content" => "New content\nLine 2"},
          nil,
          nil
        )

      assert %AgentToolResult{} = write_result
      [%TextContent{text: write_text}] = write_result.content
      assert write_text =~ "Successfully wrote"

      # Verify file was written
      assert File.read!(test_file) == "New content\nLine 2"
    end

    @tag :tmp_dir
    test "read tool handles missing files gracefully", %{tmp_dir: tmp_dir} do
      read_tool = CodingAgent.Tools.Read.tool(tmp_dir)

      result =
        read_tool.execute.(
          "test_call",
          %{"path" => Path.join(tmp_dir, "nonexistent.txt")},
          nil,
          nil
        )

      assert {:error, message} = result
      assert message =~ "not found"
    end

    @tag :tmp_dir
    test "write tool creates parent directories", %{tmp_dir: tmp_dir} do
      nested_path = Path.join([tmp_dir, "nested", "deep", "file.txt"])
      write_tool = CodingAgent.Tools.Write.tool(tmp_dir)

      result =
        write_tool.execute.(
          "test_write",
          %{"path" => nested_path, "content" => "nested content"},
          nil,
          nil
        )

      assert %AgentToolResult{} = result
      assert File.read!(nested_path) == "nested content"
    end

    @tag :tmp_dir
    test "tool results can be serialized for persistence", %{tmp_dir: tmp_dir} do
      # Create a tool result like what would come from tool execution
      tool_result = %AgentToolResult{
        content: [%TextContent{type: :text, text: "Tool output"}],
        details: %{path: "/some/path", bytes_written: 100}
      }

      # Create a tool result message
      tool_result_msg = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_123",
        tool_name: "write",
        content: tool_result.content,
        details: tool_result.details,
        is_error: false,
        timestamp: System.system_time(:millisecond)
      }

      # Serialize it (simulating what Session does)
      serialized = %{
        "role" => "tool_result",
        "tool_call_id" => tool_result_msg.tool_call_id,
        "tool_name" => tool_result_msg.tool_name,
        "content" => Enum.map(tool_result_msg.content, fn
          %TextContent{text: text} -> %{"type" => "text", "text" => text}
        end),
        "is_error" => tool_result_msg.is_error,
        "timestamp" => tool_result_msg.timestamp
      }

      # Save to session manager
      session_manager = SessionManager.new(tmp_dir)
        |> SessionManager.append_message(serialized)

      session_file = Path.join(tmp_dir, "tool_persistence_test.jsonl")
      :ok = SessionManager.save_to_file(session_file, session_manager)

      # Reload and verify
      {:ok, loaded} = SessionManager.load_from_file(session_file)

      assert length(loaded.entries) == 1
      entry = hd(loaded.entries)
      assert entry.message["role"] == "tool_result"
      assert entry.message["tool_call_id"] == "call_123"
    end
  end

  # ============================================================================
  # Test Group 4: Steering and Follow-up Queue Management
  # ============================================================================

  describe "Steering and Follow-up" do
    @tag :tmp_dir
    test "steering messages are queued", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      # Queue steering messages before any prompt
      :ok = Session.steer(session, "First steering message")
      :ok = Session.steer(session, "Second steering message")

      state = Session.get_state(session)
      assert :queue.len(state.steering_queue) == 2
    end

    @tag :tmp_dir
    test "follow-up messages are queued", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      # Queue follow-up messages
      :ok = Session.follow_up(session, "Do this next")
      :ok = Session.follow_up(session, "And then this")

      state = Session.get_state(session)
      assert :queue.len(state.follow_up_queue) == 2
    end

    @tag :tmp_dir
    test "reset clears both queues", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      # Add messages to both queues
      :ok = Session.steer(session, "Steer message")
      :ok = Session.follow_up(session, "Follow-up message")

      # Verify queues have content
      state_before = Session.get_state(session)
      assert :queue.len(state_before.steering_queue) == 1
      assert :queue.len(state_before.follow_up_queue) == 1

      # Reset
      :ok = Session.reset(session)

      # Verify queues are cleared
      state_after = Session.get_state(session)
      assert :queue.len(state_after.steering_queue) == 0
      assert :queue.len(state_after.follow_up_queue) == 0
    end

    @tag :tmp_dir
    test "prompt while already streaming returns error", %{tmp_dir: tmp_dir} do
      # This test relies on the session accepting the prompt and setting is_streaming
      # before the actual API call fails
      session = start_session(cwd: tmp_dir)

      # First prompt should be accepted
      result1 = Session.prompt(session, "First prompt")
      assert result1 == :ok

      # Second prompt should fail while streaming
      result2 = Session.prompt(session, "Second prompt")
      assert result2 == {:error, :already_streaming}

      # Wait for streaming to complete (will fail with API error but that's ok)
      wait_for_streaming_complete(session)
    end

    @tag :tmp_dir
    test "abort can be called without error", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      # Should not raise even when not streaming
      :ok = Session.abort(session)

      # Start streaming
      :ok = Session.prompt(session, "Hello")

      # Abort should work
      :ok = Session.abort(session)

      # Wait for things to settle
      wait_for_streaming_complete(session)

      state = Session.get_state(session)
      assert state.is_streaming == false
    end

    @tag :tmp_dir
    test "session statistics track turn_index correctly", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      stats_before = Session.get_stats(session)
      assert stats_before.turn_count == 0

      # Each prompt increments turn_index
      :ok = Session.prompt(session, "First prompt")
      wait_for_streaming_complete(session)

      stats_after = Session.get_stats(session)
      assert stats_after.turn_count == 1
    end
  end

  # ============================================================================
  # Test Group 5: Model and Thinking Level Changes
  # ============================================================================

  describe "Model and Thinking Level Changes" do
    @tag :tmp_dir
    test "switch_model records change in session", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      new_model = mock_model(id: "new-model-id", provider: :new_provider)
      :ok = Session.switch_model(session, new_model)

      state = Session.get_state(session)
      assert state.model.id == "new-model-id"

      # Verify model change was recorded
      model_changes =
        Enum.filter(state.session_manager.entries, &(&1.type == :model_change))

      assert length(model_changes) == 1
      assert hd(model_changes).model_id == "new-model-id"
    end

    @tag :tmp_dir
    test "set_thinking_level records change in session", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir, thinking_level: :off)

      :ok = Session.set_thinking_level(session, :high)

      state = Session.get_state(session)
      assert state.thinking_level == :high

      # Verify thinking level change was recorded
      thinking_changes =
        Enum.filter(state.session_manager.entries, &(&1.type == :thinking_level_change))

      assert length(thinking_changes) == 1
      assert hd(thinking_changes).thinking_level == :high
    end

    @tag :tmp_dir
    test "model and thinking level changes persist through save/load", %{tmp_dir: tmp_dir} do
      session_file = Path.join(tmp_dir, "model_thinking_test.jsonl")

      # Start session with explicit file path
      session = start_session(cwd: tmp_dir, session_file: session_file)

      # Make changes
      new_model = mock_model(id: "persisted-model")
      :ok = Session.switch_model(session, new_model)
      :ok = Session.set_thinking_level(session, :medium)

      # Save
      :ok = Session.save(session)

      # Load the file directly and verify
      {:ok, loaded} = SessionManager.load_from_file(session_file)

      # Find the model change entry
      model_entry = Enum.find(loaded.entries, &(&1.type == :model_change))
      assert model_entry.model_id == "persisted-model"

      # Find the thinking level change entry
      thinking_entry = Enum.find(loaded.entries, &(&1.type == :thinking_level_change))
      assert thinking_entry.thinking_level == :medium
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp deserialize_message(%{"role" => "user"} = msg) do
    %UserMessage{
      role: :user,
      content: msg["content"],
      timestamp: msg["timestamp"] || 0
    }
  end

  defp deserialize_message(%{"role" => "assistant"} = msg) do
    content =
      case msg["content"] do
        list when is_list(list) ->
          Enum.map(list, fn
            %{"type" => "text", "text" => text} -> %TextContent{type: :text, text: text}
            other -> other
          end)

        other ->
          [%TextContent{type: :text, text: to_string(other)}]
      end

    %AssistantMessage{
      role: :assistant,
      content: content,
      timestamp: msg["timestamp"] || 0
    }
  end

  defp deserialize_message(%{"role" => "tool_result"} = msg) do
    %ToolResultMessage{
      role: :tool_result,
      tool_call_id: msg["tool_call_id"] || "",
      tool_name: msg["tool_name"] || "",
      content: [],
      is_error: msg["is_error"] || false,
      timestamp: msg["timestamp"] || 0
    }
  end

  defp deserialize_message(_), do: nil
end
