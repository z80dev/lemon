defmodule CodingAgent.Tools.Task.ResultTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
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

  test "poll exposes reasoning as metadata without thinking marker text" do
    task_id =
      TaskStore.new_task(%{
        description: "Reasoning task",
        engine: "internal",
        run_id: "run_reasoning_1"
      })

    TaskStore.mark_running(task_id)

    TaskStore.append_event(task_id, %AgentToolResult{
      content: Result.build_update_content("working answer", "checking the router path"),
      details: %{
        reasoning:
          Result.reasoning_details("checking the router path", "assistant_thinking", "updated")
      }
    })

    %AgentToolResult{content: [%TextContent{text: text}], details: details} =
      Result.do_poll(%{"task_id" => task_id})

    refute text =~ "[thinking]"
    assert details.reasoning.text == "checking the router path"
    assert details.reasoning.source == "assistant_thinking"
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
        description: "Telegram files overview",
        run_id: "run_task_1"
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
  end

  test "a join reports the stored record, not a disagreeing run graph row" do
    run_id = CodingAgent.RunGraph.new_run(%{type: :task, description: "Stored truth"})
    task_id = TaskStore.new_task(%{description: "Stored truth", run_id: run_id})

    TaskStore.finish(task_id, %AgentToolResult{
      content: [%TextContent{text: "stored answer"}],
      details: %{status: "completed"}
    })

    # A stale or racing writer marked the run failed; it does not decide the task.
    CodingAgent.RunGraph.fail(run_id, "run row disagrees")

    assert %AgentToolResult{details: %{tasks: [task]}} =
             Result.do_join(%{"task_ids" => [task_id]})

    assert %{status: "completed", output: "stored answer"} = task
    refute task[:error]
  end
end
