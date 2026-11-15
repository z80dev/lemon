defmodule LemonComputerUse.ServerRpcTest do
  use ExUnit.Case, async: false

  alias LemonComputerUse.Server
  alias LemonComputerUse.Tools.Common
  alias LemonCore.Rpc.{Client, JsonLines}

  setup do
    server = start_supervised!({Server, name: nil})
    test_pid = self()

    state =
      :sys.replace_state(server, fn state ->
        {:ok, rpc} =
          Client.start_link(
            owner: server,
            framing: JsonLines,
            send: fn bytes ->
              {:ok, [request], ""} = JsonLines.decode(bytes)
              send(test_pid, {:sent, request})
              :ok
            end
          )

        %{state | rpc: rpc, connected?: true}
      end)

    %{server: server, rpc: state.rpc}
  end

  test "the shared client correlates split frames while only one operation is dispatched", %{
    server: server,
    rpc: rpc
  } do
    first = request(server, "first")
    assert_receive {:sent, %{"type" => "call", "id" => first_id}}
    second = request(server, "second")
    assert %{busy: true, queued: 1} = Server.status(server)
    assert Client.pending_count(rpc) == 1
    refute_receive {:sent, _}, 0

    feed(rpc, %{"id" => -1, "ok" => true, "result" => "unrelated"})
    bytes = Jason.encode!(%{id: first_id, ok: true, result: "first result"}) <> "\n"
    <<prefix::binary-size(5), suffix::binary>> = bytes
    Client.feed(rpc, prefix)
    assert Client.pending_count(rpc) == 1
    refute_receive {^first, _}, 0
    Client.feed(rpc, suffix)

    assert_receive {^first, {:ok, "first result"}}
    assert_receive {:sent, %{"type" => "call", "id" => second_id}}
    assert second_id != first_id
    assert Client.pending_count(rpc) == 1
    feed(rpc, %{id: second_id, ok: true, result: "second result"})
    assert_receive {^second, {:ok, "second result"}}
    assert %{busy: false, queued: 0} = Server.status(server)
    assert Client.pending_count(rpc) == 0
  end

  test "caller death cancels approvals but holds the desktop until the bridge acknowledges", %{
    server: server,
    rpc: rpc
  } do
    test_pid = self()

    approve = fn request ->
      send(test_pid, {:approval_waiting, self(), request})

      receive do
        :approve -> {:ok, :approved, :approve_once}
      end
    end

    context = Map.put(context(), :approval_request_fun, approve)

    {caller, caller_monitor} =
      spawn_monitor(fn -> Server.call("js", %{"code" => "first"}, context, nil, server) end)

    assert_receive {:sent, %{"id" => id, "type" => "call"}}
    feed(rpc, elicitation(10))
    assert_receive {:approval_waiting, approval, %{expires_in_ms: :infinity}}
    approval_monitor = Process.monitor(approval)
    second = request(server, "second")
    assert %{queued: 1} = Server.status(server)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    assert_receive {:sent, %{"type" => "cancel", "target" => ^id}}
    assert_receive {:DOWN, ^approval_monitor, :process, ^approval, :killed}
    assert Client.pending_count(rpc) == 0
    assert %{busy: true, queued: 1} = Server.status(server)
    refute_receive {:sent, %{"type" => "call"}}, 0

    feed(rpc, elicitation(11))

    assert_receive {:sent,
                    %{
                      "type" => "elicitationResponse",
                      "id" => 11,
                      "response" => %{"action" => "cancel"}
                    }}

    refute_receive {:approval_waiting, _, _}, 0
    feed(rpc, %{id: id, ok: false, error: "aborted"})
    assert_receive {:sent, %{"type" => "call", "id" => second_id}}
    feed(rpc, %{id: second_id, ok: true, result: "after cancellation"})
    assert_receive {^second, {:ok, "after cancellation"}}
    assert Client.pending_count(rpc) == 0
  end

  test "message-driven abort retains the shared request until acknowledgement", %{
    server: server,
    rpc: rpc
  } do
    signal = LemonAgent.AbortSignal.new()
    task = Task.async(fn -> Server.call("js", %{}, context(), signal, server) end)
    assert_receive {:sent, %{"type" => "call", "id" => id}}
    send(task.pid, {:lemon_abort, signal, :abort})
    assert_receive {:sent, %{"type" => "cancel", "target" => ^id}}
    assert Client.pending_count(rpc) == 1
    assert %{busy: true} = Server.status(server)

    feed(rpc, %{id: id, ok: false, error: "aborted"})
    assert Task.await(task) == {:error, {:bridge_error, "aborted", nil}}
    assert %{busy: false} = Server.status(server)
    assert Client.pending_count(rpc) == 0
  end

  test "queued cancellation never dispatches another operation", %{server: server, rpc: rpc} do
    first = request(server, "first")
    assert_receive {:sent, %{"type" => "call", "id" => id}}
    second = request(server, "second")
    GenServer.cast(server, {:cancel, second})
    assert_receive {^second, {:error, :aborted}}
    assert %{busy: true, queued: 0} = Server.status(server)
    assert Client.pending_count(rpc) == 1

    feed(rpc, %{id: id, ok: true, result: "finished"})
    assert_receive {^first, {:ok, "finished"}}
    assert %{busy: false, queued: 0} = Server.status(server)
    refute_receive {:sent, _}, 0
  end

  test "transport loss fails active and queued calls without replaying desktop actions", %{
    server: server,
    rpc: rpc
  } do
    task = Task.async(fn -> Server.call("js", %{}, context(), nil, server) end)
    assert_receive {:sent, %{"type" => "call"}}
    queued = request(server, "never sent")
    assert %{queued: 1} = Server.status(server)
    Client.peer_down(rpc, :closed)

    assert {:error, {:bridge_exited, :connection_closed} = reason} = Task.await(task)
    assert Common.error_text(reason) =~ "may already have taken effect"
    assert_receive {^queued, {:error, {:bridge_exited, :rpc_closed}}}
    assert %{busy: false, queued: 0, connected: false} = Server.status(server)
    refute_receive {:sent, _}, 0
  end

  test "malformed bridge frames retain unknown-outcome semantics", %{server: server, rpc: rpc} do
    task = Task.async(fn -> Server.call("js", %{}, context(), nil, server) end)
    assert_receive {:sent, %{"type" => "call"}}
    monitor = Process.monitor(rpc)
    Client.feed(rpc, "not-json\n")

    assert {:error, {:bridge_exited, :invalid_frame} = reason} = Task.await(task)
    assert Common.error_text(reason) =~ "may already have taken effect"
    assert_receive {:DOWN, ^monitor, :process, ^rpc, :normal}
  end

  defp request(server, code) do
    ref = make_ref()
    GenServer.cast(server, {:call, self(), ref, "js", %{"code" => code}, context()})
    ref
  end

  defp context, do: %{session_id: "rpc-session", turn_id: "rpc-turn"}

  defp feed(rpc, message) do
    {:ok, bytes} = JsonLines.encode(message)
    Client.feed(rpc, bytes)
  end

  defp elicitation(id) do
    %{
      type: "elicitation",
      id: id,
      params: %{
        "mode" => "form",
        "message" => "Allow Calculator?",
        "requestedSchema" => %{"type" => "object", "properties" => %{}},
        "_meta" => %{
          "codex_approval_kind" => "mcp_tool_call",
          "connector_id" => "computer-use",
          "tool_params" => %{"app" => "com.apple.calculator"},
          "x-codex-turn-metadata" => %{"session_id" => "rpc-session", "turn_id" => "rpc-turn"}
        }
      }
    }
  end
end
