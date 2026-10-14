defmodule LemonControlPlane.Methods.NodeSecretProofsTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.{NodeIO, NodeSecretProofs, NodeStore}
  alias LemonControlPlane.Methods.{NodeInvoke, NodeSecretsSet}
  alias LemonCore.{NodeRegistry, Store}

  setup do
    node_id = LemonCore.Id.uuid()
    owner = self()
    metadata = %{capabilities: %{"coding_agent.run" => %{"version" => 1,
      "nativePrivacyContext" => %{"version" => 1}}}}
    NodeStore.put_node(node_id, %{id: node_id, name: node_id})
    assert :ok = NodeRegistry.register_session(node_id, node_id, owner, 1, metadata)
    on_exit(fn ->
      NodeRegistry.unregister(node_id, owner)
      Store.delete(:nodes_registry, node_id)
    end)
    {:ok, node_id: node_id, owner: owner, metadata: metadata}
  end

  defp proof(run_id), do: %{"name" => "lemon_bot/invocations/" <> run_id,
    "operationId" => run_id, "value" => "private-proof-token"}

  test "strict absent root captures exact live PID/generation and public setter dispatches with that admission", ctx do
    run_id = LemonCore.Id.uuid()
    args = proof(run_id)
    assert {:ok, opts} = NodeSecretProofs.dispatch_opts(ctx.node_id, args)
    assert opts == [expected_pid: ctx.owner, expected_generation: 1, required_native_privacy_context: 1]
    task = Task.async(fn -> NodeSecretsSet.handle(Map.put(args, "nodeId", ctx.node_id), %{conn_pid: ctx.owner}) end)
    assert_receive {:node_event, "node.invoke.request", %{"method" => "node.secrets.set",
      "nodeId" => node_id, "invokeId" => invocation, "args" => ^args}}, 1_000
    assert node_id == ctx.node_id
    result = %{"name" => args["name"], "set" => true, "operationId" => run_id,
      "status" => "applied", "currentBindingMatches" => true}
    assert :ok = NodeRegistry.complete_session(ctx.node_id, ctx.owner, 1, invocation, result)
    assert {:ok, ^result} = Task.await(task)
  end

  test "same PID credential generation replacement cannot receive the previously inspected root proof", ctx do
    args = proof(LemonCore.Id.uuid())
    assert {:ok, opts} = NodeSecretProofs.dispatch_opts(ctx.node_id, args)
    assert :ok = NodeRegistry.register_session(ctx.node_id, ctx.node_id, ctx.owner, 2, ctx.metadata)
    assert {:error, {:conflict, _, %{"reason" => "node_connection_changed", "preDispatch" => true}}} =
      NodeIO.invoke(ctx.node_id, "node.secrets.set", args, %{conn_pid: ctx.owner}, opts)
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "existing terminal or malformed owner row never falls back to a new root", ctx do
    table = LemonRouter.RunOrchestrator.admission_table()
    for row <- [%{terminal: true, admission_status: :native_rejected}, %{}] do
      run_id = LemonCore.Id.uuid()
      assert :ok = Store.put(table, run_id, row)
      on_exit(fn -> Store.delete(table, run_id) end)
      assert {:error, {:conflict, _, %{"reason" => "private_proof_not_pending"}}} =
        NodeSecretProofs.dispatch_opts(ctx.node_id, proof(run_id))
    end
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "unsupported current worker refuses root proof before receiving its value", ctx do
    assert :ok = NodeRegistry.register_session(ctx.node_id, ctx.node_id, ctx.owner, 2,
      %{capabilities: %{"coding_agent.run" => %{"version" => 1}}})
    args = Map.put(proof(LemonCore.Id.uuid()), "nodeId", ctx.node_id)
    assert {:error, {:unavailable, _, %{"reason" => "native_privacy_context_unsupported", "preDispatch" => true}}} =
      NodeSecretsSet.handle(args, %{conn_pid: ctx.owner})
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "normalized proof names require exact fixed operation ID and raw invoke cannot bypass wrapper", ctx do
    run_id = LemonCore.Id.uuid()
    args = proof(run_id) |> Map.put("name", "  lemon_bot/invocations/" <> run_id <> "  ")
    for wrong <- [nil, "different"] do
      params = args |> Map.put("operationId", wrong) |> Map.put("nodeId", ctx.node_id)
      assert {:error, {:invalid_request, _}} = NodeSecretsSet.handle(params, %{})
    end
    assert {:error, {:forbidden, _}} = NodeInvoke.handle(%{"nodeId" => ctx.node_id,
      "method" => "node.secrets.set", "args" => args}, %{})
    assert {:ok, []} = NodeSecretProofs.dispatch_opts(ctx.node_id, %{"name" => "ordinary", "value" => "value"})
    refute_receive {:node_event, "node.invoke.request", _}
  end
end
