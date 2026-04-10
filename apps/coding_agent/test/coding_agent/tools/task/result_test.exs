defmodule CodingAgent.Tools.Task.ResultTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.Result

  setup do
    TaskStore.clear()
    :ok
  end

  test "poll returns status-only text for running command-heavy tasks" do
    task_id =
      TaskStore.new_task(%{
        description: "Telegram files overview (codex)",
        engine: "codex",
        run_id: "run_codex_1"
      })

    TaskStore.mark_running(task_id)

    TaskStore.append_event(task_id, %AgentToolResult{
      content: [%TextContent{text: "Completed: /usr/bin/zsh -c \"sed -n '1,260p' delivery.ex\""}],
      details: %{
        current_action: %{
          title: "/usr/bin/zsh -c \"sed -n '1,260p' delivery.ex\"",
          kind: "command",
          phase: "completed"
        }
      }
    })

    %AgentToolResult{content: [%TextContent{text: text}], details: details} =
      Result.do_poll(%{"task_id" => task_id})

    assert text == "Task status: running\nCurrent action: command"
    refute text =~ "/usr/bin/zsh"
    assert details.current_action.title =~ "/usr/bin/zsh"
    assert details.current_action.kind == "command"
  end

  test "get returns status-only text for running command-heavy tasks" do
    task_id =
      TaskStore.new_task(%{
        description: "Telegram files overview (codex)",
        engine: "codex",
        run_id: "run_codex_2"
      })

    TaskStore.mark_running(task_id)

    TaskStore.append_event(task_id, %AgentToolResult{
      content: [%TextContent{text: "Completed: /usr/bin/zsh -c \"sed -n '1,260p' delivery.ex\""}],
      details: %{
        current_action: %{
          title: "/usr/bin/zsh -c \"sed -n '1,260p' delivery.ex\"",
          kind: "command",
          phase: "completed"
        }
      }
    })

    %AgentToolResult{content: [%TextContent{text: text}], details: details} =
      Result.do_get(%{"task_id" => task_id})

    assert text == "Task status: running\nCurrent action: command"
    refute text =~ "/usr/bin/zsh"
    assert details.current_action.title =~ "/usr/bin/zsh"
    assert details.current_action.kind == "command"
  end

  test "get returns final visible output for completed tasks" do
    task_id =
      TaskStore.new_task(%{
        description: "Telegram files overview (claude)",
        engine: "claude",
        run_id: "run_claude_1"
      })

    TaskStore.mark_running(task_id)

    TaskStore.finish(task_id, %AgentToolResult{
      content: [%TextContent{text: "Final answer"}],
      details: %{status: "completed"}
    })

    %AgentToolResult{content: [%TextContent{text: text}], details: details} =
      Result.do_get(%{"task_id" => task_id})

    assert text == "Final answer"
    assert details.status == "completed"
    assert details.engine == "claude"
  end
end
