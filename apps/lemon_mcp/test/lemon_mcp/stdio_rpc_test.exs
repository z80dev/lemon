defmodule LemonMCP.StdioRpcTest do
  use ExUnit.Case, async: true

  alias LemonCore.Rpc.Client, as: RpcClient
  alias LemonMCP.Client

  @fixture """
  const rl = require('readline').createInterface({input: process.stdin});
  const send = message => process.stdout.write(JSON.stringify(message) + '\\n');
  const notify = (method, params = {}) => send({jsonrpc: '2.0', method, params});
  console.error('fixture startup log on merged stderr');
  rl.on('line', line => {
    const m = JSON.parse(line);
    if (m.method === 'fixture/emit') send(m.params);
    else if (m.method === 'fixture/exit') process.exit(0);
    else if (m.method === 'initialize') {
      notify('fixture/initialize', m);
      if (m.params.clientInfo.name !== 'no-handshake') {
        send({jsonrpc: '2.0', id: m.id, result: {
          protocolVersion: '2024-11-05', capabilities: {tools: {}, resources: {}, prompts: {}},
          serverInfo: {name: 'rpc-fixture', version: '1'}
        }});
      }
    } else if (m.method === 'notifications/initialized') notify('fixture/ready');
    else if (m.method) notify('fixture/request', m);
    else notify('fixture/reply', m);
  });
  """

  test "core owns original callers and correlates out-of-order responses exactly once" do
    {client, port} = start_client()
    first = Task.async(fn -> Client.list_tools(client, :infinity) end)
    second = Task.async(fn -> Client.list_resources(client, :infinity) end)
    first_id = await_request("tools/list")
    second_id = await_request("resources/list")
    state = :sys.get_state(client)

    refute Map.has_key?(state, :pending_requests)
    refute Map.has_key?(state, :message_buffer)
    assert RpcClient.pending_count(state.rpc) == 2
    assert {:monitors, monitors} = Process.info(state.rpc, :monitors)
    assert {:process, first.pid} in monitors
    assert {:process, second.pid} in monitors

    emit(port, %{jsonrpc: "2.0", id: first_id, method: "unsupported/request"})

    assert_receive {:notification,
                    %{
                      method: "fixture/reply",
                      params: %{"id" => ^first_id, "error" => %{"code" => -32_601}}
                    }, _},
                   5_000

    assert RpcClient.pending_count(state.rpc) == 2

    respond(port, second_id, %{resources: [%{uri: "fixture://second"}]})
    assert {:ok, [%{"uri" => "fixture://second"}]} = Task.await(second)
    assert RpcClient.pending_count(state.rpc) == 1

    respond(port, second_id, %{resources: []})
    respond(port, "unknown", %{tools: []})
    respond(port, first_id, %{tools: [%{name: "first"}]})
    assert {:ok, [%{"name" => "first"}]} = Task.await(first)
    assert RpcClient.pending_count(state.rpc) == 0
    assert Client.state(client) == :ready
  end

  test "public call timeout is a core deadline and a late response cannot revive the call" do
    {client, port} = start_client(timeout_ms: 60_000)
    task = Task.async(fn -> Client.call_tool(client, "blocked", %{}, 0) end)
    id = await_request("tools/call")
    assert {:error, :timeout} = Task.await(task)
    rpc = :sys.get_state(client).rpc
    assert RpcClient.pending_count(rpc) == 0

    respond(port, id, %{content: [%{type: "text", text: "late"}]})
    next = Task.async(fn -> Client.list_tools(client) end)
    next_id = await_request("tools/list")
    respond(port, next_id, %{tools: []})
    assert {:ok, []} = Task.await(next)
    assert RpcClient.pending_count(rpc) == 0
  end

  test "caller death removes the core request and its monitor without a wrapper timer" do
    {client, _port} = start_client()
    rpc = :sys.get_state(client).rpc
    :erlang.trace(rpc, true, [:send])
    caller = spawn(fn -> Client.list_tools(client, :infinity) end)
    id = await_request("tools/list")
    assert RpcClient.pending_count(rpc) == 1

    Process.exit(caller, :kill)
    assert_receive {:trace, ^rpc, :send, {:rpc_finished, ^id, :caller_down}, ^client}, 5_000
    assert RpcClient.pending_count(rpc) == 0
    assert {:monitors, monitors} = Process.info(rpc, :monitors)
    refute {:process, caller} in monitors
  end

  test "peer exit fails every pending caller before stopping the wrapper" do
    {client, port} = start_client()
    state = :sys.get_state(client)
    monitor = Process.monitor(client)
    first = Task.async(fn -> Client.list_tools(client, :infinity) end)
    second = Task.async(fn -> Client.list_prompts(client, :infinity) end)
    await_request("tools/list")
    await_request("prompts/list")

    control(port, "fixture/exit")
    assert {:error, :connection_closed} = Task.await(first)
    assert {:error, :connection_closed} = Task.await(second)
    assert_receive {:DOWN, ^monitor, :process, ^client, {:transport_died, :normal}}, 5_000
    refute Process.alive?(state.rpc)
    refute Process.alive?(state.task_supervisor)
  end

  test "blocked sampling runs under the client supervisor without blocking responses or deadlines" do
    owner = self()

    handler = fn params ->
      send(owner, {:sampling, self(), params})

      receive do
        :release -> {:ok, %{role: "assistant", content: %{type: "text", text: "sampled"}}}
      end
    end

    {client, port} = start_client(sampling_handler: handler)
    assert_receive {:notification, %{method: "fixture/initialize", params: initialize}, _}
    assert initialize["params"]["capabilities"]["sampling"] == %{}

    emit(port, %{
      jsonrpc: "2.0",
      id: "sampling",
      method: "sampling/createMessage",
      params: %{maxTokens: 4}
    })

    assert_receive {:sampling, worker, %{"maxTokens" => 4}}, 5_000
    state = :sys.get_state(client)
    assert worker in Task.Supervisor.children(state.task_supervisor)
    assert worker != client
    assert worker != state.rpc

    tools = Task.async(fn -> Client.list_tools(client) end)
    id = await_request("tools/list")
    respond(port, id, %{tools: []})
    assert {:ok, []} = Task.await(tools)
    assert {:error, :timeout} = Client.call_tool(client, "deadline", %{}, 0)
    await_request("tools/call")

    emit(port, %{jsonrpc: "2.0", method: "notifications/tools/list_changed"})

    assert_receive {:notification, %{method: "notifications/tools/list_changed", params: %{}}, _},
                   5_000

    send(worker, :release)

    assert_receive {:notification,
                    %{
                      method: "fixture/reply",
                      params: %{"id" => "sampling", "result" => %{"role" => "assistant"}}
                    }, _},
                   5_000
  end

  test "close fails pending calls and stops supervised sampling, transport, and RPC processes" do
    owner = self()

    handler = fn _params ->
      send(owner, {:sampling_worker, self()})

      receive do
        :release -> {:ok, %{}}
      end
    end

    {client, port} = start_client(sampling_handler: handler)
    state = :sys.get_state(client)
    emit(port, %{jsonrpc: "2.0", id: "sampling", method: "sampling/createMessage"})
    assert_receive {:sampling_worker, worker}, 5_000
    task = Task.async(fn -> Client.list_tools(client, :infinity) end)
    await_request("tools/list")

    assert :ok = Client.close(client)
    assert {:error, :connection_closed} = Task.await(task)
    assert Client.state(client) == :disconnected
    assert {:error, {:not_ready, :disconnected}} = Client.list_tools(client)
    assert :ok = Client.close(client)

    for pid <- [worker, state.rpc, state.task_supervisor, state.transport] do
      refute Process.alive?(pid)
    end
  end

  test "sampling callback can make a nested client request without mailbox deadlock" do
    owner = self()

    handler = fn _params ->
      send(owner, {:sampling_worker, self()})

      receive do
        {:client, client} ->
          {:ok, tools} = Client.list_tools(client)

          {:ok,
           %{role: "assistant", model: "nested", content: %{type: "text", text: inspect(tools)}}}
      end
    end

    {client, port} = start_client(sampling_handler: handler)
    emit(port, %{jsonrpc: "2.0", id: "nested", method: "sampling/createMessage"})
    assert_receive {:sampling_worker, worker}, 5_000
    send(worker, {:client, client})
    id = await_request("tools/list")
    respond(port, id, %{tools: []})

    assert_receive {:notification,
                    %{
                      method: "fixture/reply",
                      params: %{"id" => "nested", "result" => %{"model" => "nested"}}
                    }, _},
                   5_000

    assert Client.state(client) == :ready
  end

  test "sampling exceptions return a redacted error and do not terminate the connection" do
    {client, port} = start_client(sampling_handler: fn _ -> raise "private handler contents" end)
    emit(port, %{jsonrpc: "2.0", id: 17, method: "sampling/createMessage", params: %{}})

    assert_receive {:notification,
                    %{method: "fixture/reply", params: %{"id" => 17, "error" => error}}, _},
                   5_000

    assert error["code"] == -32_603
    assert error["message"] == "Sampling handler failed"
    refute inspect(error) =~ "private handler contents"
    assert Client.state(client) == :ready
  end

  test "disabled sampling and unknown peer requests get protocol errors, not notifications" do
    {client, port} = start_client()
    assert_receive {:notification, %{method: "fixture/initialize", params: initialize}, _}
    refute Map.has_key?(initialize["params"]["capabilities"], "sampling")

    for {method, code} <- [{"sampling/createMessage", -1}, {"unsupported/request", -32_601}] do
      emit(port, %{jsonrpc: "2.0", id: method, method: method})

      assert_receive {:notification,
                      %{
                        method: "fixture/reply",
                        params: %{"id" => ^method, "error" => %{"code" => ^code}}
                      }, _},
                     5_000

      refute_receive {:notification, %{method: ^method}, _}, 0
    end

    assert Client.state(client) == :ready
  end

  test "preserves resource, prompt, tool-error, and RPC-error result shapes" do
    {client, port} = start_client()

    for {call, method, result, expected} <- [
          {fn -> Client.read_resource(client, "fixture://resource") end, "resources/read",
           %{contents: [%{uri: "fixture://resource", text: "ok"}]},
           {:ok, [%{"uri" => "fixture://resource", "text" => "ok"}]}},
          {fn -> Client.list_prompts(client) end, "prompts/list", %{prompts: [%{name: "brief"}]},
           {:ok, [%{"name" => "brief"}]}},
          {fn -> Client.get_prompt(client, "brief", %{"topic" => "beam"}) end, "prompts/get",
           %{description: "Brief", messages: [%{role: "user"}]},
           {:ok, %{description: "Brief", messages: [%{"role" => "user"}]}}},
          {fn -> Client.call_tool(client, "failure") end, "tools/call",
           %{content: [%{type: "text", text: "failed"}], isError: true},
           {:error, {:tool_error, [%{"type" => "text", "text" => "failed"}]}}}
        ] do
      task = Task.async(call)
      id = await_request(method)
      respond(port, id, result)
      assert Task.await(task) == expected
    end

    task = Task.async(fn -> Client.list_tools(client) end)
    id = await_request("tools/list")
    emit(port, %{jsonrpc: "2.0", id: id, error: %{code: -32_601, message: "unsupported"}})

    assert {:error, {:rpc_error, %LemonMCP.Protocol.JSONRPCError{code: -32_601}}} =
             Task.await(task)
  end

  test "initialize responses must match the handshake request ID" do
    state = %{state: :initializing, initialize_id: "expected", rpc: self()}

    response = %{
      "jsonrpc" => "2.0",
      "id" => "unexpected",
      "result" => %{"serverInfo" => %{"name" => "unrelated", "version" => "1"}}
    }

    assert {:noreply, ^state} = Client.handle_info({:rpc_message, response}, state)
  end

  test "an initialize error terminates the connection with the protocol error" do
    {client, port} = start_client(client_name: "no-handshake", await_ready: false)
    monitor = Process.monitor(client)

    assert_receive {:notification, %{method: "fixture/initialize", params: %{"id" => id}}, _},
                   5_000

    emit(port, %{jsonrpc: "2.0", id: id, error: %{code: -32_602, message: "bad initialization"}})

    assert_receive {:DOWN, ^monitor, :process, ^client,
                    {:init_failed, %LemonMCP.Protocol.JSONRPCError{code: -32_602}}},
                   5_000
  end

  test "core connect timeout closes a server that never answers initialize" do
    {client, _port} =
      start_client(client_name: "no-handshake", timeout_ms: 500, await_ready: false)

    state = :sys.get_state(client)
    monitor = Process.monitor(client)
    assert_receive {:DOWN, ^monitor, :process, ^client, {:rpc_died, :normal}}, 5_000

    for pid <- [state.rpc, state.task_supervisor, state.transport] do
      refute Process.alive?(pid)
    end
  end

  defp start_client(opts \\ []) do
    owner = self()
    {await_ready, opts} = Keyword.pop(opts, :await_ready, true)

    defaults = [
      command: System.find_executable("node"),
      args: ["-e", @fixture],
      timeout_ms: :infinity,
      notification_handler: fn notification ->
        send(owner, {:notification, notification, self()})
      end,
      port_open: fn spec, options ->
        port = Port.open(spec, options)
        send(owner, {:fixture_port, port})
        port
      end
    ]

    client =
      start_supervised!(
        Supervisor.child_spec({Client, Keyword.merge(defaults, opts)}, restart: :temporary)
      )

    assert_receive {:fixture_port, port}, 5_000

    if await_ready do
      assert_receive {:notification, %{method: "fixture/ready"}, _}, 5_000
      assert Client.state(client) == :ready
    end

    {client, port}
  end

  defp await_request(method) do
    assert_receive {:notification,
                    %{method: "fixture/request", params: %{"method" => ^method, "id" => id}}, _},
                   5_000

    id
  end

  defp respond(port, id, result), do: emit(port, %{jsonrpc: "2.0", id: id, result: result})
  defp emit(port, message), do: control(port, "fixture/emit", message)

  defp control(port, method, params \\ %{}) do
    true = Port.command(port, Jason.encode!(%{method: method, params: params}) <> "\n")
  end
end
