defmodule LemonControlPlane.WS.ConnectionTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.WS.Connection

  defmodule AsyncHandler do
    @behaviour LemonControlPlane.Method

    @impl true
    def name, do: "connection.test.async"

    @impl true
    def scopes, do: []

    @impl true
    def dispatch_mode, do: :async

    @impl true
    def handle(_params, ctx) do
      send(ctx.auth.test_pid, {:async_handler_started, self()})

      receive do
        :finish -> {:ok, %{"finished" => true}}
      after
        1_000 -> {:error, {:timeout, "test handler timed out"}}
      end
    end
  end

  defmodule InvalidResultHandler do
    @behaviour LemonControlPlane.Method
    @impl true
    def name, do: "connection.test.invalid_result"
    @impl true
    def scopes, do: []
    @impl true
    def handle(_params, _ctx), do: {:ok, %{"usage" => %LemonAi.Types.Usage{input: 1}}}
  end

  test "a fresh old worker cannot inherit durable native or memory privacy capabilities" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    node_id = "privacy-handshake-" <> suffix
    name = "Privacy Handshake " <> suffix
    token = "privacy-node-token-" <> suffix

    stored = %{
      "coding_agent.run" => %{
        "version" => 2,
        "executionContext" => %{"version" => 1},
        "nativePrivacyContext" => %{"version" => 1}
      },
      "memory.search" => %{"version" => 1, "contextVersion" => 1},
      "memory.transfer.import" => %{"version" => 1, "contextVersion" => 1},
      "ordinary.legacy" => true
    }

    assert :ok =
             LemonControlPlane.NodeStore.put_node(
               node_id,
               %{
                 id: node_id,
                 name: name,
                 type: "coding_agent",
                 capabilities: stored,
                 status: :offline
               }
             )

    assert {:ok, _} =
             LemonControlPlane.Auth.TokenStore.store(token, %{
               "type" => "node",
               "nodeId" => node_id
             })

    node_pid = self()

    on_exit(fn ->
      LemonCore.NodeRegistry.unregister(node_id, node_pid)
      LemonCore.Store.delete(:session_tokens, token)
      LemonCore.Store.delete(:session_token_heads, {"node", node_id})
      LemonControlPlane.NodeStore.release_node_name(name, node_id)
      LemonCore.Store.delete(:nodes_registry, node_id)
    end)

    assert {:ok, state} = Connection.init([])

    frame =
      Jason.encode!(%{
        "type" => "req",
        "id" => "old-connect",
        "method" => "connect",
        "params" => %{"auth" => %{"token" => token}}
      })

    assert {:push, {:text, hello}, connected} =
             Connection.handle_in({frame, [opcode: :text]}, state)

    assert Jason.decode!(hello)["type"] == "hello-ok"
    assert {:ok, live} = LemonCore.NodeRegistry.resolve_id(node_id)
    refute get_in(live.metadata, [:capabilities, "coding_agent.run", "nativePrivacyContext"])
    refute get_in(live.metadata, [:capabilities, "memory.search", "contextVersion"])
    refute get_in(live.metadata, [:capabilities, "memory.transfer.import", "contextVersion"])
    assert live.metadata.capabilities["ordinary.legacy"] == true

    assert get_in(LemonControlPlane.NodeStore.get_node(node_id), [
             :capabilities,
             "coding_agent.run",
             "nativePrivacyContext",
             "version"
           ]) == 1

    assert {:error, {:native_privacy_context_unsupported, ^node_id}} =
             LemonCore.NodeRegistry.invoke_node(
               node_id,
               "coding_agent.run",
               %{
                 "version" => 1,
                 "prompt" => "private payload",
                 "meta" => %{"invocation_context_key" => "private-actor"}
               },
               expected_pid: self(),
               expected_generation: live.generation,
               required_native_privacy_context: 1
             )

    refute_receive {:node_event, "node.invoke.request", _}

    frame =
      Jason.encode!(%{
        "type" => "req",
        "id" => "fresh-connect",
        "method" => "connect",
        "params" => %{"auth" => %{"token" => token}, "capabilities" => stored}
      })

    assert {:ok, reconnect_state} = Connection.init([])

    assert {:push, {:text, fresh_hello}, _} =
             Connection.handle_in({frame, [opcode: :text]}, reconnect_state)

    assert Jason.decode!(fresh_hello)["type"] == "hello-ok"
    assert {:ok, fresh} = LemonCore.NodeRegistry.resolve_id(node_id)

    assert get_in(fresh.metadata, [
             :capabilities,
             "coding_agent.run",
             "nativePrivacyContext",
             "version"
           ]) == 1

    assert connected.auth.role == :node
  end

  test "native conduit budget is larger only for authenticated node methods" do
    large_policy = %{"allow" => Enum.map(1..12_000, &"tool-#{&1}")}

    body =
      Jason.encode!(%{
        "type" => "req",
        "id" => "large-floor",
        "method" => "node.native.lineage.floor",
        "params" => %{
          "sourceRunId" => "unknown-root",
          "lineageHandle" => String.duplicate("x", 43),
          "toolPolicy" => large_policy
        }
      })

    node = %Connection{
      conn_id: "native-budget",
      connected: true,
      auth: %{role: :node, client_id: "unknown", scopes: [:invoke]}
    }

    assert {:ok, _} = Connection.handle_in({body, [opcode: :text]}, node)
    assert_receive {:method_result, "large-floor", {:error, _}}, 1000
    operator = %{node | auth: %{role: :operator, scopes: [:admin]}}
    assert {:push, {:text, rejected}, _} = Connection.handle_in({body, [opcode: :text]}, operator)
    assert Jason.decode!(rejected)["ok"] == false
    ordinary = String.replace(body, "node.native.lineage.floor", "node.invoke.event")
    assert {:push, {:text, rejected}, _} = Connection.handle_in({ordinary, [opcode: :text]}, node)
    assert Jason.decode!(rejected)["ok"] == false
  end

  test "unsupported inline and async responses preserve the socket with reconciliation errors" do
    :ok = Registry.register(InvalidResultHandler)
    on_exit(fn -> Registry.unregister(InvalidResultHandler.name()) end)

    state = %Connection{
      conn_id: "encoding-test",
      auth: %{role: :operator, scopes: [:read, :write], client_id: "test"},
      connected: true
    }

    request =
      Jason.encode!(%{
        "type" => "req",
        "id" => "invalid-result",
        "method" => InvalidResultHandler.name(),
        "params" => %{}
      })

    for {operation, id} <- [
          {fn -> Connection.handle_in({request, [opcode: :text]}, state) end, "invalid-result"},
          {fn ->
             Connection.handle_info(
               {:method_result, "invalid-async", {:ok, %{private_value: self()}}},
               state
             )
           end, "invalid-async"}
        ] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:push, {:text, frame}, ^state} = operation.()

          assert %{
                   "id" => ^id,
                   "ok" => false,
                   "error" => %{
                     "code" => "INTERNAL_ERROR",
                     "details" => %{"code" => "RESPONSE_ENCODING_FAILED", "retrySafe" => false}
                   }
                 } = Jason.decode!(frame)
        end)

      refute log =~ "private_value"
      refute log =~ "LemonAi.Types.Usage"
    end

    assert {:push, {:text, valid}, ^state} =
             Connection.handle_info({:method_result, "healthy", {:ok, %{ok: true}}}, state)

    assert %{"id" => "healthy", "ok" => true} = Jason.decode!(valid)
  end

  describe "async method dispatch" do
    test "keeps event delivery live while an approval-style method is waiting" do
      :ok = Registry.register(AsyncHandler)
      on_exit(fn -> Registry.unregister(AsyncHandler.name()) end)

      state = %Connection{
        conn_id: "async-test-conn",
        auth: %{
          role: :operator,
          scopes: [:admin, :read, :write],
          client_id: "test-client",
          test_pid: self()
        },
        connected: true,
        event_seq: 0,
        state_version: %{}
      }

      request =
        Jason.encode!(%{
          "type" => "req",
          "id" => "slow-request",
          "method" => AsyncHandler.name(),
          "params" => %{}
        })

      assert {:ok, ^state} = Connection.handle_in({request, [opcode: :text]}, state)
      assert_receive {:async_handler_started, worker}

      assert {:push, {:text, event_frame}, event_state} =
               Connection.handle_info(
                 {:event, "exec.approval.requested", %{"approvalId" => "approval-1"}},
                 state
               )

      assert %{"type" => "event", "event" => "exec.approval.requested"} =
               Jason.decode!(event_frame)

      send(worker, :finish)
      assert_receive {:method_result, "slow-request", {:ok, %{"finished" => true}}} = result

      assert {:push, {:text, response_frame}, ^event_state} =
               Connection.handle_info(result, event_state)

      assert %{
               "type" => "res",
               "id" => "slow-request",
               "ok" => true,
               "payload" => %{"finished" => true}
             } = Jason.decode!(response_frame)
    end
  end

  describe "handle_info/2 event delivery" do
    setup do
      # Create a minimal state for testing
      state = %Connection{
        conn_id: "test-conn-#{System.unique_integer()}",
        auth: %{role: :operator, scopes: [:read, :write], client_id: "test-client"},
        connected: true,
        event_seq: 0,
        state_version: %{}
      }

      {:ok, state: state}
    end

    test "handles 3-tuple events without state version", %{state: state} do
      event_name = "test.event"
      payload = %{"data" => "value"}

      {:push, {:text, frame}, new_state} =
        Connection.handle_info({:event, event_name, payload}, state)

      # Event seq should increment
      assert new_state.event_seq == 1

      # State version should remain unchanged
      assert new_state.state_version == %{}

      # Frame should be valid JSON
      assert {:ok, decoded} = Jason.decode(frame)
      assert decoded["type"] == "event"
      assert decoded["event"] == event_name
    end

    test "handles 4-tuple events with state version update", %{state: state} do
      event_name = "presence"
      payload = %{"connections" => [], "count" => 0}
      new_state_version = %{presence: 1, health: 0, cron: 0}

      {:push, {:text, frame}, new_state} =
        Connection.handle_info({:event, event_name, payload, new_state_version}, state)

      # Event seq should increment
      assert new_state.event_seq == 1

      # State version should be updated from the 4-tuple
      assert new_state.state_version == new_state_version

      # Frame should be valid JSON with stateVersion
      assert {:ok, decoded} = Jason.decode(frame)
      assert decoded["type"] == "event"
      assert decoded["event"] == event_name
    end

    test "accumulates state version across multiple 4-tuple events", %{state: state} do
      # First event
      {:push, {:text, _}, state1} =
        Connection.handle_info(
          {:event, "presence", %{}, %{presence: 1, health: 0, cron: 0}},
          state
        )

      assert state1.state_version == %{presence: 1, health: 0, cron: 0}
      assert state1.event_seq == 1

      # Second event updates some values
      {:push, {:text, _}, state2} =
        Connection.handle_info(
          {:event, "tick", %{}, %{presence: 1, health: 0, cron: 1}},
          state1
        )

      assert state2.state_version == %{presence: 1, health: 0, cron: 1}
      assert state2.event_seq == 2

      # Third event with different increments
      {:push, {:text, _}, state3} =
        Connection.handle_info(
          {:event, "presence", %{}, %{presence: 2, health: 1, cron: 1}},
          state2
        )

      assert state3.state_version == %{presence: 2, health: 1, cron: 1}
      assert state3.event_seq == 3
    end

    test "event_seq increments for all event types", %{state: state} do
      # 3-tuple event
      {:push, {:text, _}, state1} =
        Connection.handle_info({:event, "test", %{}}, state)

      assert state1.event_seq == 1

      # 4-tuple event
      {:push, {:text, _}, state2} =
        Connection.handle_info({:event, "test2", %{}, %{presence: 0}}, state1)

      assert state2.event_seq == 2
    end
  end

  describe "handle_info/2 push_frame" do
    setup do
      state = %Connection{
        conn_id: "test-conn-#{System.unique_integer()}",
        auth: nil,
        connected: false,
        event_seq: 0,
        state_version: %{}
      }

      {:ok, state: state}
    end

    test "handles push_frame messages", %{state: state} do
      frame = ~s({"type":"evt","event":"test"})

      {:push, {:text, pushed_frame}, new_state} =
        Connection.handle_info({:push_frame, frame}, state)

      assert pushed_frame == frame
      # State should not change
      assert new_state == state
    end
  end

  describe "handle_info/2 unknown messages" do
    setup do
      state = %Connection{
        conn_id: "test-conn-#{System.unique_integer()}",
        auth: nil,
        connected: false,
        event_seq: 0,
        state_version: %{}
      }

      {:ok, state: state}
    end

    test "handles unknown messages gracefully", %{state: state} do
      {:ok, new_state} = Connection.handle_info(:unknown_message, state)
      assert new_state == state
    end
  end

  describe "connect error classification and auth reasons" do
    test "expired token returns UNAUTHORIZED with session_expired reason" do
      token = "ws-expired-token-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:session_tokens, token, %{
        token: token,
        identity: %{"type" => "node", "nodeId" => "expired-node-id"},
        issued_at_ms: System.system_time(:millisecond) - 60_000,
        expires_at_ms: System.system_time(:millisecond) - 1_000
      })

      on_exit(fn ->
        LemonCore.Store.delete(:session_tokens, token)
      end)

      assert {:ok, state} = Connection.init([])

      frame =
        Jason.encode!(%{
          "type" => "req",
          "id" => "expired-connect",
          "method" => "connect",
          "params" => %{"auth" => %{"token" => token}}
        })

      assert {:push, {:text, response_text}, _state} =
               Connection.handle_in({frame, [opcode: :text]}, state)

      response = Jason.decode!(response_text)
      assert response["type"] == "res"
      assert response["id"] == "expired-connect"
      assert response["ok"] == false
      assert response["error"]["code"] == "UNAUTHORIZED"
      assert response["error"]["message"] =~ "Token has expired"
      assert response["error"]["details"] == %{"reason" => "session_expired"}
    end

    test "invalid token returns UNAUTHORIZED with session_invalid reason" do
      assert {:ok, state} = Connection.init([])

      frame =
        Jason.encode!(%{
          "type" => "req",
          "id" => "invalid-connect",
          "method" => "connect",
          "params" => %{"auth" => %{"token" => "completely-invalid-token"}}
        })

      assert {:push, {:text, response_text}, _state} =
               Connection.handle_in({frame, [opcode: :text]}, state)

      response = Jason.decode!(response_text)
      assert response["type"] == "res"
      assert response["id"] == "invalid-connect"
      assert response["ok"] == false
      assert response["error"]["code"] == "UNAUTHORIZED"
      assert response["error"]["message"] =~ "Invalid token"
      assert response["error"]["details"] == %{"reason" => "session_invalid"}
    end

    test "paired node not found returns UNAUTHORIZED with node_not_found reason" do
      node_id = "missing-node-#{System.unique_integer([:positive])}"
      token = "missing-node-token-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               LemonControlPlane.Auth.TokenStore.store(token, %{
                 "type" => "node",
                 "nodeId" => node_id
               })

      on_exit(fn ->
        LemonCore.Store.delete(:session_tokens, token)
      end)

      assert {:ok, state} = Connection.init([])

      frame =
        Jason.encode!(%{
          "type" => "req",
          "id" => "not-found-connect",
          "method" => "connect",
          "params" => %{"auth" => %{"token" => token}}
        })

      assert {:push, {:text, response_text}, _state} =
               Connection.handle_in({frame, [opcode: :text]}, state)

      response = Jason.decode!(response_text)
      assert response["type"] == "res"
      assert response["id"] == "not-found-connect"
      assert response["ok"] == false
      assert response["error"]["code"] == "UNAUTHORIZED"
      assert response["error"]["message"] == "Paired node was not found"
      assert response["error"]["details"] == %{"reason" => "node_not_found"}
    end

    test "node name conflict returns CONFLICT with node_name_conflict reason" do
      suffix = Integer.to_string(System.unique_integer([:positive]))
      node_id1 = "conflict-node-1-" <> suffix
      node_id2 = "conflict-node-2-" <> suffix
      name = "Conflict Node " <> suffix
      token1 = "conflict-token-1-" <> suffix
      token2 = "conflict-token-2-" <> suffix

      # First node is registered and active
      LemonControlPlane.NodeStore.put_node(node_id1, %{
        id: node_id1,
        name: name,
        type: "coding_agent",
        status: :offline
      })

      LemonControlPlane.NodeStore.put_node(node_id2, %{
        id: node_id2,
        name: name,
        type: "coding_agent",
        status: :offline
      })

      # Reserve name for node_id1
      LemonControlPlane.NodeStore.reserve_node_name(name, node_id1)

      assert {:ok, _} =
               LemonControlPlane.Auth.TokenStore.store(token2, %{
                 "type" => "node",
                 "nodeId" => node_id2
               })

      on_exit(fn ->
        LemonCore.Store.delete(:session_tokens, token1)
        LemonCore.Store.delete(:session_tokens, token2)
        LemonControlPlane.NodeStore.release_node_name(name, node_id1)
        LemonCore.Store.delete(:nodes_registry, node_id1)
        LemonCore.Store.delete(:nodes_registry, node_id2)
      end)

      assert {:ok, state} = Connection.init([])

      frame =
        Jason.encode!(%{
          "type" => "req",
          "id" => "conflict-connect",
          "method" => "connect",
          "params" => %{"auth" => %{"token" => token2}}
        })

      assert {:push, {:text, response_text}, _state} =
               Connection.handle_in({frame, [opcode: :text]}, state)

      response = Jason.decode!(response_text)
      assert response["type"] == "res"
      assert response["id"] == "conflict-connect"
      assert response["ok"] == false
      assert response["error"]["code"] == "CONFLICT"
      assert response["error"]["message"] == "Node name is already in use"
      assert response["error"]["details"] == %{"reason" => "node_name_conflict"}
    end

    test "node connect touches session and schedules hourly touch timer" do
      suffix = Integer.to_string(System.unique_integer([:positive]))
      node_id = "touch-ws-" <> suffix
      name = "Touch WS " <> suffix
      token = "touch-ws-token-" <> suffix

      LemonControlPlane.NodeStore.put_node(node_id, %{
        id: node_id,
        name: name,
        type: "coding_agent",
        status: :offline
      })

      assert {:ok, info} =
               LemonControlPlane.Auth.TokenStore.replace_node_session(token, %{
                 "type" => "node",
                 "nodeId" => node_id
               }, ttl_ms: 24 * 60 * 60 * 1000)

      node_pid = self()

      on_exit(fn ->
        LemonCore.NodeRegistry.unregister(node_id, node_pid)
        LemonCore.Store.delete(:session_tokens, token)
        LemonCore.Store.delete(:session_token_heads, {"node", node_id})
        LemonControlPlane.NodeStore.release_node_name(name, node_id)
        LemonCore.Store.delete(:nodes_registry, node_id)
      end)

      assert {:ok, state} = Connection.init([])

      frame =
        Jason.encode!(%{
          "type" => "req",
          "id" => "touch-connect",
          "method" => "connect",
          "params" => %{"auth" => %{"token" => token}}
        })

      assert {:push, {:text, hello}, connected_state} =
               Connection.handle_in({frame, [opcode: :text]}, state)

      assert Jason.decode!(hello)["type"] == "hello-ok"
      assert is_reference(connected_state.node_session_touch_timer_ref)

      # Token expiry should have been touched to 7 days
      updated_info = LemonCore.Store.get(:session_tokens, token)
      assert updated_info.expires_at_ms > info.expires_at_ms

      # Test handling :node_session_touch message
      assert {:ok, touched_state} =
               Connection.handle_info(:node_session_touch, connected_state)

      assert is_reference(touched_state.node_session_touch_timer_ref)

      # Test terminate cancels timer
      assert :ok = Connection.terminate(:normal, touched_state)
    end
  end
end
