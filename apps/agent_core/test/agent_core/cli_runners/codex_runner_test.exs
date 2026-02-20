defmodule AgentCore.CliRunners.CodexRunnerTest do
  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.CodexRunner
  alias AgentCore.CliRunners.CodexRunner.RunnerState

  alias AgentCore.CliRunners.CodexSchema.{
    AgentMessageItem,
    CommandExecutionItem,
    ErrorItem,
    FileChangeItem,
    FileUpdateChange,
    ItemCompleted,
    ItemStarted,
    ItemUpdated,
    McpToolCallItem,
    McpToolCallItemError,
    McpToolCallItemResult,
    ReasoningItem,
    StreamError,
    ThreadStarted,
    TodoItem,
    TodoListItem,
    TurnCompleted,
    TurnFailed,
    TurnStarted,
    Usage,
    WebSearchItem
  }

  alias AgentCore.CliRunners.CodexSchema.ThreadError
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  # ============================================================================
  # Engine Identity
  # ============================================================================

  describe "engine/0" do
    test "returns codex" do
      assert CodexRunner.engine() == "codex"
    end
  end

  # ============================================================================
  # Command Building
  # ============================================================================

  describe "build_command/3" do
    setup do
      prev_env = System.get_env("LEMON_CODEX_EXTRA_ARGS")
      prev_auto = System.get_env("LEMON_CODEX_AUTO_APPROVE")

      System.delete_env("LEMON_CODEX_EXTRA_ARGS")
      System.delete_env("LEMON_CODEX_AUTO_APPROVE")

      on_exit(fn ->
        if prev_env do
          System.put_env("LEMON_CODEX_EXTRA_ARGS", prev_env)
        else
          System.delete_env("LEMON_CODEX_EXTRA_ARGS")
        end

        if prev_auto do
          System.put_env("LEMON_CODEX_AUTO_APPROVE", prev_auto)
        else
          System.delete_env("LEMON_CODEX_AUTO_APPROVE")
        end
      end)

      :ok
    end

    test "builds command for new session" do
      state = RunnerState.new()
      {cmd, args} = CodexRunner.build_command("Hello", nil, state)

      assert cmd == "codex"

      assert args == [
               "-c",
               "notify=[]",
               "exec",
               "--json",
               "--skip-git-repo-check",
               "--color=never",
               "-"
             ]
    end

    test "builds command for resumed session" do
      state = RunnerState.new()
      token = ResumeToken.new("codex", "thread_123")
      {cmd, args} = CodexRunner.build_command("Continue", token, state)

      assert cmd == "codex"

      assert args == [
               "-c",
               "notify=[]",
               "exec",
               "--json",
               "--skip-git-repo-check",
               "--color=never",
               "resume",
               "thread_123",
               "-"
             ]
    end

    test "passes model override to codex exec via --model" do
      state = RunnerState.new(nil, "openai-codex:gpt-5.3-codex")
      {_cmd, args} = CodexRunner.build_command("Hello", nil, state)

      assert "--model" in args
      model_idx = Enum.find_index(args, &(&1 == "--model"))
      assert Enum.at(args, model_idx + 1) == "gpt-5.3-codex"
    end

    test "passes config model via --model when no override is present" do
      config = %LemonCore.Config{agent: %{cli: %{codex: %{model: "gpt-5.2-codex"}}}}
      state = RunnerState.new(config)
      {_cmd, args} = CodexRunner.build_command("Hello", nil, state)

      assert "--model" in args
      model_idx = Enum.find_index(args, &(&1 == "--model"))
      assert Enum.at(args, model_idx + 1) == "gpt-5.2-codex"
    end

    test "adds auto-approve flag when enabled via config" do
      config = %LemonCore.Config{agent: %{cli: %{codex: %{auto_approve: true}}}}
      state = RunnerState.new(config)
      {_cmd, args} = CodexRunner.build_command("Hello", nil, state)

      assert "--dangerously-bypass-approvals-and-sandbox" in args
    end

    test "adds auto-approve flag when enabled via environment variable" do
      System.put_env("LEMON_CODEX_AUTO_APPROVE", "1")
      state = RunnerState.new(LemonCore.Config.load())
      {_cmd, args} = CodexRunner.build_command("Hello", nil, state)

      assert "--dangerously-bypass-approvals-and-sandbox" in args
    end

    test "respects extra args from environment variable" do
      System.put_env("LEMON_CODEX_EXTRA_ARGS", "--model o1 --provider openai")
      state = RunnerState.new(LemonCore.Config.load())
      {_cmd, args} = CodexRunner.build_command("Hello", nil, state)

      assert "--model" in args
      assert "o1" in args
      assert "--provider" in args
      assert "openai" in args
    end

    test "config takes precedence over default extra args" do
      config = %LemonCore.Config{agent: %{cli: %{codex: %{extra_args: ["--custom", "value"]}}}}
      state = RunnerState.new(config)
      {_cmd, args} = CodexRunner.build_command("Hello", nil, state)

      assert "--custom" in args
      assert "value" in args
      refute "-c" in args
    end
  end

  # ============================================================================
  # stdin_payload/3
  # ============================================================================

  describe "stdin_payload/3" do
    test "returns prompt with newline" do
      state = RunnerState.new()
      assert CodexRunner.stdin_payload("Hello", nil, state) == "Hello\n"
    end

    test "preserves multiline prompts" do
      state = RunnerState.new()
      prompt = "Line 1\nLine 2\nLine 3"
      assert CodexRunner.stdin_payload(prompt, nil, state) == "Line 1\nLine 2\nLine 3\n"
    end

    test "works with resume token" do
      state = RunnerState.new()
      token = ResumeToken.new("codex", "thread_123")
      assert CodexRunner.stdin_payload("Continue", token, state) == "Continue\n"
    end
  end

  # ============================================================================
  # init_state/2
  # ============================================================================

  describe "init_state/2" do
    test "creates fresh RunnerState" do
      state = CodexRunner.init_state("Hello", nil)

      assert %RunnerState{} = state
      assert state.final_answer == nil
      assert state.turn_index == 0
      assert state.found_session == nil
      assert state.factory != nil
    end

    test "ignores prompt and resume in state initialization" do
      state1 = CodexRunner.init_state("Prompt 1", nil)
      state2 = CodexRunner.init_state("Prompt 2", ResumeToken.new("codex", "t_1"))

      # Both should have same initial structure
      assert state1.turn_index == state2.turn_index
      assert state1.final_answer == state2.final_answer
    end

    test "captures model override from init_state/4 options" do
      state = CodexRunner.init_state("Prompt 1", nil, File.cwd!(), model: "codex:gpt-5.1-codex")
      assert state.model_override == "gpt-5.1-codex"
    end
  end

  # ============================================================================
  # decode_line/1
  # ============================================================================

  describe "decode_line/1" do
    test "decodes valid ThreadStarted event" do
      json = ~s|{"type":"thread.started","thread_id":"abc123"}|
      assert {:ok, %ThreadStarted{thread_id: "abc123"}} = CodexRunner.decode_line(json)
    end

    test "decodes valid TurnCompleted event" do
      json = ~s|{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":50}}|
      assert {:ok, %TurnCompleted{usage: usage}} = CodexRunner.decode_line(json)
      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = CodexRunner.decode_line("not valid json")
    end

    test "returns error for unknown event type" do
      json = ~s|{"type":"unknown.event"}|
      assert {:error, {:unknown_event_type, "unknown.event"}} = CodexRunner.decode_line(json)
    end
  end

  # ============================================================================
  # translate_event/2 - Session Lifecycle
  # ============================================================================

  describe "translate_event/2 - session lifecycle" do
    test "translates ThreadStarted to StartedEvent" do
      state = RunnerState.new()
      event = %ThreadStarted{thread_id: "thread_abc"}

      {events, new_state, opts} = CodexRunner.translate_event(event, state)

      assert [%StartedEvent{} = started] = events
      assert started.engine == "codex"
      assert started.resume.value == "thread_abc"
      assert new_state.found_session.value == "thread_abc"
      assert opts[:found_session].value == "thread_abc"
    end

    test "translates TurnStarted to action event" do
      state = RunnerState.new()
      event = %TurnStarted{}

      {events, new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :started
      assert action.action.kind == :turn
      assert new_state.turn_index == 1
    end

    test "increments turn_index for each TurnStarted" do
      state = RunnerState.new()

      {_, state, _} = CodexRunner.translate_event(%TurnStarted{}, state)
      assert state.turn_index == 1

      {_, state, _} = CodexRunner.translate_event(%TurnStarted{}, state)
      assert state.turn_index == 2

      {_, state, _} = CodexRunner.translate_event(%TurnStarted{}, state)
      assert state.turn_index == 3
    end

    test "translates TurnCompleted to CompletedEvent" do
      state = %{
        RunnerState.new()
        | final_answer: "Done!",
          found_session: ResumeToken.new("codex", "thread_123")
      }

      event = %TurnCompleted{usage: %Usage{input_tokens: 100, output_tokens: 200}}

      {events, _new_state, opts} = CodexRunner.translate_event(event, state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == true
      assert completed.answer == "Done!"
      assert completed.resume.value == "thread_123"
      assert completed.usage.input_tokens == 100
      assert opts[:done] == true
    end

    test "translates TurnCompleted with empty answer when no final_answer captured" do
      state = %{RunnerState.new() | found_session: ResumeToken.new("codex", "thread_123")}
      event = %TurnCompleted{usage: %Usage{}}

      {events, _new_state, opts} = CodexRunner.translate_event(event, state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == true
      assert completed.answer == ""
      assert opts[:done] == true
    end

    test "translates TurnFailed to CompletedEvent with error" do
      state = %{
        RunnerState.new()
        | final_answer: "partial",
          found_session: ResumeToken.new("codex", "t_1")
      }

      event = %TurnFailed{error: %ThreadError{message: "API rate limit exceeded"}}

      {events, _new_state, opts} = CodexRunner.translate_event(event, state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == false
      assert completed.error == "API rate limit exceeded"
      assert completed.answer == "partial"
      assert completed.resume.value == "t_1"
      assert opts[:done] == true
    end

    test "preserves cached_input_tokens in usage" do
      state = %{RunnerState.new() | found_session: ResumeToken.new("codex", "t_1")}

      event = %TurnCompleted{
        usage: %Usage{input_tokens: 100, cached_input_tokens: 50, output_tokens: 200}
      }

      {[completed], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert completed.usage.cached_input_tokens == 50
    end
  end

  # ============================================================================
  # translate_event/2 - Stream Errors
  # ============================================================================

  describe "translate_event/2 - stream errors" do
    test "translates reconnection message (attempt 1)" do
      state = RunnerState.new()
      event = %StreamError{message: "Reconnecting...1/3"}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :started
      assert action.action.kind == :note
      assert action.action.detail.attempt == 1
      assert action.action.detail.max == 3
    end

    test "translates reconnection message (attempt 2+) as updated" do
      state = RunnerState.new()
      event = %StreamError{message: "Reconnecting...2/3"}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :updated
      assert action.action.detail.attempt == 2
    end

    test "translates non-reconnection error as warning" do
      state = RunnerState.new()
      event = %StreamError{message: "Some error"}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :completed
      assert action.action.kind == :warning
      assert action.ok == false
    end

    test "handles various reconnection message formats" do
      state = RunnerState.new()

      # Different spacing/formatting
      event1 = %StreamError{message: "Reconnecting... 1/5"}
      {[action1], _, _} = CodexRunner.translate_event(event1, state)
      assert action1.action.detail.attempt == 1
      assert action1.action.detail.max == 5

      event2 = %StreamError{message: "Reconnecting to server...3/10"}
      {[action2], _, _} = CodexRunner.translate_event(event2, state)
      assert action2.action.detail.attempt == 3
      assert action2.action.detail.max == 10
    end
  end

  # ============================================================================
  # translate_event/2 - Command Execution Items
  # ============================================================================

  describe "translate_event/2 - command execution items" do
    test "translates command execution started" do
      state = RunnerState.new()
      item = %CommandExecutionItem{id: "cmd_1", command: "ls -la", status: :in_progress}
      event = %ItemStarted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :started
      assert action.action.kind == :command
      assert action.action.id == "cmd_1"
    end

    test "translates command execution updated" do
      state = RunnerState.new()
      item = %CommandExecutionItem{id: "cmd_1", command: "npm install", status: :in_progress}
      event = %ItemUpdated{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :updated
      assert action.action.kind == :command
    end

    test "translates command execution completed with success" do
      state = RunnerState.new()
      item = %CommandExecutionItem{id: "cmd_1", command: "ls", exit_code: 0, status: :completed}
      event = %ItemCompleted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :completed
      assert action.ok == true
      assert action.action.detail.exit_code == 0
    end

    test "translates command execution completed with failure" do
      state = RunnerState.new()
      item = %CommandExecutionItem{id: "cmd_1", command: "false", exit_code: 1, status: :failed}
      event = %ItemCompleted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.ok == false
      assert action.action.detail.exit_code == 1
      assert action.action.detail.status == :failed
    end

    test "translates command execution declined" do
      state = RunnerState.new()

      item = %CommandExecutionItem{
        id: "cmd_1",
        command: "rm -rf /",
        exit_code: nil,
        status: :declined
      }

      event = %ItemCompleted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.ok == false
      assert action.action.detail.status == :declined
    end

    test "relativizes long commands with home directory" do
      state = RunnerState.new()
      home = System.user_home() || "/home/user"

      item = %CommandExecutionItem{
        id: "cmd_1",
        command: "cat #{home}/very/long/path/to/file.txt",
        status: :in_progress
      }

      event = %ItemStarted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert String.contains?(action.action.title, "~")
      refute String.contains?(action.action.title, home)
    end

    test "truncates very long commands" do
      state = RunnerState.new()
      long_command = String.duplicate("a", 200)
      item = %CommandExecutionItem{id: "cmd_1", command: long_command, status: :in_progress}
      event = %ItemStarted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert String.length(action.action.title) <= 80
    end
  end

  # ============================================================================
  # translate_event/2 - Agent Message Items
  # ============================================================================

  describe "translate_event/2 - agent message items" do
    test "captures agent message as final answer on completion" do
      state = RunnerState.new()
      item = %AgentMessageItem{id: "msg_1", text: "Here is my answer"}
      event = %ItemCompleted{item: item}

      {events, new_state, _opts} = CodexRunner.translate_event(event, state)

      assert events == []
      assert new_state.final_answer == "Here is my answer"
    end

    test "ignores agent message on started phase" do
      state = RunnerState.new()
      item = %AgentMessageItem{id: "msg_1", text: "Starting..."}
      event = %ItemStarted{item: item}

      {events, new_state, _opts} = CodexRunner.translate_event(event, state)

      assert events == []
      assert new_state.final_answer == nil
    end

    test "ignores agent message on updated phase" do
      state = RunnerState.new()
      item = %AgentMessageItem{id: "msg_1", text: "In progress..."}
      event = %ItemUpdated{item: item}

      {events, new_state, _opts} = CodexRunner.translate_event(event, state)

      assert events == []
      assert new_state.final_answer == nil
    end

    test "overwrites previous final answer with new completion" do
      state = %{RunnerState.new() | final_answer: "Old answer"}
      item = %AgentMessageItem{id: "msg_2", text: "New answer"}
      event = %ItemCompleted{item: item}

      {_events, new_state, _opts} = CodexRunner.translate_event(event, state)

      assert new_state.final_answer == "New answer"
    end
  end

  # ============================================================================
  # translate_event/2 - File Change Items
  # ============================================================================

  describe "translate_event/2 - file change items" do
    test "translates file change completed with single file" do
      state = RunnerState.new()

      item = %FileChangeItem{
        id: "fc_1",
        changes: [%FileUpdateChange{path: "foo.ex", kind: :add}],
        status: :completed
      }

      event = %ItemCompleted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.kind == :file_change
      assert action.action.title == "1 file changed"
      assert action.ok == true
    end

    test "translates file change completed with multiple files" do
      state = RunnerState.new()

      item = %FileChangeItem{
        id: "fc_1",
        changes: [
          %FileUpdateChange{path: "foo.ex", kind: :add},
          %FileUpdateChange{path: "bar.ex", kind: :update}
        ],
        status: :completed
      }

      event = %ItemCompleted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.kind == :file_change
      assert action.action.title == "2 files changed"
      assert action.ok == true
    end

    test "translates file change with no changes" do
      state = RunnerState.new()
      item = %FileChangeItem{id: "fc_1", changes: [], status: :completed}
      event = %ItemCompleted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.title == "no changes"
    end

    test "ignores file change on started phase" do
      state = RunnerState.new()
      item = %FileChangeItem{id: "fc_1", changes: [], status: :in_progress}
      event = %ItemStarted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)
      assert events == []
    end

    test "ignores file change on updated phase" do
      state = RunnerState.new()
      item = %FileChangeItem{id: "fc_1", changes: [], status: :in_progress}
      event = %ItemUpdated{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)
      assert events == []
    end

    test "normalizes change list in detail" do
      state = RunnerState.new()

      item = %FileChangeItem{
        id: "fc_1",
        changes: [
          %FileUpdateChange{path: "/full/path/foo.ex", kind: :add},
          %FileUpdateChange{path: "relative/bar.ex", kind: :delete}
        ],
        status: :completed
      }

      event = %ItemCompleted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [change1, change2] = action.action.detail.changes
      assert change1.path == "/full/path/foo.ex"
      assert change1.kind == :add
      assert change2.path == "relative/bar.ex"
      assert change2.kind == :delete
    end

    test "marks failed file changes as not ok" do
      state = RunnerState.new()

      item = %FileChangeItem{
        id: "fc_1",
        changes: [%FileUpdateChange{path: "foo.ex", kind: :add}],
        status: :failed
      }

      event = %ItemCompleted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.ok == false
    end
  end

  # ============================================================================
  # translate_event/2 - MCP Tool Call Items
  # ============================================================================

  describe "translate_event/2 - mcp tool call items" do
    test "translates mcp tool call started" do
      state = RunnerState.new()

      item = %McpToolCallItem{
        id: "t_1",
        server: "filesystem",
        tool: "read_file",
        arguments: %{"path" => "foo.ex"},
        status: :in_progress
      }

      event = %ItemStarted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.kind == :tool
      assert action.action.title == "filesystem.read_file"
      assert action.action.detail.server == "filesystem"
      assert action.action.detail.tool == "read_file"
    end

    test "translates mcp tool call with empty server" do
      state = RunnerState.new()

      item = %McpToolCallItem{
        id: "t_1",
        server: "",
        tool: "some_tool",
        arguments: %{},
        status: :in_progress
      }

      event = %ItemStarted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.action.title == "some_tool"
    end

    test "translates mcp tool call with nil server" do
      state = RunnerState.new()

      item = %McpToolCallItem{
        id: "t_1",
        server: nil,
        tool: "some_tool",
        arguments: %{},
        status: :in_progress
      }

      event = %ItemStarted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.action.title == "some_tool"
    end

    test "translates mcp tool call completed with success" do
      state = RunnerState.new()

      item = %McpToolCallItem{
        id: "t_1",
        server: "fs",
        tool: "read",
        arguments: %{},
        result: %McpToolCallItemResult{content: [%{"type" => "text", "text" => "file contents"}]},
        status: :completed
      }

      event = %ItemCompleted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.ok == true
      assert action.action.detail.result_summary == "file contents"
    end

    test "translates mcp tool call completed with error" do
      state = RunnerState.new()

      item = %McpToolCallItem{
        id: "t_1",
        server: "fs",
        tool: "read",
        arguments: %{},
        error: %McpToolCallItemError{message: "File not found"},
        status: :failed
      }

      event = %ItemCompleted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.ok == false
      assert action.action.detail.error_message == "File not found"
    end

    test "truncates long result summaries" do
      state = RunnerState.new()
      long_text = String.duplicate("x", 500)

      item = %McpToolCallItem{
        id: "t_1",
        server: "fs",
        tool: "read",
        arguments: %{},
        result: %McpToolCallItemResult{content: [%{"type" => "text", "text" => long_text}]},
        status: :completed
      }

      event = %ItemCompleted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert String.length(action.action.detail.result_summary) <= 200
    end
  end

  # ============================================================================
  # translate_event/2 - Web Search Items
  # ============================================================================

  describe "translate_event/2 - web search items" do
    test "translates web search started" do
      state = RunnerState.new()
      item = %WebSearchItem{id: "ws_1", query: "elixir genserver tutorial"}
      event = %ItemStarted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.kind == :web_search
      assert action.action.title == "elixir genserver tutorial"
      assert action.phase == :started
    end

    test "translates web search updated" do
      state = RunnerState.new()
      item = %WebSearchItem{id: "ws_1", query: "elixir genserver"}
      event = %ItemUpdated{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.phase == :updated
    end

    test "translates web search completed" do
      state = RunnerState.new()
      item = %WebSearchItem{id: "ws_1", query: "elixir genserver"}
      event = %ItemCompleted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.phase == :completed
      assert action.ok == true
    end
  end

  # ============================================================================
  # translate_event/2 - Todo List Items
  # ============================================================================

  describe "translate_event/2 - todo list items" do
    test "translates todo list with mixed completion status" do
      state = RunnerState.new()

      item = %TodoListItem{
        id: "todo_1",
        items: [
          %TodoItem{text: "Task 1", completed: true},
          %TodoItem{text: "Task 2", completed: false},
          %TodoItem{text: "Task 3", completed: true}
        ]
      }

      event = %ItemCompleted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.title == "2/3 tasks"
      assert action.action.detail.done == 2
      assert action.action.detail.total == 3
    end

    test "translates empty todo list" do
      state = RunnerState.new()
      item = %TodoListItem{id: "todo_1", items: []}
      event = %ItemCompleted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.action.title == "0/0 tasks"
    end

    test "translates todo list started" do
      state = RunnerState.new()

      item = %TodoListItem{
        id: "todo_1",
        items: [%TodoItem{text: "Task 1", completed: false}]
      }

      event = %ItemStarted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.phase == :started
      assert action.action.kind == :note
    end

    test "translates todo list updated" do
      state = RunnerState.new()

      item = %TodoListItem{
        id: "todo_1",
        items: [%TodoItem{text: "Task 1", completed: true}]
      }

      event = %ItemUpdated{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.phase == :updated
    end
  end

  # ============================================================================
  # translate_event/2 - Error Items
  # ============================================================================

  describe "translate_event/2 - error items" do
    test "translates error item on completion" do
      state = RunnerState.new()
      item = %ErrorItem{id: "err_1", message: "Something went wrong"}
      event = %ItemCompleted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.kind == :warning
      assert action.action.title == "Something went wrong"
      assert action.ok == false
      assert action.level == :warning
    end

    test "ignores error item on started phase" do
      state = RunnerState.new()
      item = %ErrorItem{id: "err_1", message: "Error"}
      event = %ItemStarted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)
      assert events == []
    end

    test "ignores error item on updated phase" do
      state = RunnerState.new()
      item = %ErrorItem{id: "err_1", message: "Error"}
      event = %ItemUpdated{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)
      assert events == []
    end
  end

  # ============================================================================
  # translate_event/2 - Reasoning Items
  # ============================================================================

  describe "translate_event/2 - reasoning items" do
    test "translates reasoning item started" do
      state = RunnerState.new()
      item = %ReasoningItem{id: "r_1", text: "Let me think about this..."}
      event = %ItemStarted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.kind == :note
      assert action.phase == :started
      assert action.action.title == "Let me think about this..."
    end

    test "translates reasoning item completed" do
      state = RunnerState.new()
      item = %ReasoningItem{id: "r_1", text: "After consideration..."}
      event = %ItemCompleted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert action.phase == :completed
      assert action.ok == true
    end

    test "truncates long reasoning text in title" do
      state = RunnerState.new()
      long_text = String.duplicate("x", 200)
      item = %ReasoningItem{id: "r_1", text: long_text}
      event = %ItemStarted{item: item}

      {[action], _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert String.length(action.action.title) <= 100
    end
  end

  # ============================================================================
  # translate_event/2 - Unknown Events
  # ============================================================================

  describe "translate_event/2 - unknown events" do
    test "returns empty events for unknown event types" do
      state = RunnerState.new()
      unknown_event = %{type: :unknown}

      {events, new_state, opts} = CodexRunner.translate_event(unknown_event, state)

      assert events == []
      assert new_state == state
      assert opts == []
    end
  end

  # ============================================================================
  # handle_exit_error/2
  # ============================================================================

  describe "handle_exit_error/2" do
    test "returns note and completed error events" do
      state = %{
        RunnerState.new()
        | final_answer: "partial",
          found_session: ResumeToken.new("codex", "t_1")
      }

      {events, _new_state} = CodexRunner.handle_exit_error(1, state)

      assert [%ActionEvent{} = note, %CompletedEvent{} = completed] = events
      assert note.action.kind == :warning
      assert String.contains?(note.action.title, "failed")
      assert completed.ok == false
      assert completed.error =~ "rc=1"
    end

    test "preserves partial answer in completed event" do
      state = %{RunnerState.new() | final_answer: "partial work"}

      {[_note, completed], _new_state} = CodexRunner.handle_exit_error(127, state)

      assert completed.answer == "partial work"
    end

    test "uses empty answer when no final_answer captured" do
      state = RunnerState.new()

      {[_note, completed], _new_state} = CodexRunner.handle_exit_error(1, state)

      assert completed.answer == ""
    end

    test "includes resume token if session was found" do
      state = %{RunnerState.new() | found_session: ResumeToken.new("codex", "thread_abc")}

      {[_note, completed], _new_state} = CodexRunner.handle_exit_error(1, state)

      assert completed.resume.value == "thread_abc"
    end

    test "handles various exit codes" do
      state = RunnerState.new()

      {[note, _], _} = CodexRunner.handle_exit_error(0, state)
      assert note.action.title =~ "rc=0"

      {[note, _], _} = CodexRunner.handle_exit_error(127, state)
      assert note.action.title =~ "rc=127"

      {[note, _], _} = CodexRunner.handle_exit_error(-1, state)
      assert note.action.title =~ "rc=-1"
    end
  end

  # ============================================================================
  # handle_stream_end/1
  # ============================================================================

  describe "handle_stream_end/1" do
    test "returns error when no session found" do
      state = RunnerState.new()

      {events, _new_state} = CodexRunner.handle_stream_end(state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == false
      assert completed.error =~ "no session_id"
    end

    test "returns error when session found without turn completion" do
      state = %{
        RunnerState.new()
        | final_answer: "Done",
          found_session: ResumeToken.new("codex", "t_1")
      }

      {events, _new_state} = CodexRunner.handle_stream_end(state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == false
      assert completed.error =~ "turn completion"
      assert completed.answer == "Done"
      assert completed.resume.value == "t_1"
    end

    test "preserves resume token for future continuation" do
      state = %{RunnerState.new() | found_session: ResumeToken.new("codex", "resumable_session")}

      {[completed], _new_state} = CodexRunner.handle_stream_end(state)

      assert completed.resume.value == "resumable_session"
    end

    test "uses empty answer when no final_answer captured" do
      state = RunnerState.new()

      {[completed], _new_state} = CodexRunner.handle_stream_end(state)

      assert completed.answer == ""
    end
  end

  # ============================================================================
  # RunnerState
  # ============================================================================

  describe "RunnerState.new/0" do
    test "creates state with default values" do
      state = RunnerState.new()

      assert state.factory != nil
      assert state.final_answer == nil
      assert state.turn_index == 0
      assert state.found_session == nil
    end

    test "factory is initialized for codex engine" do
      state = RunnerState.new()

      assert state.factory.engine == "codex"
    end
  end
end

defmodule AgentCore.CliRunners.CodexRunnerIntegrationTest do
  @moduledoc """
  Integration tests for CodexRunner GenServer lifecycle and process management.

  These tests use the JsonlRunner infrastructure directly to test the CodexRunner
  callbacks without requiring the actual codex binary.
  """
  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.JsonlRunner
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  @moduletag timeout: 30_000

  # ============================================================================
  # Mock Runner for Integration Tests
  # ============================================================================

  defmodule MockCodexRunner do
    @moduledoc "Mock runner that uses bash scripts directly"
    use AgentCore.CliRunners.JsonlRunner

    alias AgentCore.CliRunners.CodexRunner
    alias AgentCore.CliRunners.CodexRunner.RunnerState

    @impl true
    def engine, do: "codex"

    @impl true
    def init_state(prompt, resume) do
      CodexRunner.init_state(prompt, resume)
    end

    @impl true
    def build_command(_prompt, _resume, _state) do
      # The script path will be passed via application env
      script = Application.get_env(:agent_core, :mock_codex_script, "true")
      {"bash", ["-c", script]}
    end

    @impl true
    def stdin_payload(prompt, resume, state) do
      CodexRunner.stdin_payload(prompt, resume, state)
    end

    @impl true
    def decode_line(line) do
      CodexRunner.decode_line(line)
    end

    @impl true
    def translate_event(data, state) do
      CodexRunner.translate_event(data, state)
    end

    @impl true
    def handle_exit_error(exit_code, state) do
      CodexRunner.handle_exit_error(exit_code, state)
    end

    @impl true
    def handle_stream_end(state) do
      CodexRunner.handle_stream_end(state)
    end
  end

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    # Store and clear configs
    prev_codex = Application.get_env(:agent_core, :codex)
    prev_script = Application.get_env(:agent_core, :mock_codex_script)

    Application.delete_env(:agent_core, :codex)
    Application.delete_env(:agent_core, :mock_codex_script)

    on_exit(fn ->
      if prev_codex do
        Application.put_env(:agent_core, :codex, prev_codex)
      else
        Application.delete_env(:agent_core, :codex)
      end

      if prev_script do
        Application.put_env(:agent_core, :mock_codex_script, prev_script)
      else
        Application.delete_env(:agent_core, :mock_codex_script)
      end
    end)

    :ok
  end

  # ============================================================================
  # GenServer Lifecycle Tests
  # ============================================================================

  describe "GenServer lifecycle - start_link/1" do
    test "starts successfully with valid options" do
      # Mock script that outputs valid JSONL
      script =
        ~s|echo '{"type":"thread.started","thread_id":"test_thread_123"}'; echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'|

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          timeout: 10_000
        )

      assert Process.alive?(pid)

      # Wait for completion
      stream = MockCodexRunner.stream(pid)
      events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      # Verify we got the expected events
      cli_events = Enum.filter(events, &match?({:cli_event, _}, &1))
      assert length(cli_events) > 0
    end

    test "handles missing prompt option" do
      # start_link without prompt will fail in init with KeyError
      # Need to trap exits since we're using start_link
      Process.flag(:trap_exit, true)
      result = MockCodexRunner.start_link(cwd: "/tmp")

      # Check that it fails or we receive an exit message
      case result do
        {:error, _} ->
          :ok

        :ignore ->
          :ok

        {:ok, _pid} ->
          # Should receive an exit message
          assert_receive {:EXIT, _, _}, 1_000
      end
    end
  end

  describe "GenServer lifecycle - terminate" do
    test "cleans up resources on normal termination" do
      script =
        ~s|echo '{"type":"thread.started","thread_id":"cleanup_test"}'; echo '{"type":"turn.completed","usage":{}}'|

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          timeout: 5_000
        )

      ref = Process.monitor(pid)
      stream = MockCodexRunner.stream(pid)

      # Consume all events
      _events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      # Wait for process to terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  # ============================================================================
  # Process Management Tests
  # ============================================================================

  describe "process management - subprocess spawning" do
    test "spawns subprocess and monitors it" do
      script =
        ~s|sleep 0.2; echo '{"type":"thread.started","thread_id":"spawn_test"}'; echo '{"type":"turn.completed","usage":{}}'|

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          timeout: 10_000
        )

      # Process should be alive during execution
      assert Process.alive?(pid)

      stream = MockCodexRunner.stream(pid)
      _events = AgentCore.EventStream.events(stream) |> Enum.to_list()
    end

    test "handles subprocess that exits with error code" do
      script = ~s|echo '{"type":"thread.started","thread_id":"error_exit"}'; exit 1|
      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          timeout: 5_000
        )

      stream = MockCodexRunner.stream(pid)
      events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      # Should have error-related events
      cli_events = for {:cli_event, e} <- events, do: e

      # Should have a completed event with ok=false
      completed = Enum.find(cli_events, &match?(%CompletedEvent{}, &1))
      assert completed != nil
      assert completed.ok == false
    end
  end

  describe "process management - cleanup" do
    test "cleans up subprocess on owner process death" do
      script = ~s|trap 'exit 0' TERM; while true; do sleep 0.1; done|
      Application.put_env(:agent_core, :mock_codex_script, script)

      # Spawn an owner process that will die
      owner =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          owner: owner,
          timeout: 10_000
        )

      ref = Process.monitor(pid)

      # Kill the owner
      send(owner, :die)

      # Runner should terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  # ============================================================================
  # Event Stream Parsing Tests
  # ============================================================================

  describe "event stream parsing and routing" do
    test "parses and routes complete session lifecycle" do
      script = """
      echo '{"type":"thread.started","thread_id":"full_lifecycle"}'
      echo '{"type":"turn.started"}'
      echo '{"type":"item.started","item":{"type":"command_execution","id":"cmd_1","command":"echo test","status":"in_progress"}}'
      echo '{"type":"item.completed","item":{"type":"command_execution","id":"cmd_1","command":"echo test","exit_code":0,"status":"completed"}}'
      echo '{"type":"item.completed","item":{"type":"agent_message","id":"msg_1","text":"Task completed"}}'
      echo '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":50}}'
      """

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          timeout: 10_000
        )

      stream = MockCodexRunner.stream(pid)
      events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      cli_events = for {:cli_event, e} <- events, do: e

      # Should have StartedEvent
      started = Enum.find(cli_events, &match?(%StartedEvent{}, &1))
      assert started != nil
      assert started.resume.value == "full_lifecycle"

      # Should have action events for command
      actions = Enum.filter(cli_events, &match?(%ActionEvent{}, &1))
      command_actions = Enum.filter(actions, fn a -> a.action.kind == :command end)
      assert length(command_actions) >= 1

      # Should have CompletedEvent
      completed = Enum.find(cli_events, &match?(%CompletedEvent{}, &1))
      assert completed != nil
      assert completed.ok == true
      assert completed.answer == "Task completed"
    end

    test "handles invalid JSON lines gracefully" do
      script = """
      echo '{"type":"thread.started","thread_id":"invalid_json_test"}'
      echo 'this is not valid json'
      echo '{"type":"turn.completed","usage":{}}'
      """

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          timeout: 10_000
        )

      stream = MockCodexRunner.stream(pid)
      events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      cli_events = for {:cli_event, e} <- events, do: e

      # Should still complete successfully
      completed = Enum.find(cli_events, &match?(%CompletedEvent{}, &1))
      assert completed != nil
      assert completed.ok == true

      # Should have warning about invalid line
      warnings =
        Enum.filter(cli_events, fn
          %ActionEvent{action: %{kind: :warning}} -> true
          _ -> false
        end)

      assert length(warnings) >= 1
    end
  end

  # ============================================================================
  # Cancel/Abort Handling Tests
  # ============================================================================

  describe "abort signal handling" do
    test "cancel stops running subprocess" do
      Application.put_env(:agent_core, :cli_cancel_grace_ms, 500)

      script =
        ~s|trap 'exit 0' TERM; echo '{"type":"thread.started","thread_id":"cancel_test"}'; while true; do sleep 0.1; done|

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          owner: self(),
          timeout: 30_000
        )

      stream = MockCodexRunner.stream(pid)
      ref = Process.monitor(pid)

      # Wait a bit for the process to start and emit the thread.started event
      Process.sleep(200)

      # Cancel the runner
      MockCodexRunner.cancel(pid, :test_cancel)

      # Collect events
      events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      # Should have cancel event
      assert Enum.any?(events, fn
               {:canceled, :test_cancel} -> true
               _ -> false
             end)

      # Runner should terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  # ============================================================================
  # Timeout Tests
  # ============================================================================

  describe "error conditions - timeout" do
    test "times out long-running subprocess" do
      script =
        ~s|trap 'exit 0' TERM; echo '{"type":"thread.started","thread_id":"timeout_test"}'; sleep 60|

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          # Very short timeout
          timeout: 500
        )

      stream = MockCodexRunner.stream(pid)
      ref = Process.monitor(pid)

      events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      # Should have timeout error (can be {:error, :timeout} or {:error, :timeout, nil})
      assert Enum.any?(events, fn
               {:error, :timeout} -> true
               {:error, :timeout, _} -> true
               _ -> false
             end)

      # Process should terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  # ============================================================================
  # Resume Token Extraction Tests
  # ============================================================================

  describe "resume token extraction" do
    test "extracts thread_id from ThreadStarted event" do
      script =
        ~s|echo '{"type":"thread.started","thread_id":"extracted_thread_abc123"}'; echo '{"type":"turn.completed","usage":{}}'|

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          timeout: 10_000
        )

      stream = MockCodexRunner.stream(pid)
      events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      cli_events = for {:cli_event, e} <- events, do: e

      # StartedEvent should have resume token
      started = Enum.find(cli_events, &match?(%StartedEvent{}, &1))
      assert started != nil
      assert started.resume.engine == "codex"
      assert started.resume.value == "extracted_thread_abc123"

      # CompletedEvent should also have resume token
      completed = Enum.find(cli_events, &match?(%CompletedEvent{}, &1))
      assert completed != nil
      assert completed.resume.value == "extracted_thread_abc123"
    end

    test "resume token is preserved through error exit" do
      script =
        ~s|echo '{"type":"thread.started","thread_id":"preserved_on_error"}'; echo '{"type":"turn.started"}'; exit 1|

      Application.put_env(:agent_core, :mock_codex_script, script)

      {:ok, pid} =
        MockCodexRunner.start_link(
          prompt: "test",
          cwd: System.tmp_dir!(),
          timeout: 10_000
        )

      stream = MockCodexRunner.stream(pid)
      events = AgentCore.EventStream.events(stream) |> Enum.to_list()

      cli_events = for {:cli_event, e} <- events, do: e

      # CompletedEvent should still have resume token for potential recovery
      completed = Enum.find(cli_events, &match?(%CompletedEvent{}, &1))
      assert completed != nil
      assert completed.ok == false
      assert completed.resume != nil
      assert completed.resume.value == "preserved_on_error"
    end
  end

  # ============================================================================
  # Session Locking Tests
  # ============================================================================

  describe "session locking" do
    test "prevents concurrent runs of same session" do
      # Need to trap exits since we're using start_link
      Process.flag(:trap_exit, true)

      # Use a unique session ID that matches what the script will output
      unique_id = "locked_session_#{System.unique_integer([:positive])}"

      script =
        ~s|trap 'exit 0' TERM; echo '{"type":"thread.started","thread_id":"#{unique_id}"}'; sleep 5; echo '{"type":"turn.completed","usage":{}}'|

      Application.put_env(:agent_core, :mock_codex_script, script)

      token = ResumeToken.new("codex", unique_id)

      # Start first runner with resume token
      {:ok, pid1} =
        MockCodexRunner.start_link(
          prompt: "test",
          resume: token,
          cwd: System.tmp_dir!(),
          timeout: 10_000
        )

      # Give it time to acquire lock
      Process.sleep(100)

      # Try to start second runner with same session - should fail
      result =
        MockCodexRunner.start_link(
          prompt: "test",
          resume: token,
          cwd: System.tmp_dir!(),
          timeout: 10_000
        )

      assert {:error, {:error, :session_locked}} = result

      # Clean up first runner
      MockCodexRunner.cancel(pid1)

      # Wait for cleanup and trap the exit
      receive do
        {:EXIT, ^pid1, _} -> :ok
      after
        1_000 -> :ok
      end
    end
  end
end
