defmodule LemonControlPlane.Methods.NodeProcessTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.{NodeIO, NodeStore}
  alias LemonControlPlane.Methods.{NodeInvoke, NodeProcessSupport, Registry}
  alias LemonControlPlane.Protocol.Schemas
  alias LemonCore.{NodeRegistry, Store}

  @receipt_fields ~w(processId nodeId state exitCode stdoutBase64 stderrBase64 outputTruncated)

  setup do
    node_id = LemonCore.Id.uuid()
    owner = self()
    metadata = %{capabilities: Map.new(~w(run get cancel), fn operation ->
      {"node.process." <> operation, %{"version" => 1}}
    end)}
    NodeStore.put_node(node_id, %{id: node_id, name: node_id})
    assert :ok = NodeRegistry.register_session(node_id, node_id, owner, 7, metadata)
    on_exit(fn ->
      NodeRegistry.unregister(node_id, owner)
      Store.delete(:nodes_registry, node_id)
    end)
    %{node_id: node_id, owner: owner, metadata: metadata,
      rpc: %{auth: %{role: :operator, scopes: [:admin]}, conn_pid: owner}}
  end

  test "canonical methods are registered, asynchronous and admin-only, including read-only get", ctx do
    for operation <- ~w(run get cancel) do
      method = "node.process." <> operation
      assert {:ok, module} = Registry.lookup(method)
      assert module.scopes() == [:admin]
      assert Registry.dispatch_mode(method) == :async
      params = if operation == "run", do: run(ctx), else: identity(ctx)
      for auth <- [%{role: :operator, scopes: [:read, :write]}, %{role: :node, scopes: [:invoke]}] do
        assert {:error, {:forbidden, _}} = Registry.dispatch(method, params, %{auth: auth, conn_pid: ctx.owner})
      end
    end
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "every run parameter and both lookup parameters are required by schema", ctx do
    for key <- Map.keys(run(ctx)) do
      assert {:error, _} = Schemas.validate("node.process.run", Map.delete(run(ctx), key))
      assert {:error, {:invalid_request, _}} = Registry.dispatch("node.process.run", Map.delete(run(ctx), key), ctx.rpc)
    end
    for method <- ~w(node.process.get node.process.cancel), key <- ~w(nodeId processId) do
      assert {:error, _} = Schemas.validate(method, Map.delete(identity(ctx), key))
    end
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "literal Unicode, spaces, quotes, empty later args and binary stdin survive exact dispatch", ctx do
    params = run(ctx) |> Map.merge(%{"argv" => ["executable", "雪 space 'quoted' $HOME ;", ""],
      "stdinBase64" => Base.encode64(<<0, 255, 10>>), "timeoutMs" => 1_800_000})
    task = dispatch(ctx, "node.process.run", params)
    args = Map.delete(params, "nodeId")
    node_id = ctx.node_id
    assert_receive {:node_event, "node.invoke.request", %{"nodeId" => ^node_id,
      "nodeGeneration" => 7, "method" => "node.process.run", "args" => ^args,
      "timeoutMs" => 1_805_000, "invokeId" => invocation}}, 1_000
    state = :sys.get_state(NodeRegistry)
    assert state.invocations[invocation].node_pid == ctx.owner
    assert state.invocations[invocation].node_generation == 7
    assert Process.read_timer(state.invocations[invocation].timer_ref) > 1_804_000
    result = receipt(ctx, "completed", %{"exitCode" => 17,
      "stdoutBase64" => Base.encode64("actual stdout"), "stderrBase64" => Base.encode64("actual stderr"),
      "outputTruncated" => false})
    assert :ok = NodeRegistry.complete_session(ctx.node_id, ctx.owner, 7, invocation, result)
    assert {:ok, ^result} = Task.await(task)
  end

  test "exact byte and count limits admit their boundaries", ctx do
    params = run(ctx) |> Map.merge(%{"argv" => ["x", String.duplicate("é", 65_535), "x"],
      "cwd" => "/" <> String.duplicate("x", 4095), "processId" => String.duplicate("a", 128),
      "stdinBase64" => Base.encode64(:binary.copy(<<255>>, 1_048_576)), "maxOutputBytes" => 1_048_576})
    result = Map.put(receipt(ctx, "running"), "processId", params["processId"])
    assert {:ok, ^result} = deliver(ctx, "node.process.run", params, result)
    params = Map.put(run(ctx), "argv", ["x" | List.duplicate("", 127)])
    assert {:ok, _} = deliver(ctx, "node.process.run", params, receipt(ctx, "running"))
  end

  test "invalid IDs, UTF-8, NUL, bounds and malformed base64 are rejected before dispatch", ctx do
    invalid_fields = [
      {"processId", ""}, {"processId", String.duplicate("a", 129)}, {"processId", "é"},
      {"processId", "a/b"}, {"processId", "a\n"}, {"processId", <<0>>}, {"processId", <<255>>},
      {"nodeId", ""}, {"nodeId", <<255>>}, {"nodeId", "node\0"},
      {"cwd", ""}, {"cwd", <<255>>}, {"cwd", "path\0"}, {"cwd", "a/../b"},
      {"cwd", String.duplicate("x", 4097)}, {"argv", []}, {"argv", [""]},
      {"argv", ["x", <<255>>]}, {"argv", ["x", "a\0"]}, {"argv", ["x", 42]},
      {"argv", List.duplicate("x", 129)}, {"argv", [String.duplicate("x", 131_073)]},
      {"argv", ["x", String.duplicate("é", 65_536)]},
      {"stdinBase64", "%%%"}, {"stdinBase64", "_w=="}, {"stdinBase64", "YQ"},
      {"stdinBase64", Base.encode64(:binary.copy(<<0>>, 1_048_577))},
      {"timeoutMs", 999}, {"timeoutMs", 1_800_001}, {"timeoutMs", 1_000.0},
      {"maxOutputBytes", 0}, {"maxOutputBytes", 1_048_577}, {"maxOutputBytes", nil}
    ]
    for {key, value} <- invalid_fields do
      assert {:error, {:invalid_request, _}} = Registry.dispatch("node.process.run", Map.put(run(ctx), key, value), ctx.rpc)
    end
    for method <- ~w(node.process.get node.process.cancel), value <- ["", "../id", "é", String.duplicate("x", 129)] do
      assert {:error, {:invalid_request, _}} = Registry.dispatch(method, Map.put(identity(ctx), "processId", value), ctx.rpc)
    end
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "client admission options, environment, shell and PTY fields cannot be supplied", ctx do
    for method <- ~w(node.process.run node.process.get node.process.cancel) do
      params = if method == "node.process.run", do: run(ctx), else: identity(ctx)
      for field <- ~w(opts expected_pid expected_generation nodeGeneration required_process_execution timeout_ms env command tty shell) do
        assert {:error, {:invalid_request, _}} = Registry.dispatch(method, Map.put(params, field, "tampering"), ctx.rpc)
      end
      assert {:error, {:forbidden, _}} = NodeInvoke.handle(%{"nodeId" => ctx.node_id,
        "method" => method, "args" => Map.delete(params, "nodeId")}, ctx.rpc)
    end
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "actual target capability version and every process operation are required before delivery", ctx do
    for capabilities <- [%{}, %{"node.process.run" => %{"version" => 1}},
      Map.new(~w(run get cancel), &{"node.process." <> &1, %{"version" => 2}})] do
      assert :ok = NodeRegistry.register_session(ctx.node_id, ctx.node_id, ctx.owner, 7,
        %{capabilities: capabilities})
      for method <- ~w(node.process.run node.process.get node.process.cancel) do
        params = if method == "node.process.run", do: run(ctx), else: identity(ctx)
        assert {:error, {:unavailable, _, %{"preDispatch" => true}}} = Registry.dispatch(method, params, ctx.rpc)
      end
    end
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "actual resolved PID and generation pin reject replacement without dispatch", ctx do
    assert {:ok, opts} = NodeProcessSupport.dispatch_opts("node.process.run", run(ctx))
    assert opts[:expected_pid] == ctx.owner
    assert opts[:expected_generation] == 7
    assert opts[:required_process_execution] == 1
    assert opts[:timeout_ms] == 6_000
    assert :ok = NodeRegistry.register_session(ctx.node_id, ctx.node_id, ctx.owner, 8, ctx.metadata)
    assert {:error, {:conflict, _, %{"preDispatch" => true}}} =
      NodeIO.invoke(ctx.node_id, "node.process.run", Map.delete(run(ctx), "nodeId"), ctx.rpc, opts)
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "offline durable ID cannot fall back to another node whose name matches it", ctx do
    attacker_id = LemonCore.Id.uuid()
    assert :ok = NodeRegistry.unregister(ctx.node_id, ctx.owner)
    assert {:error, :not_found} = NodeRegistry.resolve_id(ctx.node_id)
    attacker = spawn(fn -> receive do message -> send(ctx.owner, {:attacker, message}) end end)
    assert :ok = NodeRegistry.register_session(attacker_id, ctx.node_id, attacker, 7, ctx.metadata)
    on_exit(fn -> NodeRegistry.unregister(attacker_id, attacker); Process.exit(attacker, :kill) end)
    assert {:error, :not_found} = NodeRegistry.resolve_id(ctx.node_id)
    for method <- ~w(node.process.run node.process.get node.process.cancel) do
      params = if method == "node.process.run", do: run(ctx), else: identity(ctx)
      assert {:error, {:unavailable, _, %{"preDispatch" => true}}} = Registry.dispatch(method, params, ctx.rpc)
    end
    refute_receive {:attacker, _}
  end

  test "get is strictly a lookup and preserves unavailable outputs and original receipt", ctx do
    for state <- ~w(running outcome_unknown not_found completed cancelled) do
      changes = if state == "completed", do: %{"exitCode" => 0}, else: %{}
      result = receipt(ctx, state, changes)
      assert {:ok, ^result} = deliver(ctx, "node.process.get", identity(ctx), Map.put(result, "privateFingerprint", "private"))
      assert Enum.sort(Map.keys(result)) == Enum.sort(@receipt_fields)
    end
    result = receipt(ctx, "cancelled")
    assert {:ok, ^result} = deliver(ctx, "node.process.cancel", identity(ctx), result)
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "only actual captured zero bytes become empty outputs; malformed receipts fail closed", ctx do
    empty = receipt(ctx, "completed", %{"exitCode" => 0, "stdoutBase64" => "", "stderrBase64" => "", "outputTruncated" => false})
    assert {:ok, ^empty} = deliver(ctx, "node.process.run", run(ctx), empty)
    for result <- [Map.delete(empty, "stdoutBase64"), Map.put(empty, "exitCode", "0"),
      Map.put(empty, "exitCode", nil),
      Map.put(empty, "nodeId", "wrong-node"), Map.put(empty, "processId", "wrong-process"),
      Map.put(empty, "state", "not_found"), Map.put(empty, "stdoutBase64", "!"),
      receipt(ctx, "running", %{"stdoutBase64" => "", "stderrBase64" => "", "outputTruncated" => false}),
      receipt(ctx, "cancelled", %{"outputTruncated" => false}),
      Map.put(empty, "stdoutBase64", Base.encode64("xx"))] do
      assert {:error, {:unavailable, _, %{"reason" => "invalid_process_receipt", "retrySafe" => false}}} =
        deliver(ctx, "node.process.run", Map.put(run(ctx), "maxOutputBytes", 1), result)
    end
  end

  test "post-dispatch broker uncertainty is an error, never fabricated execution or absence", ctx do
    for method <- ~w(node.process.run node.process.get node.process.cancel) do
      params = if method == "node.process.run", do: run(ctx), else: identity(ctx)
      task = dispatch(ctx, method, params)
      assert_receive {:node_event, "node.invoke.request", %{"invokeId" => invocation}}, 1_000
      send(NodeRegistry, {:invoke_timeout, invocation})
      assert {:error, {:unavailable, _, %{"preDispatch" => false, "retrySafe" => false}}} = Task.await(task)
      assert_receive {:node_event, "node.invoke.cancel", _}, 1_000
    end
    refute_receive {:node_event, "node.invoke.request", _}
  end

  defp identity(ctx), do: %{"nodeId" => ctx.node_id, "processId" => "process:fixed-1"}
  defp run(ctx), do: Map.merge(identity(ctx), %{"cwd" => ".", "argv" => ["literal-executable"],
    "stdinBase64" => "", "timeoutMs" => 1_000, "maxOutputBytes" => 128})

  defp receipt(ctx, state, changes \\ %{}) do
    Map.merge(%{"processId" => "process:fixed-1", "nodeId" => ctx.node_id, "state" => state,
      "exitCode" => nil, "stdoutBase64" => nil, "stderrBase64" => nil, "outputTruncated" => true}, changes)
  end

  defp dispatch(ctx, method, params), do: Task.async(fn -> Registry.dispatch(method, params, ctx.rpc) end)

  defp deliver(ctx, method, params, result) do
    task = dispatch(ctx, method, params)
    args = Map.delete(params, "nodeId")
    timeout = if method == "node.process.run", do: params["timeoutMs"] + 5_000, else: 30_000
    assert_receive {:node_event, "node.invoke.request", %{"method" => ^method, "args" => ^args,
      "nodeGeneration" => 7, "timeoutMs" => ^timeout, "invokeId" => invocation}}, 1_000
    assert :ok = NodeRegistry.complete_session(ctx.node_id, ctx.owner, 7, invocation, result)
    Task.await(task)
  end
end
