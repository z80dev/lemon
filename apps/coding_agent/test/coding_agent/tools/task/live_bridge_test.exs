defmodule CodingAgent.Tools.Task.LiveBridgeTest do
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.RunGraph
  alias CodingAgent.TaskProgressBindingServer
  alias CodingAgent.TaskProgressBindingStore
  alias CodingAgent.{TaskRuntime, TaskRuntimeHelpers}
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task
  alias LemonCore.{Bus, Event}
  alias LemonPlatformTest.EventsFixtures

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
    test_pid = self()

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
          # Keep the child run (and its bridge) alive until the test is done.
          send(test_pid, {:child_run_started, self()})

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end

          %LemonAgent.Types.AgentToolResult{
            content: [%LemonAi.Types.TextContent{text: "done"}],
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

    assert projected.phase == :started
    assert projected.action.id == "taskproj:" <> child_run_id <> ":child_action_1"
    assert projected.action.detail.parent_tool_use_id == "tool_call_bridge_1"
    assert projected.action.detail.task_id == result.details.task_id
    assert projected.action.detail.child_run_id == child_run_id
    assert meta.run_id == parent_run_id
    assert meta.child_run_id == child_run_id

    assert_receive {:child_run_started, run_pid}, 2_000
    send(run_pid, :release)
  end

  test "given child run completed event, the owner closes its bridge and deletes the binding" do
    {id, binding} = bridged_child("complete")
    owner = TaskRuntime.whereis(id)
    assert_eventually(fn -> is_map(TaskRuntimeHelpers.entry(id).bridge) end)

    :ok =
      Bus.broadcast(
        Bus.run_topic(binding.child_run_id),
        Event.new(:run_completed, EventsFixtures.run_completed())
      )

    assert_eventually(fn -> TaskRuntimeHelpers.entry(id).bridge == nil end)
    assert TaskRuntime.whereis(id) == owner

    assert {:error, :not_found} =
             TaskProgressBindingStore.get_by_child_run_id(binding.child_run_id)
  end

  test "duplicate child action updates do not crash the owner" do
    {id, binding} = bridged_child("dupe")
    owner = TaskRuntime.whereis(id)
    Bus.subscribe(Bus.run_topic(binding.parent_run_id))

    action_event =
      Event.new(:engine_action, %{
        engine: "claude",
        action: %{id: "same_action", kind: :command, title: "pwd", detail: %{}},
        phase: :updated,
        ok: nil,
        message: nil,
        level: nil
      })

    assert_eventually(fn -> is_map(TaskRuntimeHelpers.entry(id).bridge) end)
    :ok = Bus.broadcast(Bus.run_topic(binding.child_run_id), action_event)
    :ok = Bus.broadcast(Bus.run_topic(binding.child_run_id), action_event)

    assert_receive %Event{type: :task_projected_child_action}, 1_000
    assert_receive %Event{type: :task_projected_child_action}, 1_000
    assert TaskRuntime.whereis(id) == owner
  end

  test "a child without a binding has no bridge" do
    id = TaskStore.new_task(%{run_id: "missing_child_run"})
    :ok = TaskRuntimeHelpers.register(id, nil)
    on_exit(fn -> TaskRuntimeHelpers.stop(id) end)
    assert TaskRuntimeHelpers.entry(id).bridge == nil
  end

  defp bridged_child(suffix) do
    binding = %{
      task_id: "task_bridge_#{suffix}",
      child_run_id: "run_child_bridge_#{suffix}",
      parent_run_id: "run_parent_bridge_#{suffix}",
      parent_session_key: "agent:default:telegram:default:dm:12345",
      parent_agent_id: "default",
      root_action_id: "tool_call_bridge_#{suffix}",
      surface: {:status_task, "tool_call_bridge_#{suffix}"}
    }

    :ok = TaskProgressBindingStore.new_binding(binding)
    assert {:ok, binding} = TaskProgressBindingStore.get_by_child_run_id(binding.child_run_id)
    id = TaskStore.new_task(%{run_id: binding.child_run_id})
    :ok = TaskRuntimeHelpers.register(id, nil)
    on_exit(fn -> TaskRuntimeHelpers.stop(id) end)
    {id, binding}
  end
end
