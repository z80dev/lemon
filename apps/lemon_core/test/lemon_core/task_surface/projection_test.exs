defmodule LemonCore.TaskSurface.ProjectionTest do
  use ExUnit.Case, async: true

  alias LemonCore.TaskSurface.Projection

  test "projects child engine actions into parent task surface payloads" do
    binding = %{
      task_id: "task-projection-1",
      child_run_id: "run-child-projection-1",
      parent_run_id: "run-parent-projection-1",
      parent_session_key: "agent:default:telegram:default:dm:12345",
      parent_agent_id: "default",
      root_action_id: "tool-call-projection-1",
      surface: {:status_task, "tool-call-projection-1"}
    }

    payload = %{
      engine: "codex",
      phase: :started,
      ok: nil,
      message: nil,
      level: nil,
      action: %{
        id: "child-action-1",
        kind: :tool,
        title: "Read AGENTS.md",
        detail: %{path: "AGENTS.md"}
      }
    }

    projected = Projection.project_child_payload(payload, binding)

    assert projected.engine == "codex"
    assert projected.phase == :started
    assert projected.action.id == "taskproj:run-child-projection-1:child-action-1"
    assert projected.action.kind == :tool
    assert projected.action.title == "Read AGENTS.md"
    assert projected.action.detail.path == "AGENTS.md"
    assert projected.action.detail.parent_tool_use_id == "tool-call-projection-1"
    assert projected.action.detail.task_id == "task-projection-1"
    assert projected.action.detail.child_run_id == "run-child-projection-1"
    assert projected.action.detail.projected_from == :child_run
  end

  test "builds deterministic projected action ids when child action id is missing" do
    assert Projection.projected_action_id("run-child", nil, "tool", "Read AGENTS.md") ==
             "taskproj:run-child::afc9a777c159"
  end
end
