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

  # Flushes the bridge mailbox. `subscribe_topics/1` is a cast and bus delivery is a plain
  # message send, so a synchronous `:sys` call returns only once both have been handled (and
  # exits if the bridge crashed while handling them).
  defp sync_bridge(bridge_pid), do: :sys.get_state(bridge_pid)

  defp flush_events do
    receive do
      {:event, _, _, _} -> flush_events()
      {:event, _, _} -> flush_events()
    after
      0 -> :ok
    end
  end

  defp start_event_collector(label) do
    parent = self()
    spawn(fn -> collect_events(parent, label) end)
  end

  defp collect_events(parent, label) do
    receive do
      {:event, _event_name, _payload, _state_version} = event ->
        send(parent, {:client_event, label, event})
        collect_events(parent, label)

      :stop ->
        :ok
    end
  end

  test "general node invocation events omit execution arguments and MCP secrets" do
    conn_id = "conn_private_invoke_#{System.unique_integer([:positive])}"
    assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
    flush_events()

    event =
      LemonCore.Event.new(
        :node_invoke_request,
        %{
          invoke_id: "inv-private",
          node_id: "worker",
          method: "coding_agent.run",
          timeout_ms: 30_000,
          args: %{
            "request" => %{
              "prompt" => "private prompt",
              "meta" => %{
                "mcp_servers" => [%{"headers" => %{"Authorization" => "Bearer private-header"}}],
                "system_prompt" => "private persona",
                "profile_instructions" => %{"SOUL.md" => "private soul"}
              }
            }
          }
        },
        %{}
      )

    LemonCore.Bus.broadcast("nodes", event)

    assert_receive {:event, "node.invoke.request", payload, _}, 1_000
    assert payload["invokeId"] == "inv-private"
    assert payload["cleanup"] == %{"includesArgs" => false}
    refute Map.has_key?(payload, "args")
    refute inspect(payload) =~ "private-header"
    refute inspect(payload) =~ "private prompt"
    refute inspect(payload) =~ "private persona"
    refute inspect(payload) =~ "private soul"
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
    test "subscribes to session topics", %{bridge_pid: bridge_pid} do
      session_key = "session_#{System.unique_integer()}"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      assert :ok = EventBridge.subscribe_topics(["session:#{session_key}"])
      sync_bridge(bridge_pid)

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
  end

  describe "event forwarding" do
    test "completed exposes authoritative cancellation independent of abort acknowledgement" do
      conn_id = "cancel_wire_#{System.unique_integer([:positive])}"
      :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      on_exit(fn -> Presence.unregister(conn_id) end)
      flush_events()

      for {completion_meta, expected} <- [
            {%{cancelled: true, budget: %{limit: 10}}, true},
            {%{"cancelled" => true}, true},
            {%{}, false}
          ] do
        send(
          Process.whereis(EventBridge),
          LemonCore.Event.new(
            :run_completed,
            %{completed: %{ok: false, error: "Cancelled", meta: completion_meta}},
            %{run_id: "cancel-wire"}
          )
        )

        assert_receive {:event, "agent", %{"type" => "completed"} = payload, _}, 1_000
        assert payload["cancelled"] == expected
        assert payload["error"] == "Cancelled"
        assert payload["ok"] == false
      end
    end

    test "completed error projection is bounded and redacts credential fields" do
      conn_id = "error_wire_#{System.unique_integer([:positive])}"
      :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      on_exit(fn -> Presence.unregister(conn_id) end)
      flush_events()

      error = %{
        message: String.duplicate("x", 100_000),
        api_key: "test-secret-token",
        state: self()
      }

      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(:run_completed, %{completed: %{ok: false, error: error}}, %{
          run_id: "error-wire"
        })
      )

      assert_receive {:event, "agent", %{"type" => "completed"} = payload, _}, 1_000
      encoded = Jason.encode!(payload["error"])
      assert byte_size(encoded) <= 32 * 1024
      refute encoded =~ "test-secret-token"
      refute Map.has_key?(payload["error"], :state)
      assert payload["cancelled"] == false
    end

    test "never forwards prompt, chat, tool, or approval events to node clients" do
      operator_pid = start_event_collector(:operator)
      node_pid = start_event_collector(:node)
      operator_conn_id = "operator_#{System.unique_integer()}"
      node_conn_id = "node_#{System.unique_integer()}"
      run_id = "run_private_#{System.unique_integer()}"
      session_key = "session:private"

      assert :ok =
               Presence.register(operator_conn_id, %{
                 role: :operator,
                 client_id: "operator",
                 pid: operator_pid
               })

      assert :ok =
               Presence.register(node_conn_id, %{
                 role: :node,
                 client_id: "node-1",
                 pid: node_pid
               })

      bridge = Process.whereis(EventBridge)

      send(
        bridge,
        LemonCore.Event.new(
          :task_started,
          %{
            task_id: "task-private",
            run_id: run_id,
            session_key: session_key,
            description: "private delegated prompt"
          },
          %{run_id: run_id, session_key: session_key}
        )
      )

      send(
        bridge,
        LemonCore.Event.new(
          :delta,
          %{run_id: run_id, seq: 1, text: "private chat text"},
          %{run_id: run_id, session_key: session_key}
        )
      )

      send(
        bridge,
        LemonCore.Event.engine_action(
          %{
            engine: "lemon",
            action: %{
              id: "tool-private",
              kind: "tool",
              title: "private tool",
              detail: %{command: "private command"}
            },
            phase: :started
          },
          %{run_id: run_id, session_key: session_key}
        )
      )

      send(
        bridge,
        LemonCore.Event.new(
          :approval_requested,
          %{
            pending: %{
              id: "approval-private",
              run_id: run_id,
              session_key: session_key,
              tool: "bash",
              action: %{command: "private approval command"},
              rationale: "private approval rationale"
            }
          },
          %{}
        )
      )

      for event_name <- ["task.started", "chat", "agent", "exec.approval.requested"] do
        assert_receive {:client_event, :operator, {:event, ^event_name, _payload, _version}},
                       1_000
      end

      for event_name <- ["task.started", "chat", "agent", "exec.approval.requested"] do
        refute_receive {:client_event, :node, {:event, ^event_name, _payload, _version}}, 50
      end

      send(operator_pid, :stop)
      send(node_pid, :stop)
      Presence.unregister(operator_conn_id)
      Presence.unregister(node_conn_id)
    end

    test "maps channel_delivery events to channel.delivery frames" do
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})

      flush_events()

      intent_id = "intent_#{System.unique_integer()}"

      payload =
        LemonCore.Events.ChannelDelivery.new(%{
          intent_id: intent_id,
          run_id: "run-bridge-1",
          session_key: "agent:default:main",
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :dm,
          peer_id: "42",
          kind: :final_text,
          text_preview: "hello",
          ok: true,
          duration_ms: 3,
          ts_ms: 1_754_800_000_000
        })

      :ok =
        LemonCore.Bus.broadcast_event("channels", :channel_delivery, payload, %{
          run_id: "run-bridge-1",
          session_key: "agent:default:main"
        })

      assert_receive {:event, "channel.delivery",
                      %{
                        "intentId" => ^intent_id,
                        "runId" => "run-bridge-1",
                        "sessionKey" => "agent:default:main",
                        "channelId" => "telegram",
                        "accountId" => "default",
                        "peerKind" => "dm",
                        "peerId" => "42",
                        "kind" => "final_text",
                        "textPreview" => "hello",
                        "ok" => true,
                        "error" => nil,
                        "durationMs" => 3,
                        "tsMs" => 1_754_800_000_000
                      }, _state_version},
                     1_000

      Presence.unregister(conn_id)
    end

    test "processes run_completed events", %{bridge_pid: bridge_pid} do
      run_id = "run_#{System.unique_integer()}"

      EventBridge.subscribe_run(run_id)
      sync_bridge(bridge_pid)

      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :run_completed,
            %{completed: %{ok: true, answer: "Done"}, duration_ms: 100},
            %{run_id: run_id, session_key: "test"}
          )

        LemonCore.Bus.broadcast("run:#{run_id}", event)

        sync_bridge(bridge_pid)
        assert Process.alive?(Process.whereis(EventBridge))
      end

      EventBridge.unsubscribe_run(run_id)
    end

    test "maps nested engine action detail metadata to agent tool_use events", %{
      bridge_pid: bridge_pid
    } do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-tool-failure"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()
      EventBridge.subscribe_run(run_id)
      sync_bridge(bridge_pid)

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
                          "kind" => :tool,
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

    test "sends operator clients the full tool result and structured details instead of the channel preview",
         %{bridge_pid: bridge_pid} do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-operator-result"
      conn_id = "conn_#{System.unique_integer()}"
      full = Enum.map_join(1..200, "\n", &"line #{&1}")
      preview = String.slice(full, 0, 500) <> "..."

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()
      EventBridge.subscribe_run(run_id)
      sync_bridge(bridge_pid)

      event =
        LemonCore.Event.engine_action(
          %{
            engine: "lemon",
            action: %{
              id: "tool_edit_1",
              kind: "file_change",
              title: "edit: `lib/a.ex`",
              detail: %{
                name: "edit",
                args: %{"path" => "lib/a.ex"},
                result: preview,
                result_full: full,
                details: %{diff: "-120\told\n+120\tnew", first_changed_line: 120}
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      LemonCore.Bus.broadcast("run:#{run_id}", event)

      assert_receive {:event, "agent", %{"type" => "tool_use", "action" => %{"detail" => detail}},
                      _state_version},
                     1_000

      assert detail.result == full
      refute Map.has_key?(detail, :result_full)
      assert detail.details == %{diff: "-120\told\n+120\tnew", first_changed_line: 120}

      reasoning_event =
        LemonCore.Event.engine_action(
          %{
            engine: "lemon",
            action: %{
              id: "lemon.reasoning.0.1",
              kind: "reasoning",
              title: "thinking",
              detail: %{
                reasoning: %{text: "...tail", full_text: "head and tail", source: "lemon"}
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      LemonCore.Bus.broadcast("run:#{run_id}", reasoning_event)

      assert_receive {:event, "agent",
                      %{
                        "type" => "tool_use",
                        "action" => %{"detail" => %{reasoning: reasoning}}
                      }, _state_version},
                     1_000

      assert reasoning == %{text: "head and tail", source: "lemon"}

      EventBridge.unsubscribe_run(run_id)
      Presence.unregister(conn_id)
    end

    test "maps checkpoint events to agent events", %{bridge_pid: bridge_pid} do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-checkpoint"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      EventBridge.subscribe_run(run_id)
      sync_bridge(bridge_pid)

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

    test "maps goal events to goal events", %{bridge_pid: bridge_pid} do
      run_id = "run_#{System.unique_integer()}"
      session_key = "session:event-bridge-goal"
      conn_id = "conn_#{System.unique_integer()}"

      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      EventBridge.subscribe_run(run_id)
      sync_bridge(bridge_pid)

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

    test "maps ingested metrics and log events with target fields" do
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

    test "subscribes to exec_approvals topic on init", %{bridge_pid: bridge_pid} do
      # EventBridge should be subscribed to exec_approvals
      if Code.ensure_loaded?(LemonCore.Bus) do
        event =
          LemonCore.Event.new(
            :approval_requested,
            %{pending: %{id: "approval-1", run_id: "run-1", tool: "bash", rationale: "test"}},
            %{}
          )

        LemonCore.Bus.broadcast("exec_approvals", event)

        sync_bridge(bridge_pid)
        assert Process.alive?(Process.whereis(EventBridge))
      end
    end

    test "approval events redact nested credentials while preserving review targets" do
      conn_id = "conn_#{System.unique_integer()}"
      assert :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      on_exit(fn -> Presence.unregister(conn_id) end)
      flush_events()

      event =
        LemonCore.Event.new(
          :approval_requested,
          %{
            pending: %{
              id: "approval-redaction",
              run_id: "run-redaction",
              session_key: "agent:test:main",
              agent_id: "test",
              tool: "bash",
              action: %{
                path: "/tmp/review-target",
                headers: %{"Authorization" => "Bearer credential-value"},
                password: "password-value"
              },
              rationale: "Review Authorization: Bearer rationale-secret"
            }
          },
          %{}
        )

      LemonCore.Bus.broadcast("exec_approvals", event)

      assert_receive {:event, "exec.approval.requested", payload, _state_version}, 1_000
      assert payload["action"]["path"] == "/tmp/review-target"

      for secret <- ["credential-value", "password-value", "rationale-secret"] do
        refute inspect(payload) =~ secret
      end

      assert :ok = Schemas.validate_event("exec.approval.requested", payload)
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
              "id" => "approval-oauth-1",
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
              id: "approval-timeout-1",
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
  end

  describe "model and usage on agent frames" do
    setup do
      conn_id = "conn_#{System.unique_integer([:positive])}"
      run_id = "run_model_#{System.unique_integer([:positive])}"

      :ok = Presence.register(conn_id, %{role: :operator, client_id: "test", pid: self()})
      flush_events()

      # Presence is stopped by the file-level teardown, which can win this race when the
      # whole suite runs; unregistering a conn on a dead registry is a no-op, not a failure.
      on_exit(fn ->
        try do
          Presence.unregister(conn_id)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, run_id: run_id}
    end

    test "started carries the resolved model, its provider and the thinking level", %{
      run_id: run_id
    } do
      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(
          :run_started,
          %{
            run_id: run_id,
            session_key: "agent:default:main",
            engine: "coding_agent",
            model: "claude-sonnet-4-20250514",
            thinking_level: :medium
          },
          %{run_id: run_id, session_key: "agent:default:main"}
        )
      )

      assert_receive {:event, "agent", payload, _version}, 1_000

      assert payload["type"] == "started"
      assert payload["runId"] == run_id
      assert payload["engine"] == "lemon"
      assert payload["model"] == "claude-sonnet-4-20250514"
      # Derived here rather than left to the client to parse out of the id.
      assert payload["provider"] == "anthropic"
      assert payload["thinkingLevel"] == "medium"
    end

    test "started falls back to the model on event meta", %{run_id: run_id} do
      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id, engine: "coding_agent"},
          %{run_id: run_id, model: "gpt-5.4"}
        )
      )

      assert_receive {:event, "agent", %{"type" => "started", "model" => "gpt-5.4"}, _}, 1_000
    end

    test "started keeps model keys present-but-null when nothing knew one", %{run_id: run_id} do
      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(:run_started, %{run_id: run_id, engine: "native"}, %{run_id: run_id})
      )

      assert_receive {:event, "agent", payload, _}, 1_000
      assert payload["type"] == "started"
      assert Map.has_key?(payload, "model")
      assert payload["model"] == nil
      assert payload["provider"] == nil
    end

    test "completed carries normalized usage and the model", %{run_id: run_id} do
      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: true,
              answer: "done",
              usage: %{
                input_tokens: 1_000,
                output_tokens: 50,
                cache_read_input_tokens: 4_000
              }
            },
            duration_ms: 12
          },
          %{run_id: run_id, session_key: "agent:default:main", model: "claude-sonnet-4-20250514"}
        )
      )

      assert_receive {:event, "agent", payload, _}, 1_000

      assert payload["type"] == "completed"
      assert payload["ok"] == true
      assert payload["model"] == "claude-sonnet-4-20250514"

      assert %{
               "inputTokens" => 1_000,
               "outputTokens" => 50,
               "cacheReadTokens" => 4_000,
               "contextTokens" => 5_000
             } = payload["usage"]
    end

    test "completed reports no usage as null rather than zeros", %{run_id: run_id} do
      send(
        Process.whereis(EventBridge),
        LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: false, error: "boom"}, duration_ms: 3},
          %{run_id: run_id}
        )
      )

      assert_receive {:event, "agent", %{"type" => "completed"} = payload, _}, 1_000
      assert payload["usage"] == nil
    end
  end
end
