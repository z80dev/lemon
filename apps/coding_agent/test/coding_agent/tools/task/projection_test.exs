defmodule CodingAgent.Tools.Task.ProjectionTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Tools.Task.Projection
  alias LemonCore.Event

  describe "engine_action_event_from_update/2" do
    test "creates canonical reasoning engine action events" do
      result = %AgentToolResult{
        details: %{
          engine: "codex",
          reasoning: %{text: "checking the router path", source: "assistant_thinking"}
        }
      }

      lifecycle_context = %{
        run_id: "run_child_reasoning_1",
        parent_run_id: "run_parent_reasoning_1",
        session_key: "agent:default:web:default:dm:1",
        agent_id: "default",
        task_id: "task_reasoning_1"
      }

      assert {:ok, %Event{} = event} =
               Projection.engine_action_event_from_update(result, lifecycle_context)

      assert event.type == :engine_action
      assert event.meta.run_id == "run_child_reasoning_1"
      assert event.meta.parent_run_id == "run_parent_reasoning_1"
      assert event.meta.session_key == "agent:default:web:default:dm:1"
      assert event.meta.visibility == :operator
      assert event.payload.engine == "codex"
      assert event.payload.action.kind == "reasoning"
      assert event.payload.action.title == "checking the router path"

      assert event.payload.action.detail.reasoning == %{
               text: "checking the router path",
               source: "assistant_thinking",
               phase: "updated"
             }
    end

    test "preserves payload compatibility for existing projection callers" do
      result = %AgentToolResult{
        details: %{
          reasoning: %{"text" => "checking payload compatibility", "phase" => "completed"}
        }
      }

      lifecycle_context = %{
        run_id: "run_child_reasoning_2",
        session_key: "agent:default:web:default:dm:2"
      }

      assert {:ok, payload} = Projection.engine_action_from_update(result, lifecycle_context)

      assert payload.phase == :completed
      assert payload.ok == true
      assert payload.action.kind == "reasoning"
      assert payload.action.detail.reasoning.phase == "completed"
    end
  end
end
