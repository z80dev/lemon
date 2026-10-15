defmodule LemonControlPlane.Methods.NodeInvokeEventTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.{Authorize, TokenStore}
  alias LemonControlPlane.Methods.{NodeInvokeEvent, Registry}
  alias LemonControlPlane.Protocol.Schemas
  alias LemonCore.NodeRegistry

  setup do
    node_id = unique("event-node")
    connection_pid = self()
    assert :ok = NodeRegistry.register_session(node_id, node_id, connection_pid, 0)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

    on_exit(fn ->
      NodeRegistry.unregister(node_id, connection_pid)
      TokenStore.revoke_identity("node", node_id)
    end)

    ctx = %{
      auth: %{role: :node, client_id: node_id, scopes: [:invoke, :event]},
      conn_pid: connection_pid
    }

    params = %{
      "invokeId" => invoke_id,
      "seq" => 1,
      "event" => %{"type" => "delta", "text" => "live"}
    }

    {:ok, node_id: node_id, invoke_id: invoke_id, ctx: ctx, params: params}
  end

  test "registers an inline node-only method with required parameter schema", %{
    ctx: ctx,
    params: params
  } do
    assert {:ok, NodeInvokeEvent} = Registry.lookup("node.invoke.event")
    assert "node.invoke.event" in Registry.list_methods()
    assert Registry.dispatch_mode("node.invoke.event") == :inline
    assert Authorize.node_only_method?("node.invoke.event")
    assert Authorize.required_scopes("node.invoke.event") == [:invoke, :event]
    assert NodeInvokeEvent.scopes() == [:invoke, :event]

    assert Schemas.get("node.invoke.event") == %{
             required: %{"invokeId" => :string, "seq" => :integer, "event" => :map}
           }

    for field <- ["invokeId", "seq", "event"] do
      assert {:error, message} = Schemas.validate("node.invoke.event", Map.delete(params, field))
      assert message =~ field
    end

    for {field, value} <- [{"invokeId", 1}, {"seq", "1"}, {"event", []}] do
      assert {:error, _message} =
               Schemas.validate("node.invoke.event", Map.put(params, field, value))
    end

    assert {:ok, %{"received" => true, "duplicate" => false}} =
             Registry.dispatch("node.invoke.event", params, ctx)
  end

  test "accepts and deduplicates events without duplicate recipient delivery", %{
    ctx: ctx,
    params: params,
    invoke_id: invoke_id
  } do
    event = params["event"]

    assert {:ok,
            %{"invokeId" => ^invoke_id, "seq" => 1, "received" => true, "duplicate" => false}} =
             NodeInvokeEvent.handle(params, ctx)

    assert_receive {:lemon_node_event, ^invoke_id, 1, ^event}

    assert {:ok, %{"invokeId" => ^invoke_id, "seq" => 1, "received" => true, "duplicate" => true}} =
             NodeInvokeEvent.handle(params, ctx)

    refute_receive {:lemon_node_event, _, _, _}

    assert {:ok, %{"seq" => 2, "duplicate" => false}} =
             NodeInvokeEvent.handle(%{params | "seq" => 2}, ctx)

    assert_receive {:lemon_node_event, ^invoke_id, 2, ^event}
  end

  test "requires authenticated node role identity and connection", %{ctx: ctx, params: params} do
    operator = %{ctx | auth: %{role: :operator, scopes: [:admin, :invoke, :event]}}

    assert {:error, {:forbidden, "This method requires node role"}} =
             NodeInvokeEvent.handle(params, operator)

    assert {:error, {:forbidden, _message}} =
             Registry.dispatch("node.invoke.event", params, operator)

    no_identity = %{ctx | auth: Map.delete(ctx.auth, :client_id)}

    assert {:error, {:forbidden, "Authenticated node identity is required"}} =
             NodeInvokeEvent.handle(params, no_identity)

    assert {:error, {:forbidden, "Authenticated node connection is required"}} =
             NodeInvokeEvent.handle(params, Map.delete(ctx, :conn_pid))

    assert {:error, {:forbidden, _message}} =
             Registry.dispatch("node.invoke.event", params, %{
               ctx
               | auth: %{ctx.auth | scopes: []}
             })

    refute_receive {:lemon_node_event, _, _, _}
  end

  test "rejects malformed params without delivering an event", %{ctx: ctx, params: params} do
    for invoke_id <- [nil, "", "  ", 123] do
      assert {:error, {:invalid_request, "invokeId must be a non-empty string"}} =
               NodeInvokeEvent.handle(%{params | "invokeId" => invoke_id}, ctx)
    end

    for seq <- [nil, 0, -1, "1", 1.5] do
      assert {:error, {:invalid_request, "seq must be a positive integer"}} =
               NodeInvokeEvent.handle(%{params | "seq" => seq}, ctx)
    end

    for event <- [nil, [], "delta"] do
      assert {:error, {:invalid_request, "event must be an object"}} =
               NodeInvokeEvent.handle(%{params | "event" => event}, ctx)
    end

    assert {:error, {:invalid_request, "event type is not allowed"}} =
             NodeInvokeEvent.handle(%{params | "event" => %{"type" => "completed"}}, ctx)

    refute_receive {:lemon_node_event, _, _, _}
  end

  test "wrong node and stale connection cannot deliver or deduplicate another session", %{
    ctx: ctx,
    params: params
  } do
    wrong = %{ctx | auth: %{ctx.auth | client_id: unique("wrong-node")}}

    assert {:error, {:forbidden, "Invocation belongs to a different node"}} =
             NodeInvokeEvent.handle(params, wrong)

    other = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(other, :kill) end)
    stale = %{ctx | conn_pid: other}

    assert {:error, {:forbidden, "Invocation belongs to a superseded node session"}} =
             NodeInvokeEvent.handle(params, stale)

    assert {:ok, %{"duplicate" => false}} = NodeInvokeEvent.handle(params, ctx)
    assert {:error, {:forbidden, _message}} = NodeInvokeEvent.handle(params, stale)
  end

  test "rejects a superseded token generation before forwarding", %{
    node_id: node_id,
    ctx: ctx,
    params: params,
    invoke_id: invoke_id
  } do
    identity = %{"type" => "node", "nodeId" => node_id}

    assert {:ok, old} =
             TokenStore.replace_node_session(unique("event-token"), identity, ttl_ms: 60_000)

    generation = old.identity["sessionGeneration"]
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), generation)
    assert_receive {:lemon_node_result, ^invoke_id, {:error, {:node_disconnected, :reconnected}}}
    assert {:ok, new_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    params = %{params | "invokeId" => new_id}
    old_ctx = %{ctx | auth: Map.put(ctx.auth, :identity, old.identity)}

    assert {:ok, current} =
             TokenStore.replace_node_session(unique("event-token"), identity, ttl_ms: 60_000)

    assert current.identity["sessionGeneration"] == generation + 1

    assert {:error, {:forbidden, "Node session has been superseded"}} =
             NodeInvokeEvent.handle(params, old_ctx)

    assert {:error, {:forbidden, "Node session has been superseded"}} =
             NodeInvokeEvent.handle(params, %{
               ctx
               | auth: Map.put(ctx.auth, :identity, %{"sessionGeneration" => "bad"})
             })

    refute_receive {:lemon_node_event, _, _, _}
  end

  test "accepts a current nonzero generation using string-keyed identity", %{
    node_id: node_id,
    ctx: ctx,
    params: params
  } do
    assert {:ok, token} =
             TokenStore.replace_node_session(
               unique("event-token"),
               %{"type" => "node", "nodeId" => node_id}, ttl_ms: 60_000)

    generation = token.identity["sessionGeneration"]
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), generation)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    auth = %{"role" => :node, "client_id" => node_id, "identity" => token.identity}

    assert {:ok, %{"duplicate" => false}} =
             NodeInvokeEvent.handle(%{params | "invokeId" => invoke_id}, %{ctx | auth: auth})

    assert_receive {:lemon_node_event, ^invoke_id, 1, _event}
  end

  test "sequence gaps are conflicts and do not consume the missing sequence", %{
    ctx: ctx,
    params: params
  } do
    assert {:error, {:conflict, _message}} = NodeInvokeEvent.handle(%{params | "seq" => 2}, ctx)
    refute_receive {:lemon_node_event, _, _, _}
    assert {:ok, %{"duplicate" => false}} = NodeInvokeEvent.handle(params, ctx)

    assert {:ok, %{"seq" => 2, "duplicate" => false}} =
             NodeInvokeEvent.handle(%{params | "seq" => 2}, ctx)
  end

  test "payload policy errors expose bounded codes, not event contents", %{
    ctx: ctx,
    params: params
  } do
    secret = "private-event-text"
    deep = Enum.reduce(1..33, nil, fn _, acc -> [acc] end)
    wide = List.duplicate(nil, LemonCore.JSONPayload.default_max_items())

    cases = [
      {%{"type" => "delta", "text" => String.duplicate(secret, 5_000)}, :max_bytes},
      {%{"type" => "action", "data" => deep}, :max_depth},
      {%{"type" => "action", "data" => wide}, :max_items},
      {%{"type" => "action", "data" => self()}, :not_json_safe}
    ]

    for {event, kind} <- cases do
      assert {:error, {:invalid_request, "event violates JSON payload policy", ^kind}} =
               result =
               NodeInvokeEvent.handle(%{params | "event" => event}, ctx)

      refute inspect(result) =~ secret
      assert byte_size(inspect(result)) < 256
    end

    refute_receive {:lemon_node_event, _, _, _}
    assert {:ok, %{"duplicate" => false}} = NodeInvokeEvent.handle(params, ctx)
  end

  test "only active coding-agent runs may stream, with no durable fallback", %{
    node_id: node_id,
    ctx: ctx,
    params: params,
    invoke_id: invoke_id
  } do
    assert {:ok, other_id} = NodeRegistry.invoke(node_id, "work.run", %{})

    assert {:error, {:invalid_request, "Only coding_agent.run invocations may stream events"}} =
             NodeInvokeEvent.handle(%{params | "invokeId" => other_id}, ctx)

    assert :ok = NodeRegistry.complete_session(node_id, self(), 0, invoke_id, %{})

    assert {:error, {:conflict, "Invocation is no longer pending"}} =
             NodeInvokeEvent.handle(params, ctx)

    assert {:error, {:conflict, "Invocation is no longer pending"}} =
             NodeInvokeEvent.handle(%{params | "invokeId" => unique("missing")}, ctx)

    refute_receive {:lemon_node_event, _, _, _}
  end

  test "disconnection rejects late events even after a new live connection registers", %{
    node_id: node_id,
    ctx: ctx,
    params: params,
    invoke_id: invoke_id
  } do
    assert :ok = NodeRegistry.unregister(node_id, self())
    assert_receive {:lemon_node_result, ^invoke_id, {:error, {:node_disconnected, :disconnected}}}
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 0)

    assert {:error, {:conflict, "Invocation is no longer pending"}} =
             NodeInvokeEvent.handle(params, ctx)

    refute_receive {:lemon_node_event, _, _, _}
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
