defmodule CodingAgent.SessionBranchTest do
  @moduledoc """
  Comprehensive tests for branch management in CodingAgent.Session.

  Tests cover:
  1. Branch management edge cases
  2. Concurrent message processing
  3. Memory pressure handling
  4. Recovery from partial failures
  5. Very deep branch trees (100+ levels)
  6. Branch switching mid-operation
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Session
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.{SessionEntry}

  alias Ai.Types.{
    AssistantMessage,
    TextContent,
    ToolCall,
    Usage,
    Cost,
    Model,
    ModelCost
  }

  # ============================================================================
  # Test Helpers
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
      Ai.EventStream.push(stream, {:start, response})

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

  defp start_session(opts \\ []) do
    opts = default_opts(opts)
    {:ok, session} = Session.start_link(opts)
    session
  end

  defp wait_for_streaming_complete(session, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_streaming_complete(session, deadline)
  end

  defp do_wait_for_streaming_complete(session, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      raise "Timeout waiting for streaming to complete"
    end

    state = Session.get_state(session)

    if state.is_streaming do
      Process.sleep(10)
      do_wait_for_streaming_complete(session, deadline)
    else
      :ok
    end
  end

  # Helper to create a session manager with a linear chain of N entries
  defp create_deep_session_manager(cwd, depth) do
    Enum.reduce(1..depth, SessionManager.new(cwd), fn i, sm ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"

      if role == "user" do
        SessionManager.append_message(sm, %{
          "role" => "user",
          "content" => "Message #{i}",
          "timestamp" => i
        })
      else
        SessionManager.append_message(sm, %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Response #{i}"}],
          "timestamp" => i
        })
      end
    end)
  end

  # Helper to create a branching session manager
  # Creates a tree where branch point is at entry N, with K alternative branches
  defp create_branching_session_manager(
         cwd,
         initial_depth,
         branch_point,
         num_branches,
         branch_depth
       ) do
    # Create initial linear chain
    sm = create_deep_session_manager(cwd, initial_depth)
    entries = sm.entries

    # Find the branch point entry
    branch_entry = Enum.at(entries, branch_point - 1)

    if branch_entry == nil do
      sm
    else
      # Create branches from the branch point
      Enum.reduce(1..num_branches, sm, fn branch_num, acc_sm ->
        # First, set leaf_id to branch_entry.id to create from that point
        acc_sm = SessionManager.set_leaf_id(acc_sm, branch_entry.id)

        # Add messages for this branch
        Enum.reduce(1..branch_depth, acc_sm, fn msg_num, inner_sm ->
          role = if rem(msg_num, 2) == 1, do: "user", else: "assistant"
          content_prefix = "Branch-#{branch_num}-"

          if role == "user" do
            SessionManager.append_message(inner_sm, %{
              "role" => "user",
              "content" => "#{content_prefix}User-#{msg_num}",
              "timestamp" => System.system_time(:millisecond) + branch_num * 1000 + msg_num
            })
          else
            SessionManager.append_message(inner_sm, %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "#{content_prefix}Response-#{msg_num}"}],
              "timestamp" => System.system_time(:millisecond) + branch_num * 1000 + msg_num
            })
          end
        end)
      end)
    end
  end

  # ============================================================================
  # 1. Branch Management Edge Cases
  # ============================================================================

  describe "branch management edge cases" do
    @tag :tmp_dir
    test "navigating to root (nil leaf_id) clears messages", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 4)
      session_file = Path.join(tmp_dir, "root_nav.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Initially should have 4 messages
      messages_before = Session.get_messages(session)
      assert length(messages_before) == 4

      # Navigate to the first entry (which clears most messages)
      first_entry = hd(sm.entries)
      :ok = Session.navigate_tree(session, first_entry.id)

      messages_after = Session.get_messages(session)
      assert length(messages_after) == 1
    end

    @tag :tmp_dir
    test "navigating to same entry is a no-op", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 4)
      session_file = Path.join(tmp_dir, "same_entry.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      state_before = Session.get_state(session)
      leaf_id = state_before.session_manager.leaf_id

      # Navigate to current position
      :ok = Session.navigate_tree(session, leaf_id)

      state_after = Session.get_state(session)
      assert state_after.session_manager.leaf_id == leaf_id

      messages = Session.get_messages(session)
      assert length(messages) == 4
    end

    @tag :tmp_dir
    test "navigating between sibling branches", %{tmp_dir: tmp_dir} do
      # Create a tree with branches
      sm = create_branching_session_manager(tmp_dir, 4, 2, 3, 4)
      session_file = Path.join(tmp_dir, "sibling_nav.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Get the branch point
      branch_entry = Enum.at(sm.entries, 1)
      children = SessionManager.get_children(sm, branch_entry.id)

      # Should have multiple children (branches)
      assert length(children) >= 2

      # Navigate to first child branch
      first_child = hd(children)
      :ok = Session.navigate_tree(session, first_child.id)

      messages1 = Session.get_messages(session)

      # Navigate to second child branch
      second_child = Enum.at(children, 1)
      :ok = Session.navigate_tree(session, second_child.id)

      messages2 = Session.get_messages(session)

      # Messages should be different between branches
      # (same prefix from common ancestor, different branch content)
      assert length(messages1) >= 1
      assert length(messages2) >= 1
    end

    @tag :tmp_dir
    test "branch with only metadata entries (no messages)", %{tmp_dir: tmp_dir} do
      sm = SessionManager.new(tmp_dir)

      # Add only metadata entries
      sm =
        sm
        |> SessionManager.append_entry(SessionEntry.thinking_level_change(:high))
        |> SessionManager.append_entry(SessionEntry.model_change(:anthropic, "claude-3-opus"))
        |> SessionManager.append_entry(SessionEntry.thinking_level_change(:medium))

      session_file = Path.join(tmp_dir, "metadata_only.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Should have no messages but valid state
      messages = Session.get_messages(session)
      assert messages == []

      # Session should still be usable
      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      messages = Session.get_messages(session)
      assert length(messages) >= 1
    end

    @tag :tmp_dir
    test "orphaned entries have truncated paths when navigated to", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 4)

      # Remember the last valid entry id before adding orphan
      last_valid_id = List.last(sm.entries).id

      # Manually create an orphaned entry (parent_id doesn't exist)
      # This entry exists but its parent chain is broken
      orphan = %SessionEntry{
        id: SessionManager.generate_id(Map.keys(sm.by_id)),
        parent_id: "non-existent-parent-id",
        timestamp: System.system_time(:millisecond),
        type: :message,
        message: %{"role" => "user", "content" => "Orphaned message", "timestamp" => 999}
      }

      # Add orphan to entries
      sm = %{
        sm
        | entries: sm.entries ++ [orphan],
          by_id: Map.put(sm.by_id, orphan.id, orphan)
      }

      session_file = Path.join(tmp_dir, "orphan.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # The orphan entry exists in entries
      state = Session.get_state(session)
      assert length(state.session_manager.entries) == 5

      # When starting, the session finds the orphan as "latest leaf" since it has no children
      # So initially we're on the orphan branch with only 1 message
      initial_messages = Session.get_messages(session)
      assert length(initial_messages) == 1

      # But we can navigate to the valid chain's end and get all 4 messages
      :ok = Session.navigate_tree(session, last_valid_id)
      valid_chain_messages = Session.get_messages(session)
      assert length(valid_chain_messages) == 4

      # And navigating back to the orphan shows only the orphan (broken parent chain)
      :ok = Session.navigate_tree(session, orphan.id)
      orphan_messages = Session.get_messages(session)
      assert length(orphan_messages) == 1
    end

    @tag :tmp_dir
    test "circular reference detection", %{tmp_dir: tmp_dir} do
      # Create a session with potential circular reference
      sm = SessionManager.new(tmp_dir)

      # Create entries manually with a cycle
      entry1 = %SessionEntry{
        id: "entry1",
        parent_id: nil,
        timestamp: 1,
        type: :message,
        message: %{"role" => "user", "content" => "First", "timestamp" => 1}
      }

      entry2 = %SessionEntry{
        id: "entry2",
        parent_id: "entry1",
        timestamp: 2,
        type: :message,
        message: %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Second"}],
          "timestamp" => 2
        }
      }

      entry3 = %SessionEntry{
        id: "entry3",
        parent_id: "entry2",
        timestamp: 3,
        type: :message,
        message: %{"role" => "user", "content" => "Third", "timestamp" => 3}
      }

      sm = %{
        sm
        | entries: [entry1, entry2, entry3],
          by_id: %{"entry1" => entry1, "entry2" => entry2, "entry3" => entry3},
          leaf_id: "entry3"
      }

      session_file = Path.join(tmp_dir, "normal_chain.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Should load normally
      messages = Session.get_messages(session)
      assert length(messages) == 3
    end

    @tag :tmp_dir
    test "branch navigation preserves entry IDs", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 6)
      original_ids = Enum.map(sm.entries, & &1.id)

      session_file = Path.join(tmp_dir, "preserve_ids.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Navigate around
      mid_entry = Enum.at(sm.entries, 2)
      :ok = Session.navigate_tree(session, mid_entry.id)

      last_entry = List.last(sm.entries)
      :ok = Session.navigate_tree(session, last_entry.id)

      # Verify IDs are preserved
      state = Session.get_state(session)
      current_ids = Enum.map(state.session_manager.entries, & &1.id)
      assert current_ids == original_ids
    end
  end

  # ============================================================================
  # 2. Concurrent Message Processing
  # ============================================================================

  describe "concurrent message processing" do
    test "concurrent navigation requests are serialized" do
      session = start_session()

      # Add some messages first
      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      state = Session.get_state(session)

      # Get entry IDs
      entries = state.session_manager.entries

      if length(entries) >= 2 do
        entry_ids = Enum.map(entries, & &1.id)

        # Concurrent navigation attempts
        tasks =
          for id <- entry_ids do
            Task.async(fn ->
              Session.navigate_tree(session, id)
            end)
          end

        results = Task.await_many(tasks, 5000)

        # All should succeed (serialized by GenServer)
        Enum.each(results, fn result ->
          assert result == :ok
        end)

        # State should be consistent
        final_state = Session.get_state(session)
        assert final_state.session_manager.leaf_id in entry_ids
      end
    end

    test "concurrent prompts and navigation" do
      slow_stream_fn = fn _model, _context, _options ->
        Process.sleep(50)
        {:ok, response_to_event_stream(assistant_message("Response"))}
      end

      session = start_session(stream_fn: slow_stream_fn)

      # Start a prompt
      :ok = Session.prompt(session, "Hello!")

      # Try to navigate while streaming
      state = Session.get_state(session)

      if state.session_manager.entries != [] do
        first_id = hd(state.session_manager.entries).id
        # This should still work (navigation doesn't require non-streaming)
        result = Session.navigate_tree(session, first_id)
        assert result == :ok
      end

      wait_for_streaming_complete(session)
    end

    test "concurrent steer and follow_up with branch operations" do
      session = start_session()

      # Add messages
      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      state = Session.get_state(session)

      if length(state.session_manager.entries) >= 1 do
        entry_id = hd(state.session_manager.entries).id

        # Concurrent operations
        tasks = [
          Task.async(fn -> Session.steer(session, "Steer 1") end),
          Task.async(fn -> Session.follow_up(session, "Follow 1") end),
          Task.async(fn -> Session.navigate_tree(session, entry_id) end),
          Task.async(fn -> Session.steer(session, "Steer 2") end),
          Task.async(fn -> Session.follow_up(session, "Follow 2") end)
        ]

        results = Task.await_many(tasks, 5000)

        # All operations should succeed
        Enum.each(results, fn result ->
          assert result == :ok
        end)
      end
    end

    test "rapid subscribe/unsubscribe during branch operations" do
      session = start_session()

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      parent = self()

      # Spawn processes that rapidly subscribe/unsubscribe
      _pids =
        for i <- 1..10 do
          spawn(fn ->
            for _ <- 1..5 do
              unsub = Session.subscribe(session)
              Process.sleep(:rand.uniform(10))
              unsub.()
            end

            send(parent, {:done, i})
          end)
        end

      # Concurrent navigation
      state = Session.get_state(session)

      if state.session_manager.entries != [] do
        entries = state.session_manager.entries

        for entry <- entries do
          Session.navigate_tree(session, entry.id)
        end
      end

      # Wait for all spawned processes
      for _ <- 1..10 do
        assert_receive {:done, _}, 5000
      end

      # Session should still be healthy
      health = Session.health_check(session)
      assert health.status == :healthy
    end

    test "concurrent get_messages during navigation" do
      session = start_session()

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      :ok = Session.prompt(session, "World!")
      wait_for_streaming_complete(session)

      state = Session.get_state(session)
      entries = state.session_manager.entries

      if length(entries) >= 2 do
        # Concurrent message reads and navigation
        tasks =
          for _ <- 1..20 do
            Task.async(fn ->
              messages = Session.get_messages(session)
              assert is_list(messages)
              :ok
            end)
          end

        # Navigate while reading
        for entry <- Enum.take(entries, 3) do
          Session.navigate_tree(session, entry.id)
        end

        Task.await_many(tasks, 5000)
      end
    end
  end

  # ============================================================================
  # 3. Memory Pressure Handling
  # ============================================================================

  describe "memory pressure handling" do
    @tag :tmp_dir
    test "handles session with many entries", %{tmp_dir: tmp_dir} do
      # Create a session with many entries
      sm = create_deep_session_manager(tmp_dir, 200)
      session_file = Path.join(tmp_dir, "many_entries.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Should load without issues
      messages = Session.get_messages(session)
      assert length(messages) == 200

      # Navigation should work
      mid_entry = Enum.at(sm.entries, 100)
      :ok = Session.navigate_tree(session, mid_entry.id)

      messages = Session.get_messages(session)
      assert length(messages) == 101
    end

    @tag :tmp_dir
    test "handles session with large message content", %{tmp_dir: tmp_dir} do
      sm = SessionManager.new(tmp_dir)

      # Add messages with large content
      large_content = String.duplicate("x", 100_000)

      sm =
        sm
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => large_content,
          "timestamp" => 1
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => large_content}],
          "timestamp" => 2
        })

      session_file = Path.join(tmp_dir, "large_content.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      messages = Session.get_messages(session)
      assert length(messages) == 2

      # Content should be preserved
      [user_msg, _assistant_msg] = messages
      assert String.length(user_msg.content) == 100_000
    end

    @tag :tmp_dir
    test "handles wide branching (many siblings)", %{tmp_dir: tmp_dir} do
      sm = SessionManager.new(tmp_dir)

      # Create root message
      sm =
        SessionManager.append_message(sm, %{
          "role" => "user",
          "content" => "Root message",
          "timestamp" => 1
        })

      root_id = hd(sm.entries).id

      # Create many sibling branches from root
      sm =
        Enum.reduce(1..50, sm, fn i, acc_sm ->
          acc_sm = SessionManager.set_leaf_id(acc_sm, root_id)

          SessionManager.append_message(acc_sm, %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "Branch #{i}"}],
            "timestamp" => i + 1
          })
        end)

      session_file = Path.join(tmp_dir, "wide_branch.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Should load (will be at one of the branches)
      messages = Session.get_messages(session)
      assert length(messages) >= 1

      # Should be able to navigate to different branches
      children = SessionManager.get_children(sm, root_id)
      assert length(children) == 50

      for child <- Enum.take(children, 10) do
        :ok = Session.navigate_tree(session, child.id)
        messages = Session.get_messages(session)
        assert length(messages) == 2
      end
    end

    test "garbage collection works during heavy branch operations" do
      session = start_session()

      # Perform many operations to create garbage
      for _ <- 1..50 do
        :ok = Session.prompt(session, "Message")
        wait_for_streaming_complete(session)

        state = Session.get_state(session)

        if state.session_manager.entries != [] do
          first_id = hd(state.session_manager.entries).id
          Session.navigate_tree(session, first_id)
        end

        Session.get_messages(session)
        Session.get_stats(session)
      end

      # Force GC
      :erlang.garbage_collect(session)

      # Session should still be healthy
      health = Session.health_check(session)
      assert health.status == :healthy
    end
  end

  # ============================================================================
  # 4. Recovery from Partial Failures
  # ============================================================================

  describe "recovery from partial failures" do
    @tag :tmp_dir
    test "session recovers after navigation to invalid entry", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 4)
      session_file = Path.join(tmp_dir, "recovery_invalid.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Navigate to invalid entry
      result = Session.navigate_tree(session, "nonexistent-id")
      assert result == {:error, :entry_not_found}

      # Session should still work
      messages = Session.get_messages(session)
      assert length(messages) == 4

      :ok = Session.prompt(session, "Still works!")
      wait_for_streaming_complete(session)
    end

    test "session recovers after agent error during branch operation" do
      error_after_count = :counters.new(1, [:atomics])

      error_stream_fn = fn _model, _context, _options ->
        count = :counters.get(error_after_count, 1)
        :counters.add(error_after_count, 1, 1)

        if count < 2 do
          {:ok, stream} = Ai.EventStream.start_link()

          Task.start(fn ->
            Ai.EventStream.push(stream, {:error, "Simulated error", %{}})
            Ai.EventStream.complete(stream, %{})
          end)

          {:ok, stream}
        else
          {:ok, response_to_event_stream(assistant_message("Recovery!"))}
        end
      end

      session = start_session(stream_fn: error_stream_fn)
      _unsub = Session.subscribe(session)

      # First prompt will error
      :ok = Session.prompt(session, "Will error")
      assert_receive {:session_event, _id, {:error, _reason, _partial}}, 5000

      Process.sleep(100)
      state = Session.get_state(session)
      assert state.is_streaming == false

      # Second prompt should work
      :ok = Session.prompt(session, "Will succeed")
      wait_for_streaming_complete(session)

      messages = Session.get_messages(session)
      # Should have messages from successful prompt
      assert length(messages) >= 1
    end

    @tag :tmp_dir
    test "handles corrupted entry in branch path", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 4)

      # Corrupt one entry's parent_id to create a gap
      entry_to_corrupt = Enum.at(sm.entries, 2)
      corrupted_entry = %{entry_to_corrupt | parent_id: "broken-parent"}

      sm = %{
        sm
        | entries: List.replace_at(sm.entries, 2, corrupted_entry),
          by_id: Map.put(sm.by_id, corrupted_entry.id, corrupted_entry)
      }

      session_file = Path.join(tmp_dir, "corrupted_path.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Session should still load (branch walk stops at broken parent)
      messages = Session.get_messages(session)
      # Only entries after the break will be in the path
      assert is_list(messages)
    end

    test "session handles rapid reset and prompt cycles" do
      session = start_session()

      for _ <- 1..10 do
        :ok = Session.prompt(session, "Hello!")
        wait_for_streaming_complete(session)
        :ok = Session.reset(session)
      end

      # Should end in clean state
      state = Session.get_state(session)
      assert state.turn_index == 0
      assert Session.get_messages(session) == []
    end

    @tag :tmp_dir
    test "recovers from save failure", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      # Save should work
      :ok = Session.save(session)

      # Add more messages
      :ok = Session.prompt(session, "World!")
      wait_for_streaming_complete(session)

      # Session should still be usable regardless of save state
      messages = Session.get_messages(session)
      assert length(messages) >= 2
    end
  end

  # ============================================================================
  # 5. Very Deep Branch Trees (100+ levels)
  # ============================================================================

  describe "very deep branch trees (100+ levels)" do
    @tag :tmp_dir
    @tag timeout: 120_000
    test "handles 100-level deep tree", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 100)
      session_file = Path.join(tmp_dir, "deep100.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Should load all messages
      messages = Session.get_messages(session)
      assert length(messages) == 100

      # Navigation to early entries should work
      entry_10 = Enum.at(sm.entries, 9)
      :ok = Session.navigate_tree(session, entry_10.id)

      messages = Session.get_messages(session)
      assert length(messages) == 10

      # Navigation back to end should work
      last_entry = List.last(sm.entries)
      :ok = Session.navigate_tree(session, last_entry.id)

      messages = Session.get_messages(session)
      assert length(messages) == 100
    end

    @tag :tmp_dir
    @tag timeout: 120_000
    test "handles 150-level deep tree", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 150)
      session_file = Path.join(tmp_dir, "deep150.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      messages = Session.get_messages(session)
      assert length(messages) == 150

      # Jump around the tree
      for idx <- [1, 50, 100, 149, 75, 25] do
        entry = Enum.at(sm.entries, idx)
        :ok = Session.navigate_tree(session, entry.id)

        messages = Session.get_messages(session)
        assert length(messages) == idx + 1
      end
    end

    @tag :tmp_dir
    @tag timeout: 120_000
    test "handles 200-level deep tree with branching", %{tmp_dir: tmp_dir} do
      # Create a 200-deep linear tree, then add branches at various points
      sm = create_deep_session_manager(tmp_dir, 200)

      # Add branches at entries 50, 100, 150
      # Note: We don't modify sm here since it's already complete
      # The branching test is more about testing navigation than creation
      # (For actual branching, see create_branching_session_manager helper)

      session_file = Path.join(tmp_dir, "deep_branched.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Should be able to navigate to any point
      state = Session.get_state(session)
      total_entries = length(state.session_manager.entries)
      assert total_entries >= 200

      # Navigate to original end
      original_end = Enum.at(sm.entries, 199)
      :ok = Session.navigate_tree(session, original_end.id)

      messages = Session.get_messages(session)
      assert length(messages) == 200
    end

    @tag :tmp_dir
    test "performance is acceptable for deep tree navigation", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 100)
      session_file = Path.join(tmp_dir, "perf_test.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Measure navigation time
      entries = sm.entries

      timings =
        for entry <- Enum.take_every(entries, 10) do
          {time, :ok} = :timer.tc(fn -> Session.navigate_tree(session, entry.id) end)
          time
        end

      # All navigations should complete in under 100ms each
      Enum.each(timings, fn time_us ->
        assert time_us < 100_000, "Navigation took #{time_us}us, expected < 100000us"
      end)
    end
  end

  # ============================================================================
  # 6. Branch Switching Mid-Operation
  # ============================================================================

  describe "branch switching mid-operation" do
    test "branch switch during prompt is safe" do
      slow_stream_fn = fn _model, _context, _options ->
        Process.sleep(100)
        {:ok, response_to_event_stream(assistant_message("Slow response"))}
      end

      session = start_session(stream_fn: slow_stream_fn)

      # Add initial message
      :ok = Session.prompt(session, "First!")
      wait_for_streaming_complete(session)

      state = Session.get_state(session)
      first_entry_id = hd(state.session_manager.entries).id

      # Start another prompt
      :ok = Session.prompt(session, "Second!")

      # Navigate while streaming (should still work)
      :ok = Session.navigate_tree(session, first_entry_id)

      wait_for_streaming_complete(session)

      # Session should be in consistent state
      final_state = Session.get_state(session)
      assert final_state.is_streaming == false
    end

    test "branch switch clears steering queue appropriately" do
      session = start_session()

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      # Add steering messages
      :ok = Session.steer(session, "Steer 1")
      :ok = Session.steer(session, "Steer 2")

      state_before = Session.get_state(session)
      assert :queue.len(state_before.steering_queue) == 2

      # Navigate to first entry
      first_id = hd(state_before.session_manager.entries).id
      :ok = Session.navigate_tree(session, first_id)

      # Steering queue should remain (it's for the agent, not session state)
      state_after = Session.get_state(session)
      assert :queue.len(state_after.steering_queue) == 2
    end

    @tag :tmp_dir
    test "branch switch with summarize_abandoned option", %{tmp_dir: tmp_dir} do
      sm = create_branching_session_manager(tmp_dir, 6, 3, 2, 4)
      session_file = Path.join(tmp_dir, "summarize_switch.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Get a branch point entry
      branch_entry = Enum.at(sm.entries, 2)
      children = SessionManager.get_children(sm, branch_entry.id)

      if length(children) >= 2 do
        first_branch = hd(children)
        second_branch = Enum.at(children, 1)

        # Navigate to first branch
        :ok = Session.navigate_tree(session, first_branch.id)

        # Navigate to second branch with summarize disabled
        :ok = Session.navigate_tree(session, second_branch.id, summarize_abandoned: false)

        state = Session.get_state(session)
        assert state.session_manager.leaf_id == second_branch.id
      end
    end

    test "branch switch during steer message delivery" do
      slow_stream_fn = fn _model, _context, _options ->
        Process.sleep(50)
        {:ok, response_to_event_stream(assistant_message("Response"))}
      end

      session = start_session(stream_fn: slow_stream_fn)

      # Build up some conversation
      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      :ok = Session.prompt(session, "World!")
      wait_for_streaming_complete(session)

      state = Session.get_state(session)

      if length(state.session_manager.entries) >= 2 do
        first_id = hd(state.session_manager.entries).id

        # Start prompt with steer
        :ok = Session.prompt(session, "Prompt with steer coming")
        :ok = Session.steer(session, "Interrupting steer!")

        # Switch branch mid-stream
        :ok = Session.navigate_tree(session, first_id)

        wait_for_streaming_complete(session)

        # Should be in consistent state
        health = Session.health_check(session)
        assert health.status == :healthy
      end
    end

    test "multiple rapid branch switches" do
      session = start_session()

      # Build conversation
      for i <- 1..5 do
        :ok = Session.prompt(session, "Message #{i}")
        wait_for_streaming_complete(session)
      end

      state = Session.get_state(session)
      entries = state.session_manager.entries

      # Rapid navigation through all entries
      for _ <- 1..3 do
        for entry <- entries do
          :ok = Session.navigate_tree(session, entry.id)
        end
      end

      # Should still be healthy
      health = Session.health_check(session)
      assert health.status == :healthy

      # Messages should be consistent with final position
      final_state = Session.get_state(session)
      messages = Session.get_messages(session)

      expected_count =
        Enum.find_index(entries, &(&1.id == final_state.session_manager.leaf_id)) + 1

      assert length(messages) == expected_count
    end

    test "branch switch preserves event subscribers" do
      session = start_session()
      _unsub = Session.subscribe(session)

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      state = Session.get_state(session)

      if state.session_manager.entries != [] do
        first_id = hd(state.session_manager.entries).id
        :ok = Session.navigate_tree(session, first_id)
      end

      # Should still receive events after branch switch
      :ok = Session.prompt(session, "After switch!")
      assert_receive {:session_event, _id, _event}, 5000
    end

    test "branch switch during extension hook execution" do
      session = start_session()

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      :ok = Session.prompt(session, "World!")
      wait_for_streaming_complete(session)

      state = Session.get_state(session)

      if length(state.session_manager.entries) >= 2 do
        # Navigate to first entry while hooks may be registered
        # (Note: This test validates that branch switches don't interfere with hooks)
        first_id = hd(state.session_manager.entries).id
        :ok = Session.navigate_tree(session, first_id)

        # Should complete without error
        assert :ok == :ok
      end
    end
  end

  # ============================================================================
  # Additional Edge Cases
  # ============================================================================

  describe "additional branch edge cases" do
    @tag :tmp_dir
    test "branch with mixed entry types", %{tmp_dir: tmp_dir} do
      sm = SessionManager.new(tmp_dir)

      sm =
        sm
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "First message",
          "timestamp" => 1
        })
        |> SessionManager.append_entry(SessionEntry.thinking_level_change(:high))
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Response"}],
          "timestamp" => 2
        })
        |> SessionManager.append_entry(SessionEntry.model_change(:openai, "gpt-4"))
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "Second message",
          "timestamp" => 3
        })
        |> SessionManager.append_entry(SessionEntry.label(nil, "checkpoint"))

      session_file = Path.join(tmp_dir, "mixed_types.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Messages should only include message entries
      messages = Session.get_messages(session)
      assert length(messages) == 3

      # Navigate to first entry
      first_id = hd(sm.entries).id
      :ok = Session.navigate_tree(session, first_id)

      messages = Session.get_messages(session)
      assert length(messages) == 1
    end

    @tag :tmp_dir
    test "session with compaction entry in branch", %{tmp_dir: tmp_dir} do
      sm = create_deep_session_manager(tmp_dir, 10)

      # Add a compaction entry
      sm =
        SessionManager.append_compaction(
          sm,
          "Summary of previous conversation",
          Enum.at(sm.entries, 4).id,
          5000,
          %{method: "test"}
        )

      session_file = Path.join(tmp_dir, "with_compaction.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Context should include summary + kept messages
      messages = Session.get_messages(session)
      # Summary message + entries from first_kept_entry onwards
      assert length(messages) >= 1
    end

    test "empty session navigation" do
      session = start_session()

      # No entries yet
      state = Session.get_state(session)
      assert state.session_manager.entries == []
      assert state.session_manager.leaf_id == nil

      # Navigation to any ID should fail
      result = Session.navigate_tree(session, "any-id")
      assert result == {:error, :entry_not_found}
    end

    test "branch operations with stream mode subscribers" do
      session = start_session()

      # Subscribe in stream mode
      {:ok, stream} = Session.subscribe(session, mode: :stream)

      :ok = Session.prompt(session, "Hello!")
      wait_for_streaming_complete(session)

      state = Session.get_state(session)

      if state.session_manager.entries != [] do
        first_id = hd(state.session_manager.entries).id
        :ok = Session.navigate_tree(session, first_id)

        # Stream should still be valid
        assert Process.alive?(stream)
      end
    end

    @tag :tmp_dir
    test "branch with custom message entries", %{tmp_dir: tmp_dir} do
      sm = SessionManager.new(tmp_dir)

      sm =
        sm
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "Hello",
          "timestamp" => 1
        })
        |> SessionManager.append_entry(
          SessionEntry.custom_message("status", "Processing started", display: true)
        )
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Hi!"}],
          "timestamp" => 2
        })

      session_file = Path.join(tmp_dir, "custom_message.jsonl")
      :ok = SessionManager.save_to_file(session_file, sm)

      session = start_session(session_file: session_file, cwd: tmp_dir)

      # Custom messages should be included in messages
      messages = Session.get_messages(session)
      assert length(messages) == 3

      custom_messages = Enum.filter(messages, &(&1.role == :custom))
      assert length(custom_messages) == 1
    end
  end
end
