defmodule LemonRouter.SurfaceManagerTest do
  use ExUnit.Case, async: false

  alias LemonCore.{DeliveryIntent, Event, SessionKey}
  alias LemonRouter.SurfaceManager

  defmodule DispatcherStub do
    @moduledoc false

    def dispatch(%DeliveryIntent{} = intent) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:dispatched_intent, intent})
      end

      :ok
    end
  end

  setup do
    previous = Application.get_env(:lemon_router, :dispatcher)
    Application.put_env(:lemon_router, :dispatcher, DispatcherStub)
    :persistent_term.put({DispatcherStub, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({DispatcherStub, :test_pid})

      if is_nil(previous) do
        Application.delete_env(:lemon_router, :dispatcher)
      else
        Application.put_env(:lemon_router, :dispatcher, previous)
      end
    end)

    :ok
  end

  test "prepare_status_action/2 creates a task-specific surface for a top-level task action" do
    action_event = %{
      action: %{
        id: "task_root",
        kind: "subagent",
        title: "task(codex): review",
        detail: %{name: "task"}
      },
      phase: :started
    }

    {state, surface, capture?} = SurfaceManager.prepare_status_action(base_state(), action_event)

    assert surface == {:status_task, "task_root"}
    assert capture? == true
    assert state.task_status_surfaces == %{"task_root" => {:status_task, "task_root"}}
  end

  test "follow-up task action with matching task_id reuses the original task surface" do
    {state, task_surface, _} =
      SurfaceManager.prepare_status_action(base_state(), %{
        action: %{
          id: "task_root",
          kind: "subagent",
          detail: %{name: "task"}
        },
        phase: :started
      })

    {state, ^task_surface, _} =
      SurfaceManager.prepare_status_action(state, %{
        action: %{
          id: "task_root",
          kind: "subagent",
          detail: %{name: "task", result_meta: %{task_id: "task-store-1"}}
        },
        phase: :completed,
        ok: true
      })

    {_state, surface, capture?} =
      SurfaceManager.prepare_status_action(state, %{
        action: %{
          id: "task_poll_1",
          kind: "subagent",
          detail: %{
            name: "task",
            args: %{"action" => "poll", "task_ids" => ["task-store-1"]},
            result_meta: %{"task_id" => "task-store-1"}
          }
        },
        phase: :completed,
        ok: true
      })

    assert surface == task_surface
    assert capture? == false
  end

  test "child action with parent_tool_use_id stays on the existing task surface" do
    {state, task_surface, _} =
      SurfaceManager.prepare_status_action(base_state(), %{
        action: %{
          id: "task_root",
          kind: "subagent",
          detail: %{name: "task"}
        },
        phase: :started
      })

    {_state, surface, capture?} =
      SurfaceManager.prepare_status_action(state, %{
        action: %{
          id: "child_1",
          kind: "tool",
          detail: %{parent_tool_use_id: "task_root"}
        },
        phase: :started
      })

    assert surface == task_surface
    assert capture? == false
  end

  test "fanout_final_answer/2 dispatches once per unique non-primary route" do
    session_key =
      SessionKey.channel_peer(%{
        agent_id: "test-agent",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "primary"
      })

    state = %{
      run_id: "run-fanout",
      session_key: session_key,
      execution_request: %LemonGateway.ExecutionRequest{
        run_id: "run-fanout",
        session_key: session_key,
        prompt: "fanout",
        engine_id: "echo",
        meta: %{
          fanout_routes: [
            %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "primary"},
            %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "111"},
            %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "111"},
            %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "222"},
            %{channel_id: "", peer_id: "bad"}
          ]
        }
      }
    }

    event =
      Event.new(
        :run_completed,
        %{completed: %{ok: true, answer: "Fanout answer"}},
        %{run_id: state.run_id, session_key: session_key}
      )

    assert :ok = SurfaceManager.fanout_final_answer(state, event)

    assert_receive {:dispatched_intent,
                    %DeliveryIntent{
                      kind: :final_text,
                      body: %{text: "Fanout answer", seq: seq_a},
                      route: %{peer_id: peer_a},
                      meta: %{fanout: true, fanout_index: fanout_index_a}
                    }},
                   1_000

    assert_receive {:dispatched_intent,
                    %DeliveryIntent{
                      kind: :final_text,
                      body: %{text: "Fanout answer", seq: seq_b},
                      route: %{peer_id: peer_b},
                      meta: %{fanout: true, fanout_index: fanout_index_b}
                    }},
                   1_000

    refute_receive {:dispatched_intent, _}, 100

    assert Enum.sort([peer_a, peer_b]) == ["111", "222"]
    assert Enum.sort([seq_a, seq_b]) == [1, 2]
    assert Enum.sort([fanout_index_a, fanout_index_b]) == [1, 2]
  end

  defp base_state do
    %{
      run_id: "run-1",
      session_key: SessionKey.main("surface-manager"),
      execution_request: %LemonGateway.ExecutionRequest{
        run_id: "run-1",
        session_key: SessionKey.main("surface-manager"),
        prompt: "test",
        engine_id: "echo",
        meta: %{}
      },
      task_status_surfaces: %{},
      task_status_refs: %{}
    }
  end
end
