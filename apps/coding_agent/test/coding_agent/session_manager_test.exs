defmodule CodingAgent.SessionManagerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  # ============================================================================
  # new/2
  # ============================================================================

  describe "new/2" do
    test "creates session with header" do
      session = SessionManager.new("/tmp/test")
      assert session.header.type == :session
      assert session.header.version == 3
      assert session.header.cwd == "/tmp/test"
      assert session.leaf_id == nil
    end

    test "generates unique session id" do
      s1 = SessionManager.new("/tmp")
      s2 = SessionManager.new("/tmp")
      assert s1.header.id != s2.header.id
    end

    test "uses provided id when given" do
      session = SessionManager.new("/tmp", id: "custom-id-123")
      assert session.header.id == "custom-id-123"
    end

    test "sets parent_session when provided" do
      session = SessionManager.new("/tmp", parent_session: "parent-session-id")
      assert session.header.parent_session == "parent-session-id"
    end

    test "initializes empty entries and by_id" do
      session = SessionManager.new("/tmp")
      assert session.entries == []
      assert session.by_id == %{}
    end

    test "sets timestamp on header" do
      before_time = System.system_time(:millisecond)
      session = SessionManager.new("/tmp")
      after_time = System.system_time(:millisecond)

      assert session.header.timestamp >= before_time
      assert session.header.timestamp <= after_time
    end
  end

  # ============================================================================
  # append_message/2
  # ============================================================================

  describe "append_message/2" do
    test "adds message entry with generated id" do
      session = SessionManager.new("/tmp")
      message = %{role: "user", content: "hello", timestamp: 123}
      session = SessionManager.append_message(session, message)

      assert length(session.entries) == 1
      entry = hd(session.entries)
      assert entry.type == :message
      assert entry.message == message
      assert entry.id != nil
      assert entry.parent_id == nil
    end

    test "links entries via parent_id" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "hi", timestamp: 1})
        |> SessionManager.append_message(%{role: "assistant", content: "hello", timestamp: 2})

      [first, second] = session.entries
      assert second.parent_id == first.id
      assert session.leaf_id == second.id
    end

    test "updates leaf_id after each append" do
      session = SessionManager.new("/tmp")
      assert session.leaf_id == nil

      session = SessionManager.append_message(session, %{role: "user", content: "1"})
      first_id = session.leaf_id
      assert first_id != nil

      session = SessionManager.append_message(session, %{role: "assistant", content: "2"})
      assert session.leaf_id != first_id
    end

    test "message entry is stored in by_id map" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "test"})

      entry = hd(session.entries)
      assert Map.get(session.by_id, entry.id) == entry
    end
  end

  # ============================================================================
  # append_entry/2
  # ============================================================================

  describe "append_entry/2" do
    test "preserves explicit id if provided" do
      session = SessionManager.new("/tmp")
      entry = SessionEntry.message(%{role: "user", content: "test"}, id: "explicit-id")
      session = SessionManager.append_entry(session, entry)

      assert hd(session.entries).id == "explicit-id"
    end

    test "preserves explicit parent_id if provided" do
      session = SessionManager.new("/tmp")
      entry = SessionEntry.message(%{role: "user", content: "test"}, parent_id: "explicit-parent")
      session = SessionManager.append_entry(session, entry)

      assert hd(session.entries).parent_id == "explicit-parent"
    end

    test "generates unique ids avoiding collisions" do
      session = SessionManager.new("/tmp")

      # Add many entries to test collision avoidance
      session =
        Enum.reduce(1..100, session, fn i, sess ->
          SessionManager.append_message(sess, %{role: "user", content: "msg #{i}"})
        end)

      ids = Enum.map(session.entries, & &1.id)
      assert length(Enum.uniq(ids)) == 100
    end
  end

  # ============================================================================
  # append_compaction/5
  # ============================================================================

  describe "append_compaction/5" do
    test "adds compaction entry" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "old msg"})

      first_id = hd(session.entries).id

      session =
        SessionManager.append_compaction(session, "Summary of conversation", first_id, 5000)

      compaction = List.last(session.entries)
      assert compaction.type == :compaction
      assert compaction.summary == "Summary of conversation"
      assert compaction.first_kept_entry_id == first_id
      assert compaction.tokens_before == 5000
    end

    test "includes details when provided" do
      session = SessionManager.new("/tmp")
      details = %{model: "gpt-4", reason: "token limit"}
      session = SessionManager.append_compaction(session, "Summary", "entry-1", 1000, details)

      compaction = List.last(session.entries)
      assert compaction.details == details
    end
  end

  # ============================================================================
  # save_to_file/2
  # ============================================================================

  describe "save_to_file/2" do
    @tag :tmp_dir
    test "does not crash when entries contain non-JSON structs (e.g. tool results)", %{
      tmp_dir: tmp_dir
    } do
      alias AgentCore.Types.AgentToolResult
      alias Ai.Types.TextContent

      tool_result = %AgentToolResult{
        content: [%TextContent{type: :text, text: "Completed: 1 file changed"}],
        details: %{
          status: "running",
          description: "Fix TG tool call formatting",
          engine: "codex"
        }
      }

      session =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_entry(
          SessionEntry.custom_message("tool_update", "ignored", details: tool_result)
        )

      session_file = Path.join(tmp_dir, "tool_result_details.jsonl")
      assert :ok = SessionManager.save_to_file(session_file, session)

      # Details should round-trip as a JSON map.
      {:ok, loaded} = SessionManager.load_from_file(session_file)
      [entry] = loaded.entries
      assert entry.type == :custom_message
      assert is_map(entry.details)
      assert entry.details["details"]["status"] == "running"
    end

    @tag :tmp_dir
    test "preserves existing file contents when temp write fails", %{tmp_dir: tmp_dir} do
      session_file = Path.join(tmp_dir, "atomic_preserve.jsonl")
      existing = "existing-session-data\n"
      File.write!(session_file, existing)

      File.chmod!(tmp_dir, 0o555)

      on_exit(fn ->
        File.chmod(tmp_dir, 0o755)
      end)

      session =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{"role" => "user", "content" => "new content"})

      assert {:error, _reason} = SessionManager.save_to_file(session_file, session)
      assert File.read!(session_file) == existing
      assert Path.wildcard(session_file <> ".tmp.*") == []
    end

    @tag :tmp_dir
    test "cleans up temp file when rename fails", %{tmp_dir: tmp_dir} do
      session_path = Path.join(tmp_dir, "rename_target")
      File.mkdir!(session_path)

      session =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{"role" => "user", "content" => "new content"})

      assert {:error, _reason} = SessionManager.save_to_file(session_path, session)
      assert File.dir?(session_path)
      assert Path.wildcard(session_path <> ".tmp.*") == []
    end
  end

  # ============================================================================
  # build_session_context/2
  # ============================================================================

  describe "build_session_context/2" do
    test "extracts messages from entries" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{"role" => "user", "content" => "q1", "timestamp" => 1})
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "content" => "a1",
          "timestamp" => 2
        })

      context = SessionManager.build_session_context(session)
      assert length(context.messages) == 2
    end

    test "includes custom_message entries in messages" do
      session = SessionManager.new("/tmp")

      custom_entry =
        SessionEntry.custom_message("system_prompt", "You are helpful", display: true)

      session = SessionManager.append_entry(session, custom_entry)

      context = SessionManager.build_session_context(session)
      assert length(context.messages) == 1

      [msg] = context.messages
      assert msg["role"] == "custom"
      assert msg["custom_type"] == "system_prompt"
      assert msg["content"] == "You are helpful"
      assert msg["display"] == true
    end

    test "includes branch_summary entries in messages" do
      session = SessionManager.new("/tmp")
      branch_entry = SessionEntry.branch_summary("from-id-123", "Branch discussed X and Y")
      session = SessionManager.append_entry(session, branch_entry)

      context = SessionManager.build_session_context(session)
      assert length(context.messages) == 1

      [msg] = context.messages
      assert msg["role"] == "branch_summary"
      assert msg["summary"] == "Branch discussed X and Y"
      assert msg["from_id"] == "from-id-123"
    end

    test "returns default thinking_level :off" do
      session = SessionManager.new("/tmp")
      context = SessionManager.build_session_context(session)
      assert context.thinking_level == :off
    end

    test "extracts thinking_level from thinking_level_change entries" do
      session = SessionManager.new("/tmp")
      entry = SessionEntry.thinking_level_change(:high)
      session = SessionManager.append_entry(session, entry)

      context = SessionManager.build_session_context(session)
      assert context.thinking_level == :high
    end

    test "uses latest thinking_level when multiple exist" do
      session = SessionManager.new("/tmp")
      session = SessionManager.append_entry(session, SessionEntry.thinking_level_change(:low))
      session = SessionManager.append_entry(session, SessionEntry.thinking_level_change(:high))
      session = SessionManager.append_entry(session, SessionEntry.thinking_level_change(:medium))

      context = SessionManager.build_session_context(session)
      assert context.thinking_level == :medium
    end

    test "returns nil model by default" do
      session = SessionManager.new("/tmp")
      context = SessionManager.build_session_context(session)
      assert context.model == nil
    end

    test "extracts model from model_change entries" do
      session = SessionManager.new("/tmp")
      entry = SessionEntry.model_change("anthropic", "claude-3-opus")
      session = SessionManager.append_entry(session, entry)

      context = SessionManager.build_session_context(session)
      assert context.model == %{provider: "anthropic", model_id: "claude-3-opus"}
    end

    test "uses compaction summary when present" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{"role" => "user", "content" => "msg1"})
        |> SessionManager.append_message(%{"role" => "assistant", "content" => "msg2"})

      second_id = List.last(session.entries).id

      session =
        session
        |> SessionManager.append_compaction("Conversation about code", second_id, 1000)
        |> SessionManager.append_message(%{"role" => "user", "content" => "msg3"})

      context = SessionManager.build_session_context(session)

      # Should have summary message + kept messages
      [summary_msg | rest] = context.messages
      assert summary_msg["content"] =~ "Conversation about code"
      assert length(rest) >= 1
    end
  end

  # ============================================================================
  # get_branch/2
  # ============================================================================

  describe "get_branch/2" do
    test "returns path from root to leaf" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "1", timestamp: 1})
        |> SessionManager.append_message(%{role: "assistant", content: "2", timestamp: 2})

      branch = SessionManager.get_branch(session, session.leaf_id)
      assert length(branch) == 2

      # Verify order is root to leaf
      [first, second] = branch
      assert first.message.content == "1"
      assert second.message.content == "2"
    end

    test "returns empty list for nil leaf_id" do
      session = SessionManager.new("/tmp")
      branch = SessionManager.get_branch(session, nil)
      assert branch == []
    end

    test "returns partial branch when starting from middle" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "1"})
        |> SessionManager.append_message(%{role: "assistant", content: "2"})
        |> SessionManager.append_message(%{role: "user", content: "3"})

      [first, second, _third] = session.entries

      branch = SessionManager.get_branch(session, second.id)
      assert length(branch) == 2
      assert hd(branch).id == first.id
    end

    test "uses session.leaf_id when leaf_id arg is nil" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "test"})

      branch1 = SessionManager.get_branch(session, session.leaf_id)
      branch2 = SessionManager.get_branch(session)

      assert branch1 == branch2
    end
  end

  # ============================================================================
  # Tree Operations
  # ============================================================================

  describe "get_leaf_id/1" do
    test "returns nil for new session" do
      session = SessionManager.new("/tmp")
      assert SessionManager.get_leaf_id(session) == nil
    end

    test "returns current leaf id" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "test"})

      leaf_id = SessionManager.get_leaf_id(session)
      assert leaf_id == session.leaf_id
      assert leaf_id == hd(session.entries).id
    end
  end

  describe "set_leaf_id/2" do
    test "changes leaf_id" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "1"})
        |> SessionManager.append_message(%{role: "assistant", content: "2"})

      [first, _second] = session.entries
      session = SessionManager.set_leaf_id(session, first.id)

      assert session.leaf_id == first.id
    end

    test "can set to nil" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "test"})
        |> SessionManager.set_leaf_id(nil)

      assert session.leaf_id == nil
    end
  end

  describe "get_entry/2" do
    test "returns entry by id" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "test"})

      entry = hd(session.entries)
      found = SessionManager.get_entry(session, entry.id)
      assert found == entry
    end

    test "returns nil for non-existent id" do
      session = SessionManager.new("/tmp")
      assert SessionManager.get_entry(session, "nonexistent") == nil
    end
  end

  describe "get_children/2" do
    test "returns direct children of entry" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "1"})
        |> SessionManager.append_message(%{role: "assistant", content: "2"})
        |> SessionManager.append_message(%{role: "user", content: "3"})

      first_id = hd(session.entries).id
      children = SessionManager.get_children(session, first_id)

      assert length(children) == 1
      assert hd(children).message.content == "2"
    end

    test "returns root entries when parent_id is nil" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "root1"})

      # Add another root by using explicit nil parent_id
      entry = SessionEntry.message(%{role: "user", content: "root2"}, parent_id: nil)

      session = %{
        session
        | entries: session.entries ++ [entry],
          by_id: Map.put(session.by_id, entry.id || "temp", entry)
      }

      root_children = SessionManager.get_children(session, nil)
      assert length(root_children) >= 1
    end

    test "returns empty list when no children exist" do
      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{role: "user", content: "leaf"})

      leaf_id = session.leaf_id
      children = SessionManager.get_children(session, leaf_id)
      assert children == []
    end
  end

  # ============================================================================
  # JSONL persistence
  # ============================================================================

  describe "JSONL persistence" do
    @tag :tmp_dir
    test "save and load roundtrip", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.jsonl")

      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{
          "role" => "user",
          "content" => "test",
          "timestamp" => 123
        })

      :ok = SessionManager.save_to_file(path, session)
      {:ok, loaded} = SessionManager.load_from_file(path)

      assert loaded.header.id == session.header.id
      assert length(loaded.entries) == length(session.entries)
      assert loaded.header.cwd == session.header.cwd
    end

    @tag :tmp_dir
    test "preserves entry types through roundtrip", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "types.jsonl")

      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{"role" => "user", "content" => "msg"})
        |> SessionManager.append_entry(SessionEntry.thinking_level_change(:high))
        |> SessionManager.append_entry(SessionEntry.model_change("anthropic", "claude-3"))
        |> SessionManager.append_entry(SessionEntry.custom_message("prompt", "content"))
        |> SessionManager.append_entry(SessionEntry.branch_summary("id", "summary"))
        |> SessionManager.append_entry(SessionEntry.label("target", "my-label"))
        |> SessionManager.append_entry(SessionEntry.session_info("session name"))
        |> SessionManager.append_entry(SessionEntry.custom("custom_type", %{key: "value"}))

      :ok = SessionManager.save_to_file(path, session)
      {:ok, loaded} = SessionManager.load_from_file(path)

      types = Enum.map(loaded.entries, & &1.type)

      assert :message in types
      assert :thinking_level_change in types
      assert :model_change in types
      assert :custom_message in types
      assert :branch_summary in types
      assert :label in types
      assert :session_info in types
      assert :custom in types
    end

    @tag :tmp_dir
    test "preserves parent_id relationships", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "parents.jsonl")

      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{"role" => "user", "content" => "1"})
        |> SessionManager.append_message(%{"role" => "assistant", "content" => "2"})
        |> SessionManager.append_message(%{"role" => "user", "content" => "3"})

      :ok = SessionManager.save_to_file(path, session)
      {:ok, loaded} = SessionManager.load_from_file(path)

      [e1, e2, e3] = loaded.entries
      assert e1.parent_id == nil
      assert e2.parent_id == e1.id
      assert e3.parent_id == e2.id
    end

    @tag :tmp_dir
    test "restores leaf_id correctly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "leaf.jsonl")

      session =
        SessionManager.new("/tmp")
        |> SessionManager.append_message(%{"role" => "user", "content" => "1"})
        |> SessionManager.append_message(%{"role" => "assistant", "content" => "2"})

      original_leaf = session.leaf_id

      :ok = SessionManager.save_to_file(path, session)
      {:ok, loaded} = SessionManager.load_from_file(path)

      assert loaded.leaf_id == original_leaf
    end

    @tag :tmp_dir
    test "creates directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      nested_path = Path.join([tmp_dir, "nested", "dir", "test.jsonl"])
      session = SessionManager.new("/tmp")

      :ok = SessionManager.save_to_file(nested_path, session)
      assert File.exists?(nested_path)
    end

    @tag :tmp_dir
    test "returns error for non-existent file" do
      result = SessionManager.load_from_file("/nonexistent/path/file.jsonl")
      assert {:error, :enoent} = result
    end

    @tag :tmp_dir
    test "returns error for empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.jsonl")
      File.write!(path, "")

      result = SessionManager.load_from_file(path)
      assert {:error, :empty_file} = result
    end

    @tag :tmp_dir
    test "returns error for invalid JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid.jsonl")
      File.write!(path, "not valid json")

      result = SessionManager.load_from_file(path)
      assert {:error, _} = result
    end
  end

  # ============================================================================
  # display field preservation
  # ============================================================================

  describe "display field preservation" do
    test "preserves display: false for custom_message" do
      entry = SessionEntry.custom_message("type", "content", display: false)
      assert entry.display == false
    end

    test "preserves display: true for custom_message" do
      entry = SessionEntry.custom_message("type", "content", display: true)
      assert entry.display == true
    end

    test "display is nil when not specified" do
      entry = SessionEntry.custom_message("type", "content")
      assert entry.display == nil
    end

    test "build_session_context treats nil display as true" do
      session = SessionManager.new("/tmp")
      entry = SessionEntry.custom_message("type", "content")
      session = SessionManager.append_entry(session, entry)

      context = SessionManager.build_session_context(session)
      [msg] = context.messages
      assert msg["display"] == true
    end

    test "build_session_context preserves explicit false display" do
      session = SessionManager.new("/tmp")
      entry = SessionEntry.custom_message("type", "content", display: false)
      session = SessionManager.append_entry(session, entry)

      context = SessionManager.build_session_context(session)
      [msg] = context.messages
      assert msg["display"] == false
    end

    @tag :tmp_dir
    test "display: false survives roundtrip", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "display.jsonl")

      session = SessionManager.new("/tmp")
      entry = SessionEntry.custom_message("type", "content", display: false)
      session = SessionManager.append_entry(session, entry)

      :ok = SessionManager.save_to_file(path, session)
      {:ok, loaded} = SessionManager.load_from_file(path)

      loaded_entry = hd(loaded.entries)
      assert loaded_entry.display == false
    end
  end

  # ============================================================================
  # SessionEntry constructors
  # ============================================================================

  describe "SessionEntry constructors" do
    test "message/2 creates message entry" do
      entry = SessionEntry.message(%{role: "user", content: "hi"}, id: "id1", parent_id: "p1")

      assert entry.type == :message
      assert entry.message == %{role: "user", content: "hi"}
      assert entry.id == "id1"
      assert entry.parent_id == "p1"
    end

    test "thinking_level_change/2 creates thinking level entry" do
      entry = SessionEntry.thinking_level_change(:medium)

      assert entry.type == :thinking_level_change
      assert entry.thinking_level == :medium
    end

    test "model_change/3 creates model change entry" do
      entry = SessionEntry.model_change("openai", "gpt-4")

      assert entry.type == :model_change
      assert entry.provider == "openai"
      assert entry.model_id == "gpt-4"
    end

    test "compaction/4 creates compaction entry" do
      entry = SessionEntry.compaction("summary", "first-id", 5000, details: %{reason: "limit"})

      assert entry.type == :compaction
      assert entry.summary == "summary"
      assert entry.first_kept_entry_id == "first-id"
      assert entry.tokens_before == 5000
      assert entry.details == %{reason: "limit"}
    end

    test "branch_summary/3 creates branch summary entry" do
      entry =
        SessionEntry.branch_summary("from-id", "The branch discussed X", details: %{extra: true})

      assert entry.type == :branch_summary
      assert entry.from_id == "from-id"
      assert entry.summary == "The branch discussed X"
      assert entry.details == %{extra: true}
    end

    test "label/3 creates label entry" do
      entry = SessionEntry.label("target-id", "important")

      assert entry.type == :label
      assert entry.target_id == "target-id"
      assert entry.label == "important"
    end

    test "session_info/2 creates session info entry" do
      entry = SessionEntry.session_info("My Session Name")

      assert entry.type == :session_info
      assert entry.name == "My Session Name"
    end

    test "custom/3 creates custom entry" do
      entry = SessionEntry.custom("my_type", %{key: "value"})

      assert entry.type == :custom
      assert entry.custom_type == "my_type"
      assert entry.data == %{key: "value"}
    end

    test "custom_message/3 creates custom message entry" do
      entry =
        SessionEntry.custom_message("prompt", [%{type: "text", text: "hello"}],
          display: true,
          details: %{source: "hook"}
        )

      assert entry.type == :custom_message
      assert entry.custom_type == "prompt"
      assert entry.content == [%{type: "text", text: "hello"}]
      assert entry.display == true
      assert entry.details == %{source: "hook"}
    end

    test "all constructors set timestamp" do
      before = System.system_time(:millisecond)
      entry = SessionEntry.message(%{})
      after_time = System.system_time(:millisecond)

      assert entry.timestamp >= before
      assert entry.timestamp <= after_time
    end
  end

  # ============================================================================
  # generate_id/1
  # ============================================================================

  describe "generate_id/1" do
    test "generates 8-character hex string" do
      id = SessionManager.generate_id([])
      assert String.length(id) == 8
      assert id =~ ~r/^[0-9a-f]{8}$/
    end

    test "avoids collisions with existing ids" do
      existing = ["abcd1234", "efgh5678"]
      id = SessionManager.generate_id(existing)
      refute id in existing
    end

    test "generates unique ids across multiple calls" do
      ids = for _ <- 1..100, do: SessionManager.generate_id([])
      assert length(Enum.uniq(ids)) == 100
    end
  end

  # ============================================================================
  # Migrations
  # ============================================================================

  describe "migrate_to_current_version/2" do
    test "v3 entries pass through unchanged" do
      entries = [
        %{"id" => "abc", "parentId" => nil, "type" => "message", "message" => %{"role" => "user"}}
      ]

      {:ok, migrated} = SessionManager.migrate_to_current_version(3, entries)

      assert length(migrated) == 1
      [entry] = migrated
      assert entry.id == "abc"
      assert entry.type == :message
    end

    test "v2 to v3 renames hookMessage role to custom" do
      entries = [
        %{
          "id" => "abc",
          "parentId" => nil,
          "type" => "message",
          "message" => %{"role" => "hookMessage", "content" => "test"}
        }
      ]

      {:ok, migrated} = SessionManager.migrate_to_current_version(2, entries)

      [entry] = migrated
      assert entry.message["role"] == "custom"
    end

    test "v1 to v3 adds ids to entries" do
      entries = [
        %{"type" => "message", "message" => %{"role" => "user", "content" => "hi"}},
        %{"type" => "message", "message" => %{"role" => "assistant", "content" => "hello"}}
      ]

      {:ok, migrated} = SessionManager.migrate_to_current_version(1, entries)

      assert length(migrated) == 2
      [first, second] = migrated
      assert first.id != nil
      assert second.id != nil
      assert first.parent_id == nil
      assert second.parent_id == first.id
    end
  end
end
