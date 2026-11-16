defmodule CodingAgent.Debug.RpcClientTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Debug.{Client, Protocol, SessionServer}
  alias LemonAgent.AbortSignal
  alias LemonCore.Rpc.Client, as: RpcClient

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    key = "rpc-dap-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if server = SessionServer.whereis(key),
        do: DynamicSupervisor.terminate_child(CodingAgent.Debug.Supervisor, server)

      :gen_tcp.close(listener)
    end)

    adapter = %{
      name: "rpc-test",
      connect_mode: :remote,
      host: "127.0.0.1",
      port: port,
      attach_defaults: %{},
      command: nil,
      args: []
    }

    %{listener: listener, adapter: adapter, cwd: cwd, key: key, owner: self()}
  end

  test "shared correlation handles fragmented, coalesced and out-of-order replies", ctx do
    {client, socket, rpc} = start_client!(ctx)
    {:ok, first} = Client.request(client, "first", %{"text" => "héllo"})
    {:ok, second} = Client.request(client, "second")

    assert [%{"seq" => ^first, "arguments" => %{"text" => "héllo"}}, %{"seq" => ^second}] =
             receive_requests(socket, 2)

    assert RpcClient.pending_count(rpc) == 2
    encoded = IO.iodata_to_binary(Protocol.encode(response(second, "second")))
    <<head::binary-size(7), tail::binary>> = encoded
    assert :ok = :gen_tcp.send(socket, head)

    assert :ok =
             :gen_tcp.send(socket, [
               tail,
               Protocol.encode(response(first, "first")),
               event("barrier")
             ])

    assert_receive {:dap, ^client, {:response, ^second, %{"command" => "second"}}}, 5_000
    assert_receive {:dap, ^client, {:response, ^first, %{"command" => "first"}}}, 5_000
    assert_receive {:dap, ^client, {:event, "barrier", %{}}}, 5_000
    assert RpcClient.pending_count(rpc) == 0
  end

  test "timeout and cancellation discard late and duplicate replies", ctx do
    {client, socket, rpc} = start_client!(ctx)
    {:ok, expired} = Client.request(client, "expired", nil, 0)
    assert_receive {:dap, ^client, {:request_error, ^expired, :timeout}}, 5_000
    assert RpcClient.pending_count(rpc) == 0

    {:ok, cancelled} = Client.request(client, "cancelled")
    assert :ok = Client.cancel(client, cancelled)
    assert RpcClient.pending_count(rpc) == 0

    {:ok, current} = Client.request(client, "current")
    assert length(receive_requests(socket, 3)) == 3

    frames =
      for {seq, command} <- [
            {expired, "expired"},
            {cancelled, "cancelled"},
            {current, "current"},
            {current, "current"},
            {999, "unknown"}
          ],
          do: Protocol.encode(response(seq, command))

    assert :ok = :gen_tcp.send(socket, [frames, event("barrier")])
    assert_receive {:dap, ^client, {:response, ^current, _}}, 5_000
    assert_receive {:dap, ^client, {:event, "barrier", %{}}}, 5_000
    refute_received {:dap, ^client, {:response, _, _}}
    refute_received {:dap, ^client, {:request_error, _, _}}
    assert RpcClient.pending_count(rpc) == 0
  end

  test "clients isolate identical sequence numbers and pending state", ctx do
    {first_client, first_socket, first_rpc} = start_client!(ctx)
    {second_client, second_socket, second_rpc} = start_client!(ctx)
    {:ok, seq} = Client.request(first_client, "first")
    assert {:ok, ^seq} = Client.request(second_client, "second")
    assert [_] = receive_requests(first_socket, 1)
    assert [_] = receive_requests(second_socket, 1)

    assert :ok = :gen_tcp.send(second_socket, Protocol.encode(response(seq, "second")))
    assert_receive {:dap, ^second_client, {:response, ^seq, %{"command" => "second"}}}, 5_000
    assert RpcClient.pending_count(first_rpc) == 1
    assert RpcClient.pending_count(second_rpc) == 0

    assert :ok = :gen_tcp.send(first_socket, Protocol.encode(response(seq, "first")))
    assert_receive {:dap, ^first_client, {:response, ^seq, %{"command" => "first"}}}, 5_000
    assert RpcClient.pending_count(first_rpc) == 0
  end

  test "peer closure fails outstanding requests and stops the shared engine", ctx do
    {client, socket, rpc} = start_client!(ctx)
    client_ref = Process.monitor(client)
    rpc_ref = Process.monitor(rpc)
    {:ok, seq} = Client.request(client, "held")
    assert [_] = receive_requests(socket, 1)
    :ok = :gen_tcp.close(socket)

    assert_receive {:dap, ^client, {:exit, message}}, 5_000
    assert message =~ "closed its connection"
    assert_receive {:dap, ^client, {:request_error, ^seq, :connection_closed}}, 5_000
    assert_receive {:DOWN, ^rpc_ref, :process, ^rpc, :normal}, 5_000
    assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 5_000
  end

  test "a shared engine crash cannot leave an adapter client running", ctx do
    {client, socket, rpc} = start_client!(ctx)
    ref = Process.monitor(client)
    Process.exit(rpc, :kill)

    assert_receive {:dap, ^client, {:exit, "debug adapter RPC connection closed"}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 5_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
  end

  test "the shared engine monitors the request caller rather than its reply relay", ctx do
    {client, socket, rpc} = start_client!(ctx)
    parent = self()

    caller =
      spawn(fn ->
        result = Client.request(client, "held")
        send(parent, {:queued, result})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:queued, {:ok, seq}}, 5_000
    assert [_] = receive_requests(socket, 1)
    :erlang.trace(rpc, true, [:receive, {:tracer, self()}])
    send(caller, :stop)
    assert_receive {:trace, ^rpc, :receive, {:DOWN, _ref, :process, ^caller, :normal}}, 5_000
    :erlang.trace(rpc, false, [:receive])
    assert RpcClient.pending_count(rpc) == 0

    assert :ok =
             :gen_tcp.send(socket, [Protocol.encode(response(seq, "held")), event("barrier")])

    assert_receive {:dap, ^client, {:event, "barrier", %{}}}, 5_000
    refute_received {:dap, ^client, {:response, ^seq, _}}
    refute_received {:dap, ^client, {:request_error, ^seq, _}}
  end

  test "owner exit tears down both client and engine with an outstanding request", ctx do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, client} = Client.start_link(adapter: ctx.adapter, cwd: ctx.cwd)
        send(parent, {:owned_client, client})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:owned_client, client}, 5_000
    {:ok, socket} = :gen_tcp.accept(ctx.listener, 5_000)
    %{rpc: rpc} = :sys.get_state(client)
    client_ref = Process.monitor(client)
    rpc_ref = Process.monitor(rpc)
    {:ok, _seq} = Client.request(client, "held")
    assert [_] = receive_requests(socket, 1)
    send(owner, :stop)

    assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 5_000
    assert_receive {:DOWN, ^rpc_ref, :process, ^rpc, :normal}, 5_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
  end

  test "early attach replies survive initialization and configuration without local maps", ctx do
    {_socket, server, rpc} = start_session!(ctx)
    state = :sys.get_state(server)
    refute Map.has_key?(state.session, :awaiting)
    refute Map.has_key?(state.session, :responses)
    assert RpcClient.pending_count(rpc) == 0
  end

  test "an abort notification cancels an outstanding request and releases its subscription",
       ctx do
    {socket, server, rpc} = start_session!(ctx)
    signal = AbortSignal.new()

    task =
      Task.async(fn ->
        session_call(ctx, %{action: "evaluate", expression: "held"}, signal: signal)
      end)

    [request] = receive_requests(socket, 1)
    assert request["command"] == "evaluate"
    assert RpcClient.pending_count(rpc) == 1
    assert [{^server, nil}] = Registry.lookup(LemonAgent.AbortSignal.Registry, signal)
    send(server, {:lemon_abort, signal, :abort})

    assert {:aborted, "Debug operation cancelled."} = Task.await(task, 5_000)
    refute AbortSignal.aborted?(signal)
    assert Registry.lookup(LemonAgent.AbortSignal.Registry, signal) == []
    assert RpcClient.pending_count(rpc) == 0

    assert :ok = :gen_tcp.send(socket, Protocol.encode(response(request["seq"], "evaluate")))
    next = Task.async(fn -> session_call(ctx, %{action: "evaluate", expression: "next"}) end)
    [request] = receive_requests(socket, 1)

    failure =
      response(request["seq"], "evaluate")
      |> Map.put("success", false)
      |> Map.put("body", %{"error" => %{"format" => "cannot evaluate: expected failure"}})

    assert :ok = :gen_tcp.send(socket, Protocol.encode(failure))
    assert {:error, "cannot evaluate: expected failure"} = Task.await(next, 5_000)
    assert RpcClient.pending_count(rpc) == 0
  end

  test "redirect notifications do not cancel a DAP request", ctx do
    {socket, server, rpc} = start_session!(ctx)
    signal = AbortSignal.new()

    task =
      Task.async(fn ->
        session_call(ctx, %{action: "evaluate", expression: "held"}, signal: signal)
      end)

    [request] = receive_requests(socket, 1)
    :erlang.trace(server, true, [:receive, {:tracer, self()}])
    send(server, {:lemon_abort, signal, :redirect})
    assert_receive {:trace, ^server, :receive, {:lemon_abort, ^signal, :redirect}}, 5_000
    :erlang.trace(server, false, [:receive])
    assert RpcClient.pending_count(rpc) == 1
    reply(socket, request, %{"result" => "kept"})

    assert {:ok, %{evaluation: %{"result" => "kept"}}} = Task.await(task, 5_000)
    assert RpcClient.pending_count(rpc) == 0
    assert Registry.lookup(LemonAgent.AbortSignal.Registry, signal) == []
  end

  test "caller death releases a blocked request without waiting for its deadline", ctx do
    {socket, server, rpc} = start_session!(ctx)
    caller = spawn(fn -> session_call(ctx, %{action: "evaluate", expression: "held"}) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert [_] = receive_requests(socket, 1)
    assert RpcClient.pending_count(rpc) == 1
    Process.exit(caller, :kill)

    assert %{session: %{client: client}} = :sys.get_state(server, 5_000)
    assert is_pid(client)
    assert RpcClient.pending_count(rpc) == 0
  end

  test "session request timeout is delivered by the shared engine", ctx do
    {socket, _server, rpc} = start_session!(ctx)

    task =
      Task.async(fn ->
        session_call(ctx, %{action: "evaluate", expression: "held"}, timeout_ms: 0)
      end)

    assert [_] = receive_requests(socket, 1)
    assert {:error, "DAP request evaluate timed out after 0s"} = Task.await(task, 5_000)
    assert RpcClient.pending_count(rpc) == 0
  end

  defp start_client!(ctx) do
    {:ok, client} = Client.start_link(adapter: ctx.adapter, cwd: ctx.cwd)
    on_exit(fn -> Client.stop(client) end)
    {:ok, socket} = :gen_tcp.accept(ctx.listener, 5_000)
    %{rpc: rpc} = :sys.get_state(client)
    {client, socket, rpc}
  end

  defp start_session!(ctx) do
    task =
      Task.async(fn ->
        session_call(ctx, %{
          action: "attach",
          adapter: ctx.adapter,
          cwd: ctx.cwd,
          port: ctx.adapter.port,
          host: ctx.adapter.host,
          pid: nil
        })
      end)

    {:ok, socket} = :gen_tcp.accept(ctx.listener, 5_000)
    [initialize] = receive_requests(socket, 1)
    assert initialize["command"] == "initialize"
    reply(socket, initialize, %{"supportsConfigurationDoneRequest" => true})
    [attach] = receive_requests(socket, 1)
    assert attach["command"] == "attach"

    # This success precedes initialized and must stay available while the
    # configurationDone request is correlated independently.
    reply(socket, attach, %{})
    assert :ok = :gen_tcp.send(socket, event("initialized"))
    [configure] = receive_requests(socket, 1)
    assert configure["command"] == "configurationDone"
    reply(socket, configure, %{})
    assert :ok = :gen_tcp.send(socket, event("stopped", %{"reason" => "entry", "threadId" => 1}))
    [stack] = receive_requests(socket, 1)
    assert stack["command"] == "stackTrace"
    reply(socket, stack, %{"stackFrames" => []})
    assert {:ok, %{state: :stopped}} = Task.await(task, 5_000)

    server = SessionServer.whereis(ctx.key)
    %{session: %{client: client}} = :sys.get_state(server)
    %{rpc: rpc} = :sys.get_state(client)
    {socket, server, rpc}
  end

  defp session_call(ctx, request, opts \\ []) do
    SessionServer.call(
      ctx.key,
      request,
      Keyword.merge([timeout_ms: 30_000, owner: ctx.owner], opts)
    )
  end

  defp receive_requests(socket, count), do: receive_requests(socket, count, [], "")

  defp receive_requests(_socket, count, messages, buffer) when length(messages) == count do
    assert buffer == ""
    messages
  end

  defp receive_requests(socket, count, messages, buffer) do
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    {decoded, rest, junk} = Protocol.decode(buffer <> bytes)
    assert junk == ""
    messages = messages ++ decoded
    assert length(messages) <= count
    receive_requests(socket, count, messages, rest)
  end

  defp response(seq, command) do
    %{
      "seq" => 1,
      "type" => "response",
      "request_seq" => seq,
      "command" => command,
      "success" => true
    }
  end

  defp reply(socket, request, body) do
    message = response(request["seq"], request["command"]) |> Map.put("body", body)
    assert :ok = :gen_tcp.send(socket, Protocol.encode(message))
  end

  defp event(name, body \\ %{}) do
    Protocol.encode(%{"seq" => 1, "type" => "event", "event" => name, "body" => body})
  end
end
