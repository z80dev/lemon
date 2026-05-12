defmodule LemonControlPlane.EventBridgeTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.EventBridge
  alias LemonControlPlane.Presence

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
                  tool_name: "missing_tool_for_runner"
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
                              tool_name: "missing_tool_for_runner"
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
  end

  describe "static topic subscriptions" do
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
