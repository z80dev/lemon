defmodule CodingAgent.Wasm.SidecarSessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.ToolIntent
  alias CodingAgent.Wasm.Config
  alias CodingAgent.Wasm.SidecarSession
  alias CodingAgent.Wasm.SidecarSession.Framing
  alias LemonAgent.AbortSignal
  alias LemonCore.Rpc.Client

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime_path = Path.join(tmp_dir, "sidecar.py")

    File.write!(runtime_path, """
    #!/usr/bin/env python3
    import json
    import os
    import sys

    def respond(req_id, result):
      print(json.dumps({"type": "response", "id": req_id, "ok": True,
                        "result": result, "error": None}), flush=True)

    for line in sys.stdin:
      req = json.loads(line)
      kind = req["type"]
      req_id = req["id"]
      if kind == "hello":
        respond(req_id, {"version": 1})
      elif kind == "discover":
        if not os.path.exists("stall-discover"):
          respond(req_id, {"tools": [], "warnings": [], "errors": []})
      elif kind == "invoke":
        if req["tool"] == "echo":
          respond(req_id, {"output_json": req["params_json"], "logs": [], "details": {}})
        elif req["tool"] == "exit":
          sys.exit(17)
        elif req["tool"] == "host_call":
          print(json.dumps({"type": "event", "event": "host_call", "request_id": req_id,
                            "call_id": "call-1", "tool": "host", "params_json": "{}"}), flush=True)
      elif kind == "host_call_result":
        respond(req_id, {"accepted": True})
      elif kind == "shutdown":
        break
    """)

    File.chmod!(runtime_path, 0o755)
    %{runtime_path: runtime_path}
  end

  test "request deadlines return errors and release the invocation slot", context do
    sidecar = start_sidecar(context)

    assert {:error, :timeout} = SidecarSession.invoke(sidecar, "never_reply", "{}", nil, 25)

    state = :sys.get_state(sidecar)
    assert state.invocation == nil
    refute Map.has_key?(state, :pending)
    assert Client.pending_count(state.rpc_client) == 0

    assert {:ok, %{output_json: "{\"next\":true}"}} =
             SidecarSession.invoke(sidecar, "echo", "{\"next\":true}")
  end

  test "discovery deadlines are owned by the RPC client", context do
    sidecar = start_sidecar(context)
    File.write!(Path.join(context.tmp_dir, "stall-discover"), "")

    assert {:error, :timeout} = SidecarSession.discover(sidecar, 25)
    assert Client.pending_count(:sys.get_state(sidecar).rpc_client) == 0

    File.rm!(Path.join(context.tmp_dir, "stall-discover"))
    assert {:ok, %{tools: [], warnings: [], errors: []}} = SidecarSession.discover(sidecar)
  end

  test "deadlines complete callers and expire parent scopes while a host callback is blocked", context do
    test_pid = self()

    sidecar =
      start_sidecar(context, fn "host", "{}", invocation ->
        send(test_pid, {:host_waiting, self(), invocation})

        receive do
          :release_host -> {:ok, "null"}
        end
      end)

    state = :sys.get_state(sidecar)
    caller =
      Task.async(fn ->
        ToolIntent.with_parent_scope("parent", fn _scope ->
          SidecarSession.invoke(sidecar, "host_call", "{}", nil, 60_000)
        end)
      end)

    assert_receive {:host_waiting, ^sidecar,
                    %{owner: owner, parent_intent_scope: {"parent", scope_owner, live}}},
                   5_000
    assert scope_owner == owner
    assert :atomics.get(live, 1) == 1
    assert owner == caller.pid

    # The callback barrier proves dispatch finished. Deliver the exact scheduled
    # timer event, without sleeping or waiting for a wall-clock race.
    {_phase, %{pending: pending}} = :sys.get_state(state.rpc_client)
    [{id, %{timer: timer, token: token}}] = Map.to_list(pending)
    assert is_reference(timer)
    assert is_integer(Process.read_timer(timer))
    Process.cancel_timer(timer)
    send(state.rpc_client, {:deadline, id, token})

    assert {:error, :timeout} = Task.await(caller, 5_000)
    assert :atomics.get(live, 1) == 0
    assert Client.pending_count(state.rpc_client) == 0

    send(sidecar, :release_host)
    assert :sys.get_state(sidecar).invocation == nil
    assert {:ok, %{output_json: "{}"}} = SidecarSession.invoke(sidecar, "echo", "{}")
  end

  test "message-driven abort removes the caller and subscription", context do
    sidecar = start_sidecar(context)
    signal = AbortSignal.new()
    {request, state} = dispatch_invoke(sidecar, signal)
    assert Client.pending_count(state.rpc_client) == 1

    AbortSignal.abort(signal)
    assert {:reply, {:error, :aborted}} = :gen_server.wait_response(request, 5_000)
    assert :sys.get_state(sidecar).invocation == nil
    assert Client.pending_count(state.rpc_client) == 0

    refute Enum.any?(Registry.lookup(LemonAgent.AbortSignal.Registry, signal), fn {pid, _} ->
             pid == sidecar
           end)

    assert {:ok, %{output_json: "{}"}} = SidecarSession.invoke(sidecar, "echo", "{}")
  end

  test "caller death releases ownership without accepting late responses", context do
    sidecar = start_sidecar(context)
    test_pid = self()
    telemetry_id = make_ref()
    session_hash = session_hash(context.tmp_dir)

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:lemon, :wasm, :invoke, :stop],
        &__MODULE__.notify_stop/4,
        {test_pid, session_hash}
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    caller =
      spawn(fn ->
        {_request, state} = dispatch_invoke(sidecar)
        send(test_pid, {:dispatched, self(), state.invocation.id, state.rpc_client})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:dispatched, ^caller, old_id, client}, 5_000
    Process.exit(caller, :kill)
    assert_receive {:invoke_stopped, %{ok: false}}, 5_000
    assert :sys.get_state(sidecar).invocation == nil
    assert Client.pending_count(client) == 0

    {request, state} = dispatch_invoke(sidecar)
    id = state.invocation.id
    send(sidecar, {:rpc_message, response(old_id, "stale")})
    assert :sys.get_state(sidecar).invocation.id == id
    assert Client.pending_count(client) == 1

    send(sidecar, {:rpc_message, response(id, "fresh")})

    assert {:reply, {:invoke_response, {:ok, %{output_json: "fresh"}}, _metadata}} =
             :gen_server.wait_response(request, 5_000)

    assert :sys.get_state(sidecar).invocation == nil
    assert Client.pending_count(client) == 0
  end

  test "the port exit result and sidecar lifecycle are preserved", context do
    sidecar = start_sidecar(context)
    state = :sys.get_state(sidecar)
    sidecar_monitor = Process.monitor(sidecar)
    client_monitor = Process.monitor(state.rpc_client)

    capture_log(fn ->
      assert {:error, {:sidecar_exit, 17}} = SidecarSession.invoke(sidecar, "exit", "{}")
      assert_receive {:DOWN, ^sidecar_monitor, :process, ^sidecar, {:sidecar_exit, 17}}, 5_000
      assert_receive {:DOWN, ^client_monitor, :process, _, :normal}, 5_000
    end)
  end

  test "stopping the sidecar drains pending callers and closes the port", context do
    sidecar = start_sidecar(context)
    {request, state} = dispatch_invoke(sidecar)
    client_monitor = Process.monitor(state.rpc_client)

    :ok = SidecarSession.stop(sidecar)
    assert {:reply, {:error, :connection_closed}} = :gen_server.wait_response(request, 5_000)
    assert_receive {:DOWN, ^client_monitor, :process, _, :normal}, 5_000
    assert Port.info(state.port) == nil
  end

  test "framing retains JSONL bytes and tolerates malformed lines between split responses" do
    message = %{"type" => "response", "id" => "invoke_1", "ok" => true}
    assert {:ok, encoded} = Framing.encode(message)
    assert encoded == Jason.encode!(message) <> "\n"
    split = byte_size(encoded) - 2
    <<first::binary-size(^split), last::binary>> = encoded
    assert {:ok, [], ^first} = Framing.decode(first)

    capture_log(fn ->
      assert {:ok, [^message, ^message], "tail"} =
               Framing.decode(first <> last <> "not-json\n[]\n\n" <> encoded <> "tail")
    end)
  end

  def notify_stop(_event, measurements, %{session_hash: hash}, {test_pid, hash}) do
    send(test_pid, {:invoke_stopped, measurements})
  end

  def notify_stop(_event, _measurements, _metadata, _config), do: :ok

  defp start_sidecar(context, host_invoke_fun \\ fn _, _ -> {:error, :not_used} end) do
    config = %Config{
      enabled: true,
      auto_build: false,
      runtime_path: context.runtime_path,
      discover_paths: [context.tmp_dir]
    }

    sidecar =
      start_supervised!(
        Supervisor.child_spec(
          {SidecarSession,
           cwd: context.tmp_dir,
           session_id: context.tmp_dir,
           wasm_config: config,
           host_invoke_fun: host_invoke_fun},
          restart: :temporary
        )
      )

    assert {:ok, %{tools: []}} = SidecarSession.discover(sidecar)
    assert SidecarSession.status(sidecar).hello_ok
    sidecar
  end

  defp dispatch_invoke(sidecar, signal \\ nil) do
    request =
      :gen_server.send_request(
        sidecar,
        {:invoke, "never_reply", "{}", nil, :infinity, signal, nil}
      )

    # Same-sender ordering makes this a dispatch barrier, not a polling loop.
    state = :sys.get_state(sidecar)
    assert %{id: id} = state.invocation
    assert is_binary(id)
    {request, state}
  end

  defp response(id, output) do
    %{
      "type" => "response",
      "id" => id,
      "ok" => true,
      "result" => %{"output_json" => output, "logs" => [], "details" => %{}}
    }
  end

  defp session_hash(session_id) do
    :crypto.hash(:sha256, session_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
