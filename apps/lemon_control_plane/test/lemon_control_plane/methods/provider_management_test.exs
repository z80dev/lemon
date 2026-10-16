defmodule LemonControlPlane.Methods.ProviderManagementTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.{Registry, NodeInvoke, NodeProvidersManagementApiKeySet}
  alias LemonControlPlane.NodeStore
  alias LemonCore.NodeRegistry

  @operations ~w(list api_key.set disconnect default.set)
  test "controller target identity is durable and distinct from named destinations" do
    assert {:ok, controller} = LemonCore.ProviderManagement.target()
    assert {:ok, again} = LemonCore.ProviderManagement.target()
    assert again.id == controller.id
    assert controller.nodeId == nil
    assert controller.id =~ ~r/^[A-Za-z0-9_.:-]{1,256}$/
    assert {:ok, destination} = LemonCore.ProviderManagement.target("offline-node")
    refute destination.id == controller.id
  end

  test "mutating dispatch exceptions are uncertain and never retry safe" do
    params = %{
      "nodeId" => "offline-node",
      "targetId" => "node:offline-node",
      "providerId" => "openai",
      "value" => "OFFLINE_MOCK_SECRET"
    }

    # Explicit malformed offline transport seam forces a monitor exception;
    # no credential service or network is reached.
    assert {:error, {:unavailable, _, details}} =
             NodeProvidersManagementApiKeySet.handle(params, %{conn_pid: 123})

    assert details == %{"retrySafe" => false, "mutationMayHaveApplied" => true}

    assert {:error, {:unavailable, _}} =
             LemonControlPlane.Methods.NodeProvidersManagementList.handle(
               %{"nodeId" => "offline-node"},
               %{conn_pid: 123}
             )
  end

  test "all local and destination methods require admin, never a node credential" do
    for prefix <- ["", "node."], operation <- @operations do
      method = prefix <> "providers.management." <> operation
      assert {:ok, module} = Registry.lookup(method)
      assert module.scopes() == [:admin]
      assert :ok = Authorize.authorize(Authorize.default_operator(), method, module.scopes())

      assert {:error, _} =
               Authorize.authorize(
                 Authorize.node_context("offline-node"),
                 method,
                 module.scopes()
               )

      assert {:error, _} =
               Authorize.authorize(
                 %{role: :operator, scopes: [:read, :write]},
                 method,
                 module.scopes()
               )
    end
  end

  test "generic write-scoped node invocation cannot bypass provider admin scope" do
    for operation <- @operations do
      assert {:error, {:forbidden, _}} =
               NodeInvoke.handle(
                 %{
                   "nodeId" => "offline-node",
                   "method" => "node.providers.management." <> operation,
                   "args" => %{}
                 },
                 %{}
               )
    end
  end

  test "unknown fields are rejected without dispatch" do
    assert {:error, _} =
             NodeProvidersManagementApiKeySet.handle(
               %{
                 "nodeId" => "offline-node",
                 "targetId" => "node:offline-node",
                 "providerId" => "openai",
                 "value" => "OFFLINE_MOCK_SECRET",
                 "unexpected" => true
               },
               %{conn_pid: self()}
             )

    refute_received {:node_event, _, _}
  end

  test "authenticated transport targets only the selected durable node and logs no credential" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    a = "provider-a-" <> suffix
    b = "provider-b-" <> suffix
    owner = self()
    # Explicit offline transport mock: acknowledges via NodeRegistry, no worker,
    # provider, credential store, or network is used by this test.
    other =
      spawn(fn ->
        receive do
          message -> send(owner, {:foreign_node, message})
        end
      end)

    for {id, pid} <- [{a, owner}, {b, other}] do
      :ok = NodeStore.put_node(id, %{id: id, name: id, type: "coding_agent"})
      :ok = NodeRegistry.register_session(id, id, pid, 1)
    end

    on_exit(fn ->
      NodeRegistry.unregister(a, owner)
      NodeRegistry.unregister(b, other)
      LemonCore.Store.delete(:nodes_registry, a)
      LemonCore.Store.delete(:nodes_registry, b)
      Process.exit(other, :kill)
    end)

    secret = "OFFLINE_MOCK_CREDENTIAL_NEVER_LOG"

    params = %{
      "nodeId" => a,
      "targetId" => "node:" <> a,
      "providerId" => "openai",
      "value" => secret
    }

    logs =
      capture_log(fn ->
        task =
          Task.async(fn ->
            NodeProvidersManagementApiKeySet.handle(params, %{conn_pid: owner})
          end)

        assert_receive {:node_event, "node.invoke.request",
                        %{
                          "invokeId" => invocation,
                          "nodeId" => ^a,
                          "method" => "node.providers.management.api_key.set",
                          "args" => args
                        }},
                       1_000

        assert args == Map.delete(params, "nodeId")

        result = %{
          "target" => %{"id" => "node:" <> a, "nodeId" => a, "hostname" => "offline-mock"},
          "default" => %{"providerId" => nil, "modelId" => nil},
          "providers" => []
        }

        assert :ok = NodeRegistry.complete_session(a, owner, 1, invocation, result)
        assert {:ok, ^result} = Task.await(task)
        refute_received {:foreign_node, _}
      end)

    refute logs =~ secret
  end
end
