defmodule CodingAgent.CliRunners.LemonRunnerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.CliRunners.LemonRunner
  alias AgentCore.CliRunners.Types.{
    Action,
    ActionEvent,
    CompletedEvent,
    EventFactory,
    ResumeToken,
    StartedEvent
  }
  alias AgentCore.EventStream

  # ============================================================================
  # Module API Tests
  # ============================================================================

  describe "module API" do
    test "engine/0 returns 'lemon'" do
      assert LemonRunner.engine() == "lemon"
    end

    test "supports_steer?/0 returns true" do
      assert LemonRunner.supports_steer?() == true
    end
  end

  # ============================================================================
  # Start Link Tests
  # ============================================================================

  describe "start_link/1" do
    test "requires prompt option" do
      # GenServer.start_link runs init/1 in a separate process, so we get an exit
      # rather than a direct exception. Trap exits to test this gracefully.
      Process.flag(:trap_exit, true)
      result = LemonRunner.start_link(cwd: System.tmp_dir!())

      # Should fail to start - the exact error depends on how GenServer handles
      # the KeyError in init/1
      case result do
        {:error, _reason} ->
          # GenServer returned an error tuple
          :ok

        {:ok, pid} ->
          # If it somehow started, it should exit quickly
          assert_receive {:EXIT, ^pid, _reason}, 1000
      end
    end

    # Note: Full integration tests require CodingAgent.Session to be available,
    # which depends on the coding_agent application being started.
    # These tests are in the coding_agent app's test suite.
  end

  # ============================================================================
  # EventFactory Tests (Unit tests for event creation)
  # ============================================================================

  describe "EventFactory for lemon engine" do
    test "creates factory with lemon engine" do
      factory = EventFactory.new("lemon")
      assert factory.engine == "lemon"
      assert factory.resume == nil
      assert factory.note_seq == 0
    end

    test "started event caches resume token" do
      factory = EventFactory.new("lemon")
      token = ResumeToken.new("lemon", "session_12345")

      {event, new_factory} = EventFactory.started(factory, token, meta: %{cwd: "/tmp"})

      assert %StartedEvent{} = event
      assert event.engine == "lemon"
      assert event.resume == token
      assert event.meta == %{cwd: "/tmp"}
      assert new_factory.resume == token
    end

    test "started event raises on engine mismatch" do
      factory = EventFactory.new("lemon")
      wrong_token = ResumeToken.new("claude", "session_wrong")

      assert_raise RuntimeError, ~r/engine mismatch/, fn ->
        EventFactory.started(factory, wrong_token)
      end
    end

    test "action_started creates action event with phase :started" do
      factory = EventFactory.new("lemon")

      {event, _factory} = EventFactory.action_started(
        factory,
        "tool_1",
        :command,
        "$ ls -la",
        detail: %{name: "Bash", args: %{"command" => "ls -la"}}
      )

      assert %ActionEvent{} = event
      assert event.engine == "lemon"
      assert event.phase == :started
      assert event.action.id == "tool_1"
      assert event.action.kind == :command
      assert event.action.title == "$ ls -la"
      assert event.action.detail.name == "Bash"
    end

    test "action_updated creates action event with phase :updated" do
      factory = EventFactory.new("lemon")

      {event, _factory} = EventFactory.action_updated(
        factory,
        "tool_1",
        :command,
        "$ ls -la",
        detail: %{partial_result: "file1.txt\n"}
      )

      assert event.phase == :updated
      assert event.action.detail.partial_result == "file1.txt\n"
    end

    test "action_completed creates action event with phase :completed" do
      factory = EventFactory.new("lemon")

      {event, _factory} = EventFactory.action_completed(
        factory,
        "tool_1",
        :command,
        "$ ls -la",
        true,
        detail: %{result: "file1.txt\nfile2.txt\n"}
      )

      assert event.phase == :completed
      assert event.ok == true
      assert event.action.detail.result == "file1.txt\nfile2.txt\n"
    end

    test "action_completed with failure" do
      factory = EventFactory.new("lemon")

      {event, _factory} = EventFactory.action_completed(
        factory,
        "tool_1",
        :command,
        "$ invalid_command",
        false,
        detail: %{result: "command not found"}
      )

      assert event.phase == :completed
      assert event.ok == false
    end

    test "completed_ok creates successful completion event" do
      factory = EventFactory.new("lemon")
      token = ResumeToken.new("lemon", "session_123")
      {_event, factory} = EventFactory.started(factory, token)

      {event, _factory} = EventFactory.completed_ok(
        factory,
        "Task completed successfully",
        usage: %{input_tokens: 100, output_tokens: 50}
      )

      assert %CompletedEvent{} = event
      assert event.engine == "lemon"
      assert event.ok == true
      assert event.answer == "Task completed successfully"
      assert event.resume == token
      assert event.usage == %{input_tokens: 100, output_tokens: 50}
    end

    test "completed_error creates error completion event" do
      factory = EventFactory.new("lemon")
      token = ResumeToken.new("lemon", "session_123")
      {_event, factory} = EventFactory.started(factory, token)

      {event, _factory} = EventFactory.completed_error(
        factory,
        "Connection timeout",
        answer: "Partial response before error"
      )

      assert %CompletedEvent{} = event
      assert event.ok == false
      assert event.error == "Connection timeout"
      assert event.answer == "Partial response before error"
      assert event.resume == token
    end

    test "note creates warning action with auto-incrementing ID" do
      factory = EventFactory.new("lemon")

      {event1, factory} = EventFactory.note(factory, "First warning")
      {event2, factory} = EventFactory.note(factory, "Second warning")
      {event3, _factory} = EventFactory.note(factory, "Third warning")

      assert event1.action.id == "note_0"
      assert event2.action.id == "note_1"
      assert event3.action.id == "note_2"

      assert event1.action.kind == :warning
      assert event1.phase == :completed
    end
  end

  # ============================================================================
  # ResumeToken Tests
  # ============================================================================

  describe "ResumeToken for lemon engine" do
    test "creates new token" do
      token = ResumeToken.new("lemon", "abc12345")

      assert token.engine == "lemon"
      assert token.value == "abc12345"
    end

    test "format/1 returns lemon resume command" do
      token = ResumeToken.new("lemon", "abc12345")

      assert ResumeToken.format(token) == "`lemon resume abc12345`"
    end

    test "extract_resume/1 extracts lemon token" do
      text = "You can continue with lemon resume session_xyz123"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "lemon"
      assert token.value == "session_xyz123"
    end

    test "extract_resume/1 extracts lemon token with backticks" do
      text = "Run `lemon resume abc123` to continue"
      token = ResumeToken.extract_resume(text)

      assert token.engine == "lemon"
      assert token.value == "abc123"
    end

    test "extract_resume/2 with specific engine" do
      text = "Run lemon resume abc and claude --resume xyz"

      lemon_token = ResumeToken.extract_resume(text, "lemon")
      assert lemon_token.engine == "lemon"
      assert lemon_token.value == "abc"

      claude_token = ResumeToken.extract_resume(text, "claude")
      assert claude_token.engine == "claude"
      assert claude_token.value == "xyz"
    end

    test "is_resume_line/1 recognizes lemon resume lines" do
      assert ResumeToken.is_resume_line("lemon resume abc123")
      assert ResumeToken.is_resume_line("`lemon resume abc123`")
      refute ResumeToken.is_resume_line("Please run lemon resume abc123")
      refute ResumeToken.is_resume_line("random text")
    end

    test "is_resume_line/2 with lemon engine" do
      assert ResumeToken.is_resume_line("lemon resume abc123", "lemon")
      refute ResumeToken.is_resume_line("claude --resume abc123", "lemon")
    end
  end

  # ============================================================================
  # Action Type Tests
  # ============================================================================

  describe "Action type" do
    test "creates action with all fields" do
      action = Action.new("tool_123", :file_change, "Write config.ex", %{path: "/app/config.ex"})

      assert action.id == "tool_123"
      assert action.kind == :file_change
      assert action.title == "Write config.ex"
      assert action.detail == %{path: "/app/config.ex"}
    end

    test "creates action with default detail" do
      action = Action.new("tool_456", :tool, "Search files")

      assert action.id == "tool_456"
      assert action.kind == :tool
      assert action.title == "Search files"
      assert action.detail == %{}
    end
  end

  # ============================================================================
  # Tool Kind Mapping Tests (mirrors translate_and_emit logic)
  # ============================================================================

  describe "tool kind mapping" do
    # These tests verify the expected kind mappings based on tool names
    # as documented in the LemonRunner module

    test "Bash maps to :command" do
      assert tool_kind("Bash") == :command
    end

    test "Read maps to :tool" do
      assert tool_kind("Read") == :tool
    end

    test "Write maps to :file_change" do
      assert tool_kind("Write") == :file_change
    end

    test "Edit maps to :file_change" do
      assert tool_kind("Edit") == :file_change
    end

    test "Glob maps to :tool" do
      assert tool_kind("Glob") == :tool
    end

    test "Grep maps to :tool" do
      assert tool_kind("Grep") == :tool
    end

    test "WebSearch maps to :web_search" do
      assert tool_kind("WebSearch") == :web_search
    end

    test "WebFetch maps to :web_search" do
      assert tool_kind("WebFetch") == :web_search
    end

    test "Task maps to :subagent" do
      assert tool_kind("Task") == :subagent
    end

    test "Unknown tool maps to :tool" do
      assert tool_kind("CustomTool") == :tool
      assert tool_kind("Anything") == :tool
    end

    # Helper to mirror the private function logic
    defp tool_kind(name) do
      case name do
        "Bash" -> :command
        "Read" -> :tool
        "Write" -> :file_change
        "Edit" -> :file_change
        "Glob" -> :tool
        "Grep" -> :tool
        "WebSearch" -> :web_search
        "WebFetch" -> :web_search
        "Task" -> :subagent
        _ -> :tool
      end
    end
  end

  # ============================================================================
  # Tool Title Generation Tests (mirrors translate_and_emit logic)
  # ============================================================================

  describe "tool title generation" do
    test "Bash with command shows preview" do
      title = tool_title("Bash", %{"command" => "ls -la"})
      assert title == "$ ls -la"
    end

    test "Bash truncates long commands" do
      long_cmd = String.duplicate("a", 100)
      title = tool_title("Bash", %{"command" => long_cmd})
      assert String.starts_with?(title, "$ ")
      assert String.length(title) <= 62  # "$ " + 60 chars
    end

    test "Bash takes first line of multiline command" do
      title = tool_title("Bash", %{"command" => "echo line1\necho line2"})
      assert title == "$ echo line1"
    end

    test "Read shows file basename" do
      title = tool_title("Read", %{"file_path" => "/path/to/file.ex"})
      assert title == "Read file.ex"
    end

    test "Write shows file basename" do
      title = tool_title("Write", %{"file_path" => "/path/to/new_file.ex"})
      assert title == "Write new_file.ex"
    end

    test "Edit shows file basename" do
      title = tool_title("Edit", %{"file_path" => "/path/to/edit.ex"})
      assert title == "Edit edit.ex"
    end

    test "Glob shows pattern" do
      title = tool_title("Glob", %{"pattern" => "**/*.ex"})
      assert title == "Glob **/*.ex"
    end

    test "Grep shows pattern" do
      title = tool_title("Grep", %{"pattern" => "defmodule"})
      assert title == "Grep defmodule"
    end

    test "WebSearch shows truncated query" do
      title = tool_title("WebSearch", %{"query" => "how to write Elixir tests"})
      assert title == "Search: how to write Elixir tests"
    end

    test "WebSearch truncates long query" do
      long_query = String.duplicate("word ", 20)
      title = tool_title("WebSearch", %{"query" => long_query})
      assert String.length(title) <= 48  # "Search: " + 40 chars
    end

    test "Task shows truncated description" do
      title = tool_title("Task", %{"description" => "Review the pull request"})
      assert title == "Task: Review the pull request"
    end

    test "Unknown tool shows just the name" do
      title = tool_title("CustomTool", %{})
      assert title == "CustomTool"
    end

    # Helper to mirror the private function logic
    defp tool_title(name, args) do
      case {name, args} do
        {"Bash", %{"command" => cmd}} ->
          cmd_preview = cmd |> String.split("\n") |> hd() |> String.slice(0, 60)
          "$ #{cmd_preview}"

        {"Read", %{"file_path" => path}} ->
          "Read #{Path.basename(path)}"

        {"Write", %{"file_path" => path}} ->
          "Write #{Path.basename(path)}"

        {"Edit", %{"file_path" => path}} ->
          "Edit #{Path.basename(path)}"

        {"Glob", %{"pattern" => pattern}} ->
          "Glob #{pattern}"

        {"Grep", %{"pattern" => pattern}} ->
          "Grep #{pattern}"

        {"WebSearch", %{"query" => query}} ->
          "Search: #{String.slice(query, 0, 40)}"

        {"Task", %{"description" => desc}} ->
          "Task: #{String.slice(desc, 0, 40)}"

        {name, _} ->
          name
      end
    end
  end

  # ============================================================================
  # Result Truncation Tests
  # ============================================================================

  describe "result truncation" do
    test "short results are not truncated" do
      result = "short result"
      assert truncate_result(result) == "short result"
    end

    test "long results are truncated at 500 chars" do
      result = String.duplicate("a", 600)
      truncated = truncate_result(result)

      assert String.length(truncated) == 503  # 500 + "..."
      assert String.ends_with?(truncated, "...")
    end

    test "exactly 500 char result is not truncated" do
      result = String.duplicate("a", 500)
      assert truncate_result(result) == result
    end

    test "non-string results are inspected" do
      result = %{key: "value", count: 42}
      truncated = truncate_result(result)

      assert is_binary(truncated)
      assert String.contains?(truncated, "key")
    end

    # Helper to mirror the private function logic
    defp truncate_result(result) when is_binary(result) do
      if String.length(result) > 500 do
        String.slice(result, 0, 500) <> "..."
      else
        result
      end
    end

    defp truncate_result(result), do: inspect(result, limit: 500)
  end

  # ============================================================================
  # Error Formatting Tests
  # ============================================================================

  describe "error formatting" do
    test "binary errors pass through" do
      assert format_error("Connection failed") == "Connection failed"
    end

    test "atom errors are converted to string" do
      assert format_error(:timeout) == "timeout"
      assert format_error(:connection_refused) == "connection_refused"
    end

    test "tuple errors are unwrapped" do
      assert format_error({:error, "inner error"}) == "inner error"
      assert format_error({:error, :inner_atom}) == "inner_atom"
    end

    test "complex terms are inspected" do
      assert format_error({:failed, %{reason: :unknown}}) == "{:failed, %{reason: :unknown}}"
    end

    # Helper to mirror the private function logic
    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp format_error({:error, reason}), do: format_error(reason)
    defp format_error(reason), do: inspect(reason)
  end

  # ============================================================================
  # Answer Extraction Tests
  # ============================================================================

  describe "answer extraction from messages" do
    test "extracts text from last assistant message with binary content" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: "Here is my answer"}
      ]

      assert extract_answer(messages, "") == "Here is my answer"
    end

    test "extracts text from list content" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: [
          %{type: :text, text: "First part. "},
          %{type: :text, text: "Second part."}
        ]}
      ]

      assert extract_answer(messages, "") == "First part. \nSecond part."
    end

    test "falls back to accumulated text when no assistant message" do
      messages = [
        %{role: :user, content: "Hello"}
      ]

      assert extract_answer(messages, "accumulated text") == "accumulated text"
    end

    test "falls back to accumulated text when content is nil" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: nil}
      ]

      assert extract_answer(messages, "fallback") == "fallback"
    end

    test "finds last assistant message when multiple exist" do
      messages = [
        %{role: :assistant, content: "First response"},
        %{role: :user, content: "Follow up"},
        %{role: :assistant, content: "Latest response"}
      ]

      assert extract_answer(messages, "") == "Latest response"
    end

    # Helper to mirror the private function logic
    defp extract_answer(messages, accumulated_text) do
      last_assistant =
        messages
        |> Enum.reverse()
        |> Enum.find(fn msg ->
          case msg do
            %{role: :assistant} -> true
            _ -> false
          end
        end)

      case last_assistant do
        %{content: content} when is_binary(content) -> content
        %{content: content} when is_list(content) -> extract_text_content(content)
        _ -> accumulated_text
      end
    end

    defp extract_text_content(content) do
      content
      |> Enum.filter(fn
        %{type: :text} -> true
        _ -> false
      end)
      |> Enum.map(fn %{text: text} -> text end)
      |> Enum.join("\n")
    end
  end

  # ============================================================================
  # Usage Aggregation Tests
  # ============================================================================

  describe "usage aggregation from messages" do
    test "returns nil when no usage present" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: "Hi"}
      ]

      assert build_usage(messages) == nil
    end

    test "aggregates usage from single message" do
      messages = [
        %{role: :assistant, content: "Hi", usage: %{input_tokens: 10, output_tokens: 5}}
      ]

      usage = build_usage(messages)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
    end

    test "sums usage from multiple messages" do
      messages = [
        %{role: :assistant, content: "First", usage: %{input_tokens: 10, output_tokens: 5}},
        %{role: :assistant, content: "Second", usage: %{input_tokens: 15, output_tokens: 8}}
      ]

      usage = build_usage(messages)
      assert usage.input_tokens == 25
      assert usage.output_tokens == 13
    end

    test "handles mixed messages with and without usage" do
      messages = [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: "First", usage: %{input_tokens: 10, output_tokens: 5}},
        %{role: :user, content: "Thanks"},
        %{role: :assistant, content: "Second", usage: %{input_tokens: 20, output_tokens: 10}}
      ]

      usage = build_usage(messages)
      assert usage.input_tokens == 30
      assert usage.output_tokens == 15
    end

    # Helper to mirror the private function logic
    defp build_usage(messages) do
      messages
      |> Enum.reduce(%{}, fn msg, acc ->
        case Map.get(msg, :usage) do
          nil -> acc
          usage -> merge_usage(acc, usage)
        end
      end)
      |> case do
        empty when map_size(empty) == 0 -> nil
        usage -> usage
      end
    end

    defp merge_usage(acc, usage) do
      Map.merge(acc, usage, fn _k, v1, v2 ->
        if is_number(v1) and is_number(v2), do: v1 + v2, else: v2
      end)
    end
  end

  # ============================================================================
  # Event Type Tests
  # ============================================================================

  describe "StartedEvent" do
    test "creates event with required fields" do
      token = ResumeToken.new("lemon", "session_123")
      event = StartedEvent.new("lemon", token)

      assert event.type == :started
      assert event.engine == "lemon"
      assert event.resume == token
      assert event.title == nil
      assert event.meta == nil
    end

    test "creates event with optional fields" do
      token = ResumeToken.new("lemon", "session_123")
      event = StartedEvent.new("lemon", token, title: "New Session", meta: %{cwd: "/tmp"})

      assert event.title == "New Session"
      assert event.meta == %{cwd: "/tmp"}
    end
  end

  describe "ActionEvent" do
    test "creates event with required fields" do
      action = Action.new("tool_1", :command, "$ ls")
      event = ActionEvent.new("lemon", action, :started)

      assert event.type == :action
      assert event.engine == "lemon"
      assert event.action == action
      assert event.phase == :started
      assert event.ok == nil
      assert event.message == nil
      assert event.level == nil
    end

    test "creates event with optional fields" do
      action = Action.new("tool_1", :command, "$ ls")
      event = ActionEvent.new("lemon", action, :completed,
        ok: true,
        message: "Command succeeded",
        level: :info
      )

      assert event.ok == true
      assert event.message == "Command succeeded"
      assert event.level == :info
    end
  end

  describe "CompletedEvent" do
    test "ok/3 creates successful completion" do
      token = ResumeToken.new("lemon", "session_123")
      event = CompletedEvent.ok("lemon", "Task done", resume: token)

      assert event.type == :completed
      assert event.engine == "lemon"
      assert event.ok == true
      assert event.answer == "Task done"
      assert event.resume == token
      assert event.error == nil
    end

    test "error/3 creates failed completion" do
      token = ResumeToken.new("lemon", "session_123")
      event = CompletedEvent.error("lemon", "Timeout",
        resume: token,
        answer: "Partial response"
      )

      assert event.type == :completed
      assert event.ok == false
      assert event.error == "Timeout"
      assert event.answer == "Partial response"
      assert event.resume == token
    end

    test "error/3 defaults answer to empty string" do
      event = CompletedEvent.error("lemon", "Failed")

      assert event.answer == ""
    end
  end

  # ============================================================================
  # Session File Path Tests
  # ============================================================================

  describe "session file path generation" do
    test "generates correct session file path" do
      session_id = "abc12345"
      cwd = "/home/user/project"

      expected = "/home/user/project/.lemon/sessions/abc12345.jsonl"
      assert session_file_path(session_id, cwd) == expected
    end

    test "handles cwd with trailing slash" do
      session_id = "xyz789"
      cwd = "/tmp/"

      # Path.join handles trailing slashes correctly
      expected = "/tmp/.lemon/sessions/xyz789.jsonl"
      assert session_file_path(session_id, cwd) == expected
    end

    # Helper to mirror the private function logic
    defp session_file_path(session_id, cwd) do
      Path.join([cwd, ".lemon", "sessions", "#{session_id}.jsonl"])
    end
  end

  # ============================================================================
  # Resume Token Validation Tests
  # ============================================================================

  describe "resume token engine validation" do
    test "accepts matching engine" do
      token = ResumeToken.new("lemon", "session_123")
      assert validate_resume_engine(token, "lemon") == :ok
    end

    test "rejects mismatched engine" do
      token = ResumeToken.new("claude", "session_123")
      assert validate_resume_engine(token, "lemon") == {:error, {:wrong_engine, "claude", "lemon"}}
    end

    test "accepts nil token" do
      assert validate_resume_engine(nil, "lemon") == :ok
    end

    # Helper to mirror the session resume validation logic
    defp validate_resume_engine(nil, _expected), do: :ok
    defp validate_resume_engine(%ResumeToken{engine: engine}, expected) when engine == expected, do: :ok
    defp validate_resume_engine(%ResumeToken{engine: other}, expected), do: {:error, {:wrong_engine, other, expected}}
  end

  # ============================================================================
  # Event Stream Integration Tests
  # ============================================================================

  describe "EventStream patterns used by LemonRunner" do
    test "EventStream can be created with runner-like options" do
      {:ok, stream} = EventStream.start_link(
        max_queue: 10_000,
        drop_strategy: :drop_oldest,
        owner: self(),
        timeout: 600_000
      )

      assert Process.alive?(stream)

      # Clean up
      EventStream.cancel(stream, :test_cleanup)
    end

    test "EventStream push_async accepts cli_event tuples" do
      {:ok, stream} = EventStream.start_link(owner: self())

      factory = EventFactory.new("lemon")
      token = ResumeToken.new("lemon", "test_session")
      {started_event, _factory} = EventFactory.started(factory, token)

      # This is how LemonRunner emits events
      :ok = EventStream.push_async(stream, {:cli_event, started_event})

      # Verify the event can be consumed
      events = EventStream.events(stream)

      Task.async(fn ->
        Process.sleep(10)
        EventStream.complete(stream, [])
      end)

      received_events = Enum.to_list(events)
      assert length(received_events) >= 1

      # Find the cli_event we pushed
      cli_events = Enum.filter(received_events, fn
        {:cli_event, _} -> true
        _ -> false
      end)

      assert length(cli_events) == 1
      {:cli_event, event} = hd(cli_events)
      assert %StartedEvent{} = event
    end

    test "EventStream complete signals end of stream" do
      {:ok, stream} = EventStream.start_link(owner: self())

      # Push some events
      EventStream.push_async(stream, {:cli_event, :test_event})
      EventStream.complete(stream, [])

      # Verify stream ends
      events = EventStream.events(stream) |> Enum.to_list()

      # Should include the test event and agent_end
      assert Enum.any?(events, fn
        {:cli_event, :test_event} -> true
        _ -> false
      end)

      assert Enum.any?(events, fn
        {:agent_end, []} -> true
        _ -> false
      end)
    end
  end

  # ============================================================================
  # State Structure Tests
  # ============================================================================

  describe "LemonRunner state structure" do
    test "state struct has all expected fields" do
      # Verify the struct can be created with all fields
      state = %LemonRunner{
        session: nil,
        session_ref: nil,
        session_id: "test_123",
        stream: nil,
        factory: EventFactory.new("lemon"),
        prompt: "test prompt",
        cwd: "/tmp",
        resume: nil,
        accumulated_text: "",
        pending_actions: %{},
        started_emitted: false,
        completed_emitted: false
      }

      assert state.session_id == "test_123"
      assert state.prompt == "test prompt"
      assert state.cwd == "/tmp"
      assert state.accumulated_text == ""
      assert state.pending_actions == %{}
      assert state.started_emitted == false
      assert state.completed_emitted == false
    end
  end
end
