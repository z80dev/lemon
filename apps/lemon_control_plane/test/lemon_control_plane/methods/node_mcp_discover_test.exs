defmodule LemonControlPlane.Methods.NodeMcpDiscoverTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{NodeInvokeResult, NodeMcpDiscover, Registry}
  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Schemas

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)

    if Process.whereis(LemonCore.NodeRegistry) == nil,
      do: start_supervised!(LemonCore.NodeRegistry)

    :ok
  end

  test "registered discovery is asynchronous and requires operator administrator scope" do
    assert Registry.lookup("node.mcp.discover") == {:ok, NodeMcpDiscover}
    assert Registry.dispatch_mode("node.mcp.discover") == :async
    assert NodeMcpDiscover.scopes() == [:admin]
    assert LemonControlPlane.Auth.Authorize.required_scopes("node.mcp.discover") == [:admin]

    for auth <- [
          %{role: :operator, scopes: [:read, :write]},
          %{role: :node, scopes: [:invoke, :event]},
          %{role: :node, scopes: [:admin]},
          %{role: :unsupported, scopes: [:admin]}
        ] do
      assert {:error, {:forbidden, _}} =
               Registry.dispatch("node.mcp.discover", params(), %{auth: auth, conn_pid: self()})
    end

    assert {:error, {:forbidden, _}} = NodeMcpDiscover.handle(params(), %{})
  end

  test "schema requires a node and server object; invalid server definitions stay secret-free" do
    assert Schemas.get("node.mcp.discover").required == %{"nodeId" => :string, "server" => :map}

    for invalid <- [%{}, %{"nodeId" => "node"}, %{"nodeId" => "node", "server" => []}] do
      assert {:error, _} = Schemas.validate("node.mcp.discover", invalid)
    end

    for server <- [
          nil,
          %{},
          Map.put(server(), "headers", "private-config"),
          Map.put(server(), "url", "file:///private-config"),
          Map.put(server(), "enabledTools", [123])
        ] do
      result = NodeMcpDiscover.handle(%{"nodeId" => "node", "server" => server}, ctx(self()))
      assert {:error, {:invalid_request, "Invalid discovery request"}} = result
      refute inspect(result) =~ "private-config"
    end

    assert {:error, {:invalid_request, _}} =
             NodeMcpDiscover.handle(%{"nodeId" => " ", "server" => server()}, ctx(self()))

    assert {:error, {:invalid_request, _}} =
             NodeMcpDiscover.handle(
               %{"nodeId" => String.duplicate("x", 129), "server" => server()},
               ctx(self())
             )
  end

  test "forwards only to the selected node without connecting or resolving references locally" do
    parent = self()
    {target_id, target} = register_node(parent, :target)
    {other_id, other} = register_node(parent, :other)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    config = Map.put(server(), "url", "http://127.0.0.1:#{port}/mcp")

    request =
      Task.async(fn ->
        Registry.dispatch(
          "node.mcp.discover",
          %{"nodeId" => target_id, "server" => config},
          ctx(parent)
        )
      end)

    assert_receive {:target, {:node_event, "node.invoke.request", payload}}
    assert payload["nodeId"] == target_id
    assert payload["method"] == "node.mcp.discover"
    assert payload["args"] == %{"server" => config}
    refute_receive {:other, {:node_event, "node.invoke.request", _}}, 50
    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)

    assert {:error, {:forbidden, _}} =
             NodeInvokeResult.handle(
               %{"invokeId" => payload["invokeId"], "result" => discovery(config)},
               %{auth: %{role: :node, client_id: other_id}, conn_pid: other}
             )

    assert {:ok, %{"received" => true}} =
             NodeInvokeResult.handle(
               %{"invokeId" => payload["invokeId"], "result" => discovery(config)},
               %{auth: %{role: :node, client_id: target_id}, conn_pid: target}
             )

    assert Task.await(request) == {:ok, discovery(config)}
    refute inspect(discovery(config)) =~ "DOES_NOT_EXIST_LOCALLY"
    refute inspect(discovery(config)) =~ "Authorization"
    assert NodeStore.get_invocation(payload["invokeId"]) == nil
  end

  test "durable discovery target cannot be hijacked by an online UUID-shaped name" do
    parent = self()

    {target_id, target} =
      register_node(parent, :target, "actual-target-#{System.unique_integer([:positive])}")

    {_shadow_id, _shadow} = register_node(parent, :shadow, target_id)

    request =
      Task.async(fn ->
        NodeMcpDiscover.handle(%{"nodeId" => target_id, "server" => server()}, ctx(parent))
      end)

    assert_receive {:target, {:node_event, "node.invoke.request", payload}}
    refute_receive {:shadow, {:node_event, "node.invoke.request", _}}, 50

    assert :ok =
             LemonCore.NodeRegistry.complete_session(
               target_id,
               target,
               0,
               payload["invokeId"],
               discovery(),
               nil
             )

    assert Task.await(request) == {:ok, discovery()}

    LemonCore.NodeRegistry.unregister(target_id, target)

    assert {:error, {:unavailable, _}} =
             NodeMcpDiscover.handle(%{"nodeId" => target_id, "server" => server()}, ctx(parent))

    refute_receive {:shadow, {:node_event, "node.invoke.request", _}}, 50
  end

  test "opening connection death cancels the targeted destination invocation" do
    {node_id, _node} = register_node(self(), :target)
    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    request =
      Task.async(fn ->
        NodeMcpDiscover.handle(%{"nodeId" => node_id, "server" => server()}, ctx(owner))
      end)

    assert_receive {:target, {:node_event, "node.invoke.request", payload}}
    invoke_id = payload["invokeId"]
    Process.exit(owner, :kill)
    assert_receive {:target, {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}}
    assert {:error, {:unavailable, _}} = Task.await(request)
  end

  test "handler cancellation removes invocation and cancels destination work" do
    {node_id, _node} = register_node(self(), :target)
    owner = self()

    handler =
      spawn(fn ->
        NodeMcpDiscover.handle(%{"nodeId" => node_id, "server" => server()}, ctx(owner))
      end)

    assert_receive {:target, {:node_event, "node.invoke.request", payload}}
    invoke_id = payload["invokeId"]
    Process.exit(handler, :kill)
    assert_receive {:target, {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}}
  end

  test "destination failures return bounded errors without secret names or config" do
    {node_id, node} = register_node(self(), :target)
    owner = self()

    request =
      Task.async(fn ->
        NodeMcpDiscover.handle(%{"nodeId" => node_id, "server" => server()}, ctx(owner))
      end)

    assert_receive {:target, {:node_event, "node.invoke.request", payload}}

    assert :ok =
             LemonCore.NodeRegistry.complete_session(
               node_id,
               node,
               0,
               payload["invokeId"],
               nil,
               "secret_resolution_failed"
             )

    assert {:error, {:unavailable, _, details}} = Task.await(request)
    refute inspect(details) =~ "DOES_NOT_EXIST_LOCALLY"
    refute inspect(details) =~ "Authorization"
  end

  defp register_node(parent, label, name \\ nil) do
    id = "discovery-#{label}-#{System.unique_integer([:positive])}"
    name = name || id
    pid = spawn(fn -> forward(parent, label) end)

    assert :ok =
             NodeStore.put_node(id, %{
               id: id,
               name: name,
               type: "coding_agent",
               capabilities: %{"node.mcp.discover" => true},
               status: :offline
             })

    assert :ok = LemonCore.NodeRegistry.register(id, name, pid)

    on_exit(fn ->
      LemonCore.NodeRegistry.unregister(id, pid)
      LemonCore.Store.delete(:nodes_registry, id)
      LemonCore.Store.delete(:nodes_by_name, name)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {id, pid}
  end

  defp forward(parent, label) do
    receive do
      message ->
        send(parent, {label, message})
        forward(parent, label)
    end
  end

  defp ctx(owner), do: %{auth: %{role: :operator, scopes: [:admin]}, conn_pid: owner}
  defp params, do: %{"nodeId" => "node", "server" => server()}

  defp server do
    %{
      "name" => "example",
      "url" => "https://example.com/mcp",
      "headers" => %{"Authorization" => "Bearer ${LEMON_SECRET:DOES_NOT_EXIST_LOCALLY}"},
      "enabledTools" => ["search.raw"]
    }
  end

  defp discovery(config \\ server()) do
    %{
      "connected" => true,
      "server" => %{"name" => "example", "status" => "connected"},
      "tools" => [
        %{
          "name" => "search.raw",
          "executionName" =>
            LemonSkills.McpSource.execution_name(config["name"], config["url"], "search.raw"),
          "description" => "Search",
          "inputSchema" => %{"type" => "object"},
          "readOnly" => false
        }
      ],
      "count" => 1,
      "truncated" => false
    }
  end
end
