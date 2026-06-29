defmodule LemonControlPlane.EventBridgeTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.EventBridge
  alias LemonControlPlane.Presence
  alias LemonControlPlane.Protocol.Schemas

  setup do
    bridge =
      case Process.whereis(EventBridge) do
        nil ->
          {:ok, pid} = EventBridge.start_link([])
          {:started, pid}

        pid ->
          {:existing, pid}
      end

    presence =
      case Process.whereis(Presence) do
        nil ->
          {:ok, pid} = Presence.start_link([])
          {:started, pid}

        pid ->
          clear_presence()
          {:existing, pid}
      end

    on_exit(fn ->
      clear_presence()

      case presence do
        {:started, pid} -> stop_if_alive(pid)
        _ -> :ok
      end

      case bridge do
        {:started, pid} -> stop_if_alive(pid)
        _ -> :ok
      end
    end)

    {:ok, bridge_pid: elem(bridge, 1)}
  end

  defp clear_presence do
    if Process.whereis(Presence) do
      for {conn_id, _} <- Presence.list() do
        Presence.unregister(conn_id)
      end
    end
  catch
    :exit, _ -> :ok
  end

  defp stop_if_alive(pid) do
    if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp flush_events do
    receive do
      {:event, _, _, _} -> flush_events()
      {:event, _, _} -> flush_events()
    after
      0 -> :ok
    end
  end

  describe "subscribe_run/1" do
    test "subscribes to run topic" do
      run_id = "run_#{System.unique_integer()}"

      # Should not raise
      assert :ok = EventBridge.subscribe_run(run_id)
    end
  end

  describe "unsubscribe_run/1" do
    test "unsubscribes from run topic" do
      run_id = "run_#{System.unique_integer()}"

      EventBridge.subscribe_run(run_id)
      assert :ok = EventBridge.unsubscribe_run(run_id)
    end
  end

  describe "dynamic topic subscriptions" do
    test "subscribes to session topics" do
      session_key = "session_#{System.unique_integer()}"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      assert :ok = EventBridge.subscribe_topics(["session:#{session_key}"])
      Process.sleep(10)

      event =
        LemonCore.Event.new(
          :task_completed,
          %{task_id: "task-1", session_key: session_key, ok: true},
          %{session_key: session_key}
        )

      LemonCore.Bus.broadcast("session:#{session_key}", event)

      assert_receive {:event, "task.completed",
                      %{"taskId" => "task-1", "sessionKey" => ^session_key}, _state_version},
                     1_000

      assert :ok = EventBridge.unsubscribe_topics(["session:#{session_key}"])
      Presence.unregister(conn_id)
    end

    test "filters custom subscribers before mailbox fanout" do
      conn_id = "conn_#{System.unique_integer()}"
      subscribed_run = "run_subscribed_#{System.unique_integer()}"
      other_run = "run_other_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})

      assert :ok =
               Presence.update_subscriptions(
                 conn_id,
                 :custom,
                 MapSet.new(["run:#{subscribed_run}"])
               )

      flush_events()

      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(:delta, %{text: "ignored"}, %{run_id: other_run})
      )

      refute_receive {:event, "chat", %{"runId" => ^other_run}, _}, 200

      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(:delta, %{text: "delivered"}, %{run_id: subscribed_run})
      )

      assert_receive {:event, "chat", %{"runId" => ^subscribed_run}, _}, 500

      Presence.unregister(conn_id)
    end
  end

  describe "event forwarding" do
    test "processes run_started events" do
      run_id = "run_#{System.unique_integer()}"

      # Subscribe to the run
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      # The EventBridge should be subscribed to run:run_id topic now
      # Events broadcast to that topic should be processed
      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :run_started,
            %{run_id: run_id, session_key: "test", engine: "lemon"},
            %{run_id: run_id, session_key: "test"}
          )

        # This won't deliver to us directly (we're not in Presence)
        # but it should not crash the EventBridge
        LemonCore.Bus.broadcast("run:#{run_id}", event)

        # Give time for processing
        Process.sleep(50)

        # EventBridge should still be alive
        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "processes delta events" do
      run_id = "run_#{System.unique_integer()}"

      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        delta = %{run_id: run_id, ts_ms: System.system_time(:millisecond), seq: 1, text: "Hello"}

        event = LemonCore.Event.new(:delta, delta, %{run_id: run_id, session_key: "test"})
        LemonCore.Bus.broadcast("run:#{run_id}", event)

        Process.sleep(50)

        # EventBridge should still be alive (didn't crash on the event)
        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "processes run_completed events" do
      run_id = "run_#{System.unique_integer()}"

      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :run_completed,
            %{completed: %{ok: true, answer: "Done"}, duration_ms: 100},
            %{run_id: run_id, session_key: "test"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)

        Process.sleep(50)
        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "maps nested engine action detail metadata to agent tool_use events" do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-tool-failure"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()
      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      event =
        LemonCore.Event.engine_action(
          %{
            engine: "lemon",
            action: %{
              id: "tool_call_missing_tool",
              kind: "tool",
              title: "missing_tool_for_runner",
              detail: %{
                name: "missing_tool_for_runner",
                result: "Tool missing_tool_for_runner not found",
                result_meta: %{
                  error_type: :unknown_tool,
                  tool_name: "missing_tool_for_runner",
                  exit_code: 127
                }
              }
            },
            phase: :completed,
            ok: false,
            message: "tool failed"
          },
          %{run_id: run_id, session_key: session_key}
        )

      LemonCore.Bus.broadcast("run:#{run_id}", event)

      assert_receive {:event, "agent",
                      %{
                        "type" => "tool_use",
                        "runId" => ^run_id,
                        "sessionKey" => ^session_key,
                        "action" => %{
                          "id" => "tool_call_missing_tool",
                          "kind" => "tool",
                          "title" => "missing_tool_for_runner",
                          "detail" => %{
                            result_meta: %{
                              error_type: :unknown_tool,
                              tool_name: "missing_tool_for_runner",
                              exit_code: 127
                            }
                          }
                        },
                        "phase" => :completed,
                        "ok" => false,
                        "message" => "tool failed"
                      }, _state_version},
                     1_000

      EventBridge.unsubscribe_run(run_id)
      Presence.unregister(conn_id)
    end

    test "maps checkpoint events to agent events" do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-checkpoint"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      event =
        LemonCore.Event.new(
          :checkpoint_created,
          %{
            checkpoint_id: "chk_bridge",
            checkpoint_kind: "filesystem",
            tool: "write",
            action: "overwrite",
            path_count: 1,
            paths: ["/tmp/example.txt"]
          },
          %{run_id: run_id, session_key: session_key}
        )

      LemonCore.Bus.broadcast("run:#{run_id}", event)

      assert_receive {:event, "agent",
                      %{
                        "type" => "checkpoint_created",
                        "runId" => ^run_id,
                        "sessionKey" => ^session_key,
                        "checkpointId" => "chk_bridge",
                        "checkpointKind" => "filesystem",
                        "tool" => "write",
                        "action" => "overwrite",
                        "pathCount" => 1,
                        "paths" => ["/tmp/example.txt"]
                      }, _state_version},
                     1_000

      EventBridge.unsubscribe_run(run_id)
      Presence.unregister(conn_id)
    end

    test "maps goal events to goal events" do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-goal"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      EventBridge.subscribe_run(run_id)
      Process.sleep(10)

      event =
        LemonCore.Event.new(
          :goal_set,
          %{
            goal_id: "goal_bridge",
            session_key: session_key,
            agent_id: "default",
            status: "active",
            objective_bytes: 12,
            continuation_count: 0
          },
          %{run_id: run_id, session_key: session_key}
        )

      LemonCore.Bus.broadcast("run:#{run_id}", event)

      assert_receive {:event, "goal",
                      %{
                        "type" => "goal_set",
                        "sessionKey" => ^session_key,
                        "goalId" => "goal_bridge",
                        "status" => "active",
                        "objectiveBytes" => 12
                      }, _state_version},
                     1_000

      EventBridge.unsubscribe_run(run_id)
      Presence.unregister(conn_id)
    end

    test "maps goal continuation and loop verdict events to goal events" do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-goal-loop"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      continuation =
        LemonCore.Event.new(
          :goal_continuation_submitted,
          %{
            goal_id: "goal_loop_bridge",
            session_key: session_key,
            agent_id: "default",
            status: "active",
            objective_bytes: 12,
            continuation_count: 1,
            last_run_id: run_id
          },
          %{session_key: session_key}
        )

      send(Process.whereis(EventBridge), continuation)

      assert_receive {:event, "goal",
                      %{
                        "type" => "goal_continuation_submitted",
                        "sessionKey" => ^session_key,
                        "goalId" => "goal_loop_bridge",
                        "continuationCount" => 1,
                        "lastRunId" => ^run_id
                      }, _state_version},
                     1_000

      verdict =
        LemonCore.Event.new(
          :goal_loop_verdict,
          %{
            goal_id: "goal_loop_bridge",
            session_key: session_key,
            agent_id: "default",
            status: "active",
            objective_bytes: 12,
            continuation_count: 1,
            last_run_id: run_id,
            loop_verdict: %{
              "action" => "continue",
              "reason" => "more work remains",
              "source" => "preview"
            }
          },
          %{session_key: session_key}
        )

      send(Process.whereis(EventBridge), verdict)

      assert_receive {:event, "goal",
                      %{
                        "type" => "goal_loop_verdict",
                        "sessionKey" => ^session_key,
                        "goalId" => "goal_loop_bridge",
                        "lastRunId" => ^run_id,
                        "loopVerdict" => %{
                          "action" => "continue",
                          "reason" => "more work remains",
                          "source" => "preview"
                        }
                      }, _state_version},
                     1_000

      EventBridge.unsubscribe_run(run_id)
      Presence.unregister(conn_id)
    end

    test "maps ingested metrics, log, and custom events with target fields" do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-ingest"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(:metrics, %{count: 2}, %{target: "run:#{run_id}"})
      )

      assert_receive {:event, "metrics",
                      %{
                        "payload" => %{"count" => 2},
                        "runId" => ^run_id
                      }, _state_version},
                     1_000

      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(
          :log,
          %{level: "info", message: String.duplicate("x", 700), timestamp_ms: 123},
          %{target: "session:#{session_key}"}
        )
      )

      assert_receive {:event, "log",
                      %{
                        "level" => "info",
                        "message" => message,
                        "timestampMs" => 123,
                        "sessionKey" => ^session_key
                      }, _state_version},
                     1_000

      assert byte_size(message) < 700

      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(
          :custom_event,
          %{custom_event_type: "custom_widget", ok: true},
          %{target: "run:#{run_id}", original_event_type: "custom_widget"}
        )
      )

      assert_receive {:event, "custom", %{"type" => "custom_widget", "runId" => ^run_id},
                      _state_version},
                     1_000

      Presence.unregister(conn_id)
    end
  end

  describe "static topic subscriptions" do
    test "subscribes to goals topic on init" do
      conn_id = "conn_#{System.unique_integer()}"
      session_key = "session:event-bridge-static-goal"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      event =
        LemonCore.Event.new(
          :goal_set,
          %{
            goal_id: "goal_static_bridge",
            session_key: session_key,
            agent_id: "default",
            status: "active",
            objective_bytes: 8,
            continuation_count: 0
          },
          %{session_key: session_key}
        )

      LemonCore.Bus.broadcast("goals", event)

      assert_receive {:event, "goal",
                      %{
                        "type" => "goal_set",
                        "sessionKey" => ^session_key,
                        "goalId" => "goal_static_bridge"
                      }, _state_version},
                     1_000

      Presence.unregister(conn_id)
    end

    test "subscribes to exec_approvals topic on init" do
      # EventBridge should be subscribed to exec_approvals
      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :approval_requested,
            %{pending: %{id: "approval-1", run_id: "run-1", tool: "bash", rationale: "test"}},
            %{}
          )

        LemonCore.Bus.broadcast("exec_approvals", event)

        Process.sleep(50)
        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "broadcasts approval requested events with structured action metadata" do
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      event =
        LemonCore.Event.new(
          :approval_requested,
          %{
            "pending" => %{
              "id" => "approval-oauth-1",
              "run_id" => "run-oauth-1",
              "session_key" => "session:oauth",
              "agent_id" => "default",
              "tool" => "mcp_mcp_oauth",
              "action" => %{
                type: "mcp_oauth_authorization",
                authorization_url: "http://127.0.0.1:9000/authorize",
                state: %{hash: "state123"},
                enabled: false
              },
              "rationale" => "Open the MCP authorization URL.",
              "requested_at_ms" => 1_700_000_000_000
            }
          },
          %{}
        )

      LemonCore.Bus.broadcast("exec_approvals", event)

      assert_receive {:event, "exec.approval.requested", payload, _state_version}, 1_000

      assert payload == %{
               "approvalId" => "approval-oauth-1",
               "runId" => "run-oauth-1",
               "sessionKey" => "session:oauth",
               "agentId" => "default",
               "tool" => "mcp_mcp_oauth",
               "action" => %{
                 "type" => "mcp_oauth_authorization",
                 "authorization_url" => "http://127.0.0.1:9000/authorize",
                 "state" => %{"hash" => "state123"},
                 "enabled" => false
               },
               "rationale" => "Open the MCP authorization URL.",
               "requestedAtMs" => 1_700_000_000_000,
               "expiresAtMs" => nil
             }

      assert :ok = Schemas.validate_event("exec.approval.requested", payload)

      Presence.unregister(conn_id)
    end

    test "broadcasts approval resolved events with pending metadata" do
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      event =
        LemonCore.Event.new(
          :approval_resolved,
          %{
            "approval_id" => "approval-oauth-1",
            "decision" => "approve_once",
            "pending" => %{
              "run_id" => "run-oauth-1",
              "session_key" => "session:oauth",
              "agent_id" => "default",
              "tool" => "mcp_mcp_oauth"
            }
          },
          %{}
        )

      LemonCore.Bus.broadcast("exec_approvals", event)

      assert_receive {:event, "exec.approval.resolved", payload, _state_version}, 1_000

      assert payload == %{
               "approvalId" => "approval-oauth-1",
               "decision" => "approve_once",
               "runId" => "run-oauth-1",
               "sessionKey" => "session:oauth",
               "agentId" => "default",
               "tool" => "mcp_mcp_oauth"
             }

      assert :ok = Schemas.validate_event("exec.approval.resolved", payload)

      Presence.unregister(conn_id)
    end

    test "broadcasts approval timeout events with pending metadata" do
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      event =
        LemonCore.Event.new(
          :approval_resolved,
          %{
            approval_id: "approval-timeout-1",
            decision: :timeout,
            pending: %{
              run_id: "run-timeout-1",
              session_key: "session:timeout",
              agent_id: "default",
              tool: "bash"
            }
          },
          %{}
        )

      LemonCore.Bus.broadcast("exec_approvals", event)

      assert_receive {:event, "exec.approval.resolved", payload, _state_version}, 1_000

      assert payload == %{
               "approvalId" => "approval-timeout-1",
               "decision" => "timeout",
               "runId" => "run-timeout-1",
               "sessionKey" => "session:timeout",
               "agentId" => "default",
               "tool" => "bash"
             }

      assert :ok = Schemas.validate_event("exec.approval.resolved", payload)

      Presence.unregister(conn_id)
    end

    test "subscribes to cron topic on init" do
      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :cron_run_started,
            %{run: %{id: "cron-run-1", job_id: "job-1"}, job: %{name: "test job"}},
            %{}
          )

        LemonCore.Bus.broadcast("cron", event)

        Process.sleep(50)
        assert Process.alive?(Process.whereis(EventBridge))
      end
    end
  end
end
