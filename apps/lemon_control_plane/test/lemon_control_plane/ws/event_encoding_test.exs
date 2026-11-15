defmodule LemonControlPlane.WS.EventEncodingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.ExecutionNode.Socket
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{Cost, TextContent, Usage}
  alias LemonControlPlane.{EventBridge, Connections}
  alias LemonControlPlane.Protocol.Frames
  alias LemonControlPlane.WS.Connection

  test "all event handlers drop unencodable frames, redact diagnostics and retain sequence/version" do
    for kind <- [:event, :versioned, :node_event] do
      state = %Connection{
        conn_id: "encoding-test",
        connected: true,
        auth: %{role: if(kind == :node_event, do: :node, else: :operator)},
        event_seq: 0,
        state_version: %{}
      }

      payload = %{"private-payload-marker" => fn -> "private-error-marker" end}
      assert_raise Protocol.UndefinedError, fn -> Frames.encode_event("bad", payload, 1) end

      message =
        case kind do
          :versioned -> {:event, "private-event-marker", payload, %{presence: 7}}
          other -> {other, "private-event-marker", payload}
        end

      log =
        capture_log(fn ->
          assert {:ok, next} = Connection.handle_info(message, state)
          assert next.event_seq == 1
          expected_version = if kind == :versioned, do: %{presence: 7}, else: %{}
          assert next.state_version == expected_version

          assert {:push, {:text, frame}, final} =
                   Connection.handle_info(
                     {if(kind == :node_event, do: :node_event, else: :event), "next",
                      %{"ok" => true}},
                     next
                   )

          assert Jason.decode!(frame)["seq"] == 2
          assert Jason.decode!(frame)["payload"] == %{"ok" => true}
          assert final.state_version == expected_version
        end)

      assert log =~ "unsupported_json_type"
      refute log =~ "private-payload-marker"
      refute log =~ "private-error-marker"
      refute log =~ "private-event-marker"
    end
  end

  test "invalid UTF-8 encoding is dropped and the next frame succeeds" do
    state = %Connection{event_seq: 0, state_version: %{}}

    capture_log(fn ->
      assert {:ok, next} = Connection.handle_info({:event, "bad", %{"text" => <<255>>}}, state)
      assert {:push, {:text, frame}, _} = Connection.handle_info({:event, "next", %{}}, next)
      assert Jason.decode!(frame)["seq"] == 2
    end)
  end

  test "real socket receives typed bash updates and completion, survives a bad frame and stays isolated from nodes" do
    previous_token = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    Application.put_env(:lemon_control_plane, :operator_token, "encoding-wire-test-secret")
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    on_exit(fn ->
      restore_env(:operator_token, previous_token)
      restore_env(:allow_unauthenticated_loopback_operator, previous_loopback)
    end)

    ensure_started(Connections)
    bridge = ensure_started(EventBridge)
    suffix = System.unique_integer([:positive])
    client_id = "encoding-wire-#{suffix}"
    node_id = "encoding-node-#{suffix}"
    :ok = Connections.register(node_id, %{role: :node, client_id: node_id, pid: self()})

    on_exit(fn ->
      if Process.whereis(Connections), do: Connections.unregister(node_id)
    end)

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:encoding_bandit, suffix},
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    socket =
      start_supervised!(%{
        id: {:encoding_socket, suffix},
        start:
          {Socket, :start_link,
           [
             [
               owner: self(),
               url: "ws://127.0.0.1:#{port}/ws",
               connect_params: %{
                 "role" => "operator",
                 "auth" => %{"token" => "encoding-wire-test-secret"},
                 "client" => %{"id" => client_id}
               },
               reconnect_delay_ms: 10,
               ping_interval_ms: 0
             ]
           ]},
        restart: :temporary
      })

    assert_receive {:execution_node_socket, ^socket, {:connected, _hello}}, 3_000

    assert {conn_id, %{pid: server}} =
             Enum.find(Connections.list(), fn {_id, info} -> info.client_id == client_id end)

    monitor = Process.monitor(server)

    result = %AgentToolResult{
      content: [%TextContent{text: "live bash output", text_signature: "private-signature"}],
      details: %{
        exit_code: 0,
        usage: %Usage{input: 2, output: 1, total_tokens: 3, cost: %Cost{total: 0.01}}
      }
    }

    run_id = "run-#{suffix}"
    session_key = "session-#{suffix}"
    action_id = "tool-#{suffix}"

    for {phase, key} <- [{:updated, :partial_result}, {:completed, :result}] do
      event =
        LemonCore.Event.engine_action(
          %{
            engine: "lemon",
            action: %{id: action_id, kind: "command", title: "bash", detail: %{key => result}},
            phase: phase,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      send(bridge, event)
      phase_text = Atom.to_string(phase)

      assert_receive {:execution_node_socket, ^socket,
                      {:event, "agent",
                       %{
                         "runId" => ^run_id,
                         "sessionKey" => ^session_key,
                         "phase" => ^phase_text,
                         "action" => %{"id" => ^action_id, "detail" => detail}
                       }}},
                     3_000

      visible = detail[Atom.to_string(key)]
      assert visible["content"] == [%{"type" => "text", "text" => "live bash output"}]
      assert visible["details"]["usage"]["total_tokens"] == 3
      assert visible["details"]["usage"]["cost"]["total"] == 0.01
    end

    refute_receive {:event, "agent", _, _}, 50

    log =
      capture_log(fn ->
        send(server, {:event, "bad-private-event", %{"private-payload" => fn -> :secret end}})
        send(server, {:event, "chat", %{"type" => "delta", "text" => "after bad frame"}})

        assert_receive {:execution_node_socket, ^socket,
                        {:event, "chat", %{"text" => "after bad frame"}}},
                       3_000
      end)

    assert log =~ "unsupported_json_type"
    refute log =~ "private-payload"
    refute log =~ "bad-private-event"
    refute_receive {:DOWN, ^monitor, :process, ^server, _}, 50
    refute_receive {:execution_node_socket, ^socket, {:disconnected, _}}, 50
    assert Connections.get(conn_id).pid == server
    assert Process.alive?(socket)
    Process.demonitor(monitor, [:flush])
  end

  defp ensure_started(module) do
    Process.whereis(module) || start_supervised!({module, []})
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_control_plane, key, value)
end
