defmodule CodingAgent.ExecutionNode.WorkerProcessTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.{ProcessService, Worker}
  alias LemonCore.Store

  defmodule Socket do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def request(pid, method, params, tag, _timeout), do: GenServer.call(pid, {:request, method, params, tag})
    def stop(pid), do: GenServer.stop(pid, :normal)
    @impl true
    def init(opts) do
      test = opts[:test]
      send(test, {:socket, self()})
      {:ok, test}
    end
    @impl true
    def handle_call({:request, method, params, tag}, _from, test) do
      send(test, {:request, method, params, tag})
      {:reply, "request", test}
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    node = "process-worker-#{System.unique_integer([:positive])}"
    worker = start_supervised!({Worker, node_name: node, controller: "ws://localhost:4040/ws",
      token: "test-token", cwd: root, allowed_roots: [root], socket_module: Socket,
      socket_opts: [test: self()], notify_pid: self()})
    assert_receive {:socket, socket}
    send(worker, {:execution_node_socket, socket, {:connected,
      %{"auth" => %{"clientId" => node}, "policy" => %{"maxPayload" => 16_777_216}}}})
    assert_receive {:execution_node_worker, ^worker, {:status, :online, ^node}}
    on_exit(fn ->
      case Store.fetch_all(:node_process_receipts) do
        {:ok, receipts} ->
          for {{^node, _} = key, _} <- receipts, do: Store.delete(:node_process_receipts, key)
        _ -> :ok
      end
    end)
    python = System.find_executable("python3")
    assert is_binary(python)
    %{worker: worker, socket: socket, node: node, root: root, python: python,
      fixture: Path.expand("../../support/node_process_fixture.py", __DIR__)}
  end

  test "advertises implemented v1 methods without changing runtime feature keys" do
    capabilities = Worker.capabilities()
    for method <- ~w(node.process.run node.process.get node.process.cancel) do
      assert capabilities[method] == %{"version" => 1, "maxStdinBytes" => 1_048_576,
        "maxOutputBytes" => 1_048_576, "maxTimeoutMs" => 1_800_000, "maxArgvBytes" => 131_072}
    end
    assert capabilities["coding_agent.run"]["version"] == 1
    assert capabilities["node.shell.open"] == true
    assert capabilities["node.fs.read"] == true
    assert Enum.sort(Map.keys(Worker.runtime_features()["features"])) ==
      Enum.sort(~w(hostIO filesystemCAS deletePreviews encryptedSecrets ptyShell mcpDiscovery profileSync liveStreaming repairInvites nativeExecutionPolicy))
  end

  test "top-level authenticated generation is required; node identity is injected, not caller trusted", ctx do
    args = args(ctx, "literal", ["report", "雪 'quoted' \"double\""])
    dispatch(ctx, "missing-generation", "node.process.run", args, nil)
    assert {:error, "invalid_node_generation"} = result("missing-generation")
    dispatch(ctx, "mismatch", "node.process.run", Map.put(args, "nodeId", "other-node"), 11)
    assert {:error, "node_mismatch"} = result("mismatch")
    dispatch(ctx, "literal-invoke", "node.process.run", args, 11)
    assert {:ok, receipt} = result("literal-invoke")
    assert receipt["nodeId"] == ctx.node
    assert receipt["state"] == "completed"
    assert receipt["exitCode"] == 17
    report = receipt["stdoutBase64"] |> Base.decode64!() |> Jason.decode!()
    assert report["isatty"] == [false, false, false]
    assert report["argv"] == ["雪 'quoted' \"double\""]
  end

  test "async run allows simultaneous get and cancel and duplicate fixed ID never re-executes", ctx do
    ready = Path.join(ctx.root, "ready")
    args = args(ctx, "active", ["hold", ready])
    dispatch(ctx, "run", "node.process.run", args, 11)
    await_file(ready)
    dispatch(ctx, "get", "node.process.get", %{"processId" => "active"}, 11)
    assert {:ok, %{"state" => "running", "stdoutBase64" => nil, "stderrBase64" => nil}} = result("get")
    dispatch(ctx, "duplicate", "node.process.run", args, 11)
    assert {:ok, %{"state" => "running"}} = result("duplicate")
    dispatch(ctx, "cancel", "node.process.cancel", %{"processId" => "active"}, 11)
    assert {:ok, cancelled} = result("cancel")
    assert cancelled["state"] == "cancelled"
    assert is_integer(cancelled["exitCode"])
    assert {:ok, ^cancelled} = result("run")
  end

  test "original invocation cancellation rejects unrelated generations before terminating group", ctx do
    ready = Path.join(ctx.root, "ready")
    survived = Path.join(ctx.root, "survived")
    dispatch(ctx, "original", "node.process.run", args(ctx, "bound", ["tree", ready, survived]), 11)
    await_file(ready)
    for generation <- [nil, 12] do
      send(ctx.worker, {:execution_node_socket, ctx.socket, {:event, "node.invoke.cancel",
        %{"invokeId" => "original", "nodeId" => ctx.node, "nodeGeneration" => generation}}})
      # A later request is a mailbox barrier after the rejected cancel.
      dispatch(ctx, "get-#{inspect(generation)}", "node.process.get", %{"processId" => "bound"}, 11)
      assert {:ok, %{"state" => "running"}} = result("get-#{inspect(generation)}")
    end
    send(ctx.worker, {:execution_node_socket, ctx.socket, {:event, "node.invoke.cancel",
      %{"invokeId" => "original", "nodeId" => ctx.node, "nodeGeneration" => 11}}})
    dispatch(ctx, "final-get", "node.process.get", %{"processId" => "bound"}, 11)
    assert {:ok, %{"state" => "cancelled", "exitCode" => code}} = result("final-get")
    assert is_integer(code)
    Process.sleep(2_100)
    refute File.exists?(survived)
  end

  test "socket disconnect cancels true owner group before task cleanup", ctx do
    ready = Path.join(ctx.root, "ready")
    survived = Path.join(ctx.root, "survived")
    dispatch(ctx, "owner-run", "node.process.run", args(ctx, "owned", ["tree", ready, survived]), 11)
    await_file(ready)
    send(ctx.worker, {:execution_node_socket, ctx.socket, {:disconnected, :closed}})
    assert_receive {:execution_node_worker, worker, {:status, :reconnecting}}, 5_000
    assert worker == ctx.worker
    opts = [node_id: ctx.node, session_generation: 11, invoke_id: "lookup", owner: self()]
    assert {:ok, %{"state" => "cancelled", "exitCode" => code}} =
      ProcessService.handle("node.process.get", %{"nodeId" => ctx.node, "processId" => "owned"}, opts)
    assert is_integer(code)
    state = :sys.get_state(ctx.worker)
    assert state.process_tasks == %{}
    Process.sleep(2_100)
    refute File.exists?(survived)
  end

  test "missing cancellation admitted through Worker suppresses any later literal run", ctx do
    dispatch(ctx, "cancel-first", "node.process.cancel", %{"processId" => "tombstone"}, 11)
    assert {:ok, %{"state" => "cancelled", "exitCode" => nil, "stdoutBase64" => nil}} = result("cancel-first")
    marker = Path.join(ctx.root, "must-not-execute")
    dispatch(ctx, "late-run", "node.process.run", args(ctx, "tombstone", ["touch", marker]), 11)
    assert {:ok, %{"state" => "cancelled", "exitCode" => nil}} = result("late-run")
    refute File.exists?(marker)
  end

  defp args(ctx, id, extra), do: %{"processId" => id, "cwd" => ctx.root,
    "argv" => [ctx.python, ctx.fixture | extra], "stdinBase64" => "", "timeoutMs" => 10_000,
    "maxOutputBytes" => 1_048_576}
  defp dispatch(ctx, invoke_id, method, args, generation) do
    send(ctx.worker, {:execution_node_socket, ctx.socket, {:event, "node.invoke.request",
      %{"invokeId" => invoke_id, "nodeId" => ctx.node, "nodeGeneration" => generation,
        "method" => method, "args" => args}}})
  end
  defp result(id) do
    assert_receive {:request, "node.invoke.result", %{"invokeId" => ^id} = params, {:invoke_result, ^id}}, 5_000
    if Map.has_key?(params, "result"), do: {:ok, params["result"]}, else: {:error, params["error"]}
  end
  defp await_file(path, attempts \\ 200)
  defp await_file(path, 0), do: flunk("fixture did not become ready: #{path}")
  defp await_file(path, attempts) do
    if File.exists?(path), do: :ok, else: (Process.sleep(10); await_file(path, attempts - 1))
  end
end
