defmodule LemonSim.Projectors.SectionedProjectorTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentTool
  alias Ai.Types.UserMessage
  alias LemonSim.{DecisionFrame, Event, PlanStep}
  alias LemonSim.Projectors.SectionedProjector

  test "builds a sectioned context with default scaffold" do
    frame = %DecisionFrame{
      sim_id: "sim-1",
      world: %{"hp" => 100, "position" => %{"x" => 2, "y" => 3}},
      recent_events: [
        %Event{kind: "enemy_seen", ts_ms: 1, payload: %{"id" => "goblin"}, meta: %{}}
      ],
      intent: %{"objective" => "survive"},
      plan_history: [PlanStep.new("moved to cover", ts_ms: 123)],
      memory_index_path: "index.md",
      meta: %{}
    }

    tools = [
      %AgentTool{
        name: "attack",
        description: "Attack target",
        parameters: %{"type" => "object", "properties" => %{"target" => %{"type" => "string"}}},
        label: "Attack",
        execute: fn _id, _params, _signal, _on_update -> AgentCore.new_tool_result() end
      }
    ]

    assert {:ok, context} = SectionedProjector.project(frame, tools, [])
    assert is_binary(context.system_prompt)
    assert [%UserMessage{content: prompt}] = context.messages

    assert String.contains?(prompt, "SIM_PROMPT_V1")
    assert String.contains?(prompt, "## World State")
    assert String.contains?(prompt, "\"objective\": \"survive\"")
    assert String.contains?(prompt, "## Available Actions")
    assert String.contains?(prompt, "\"name\": \"attack\"")
  end

  test "supports section builders and overrides" do
    frame = %DecisionFrame{
      sim_id: "sim-2",
      world: %{"hp" => 80},
      recent_events: [],
      intent: nil,
      plan_history: [],
      memory_index_path: "index.md",
      meta: %{}
    }

    {:ok, context} =
      SectionedProjector.project(
        frame,
        [],
        section_overrides: %{decision_contract: "- choose one action only"},
        section_builders: %{
          world_state: fn _frame, _tools, _opts ->
            %{title: "World Snapshot", format: :markdown, content: "hp=80"}
          end,
          memory: fn _frame, _tools, _opts -> nil end
        },
        section_order: [:world_state, :decision_contract]
      )

    [%UserMessage{content: prompt}] = context.messages

    assert String.contains?(prompt, "## World Snapshot")
    assert String.contains?(prompt, "hp=80")
    assert String.contains?(prompt, "- choose one action only")
    refute String.contains?(prompt, "## Memory")
  end
end
