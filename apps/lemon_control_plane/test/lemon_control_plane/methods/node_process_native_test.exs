defmodule LemonControlPlane.Methods.NodeProcessNativeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias CodingAgent.ExecutionNode.ProcessService
  alias LemonControlPlane.{NodeStore, Methods.Registry}
  alias LemonCore.{NodeRegistry, Store}

  @moduletag :tmp_dir
  @store __MODULE__.Store
  @service __MODULE__.Service

  setup %{tmp_dir: root} do
    store = start_supervised!(Supervisor.child_spec({Store, name: @store,
      backend: LemonCore.Store.SqliteBackend,
      backend_opts: [path: Path.join(root, "process.sqlite3"), ephemeral_tables: []]}, id: @store))
    start_supervised!(Supervisor.child_spec({ProcessService, name: @service, store: store}, id: @service))
    node_id = LemonCore.Id.uuid()
    observer = self()
    destination = start_supervised!(%{id: :native_process_destination,
      start: {Task, :start_link, [fn -> destination_loop(node_id, root, observer) end]}, restart: :temporary})
    capabilities = Map.new(~w(run get cancel), &{"node.process." <> &1, %{"version" => 1}})
    NodeStore.put_node(node_id, %{id: node_id, name: node_id})
    assert :ok = NodeRegistry.register_session(node_id, node_id, destination, 11, %{capabilities: capabilities})
    on_exit(fn ->
      NodeRegistry.unregister(node_id, destination)
      Store.delete(:nodes_registry, node_id)
    end)
    %{node_id: node_id, root: root, store: store, destination: destination,
      rpc: %{auth: %{role: :operator, scopes: [:admin]}, conn_pid: observer}}
  end

  test "real CP registry dispatch executes literal native argv/stdin with no TTY, independent output and private projections", ctx do
    :ok = LemonCore.Bus.subscribe("nodes")
    sentinel = "private-process-credential-sentinel"
    script = "import os,sys; data=sys.stdin.buffer.read(); " <>
      "sys.stdout.buffer.write(data); sys.stdout.flush(); " <>
      "sys.stderr.write('|'.join(sys.argv[1:])+':'+','.join(str(int(os.isatty(fd))) for fd in (0,1,2))); sys.exit(19)"
    params = run(ctx, "literal:1", ["python3", "-c", script, "雪 with spaces 'quotes' $HOME ;", "", sentinel])
      |> Map.put("stdinBase64", Base.encode64(<<0, 255, 10>>))
    log = capture_log(fn ->
      assert {:ok, result} = Registry.dispatch("node.process.run", params, ctx.rpc)
      assert result == %{"processId" => "literal:1", "nodeId" => ctx.node_id,
        "state" => "completed", "exitCode" => 19, "stdoutBase64" => Base.encode64(<<0, 255, 10>>),
        "stderrBase64" => Base.encode64("雪 with spaces 'quotes' $HOME ;||" <> sentinel <> ":0,0,0"),
        "outputTruncated" => false}
      assert {:ok, ^result} = Registry.dispatch("node.process.get", identity(ctx, "literal:1"), ctx.rpc)
      assert {:ok, metadata} = Store.fetch(ctx.store, :node_process_receipts, {ctx.node_id, "literal:1"})
      refute Map.has_key?(metadata, :argv)
      refute Map.has_key?(metadata, :stdin)
      refute Map.has_key?(metadata, :stdout)
      refute Map.has_key?(metadata, :stderr)
      refute inspect(metadata) =~ sentinel
      refute_receive %LemonCore.Event{payload: %{result: ^result}}
      refute_receive %LemonCore.Event{payload: %{args: _}}
      refute_receive %LemonCore.Event{payload: %{"stdoutBase64" => _}}
      refute_receive {:event, "node.process.output", _}
    end)
    refute log =~ sentinel
    refute log =~ params["stdinBase64"]
    assert_receive {:native_dispatch, "node.process.run", %{"nodeGeneration" => 11, "timeoutMs" => 15_000}}, 1_000
    assert_receive {:native_dispatch, "node.process.get", %{"nodeGeneration" => 11, "timeoutMs" => 30_000}}, 1_000
  end

  test "strict absent get launches nothing and durable cancel-before-run tombstone wins", ctx do
    id = "cancel:first"
    marker = Path.join(ctx.root, "must-not-execute")
    assert {:ok, absent} = Registry.dispatch("node.process.get", identity(ctx, id), ctx.rpc)
    assert absent == receipt(ctx, id, "not_found")
    assert {:ok, cancelled} = Registry.dispatch("node.process.cancel", identity(ctx, id), ctx.rpc)
    assert cancelled == receipt(ctx, id, "cancelled")
    assert {:ok, %{state: "cancelled"}} = Store.fetch(ctx.store, :node_process_receipts, {ctx.node_id, id})
    params = run(ctx, id, ["python3", "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('started')", marker])
    assert {:ok, ^cancelled} = Registry.dispatch("node.process.run", params, ctx.rpc)
    assert {:ok, ^cancelled} = Registry.dispatch("node.process.get", identity(ctx, id), ctx.rpc)
    refute File.exists?(marker)
  end

  test "active cancellation races the awaited run through the same real owning receipt", ctx do
    id = "cancel:active"
    task = Task.async(fn -> Registry.dispatch("node.process.run",
      run(ctx, id, ["python3", "-c", "import time; time.sleep(30)"]), ctx.rpc) end)
    assert_receive {:native_dispatch, "node.process.run", _}, 1_000
    assert_running(ctx, id)
    assert {:ok, cancelled} = Registry.dispatch("node.process.cancel", identity(ctx, id), ctx.rpc)
    assert cancelled["state"] == "cancelled"
    assert {:ok, ^cancelled} = Task.await(task)
    assert {:ok, ^cancelled} = Registry.dispatch("node.process.get", identity(ctx, id), ctx.rpc)
  end

  test "controller timeout does not become absence or trigger redispatch; get reads the original owning receipt", ctx do
    id = "uncertain:1"
    task = Task.async(fn -> Registry.dispatch("node.process.run",
      run(ctx, id, ["python3", "-c", "import time; time.sleep(30)"]), ctx.rpc) end)
    assert_receive {:native_dispatch, "node.process.run", %{"invokeId" => invocation}}, 1_000
    # A strict running receipt proves the native owner admitted the intent before
    # the controller loses its response. Get itself cannot admit or restart it.
    assert_running(ctx, id)
    send(NodeRegistry, {:invoke_timeout, invocation})
    assert {:error, {:unavailable, _, %{"preDispatch" => false, "retrySafe" => false}}} = Task.await(task)
    assert_receive {:native_cancelled_invocation, ^invocation}, 5_000
    assert {:ok, result} = Registry.dispatch("node.process.get", identity(ctx, id), ctx.rpc)
    assert result["state"] in ["cancelled", "outcome_unknown"]
    refute result["state"] == "not_found"
    refute_receive {:native_dispatch, "node.process.run", _}
  end

  defp assert_running(ctx, id, attempts \\ 100)
  defp assert_running(_, _, 0), do: flunk("native admission did not become running")
  defp assert_running(ctx, id, attempts) do
    case Registry.dispatch("node.process.get", identity(ctx, id), ctx.rpc) do
      {:ok, %{"state" => "running"} = result} ->
        assert result == receipt(ctx, id, "running")
      {:ok, %{"state" => "not_found"}} ->
        Process.sleep(10)
        assert_running(ctx, id, attempts - 1)
      other -> flunk("unexpected native lookup: #{inspect(other)}")
    end
  end

  # This is a transport relay, not a substitute handler: the actual registry
  # seals destination/generation and the real owning service executes the Python
  # helper and persists through a real isolated SQLite Store.
  defp destination_loop(node_id, root, observer) do
    receive do
      {:node_event, "node.invoke.request", %{"nodeId" => ^node_id, "nodeGeneration" => generation,
        "invokeId" => invocation, "method" => method, "args" => args} = payload} ->
        send(observer, {:native_dispatch, method, Map.take(payload, ["invokeId", "nodeGeneration", "timeoutMs"])})
        owner = self()
        Task.start(fn ->
          result = ProcessService.handle(method, Map.put(args, "nodeId", node_id),
            server: @service, node_id: node_id, session_generation: generation,
            invoke_id: invocation, owner: owner, default_cwd: root, allowed_roots: [root])
          send(owner, {:native_result, generation, invocation, result})
        end)
        destination_loop(node_id, root, observer)

      {:native_result, generation, invocation, result} ->
        case result do
          {:ok, receipt} -> NodeRegistry.complete_session(node_id, self(), generation, invocation, receipt)
          {:error, reason} -> NodeRegistry.complete_session(node_id, self(), generation, invocation, nil, Atom.to_string(reason))
        end
        destination_loop(node_id, root, observer)

      {:node_event, "node.invoke.cancel", %{"invokeId" => invocation}} ->
        ProcessService.cancel_invocation(self(), invocation, @service)
        send(observer, {:native_cancelled_invocation, invocation})
        destination_loop(node_id, root, observer)
    end
  end

  defp identity(ctx, id), do: %{"nodeId" => ctx.node_id, "processId" => id}
  defp run(ctx, id, argv), do: Map.merge(identity(ctx, id), %{"cwd" => ctx.root, "argv" => argv,
    "stdinBase64" => "", "timeoutMs" => 10_000, "maxOutputBytes" => 1_048_576})
  defp receipt(ctx, id, state), do: %{"processId" => id, "nodeId" => ctx.node_id, "state" => state,
    "exitCode" => nil, "stdoutBase64" => nil, "stderrBase64" => nil, "outputTruncated" => true}
end
