defmodule LemonControlPlane.Methods.ProviderManagementTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.Methods.{Registry, NodeInvoke, NodeProvidersManagementApiKeySet}
  alias LemonControlPlane.NodeStore
  alias LemonCore.NodeRegistry

  @operations LemonCore.ProviderManagement.operations()

  # Explicit offline boundary mock; never contacts a provider or changes config.
  defmodule OfflineDeviceFailureMock do
    def device_start(_, _), do: raise("OFFLINE_DEVICE_TOKEN_EXCEPTION")
    def device_poll(_, _), do: {:error, :forbidden}
    def device_challenge(_, _), do: {:error, :forbidden}
    def device_cancel(_, _), do: {:error, {:private, "OFFLINE_DEVICE_TOKEN_EXCEPTION"}}

    def device_complete(%{"sessionId" => "foreign-session"}, _),
      do: {:error, :provider_binding_rejected}

    def device_complete(_, _), do: {:error, :forbidden}
  end

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
      assert module.dispatch_mode() == :async
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

  test "device methods declare all binding fields in protocol schemas" do
    for prefix <- ["", "node."],
        operation <- ~w(device.start device.poll device.challenge device.cancel) do
      method = prefix <> "providers.management." <> operation
      required = LemonControlPlane.Protocol.Schemas.get(method).required
      fields = ~w(targetId providerId loginId ownerId sessionId)
      fields = if prefix == "node.", do: ["nodeId" | fields], else: fields
      assert required == Map.new(fields, &{&1, :string})
      params = Map.new(fields, &{&1, "mock-identity"})
      assert :ok = LemonControlPlane.Protocol.Schemas.validate(method, params)

      for field <- fields do
        assert {:error, _} =
                 LemonControlPlane.Protocol.Schemas.validate(method, Map.delete(params, field))

        assert {:error, _} =
                 LemonControlPlane.Protocol.Schemas.validate(method, Map.put(params, field, 123))
      end
    end
  end

  test "in-flight credential completion does not block revocation, even while the target goes offline" do
    %{node: node, token: token, params: params} = completion_node()
    {task, _invocation, args} = dispatch_completion(params)

    assert args == Map.delete(params, "nodeId")
    assert args["commit"] == true
    refute Map.has_key?(args, "authorizationExpiresAtMs")

    assert {:ok, %{"revoked" => true, "revokedSessions" => 1}} =
             LemonControlPlane.Methods.NodesRevoke.handle(
               %{"nodeId" => node, "confirmName" => node},
               %{}
             )

    assert {:error, _} = TokenStore.validate(token)
    assert {:error, {:unavailable, _, details}} = Task.await(task)
    assert details["retrySafe"] == false
    assert details["mutationMayHaveApplied"] == true

    {:ok, module} = Registry.lookup("node.providers.management.device.complete")
    assert {:error, _} = module.handle(params, %{conn_pid: self()})
    refute_received {:node_event, "node.invoke.request", _}

    # A later offline settlement cannot attest whether the earlier write applied.
    settlement = Map.put(params, "commit", false)
    assert {:error, {:unavailable, _, details}} = module.handle(settlement, %{conn_pid: self()})
    assert details["preDispatch"] == true
    assert details["retrySafe"] == false
    refute details["mutationMayHaveApplied"] == false
  end

  test "legacy completion reservations cannot block session replacement or direct token revocation" do
    %{node: node, token: token, params: params} = completion_node()
    legacy_key = "legacy-" <> node

    # A reloaded record from an older controller is no longer an authority fence.
    assert :ok =
             LemonCore.Store.put(:provider_completion_authority, legacy_key, %{
               "nodeId" => node,
               "binding" => Map.delete(params, "commit")
             })

    on_exit(fn -> LemonCore.Store.delete(:provider_completion_authority, legacy_key) end)
    {task, _invocation, _args} = dispatch_completion(params)

    replacement_token = token <> "-replacement"

    assert {:ok, replacement} =
             TokenStore.replace_node_session(replacement_token, %{
               "type" => "node",
               "nodeId" => node
             })

    generation = replacement.identity["sessionGeneration"]
    assert :ok = NodeRegistry.register_session(node, node, self(), generation)
    assert {:error, {:unavailable, _, details}} = Task.await(task)
    assert details["mutationMayHaveApplied"] == true
    assert {:error, :invalid_token} = TokenStore.validate(token)
    assert :ok = TokenStore.revoke(replacement_token)
    assert {:error, :invalid_token} = TokenStore.validate(replacement_token)

    # Settlement uses the current connection without authorizing another write.
    settlement = Map.put(params, "commit", false)
    {task, invocation, args} = dispatch_completion(settlement)
    assert args == Map.delete(settlement, "nodeId")
    public = device_result(params)
    assert :ok = NodeRegistry.complete_session(node, self(), generation, invocation, public)
    assert {:ok, ^public} = Task.await(task)
  end

  test "expired node credentials reject writes but not fixed-ID non-writing settlement" do
    %{node: node, token: token, info: info, generation: generation, params: params} =
      completion_node()

    expiry = System.system_time(:millisecond) - 1
    assert :ok = LemonCore.Store.put(:session_tokens, token, %{info | expires_at_ms: expiry})
    {:ok, module} = Registry.lookup("node.providers.management.device.complete")
    assert {:error, {:forbidden, _}} = module.handle(params, %{conn_pid: self()})
    refute_received {:node_event, "node.invoke.request", _}

    settlement =
      params
      |> Map.put("commit", false)
      |> Map.put("challengeNonce", "")

    {task, invocation, args} = dispatch_completion(settlement)
    assert args == Map.delete(settlement, "nodeId")
    public = terminal_device_result(params, "lost")
    assert :ok = NodeRegistry.complete_session(node, self(), generation, invocation, public)
    assert {:ok, ^public} = Task.await(task)
  end

  test "completion transports only the exact nonce under skewed or backward controller clocks" do
    %{node: node, token: token, info: info, generation: generation, params: params} =
      completion_node()

    for offset <- [86_400_000, -86_400_000, -172_800_000] do
      now = System.system_time(:millisecond) + offset

      assert :ok =
               LemonCore.Store.put(:session_tokens, token, %{info | expires_at_ms: now + 3_000})

      {task, invocation, args} = dispatch_completion(params, %{provider_completion_now_ms: now})
      assert args == Map.delete(params, "nodeId")
      refute Map.has_key?(args, "authorizationExpiresAtMs")
      public = device_result(params)
      assert :ok = NodeRegistry.complete_session(node, self(), generation, invocation, public)
      assert {:ok, ^public} = Task.await(task)
    end

    # Current generation remains mandatory independently of the injected clock.
    assert :ok = LemonCore.Store.put(:session_tokens, token, info)

    # A live registry connection from a different credential generation is not authority.
    assert :ok = NodeRegistry.register_session(node, node, self(), generation + 1)
    {:ok, module} = Registry.lookup("node.providers.management.device.complete")
    assert {:error, {:forbidden, _}} = module.handle(params, %{conn_pid: self()})
    refute_received {:node_event, "node.invoke.request", _}
  end

  test "lost acknowledgement settles after token expiry, registry restart and re-pair before revocation" do
    %{node: node, token: token, info: info, generation: generation, params: params} =
      completion_node()

    {task, original_invocation, _args} = dispatch_completion(params)

    # Disconnect after dispatch: the controller cannot know whether the target wrote.
    assert :ok = NodeRegistry.unregister(node, self())
    assert {:error, {:unavailable, _, details}} = Task.await(task)
    assert details["mutationMayHaveApplied"] == true

    assert :ok =
             LemonCore.Store.put(:session_tokens, token, %{
               info
               | expires_at_ms: System.system_time(:millisecond) - 1
             })

    old_registry = Process.whereis(NodeRegistry)
    assert :ok = Supervisor.terminate_child(LemonCore.Supervisor, NodeRegistry)
    assert {:ok, registry} = Supervisor.restart_child(LemonCore.Supervisor, NodeRegistry)
    refute registry == old_registry
    assert :ok = NodeRegistry.register_session(node, node, self(), generation)
    {:ok, module} = Registry.lookup("node.providers.management.device.complete")
    assert {:error, {:forbidden, _}} = module.handle(params, %{conn_pid: self()})
    refute_received {:node_event, "node.invoke.request", _}

    assert {:ok, replacement} =
             TokenStore.replace_node_session(token <> "-repaired", %{
               "type" => "node",
               "nodeId" => node
             })

    replacement_generation = replacement.identity["sessionGeneration"]
    assert replacement_generation > generation
    owner = self()

    replacement_owner =
      spawn(fn ->
        for _ <- 1..2 do
          receive do
            message -> send(owner, message)
          end
        end

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      NodeRegistry.unregister(node, replacement_owner)
      Process.exit(replacement_owner, :kill)
    end)

    assert :ok =
             NodeRegistry.register_session(node, node, replacement_owner, replacement_generation)

    assert {:error, :not_found} =
             NodeRegistry.complete_session(
               node,
               self(),
               generation,
               original_invocation,
               device_result(params)
             )

    settlement = Map.put(params, "commit", false)
    {task, invocation, args} = dispatch_completion(settlement)
    assert args["completionId"] == params["completionId"]

    assert Map.take(args, ~w(targetId providerId loginId ownerId sessionId)) ==
             Map.take(params, ~w(targetId providerId loginId ownerId sessionId))

    public = terminal_device_result(params, "completed")

    assert :ok =
             NodeRegistry.complete_session(
               node,
               replacement_owner,
               replacement_generation,
               invocation,
               public
             )

    assert {:ok, ^public} = Task.await(task)

    # A new explicitly chosen login works on the re-paired target after the old
    # fixed completion was reconciled; no previous authorization is replayed.
    fresh = Map.put(device_params(node), "loginId", params["loginId"] <> "-fresh")
    {:ok, start_module} = Registry.lookup("node.providers.management.device.start")
    start_task = Task.async(fn -> start_module.handle(fresh, %{conn_pid: owner}) end)

    assert_receive {:node_event, "node.invoke.request",
                    %{
                      "invokeId" => start_invocation,
                      "method" => "node.providers.management.device.start",
                      "args" => start_args
                    }},
                   1_000

    assert start_args == Map.delete(fresh, "nodeId")
    fresh_public = device_result(fresh)

    assert :ok =
             NodeRegistry.complete_session(
               node,
               replacement_owner,
               replacement_generation,
               start_invocation,
               fresh_public
             )

    assert {:ok, ^fresh_public} = Task.await(start_task)

    assert {:ok, %{"revoked" => true}} =
             LemonControlPlane.Methods.NodesRevoke.handle(
               %{"nodeId" => node, "confirmName" => node},
               %{}
             )

    assert {:error, _} = TokenStore.validate(token)
    assert {:error, _} = TokenStore.validate(token <> "-repaired")
  end

  test "only exact target binding rejection is a scoped non-writing completion error" do
    %{node: node, generation: generation, params: params} = completion_node()

    for commit <- [true, false] do
      request = params |> Map.put("commit", commit) |> Map.put("sessionId", "foreign-session")
      {task, invocation, _args} = dispatch_completion(request)

      assert :ok =
               NodeRegistry.complete_session(
                 node,
                 self(),
                 generation,
                 invocation,
                 nil,
                 "provider_binding_rejected"
               )

      assert {:error, {:forbidden, _, details}} = Task.await(task)

      assert details == %{
               "reason" => "provider_binding_rejected",
               "retrySafe" => false,
               "mutationMayHaveApplied" => false
             }
    end

    {task, invocation, _args} = dispatch_completion(Map.put(params, "commit", false))

    assert :ok =
             NodeRegistry.complete_session(node, self(), generation, invocation, nil, "forbidden")

    assert {:error, {:forbidden, _, details}} = Task.await(task)
    assert details["reason"] == "permission_denied"
    refute details["mutationMayHaveApplied"] == false
  end

  test "completion RPC requires bounded authorization fields on controller and owned-node transports" do
    for prefix <- ["", "node."] do
      method = prefix <> "providers.management.device.complete"

      params =
        Map.merge(device_params("offline-device-node"), %{
          "completionId" => "fixed-completion-id",
          "challengeNonce" => "",
          "commit" => false
        })

      params = if prefix == "", do: Map.delete(params, "nodeId"), else: params
      assert :ok = LemonControlPlane.Protocol.Schemas.validate(method, params)
      {:ok, module} = Registry.lookup(method)
      assert module.scopes() == [:admin]
      assert module.dispatch_mode() == :async

      for field <- ~w(completionId challengeNonce commit) do
        assert {:error, {:invalid_request, _}} =
                 module.handle(Map.delete(params, field), %{conn_pid: self()})
      end
    end
  end

  test "device validation rejects incomplete binding and wrong providers before node dispatch" do
    for operation <- ~w(device.start device.poll device.challenge device.cancel) do
      {:ok, module} = Registry.lookup("node.providers.management." <> operation)
      params = device_params("offline-device-node")

      for field <- ~w(nodeId targetId providerId loginId ownerId sessionId) do
        assert {:error, {:invalid_request, _}} =
                 module.handle(Map.delete(params, field), %{conn_pid: self()})
      end

      for extra <- ~w(cwd config_path value accessToken refreshToken deviceCode verifier) do
        assert {:error, {:invalid_request, _}} =
                 module.handle(Map.put(params, extra, "MOCK_PRIVATE"), %{conn_pid: self()})
      end

      assert {:error, {:invalid_request, _}} =
               module.handle(%{params | "providerId" => "openai"}, %{conn_pid: self()})

      assert {:error, {:invalid_request, _}} =
               module.handle(%{params | "providerId" => "openai-codex"}, %{conn_pid: self()})

      refute_received {:node_event, _, _}
    end
  end

  test "local device binding denial and upstream failures never expose token material" do
    previous = LemonCore.ProviderManagement.service()
    Application.put_env(:lemon_core, :provider_management_service, OfflineDeviceFailureMock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :provider_management_service, previous),
        else: Application.delete_env(:lemon_core, :provider_management_service)
    end)

    {:ok, target} = LemonCore.ProviderManagement.target()

    params =
      device_params("offline-device-node")
      |> Map.delete("nodeId")
      |> Map.put("targetId", target.id)

    logs =
      capture_log(fn ->
        for operation <- ~w(device.start device.cancel) do
          {:ok, module} = Registry.lookup("providers.management." <> operation)
          assert {:error, {:unavailable, message, details}} = module.handle(params, %{})
          assert details["retrySafe"] == false
          assert details["mutationMayHaveApplied"] == true
          refute message =~ "OFFLINE_DEVICE_TOKEN"
        end

        {:ok, module} = Registry.lookup("providers.management.device.poll")
        assert {:error, {:forbidden, message}} = module.handle(params, %{})
        refute message =~ "OFFLINE_DEVICE_TOKEN"

        {:ok, module} = Registry.lookup("providers.management.device.complete")

        completion =
          Map.merge(params, %{
            "completionId" => "fixed-completion-id",
            "challengeNonce" => "",
            "commit" => false
          })

        assert {:error, {:forbidden, _, details}} =
                 module.handle(Map.put(completion, "sessionId", "foreign-session"), %{})

        assert details == %{
                 "reason" => "provider_binding_rejected",
                 "retrySafe" => false,
                 "mutationMayHaveApplied" => false
               }

        assert {:error, {:forbidden, _}} = module.handle(completion, %{})
      end)

    refute logs =~ "OFFLINE_DEVICE_TOKEN"
  end

  test "device transport preserves binding and projects only selected target public state" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    node = "device-a-" <> suffix
    foreign = "device-b-" <> suffix
    owner = self()

    other =
      spawn(fn ->
        receive do
          message -> send(owner, {:foreign_device_node, message})
        end
      end)

    for {id, pid} <- [{node, owner}, {foreign, other}] do
      :ok = NodeStore.put_node(id, %{id: id, name: id, type: "coding_agent"})
      :ok = NodeRegistry.register_session(id, id, pid, 1)
    end

    on_exit(fn ->
      NodeRegistry.unregister(node, owner)
      NodeRegistry.unregister(foreign, other)
      LemonCore.Store.delete(:nodes_registry, node)
      LemonCore.Store.delete(:nodes_registry, foreign)
      Process.exit(other, :kill)
    end)

    params = device_params(node)
    secret = "OFFLINE_DEVICE_TRANSPORT_TOKEN_NEVER_ECHO"

    logs =
      capture_log(fn ->
        for operation <- ~w(device.start device.poll device.challenge device.cancel) do
          method = "node.providers.management." <> operation
          {:ok, module} = Registry.lookup(method)
          task = Task.async(fn -> module.handle(params, %{conn_pid: owner}) end)

          assert_receive {:node_event, "node.invoke.request",
                          %{
                            "invokeId" => invocation,
                            "nodeId" => ^node,
                            "method" => ^method,
                            "args" => args
                          }},
                         1_000

          assert args == Map.delete(params, "nodeId")
          public = device_result(params)

          public =
            if operation == "device.challenge",
              do: Map.put(public, "challengeNonce", String.duplicate("n", 43)),
              else: public

          # Explicit offline target transport mock; never contacts OAuth or persists credentials.
          assert :ok =
                   NodeRegistry.complete_session(
                     node,
                     owner,
                     1,
                     invocation,
                     Map.merge(public, %{
                       "accessToken" => secret,
                       "challengeNonce" => public["challengeNonce"] || String.duplicate("p", 43)
                     })
                   )

          assert {:ok, ^public} = Task.await(task)
          refute_received {:foreign_device_node, _}
        end

        {:ok, module} = Registry.lookup("node.providers.management.device.poll")

        for result <- [
              %{device_result(params) | "targetId" => "node:" <> foreign},
              %{device_result(params) | "verificationUrl" => "https://foreign.invalid/"}
            ] do
          task = Task.async(fn -> module.handle(params, %{conn_pid: owner}) end)
          assert_receive {:node_event, "node.invoke.request", %{"invokeId" => invocation}}, 1_000
          assert :ok = NodeRegistry.complete_session(node, owner, 1, invocation, result)
          assert {:error, {:unavailable, _, details}} = Task.await(task)
          assert details["retrySafe"] == false
        end

        task = Task.async(fn -> module.handle(params, %{conn_pid: owner}) end)
        assert_receive {:node_event, "node.invoke.request", %{"invokeId" => invocation}}, 1_000

        assert :ok =
                 NodeRegistry.complete_session(node, owner, 1, invocation, %{"error" => secret})

        assert {:error, {:unavailable, _, details}} = Task.await(task)
        refute inspect(details) =~ secret

        for {reason, expected} <- [{"forbidden", :forbidden}, {secret, :unavailable}] do
          task = Task.async(fn -> module.handle(params, %{conn_pid: owner}) end)
          assert_receive {:node_event, "node.invoke.request", %{"invokeId" => invocation}}, 1_000
          assert :ok = NodeRegistry.complete_session(node, owner, 1, invocation, nil, reason)
          assert {:error, error} = Task.await(task)
          assert elem(error, 0) == expected
          refute inspect(error) =~ secret
        end
      end)

    refute logs =~ secret
  end

  defp completion_node do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    node = "mock-completion-node-" <> suffix
    token = "mock-node-session-" <> suffix
    owner = self()

    assert {:ok, info} =
             TokenStore.replace_node_session(token, %{"type" => "node", "nodeId" => node})

    generation = info.identity["sessionGeneration"]
    assert :ok = NodeStore.put_node(node, %{id: node, name: node, type: "coding_agent"})
    assert :ok = NodeRegistry.register_session(node, node, owner, generation)

    on_exit(fn ->
      TokenStore.revoke_identity("node", node)
      NodeRegistry.unregister(node, owner)
      LemonCore.Store.delete(:nodes_registry, node)
    end)

    params =
      Map.merge(device_params(node), %{
        "completionId" => "mock-completion-" <> suffix,
        "challengeNonce" => String.duplicate("n", 43),
        "commit" => true
      })

    %{node: node, token: token, info: info, generation: generation, params: params}
  end

  defp dispatch_completion(params, ctx \\ %{}) do
    {:ok, module} = Registry.lookup("node.providers.management.device.complete")
    owner = self()
    task = Task.async(fn -> module.handle(params, Map.put(ctx, :conn_pid, owner)) end)

    assert_receive {:node_event, "node.invoke.request",
                    %{
                      "invokeId" => invocation,
                      "method" => "node.providers.management.device.complete",
                      "args" => args
                    }},
                   1_000

    {task, invocation, args}
  end

  defp terminal_device_result(params, status) do
    params
    |> Map.take(~w(loginId targetId providerId))
    |> Map.merge(%{
      "status" => status,
      "verificationUrl" => nil,
      "userCode" => nil,
      "expiresAtMs" => nil,
      "pollIntervalMs" => nil
    })
  end

  defp device_params(node) do
    %{
      "nodeId" => node,
      "targetId" => "node:" <> node,
      "providerId" => "openai_codex",
      "loginId" => "fixed-product-nonce",
      "ownerId" => "owner-hash",
      "sessionId" => "session-hash"
    }
  end

  defp device_result(params) do
    params
    |> Map.take(~w(loginId targetId providerId))
    |> Map.merge(%{
      "status" => "pending",
      "verificationUrl" => "https://auth.openai.com/codex/device",
      "userCode" => "MOCK-CODE",
      "expiresAtMs" => 1_900_000_000_000,
      "pollIntervalMs" => 5_000
    })
  end
end
