defmodule CodingAgent.Tools.Task.LiveBridgeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.RunGraph
  alias CodingAgent.TaskProgressBindingServer
  alias CodingAgent.TaskProgressBindingStore
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task
  alias CodingAgent.Tools.Task.LiveBridge
  alias LemonCore.{Bus, Event}

  setup do
    try do
      TaskStore.clear()
    catch
      _, _ -> :ok
    end

    try do
      RunGraph.clear()
    catch
      _, _ -> :ok
    end

    try do
      TaskProgressBindingServer.clear(CodingAgent.TaskProgressBindingServer)
    catch
      _, _ -> :ok
    end

    :ok
  end

  test "given binding + child run bus action event started, bridge emits projected parent event" do
    parent_run_id = "run_parent_bridge_1"
    parent_session_key = "agent:default:telegram:default:dm:12345"

    result =
      Task.execute(
        "tool_call_bridge_1",
        %{
          "description" => "Bridge test task",
          "prompt" => "Block until released",
          "async" => true
        },
        nil,
        nil,
        "/tmp",
        parent_run_id: parent_run_id,
        session_key: parent_session_key,
        agent_id: "default",
        run_override: fn _on_update, _signal ->
          Process.sleep(300)

          %AgentCore.Types.AgentToolResult{
            content: [%Ai.Types.TextContent{text: "done"}],
            details: %{status: "completed"}
          }
        end
      )

    child_run_id = result.details.run_id
    assert {:ok, _binding} = TaskProgressBindingStore.get_by_child_run_id(child_run_id)

    Bus.subscribe(Bus.run_topic(parent_run_id))

    :ok =
      Bus.broadcast(
        Bus.run_topic(child_run_id),
        Event.new(:engine_action, %{
          engine: "codex",
          action: %{
            id: "child_action_1",
            kind: :tool,
            title: "Read: AGENTS.md",
            detail: %{path: "AGENTS.md"}
          },
          phase: :started,
          ok: nil,
          message: nil,
          level: nil
        })
      )

    assert_receive %Event{type: :task_projected_child_action, payload: projected, meta: meta},
                   1_000

    assert projected.engine == "codex"
    assert projected.phase == :started
    assert projected.action.id == "taskproj:" <> child_run_id <> ":child_action_1"
    assert projected.action.detail.parent_tool_use_id == "tool_call_bridge_1"
    assert projected.action.detail.task_id == result.details.task_id
    assert projected.action.detail.child_run_id == child_run_id
    assert meta.run_id == parent_run_id
    assert meta.child_run_id == child_run_id
  end

  test "given child run completed event, bridge terminates and binding is deleted" do
    binding = %{
      task_id: "task_bridge_complete",
      child_run_id: "run_child_bridge_complete",
      parent_run_id: "run_parent_bridge_complete",
      parent_session_key: "agent:default:telegram:default:dm:12345",
      parent_agent_id: "default",
      root_action_id: "tool_call_bridge_complete",
      surface: {:status_task, "tool_call_bridge_complete"}
    }

    :ok = TaskProgressBindingStore.new_binding(binding)
    assert {:ok, binding} = TaskProgressBindingStore.get_by_child_run_id(binding.child_run_id)

    assert {:ok, pid} = LiveBridge.start_link(binding)
    ref = Process.monitor(pid)

    :ok =
      Bus.broadcast(
        Bus.run_topic(binding.child_run_id),
        Event.new(:run_completed, %{completed: %{ok: true}})
      )

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    assert {:error, :not_found} =
             TaskProgressBindingStore.get_by_child_run_id(binding.child_run_id)
  end

  test "duplicate child action updates do not crash" do
    binding = %{
      task_id: "task_bridge_dupe",
      child_run_id: "run_child_bridge_dupe",
      parent_run_id: "run_parent_bridge_dupe",
      parent_session_key: "agent:default:telegram:default:dm:12345",
      parent_agent_id: "default",
      root_action_id: "tool_call_bridge_dupe",
      surface: {:status_task, "tool_call_bridge_dupe"}
    }

    :ok = TaskProgressBindingStore.new_binding(binding)
    assert {:ok, pid} = LiveBridge.start_link(binding)
    assert Process.alive?(pid)

    action_event =
      Event.new(:engine_action, %{
        engine: "claude",
        action: %{id: "same_action", kind: :command, title: "pwd", detail: %{}},
        phase: :updated,
        ok: nil,
        message: nil,
        level: nil
      })

    :ok = Bus.broadcast(Bus.run_topic(binding.child_run_id), action_event)
    :ok = Bus.broadcast(Bus.run_topic(binding.child_run_id), action_event)

    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "missing binding is ignored safely" do
    assert :ok = LiveBridge.start_for_child_run("missing_child_run")
  end
end
