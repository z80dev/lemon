defmodule AgentCore.CliRunners.CodexRunnerTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.CodexRunner
  alias AgentCore.CliRunners.CodexRunner.RunnerState
  alias AgentCore.CliRunners.CodexSchema.{
    AgentMessageItem,
    CommandExecutionItem,
    FileChangeItem,
    FileUpdateChange,
    ItemCompleted,
    ItemStarted,
    McpToolCallItem,
    StreamError,
    ThreadStarted,
    TodoItem,
    TodoListItem,
    TurnCompleted,
    TurnStarted,
    Usage,
    WebSearchItem
  }
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  describe "engine/0" do
    test "returns codex" do
      assert CodexRunner.engine() == "codex"
    end
  end

  describe "build_command/3" do
    setup do
      prev_codex = Application.get_env(:agent_core, :codex)

      Application.delete_env(:agent_core, :codex)

      on_exit(fn ->
        if is_nil(prev_codex) do
          Application.delete_env(:agent_core, :codex)
        else
          Application.put_env(:agent_core, :codex, prev_codex)
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

    test "adds auto-approve flag when enabled" do
      Application.put_env(:agent_core, :codex, auto_approve: true)
      state = RunnerState.new()
      {_cmd, args} = CodexRunner.build_command("Hello", nil, state)

      assert "--dangerously-bypass-approvals-and-sandbox" in args
    end
  end

  describe "stdin_payload/3" do
    test "returns prompt with newline" do
      state = RunnerState.new()
      assert CodexRunner.stdin_payload("Hello", nil, state) == "Hello\n"
    end
  end

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

    test "translates TurnCompleted to CompletedEvent" do
      state = %{RunnerState.new() | final_answer: "Done!", found_session: ResumeToken.new("codex", "thread_123")}
      event = %TurnCompleted{usage: %Usage{input_tokens: 100, output_tokens: 200}}

      {events, _new_state, opts} = CodexRunner.translate_event(event, state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == true
      assert completed.answer == "Done!"
      assert completed.resume.value == "thread_123"
      assert completed.usage.input_tokens == 100
      assert opts[:done] == true
    end
  end

  describe "translate_event/2 - stream errors" do
    test "translates reconnection message" do
      state = RunnerState.new()
      event = %StreamError{message: "Reconnecting...1/3"}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :started
      assert action.action.kind == :note
      assert action.action.detail.attempt == 1
      assert action.action.detail.max == 3
    end

    test "translates non-reconnection error as warning" do
      state = RunnerState.new()
      event = %StreamError{message: "Some error"}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.phase == :completed
      assert action.action.kind == :warning
    end
  end

  describe "translate_event/2 - item events" do
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
    end

    test "captures agent message as final answer" do
      state = RunnerState.new()
      item = %AgentMessageItem{id: "msg_1", text: "Here is my answer"}
      event = %ItemCompleted{item: item}

      {events, new_state, _opts} = CodexRunner.translate_event(event, state)

      assert events == []
      assert new_state.final_answer == "Here is my answer"
    end

    test "translates file change completed" do
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

    test "translates mcp tool call" do
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
    end

    test "translates web search" do
      state = RunnerState.new()
      item = %WebSearchItem{id: "ws_1", query: "elixir genserver tutorial"}
      event = %ItemStarted{item: item}

      {events, _new_state, _opts} = CodexRunner.translate_event(event, state)

      assert [%ActionEvent{} = action] = events
      assert action.action.kind == :web_search
      assert action.action.title == "elixir genserver tutorial"
    end

    test "translates todo list" do
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
  end

  describe "handle_exit_error/2" do
    test "returns note and completed error events" do
      state = %{RunnerState.new() | final_answer: "partial", found_session: ResumeToken.new("codex", "t_1")}

      {events, _new_state} = CodexRunner.handle_exit_error(1, state)

      assert [%ActionEvent{} = note, %CompletedEvent{} = completed] = events
      assert note.action.kind == :warning
      assert String.contains?(note.action.title, "failed")
      assert completed.ok == false
      assert completed.error =~ "rc=1"
    end
  end

  describe "handle_stream_end/1" do
    test "returns error when no session found" do
      state = RunnerState.new()

      {events, _new_state} = CodexRunner.handle_stream_end(state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == false
      assert completed.error =~ "no session_id"
    end

    test "returns success when session found" do
      state = %{RunnerState.new() | final_answer: "Done", found_session: ResumeToken.new("codex", "t_1")}

      {events, _new_state} = CodexRunner.handle_stream_end(state)

      assert [%CompletedEvent{} = completed] = events
      assert completed.ok == true
      assert completed.answer == "Done"
      assert completed.resume.value == "t_1"
    end
  end
end
