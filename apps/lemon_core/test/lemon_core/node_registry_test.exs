defmodule LemonCore.NodeRegistryTest do
  use ExUnit.Case, async: false

  alias LemonCore.NodeRegistry

  setup do
    for node <- NodeRegistry.list() do
      NodeRegistry.unregister(node.id, node.pid)
    end

    :ok
  end

  test "registers and resolves a live node by name or id" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self(), %{"gpu" => true})

    assert {:ok, %{id: "node-1", name: "newphy", metadata: %{"gpu" => true}}} =
             NodeRegistry.resolve("newphy")

    assert {:ok, %{name: "newphy"}} = NodeRegistry.resolve("node-1")
    assert NodeRegistry.online?("newphy")
  end

  test "requires unique live names" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = NodeRegistry.register("node-1", "gpu-box", first)

    assert {:error, {:name_taken, "gpu-box"}} =
             NodeRegistry.register("node-2", "gpu-box", second)

    Process.exit(first, :kill)
    Process.exit(second, :kill)
  end

  test "replaces an earlier connection for the same paired node" do
    parent = self()

    old = spawn(fn -> relay(parent, :old_connection) end)

    new = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = NodeRegistry.register("node-1", "ophy", old)
    assert {:ok, invoke_id} = NodeRegistry.invoke("ophy", "coding_agent.run", %{})

    assert_receive {:old_connection,
                    {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}}

    assert :ok = NodeRegistry.register("node-1", "ophy", new)

    assert_receive {:old_connection,
                    {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}}

    assert_receive {:lemon_node_result, ^invoke_id, {:error, {:node_disconnected, :reconnected}}}

    assert {:ok, %{pid: ^new}} = NodeRegistry.resolve("ophy")

    Process.exit(old, :kill)
    Process.exit(new, :kill)
  end

  test "renames a live node without dropping active invocations" do
    assert :ok = NodeRegistry.register("node-1", "old-name", self())
    assert {:ok, invoke_id} = NodeRegistry.invoke("old-name", "coding_agent.run", %{})
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

    assert :ok = NodeRegistry.rename("node-1", "new-name")
    assert {:error, :not_found} = NodeRegistry.resolve("old-name")
    assert {:ok, %{id: "node-1"}} = NodeRegistry.resolve("new-name")

    assert :ok = NodeRegistry.complete("node-1", invoke_id, %{"answer" => "done"})
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"answer" => "done"}}}
  end

  test "targets invocation requests and binds completion to the selected node" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())
    assert {:ok, invoke_id} = NodeRegistry.invoke("newphy", "coding_agent.run", %{"x" => 1})

    assert_receive {:node_event, "node.invoke.request", payload}
    assert payload["invokeId"] == invoke_id
    assert payload["nodeName"] == "newphy"

    assert {:error, :wrong_node} = NodeRegistry.complete("node-2", invoke_id, %{}, nil)
    refute_receive {:lemon_node_result, ^invoke_id, _}

    assert :ok = NodeRegistry.complete("node-1", invoke_id, %{"answer" => "done"}, nil)
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"answer" => "done"}}}
  end

  test "strict completion is bound to the receiving connection and generation" do
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = NodeRegistry.register_session("strict-node", "newphy", self(), 7)
    assert {:ok, invoke_id} = NodeRegistry.invoke("newphy", "coding_agent.run", %{})
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

    assert {:error, :stale_session} =
             NodeRegistry.complete_session(
               "strict-node",
               other,
               7,
               invoke_id,
               %{"wrong" => true}
             )

    assert {:error, :stale_session} =
             NodeRegistry.complete_session(
               "strict-node",
               self(),
               6,
               invoke_id,
               %{"old" => true}
             )

    assert :ok =
             NodeRegistry.complete_session(
               "strict-node",
               self(),
               7,
               invoke_id,
               %{"ok" => true}
             )

    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => true}}}
    Process.exit(other, :kill)
  end

  test "credential rotation revokes the live stale session immediately" do
    parent = self()
    stale = spawn(fn -> relay(parent, :stale_session) end)

    assert :ok = NodeRegistry.register_session("rotating-node", "newphy", stale, 3)
    assert {:ok, invoke_id} = NodeRegistry.invoke("newphy", "coding_agent.run", %{})

    assert_receive {:stale_session,
                    {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}}

    assert :ok = NodeRegistry.revoke_session("rotating-node", 4)
    assert_receive {:stale_session, {:node_session_revoked, "rotating-node", 4}}

    assert_receive {:lemon_node_result, ^invoke_id,
                    {:error, {:node_disconnected, :credential_rotated}}}

    refute NodeRegistry.online?("rotating-node")
    Process.exit(stale, :kill)
  end

  test "revoke before a delayed handshake retains the authorized generation floor" do
    assert :ok = NodeRegistry.revoke_session("delayed-handshake-node", 2)

    assert {:error, :stale_session} =
             NodeRegistry.register_session("delayed-handshake-node", "delayed", self(), 1)

    refute NodeRegistry.online?("delayed-handshake-node")
    assert :ok = NodeRegistry.register_session("delayed-handshake-node", "delayed", self(), 2)
    assert NodeRegistry.online?("delayed-handshake-node")
  end

  test "a lower generation cannot replace a higher live session" do
    parent = self()
    current = spawn(fn -> relay(parent, :current_session) end)
    stale = spawn(fn -> relay(parent, :stale_session) end)

    assert :ok = NodeRegistry.register_session("monotonic-node", "monotonic", current, 5)

    assert {:error, :stale_session} =
             NodeRegistry.register_session("monotonic-node", "monotonic", stale, 4)

    assert {:ok, %{pid: ^current}} = NodeRegistry.resolve("monotonic-node")
    refute_receive {:current_session, {:node_session_revoked, _, _}}

    Process.exit(current, :kill)
    Process.exit(stale, :kill)
  end

  test "rejects an invocation when the full request envelope exceeds maxPayload" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    assert {:error, {:invalid_payload, {:max_bytes, 160}}} =
             NodeRegistry.invoke(
               "newphy",
               "coding_agent.run",
               %{"prompt" => String.duplicate("x", 128)},
               max_payload_bytes: 160
             )

    refute_receive {:node_event, "node.invoke.request", _payload}
  end

  test "fails an active invocation when its node disconnects" do
    node = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = NodeRegistry.register("node-1", "newphy", node)
    assert {:ok, invoke_id} = NodeRegistry.invoke("newphy", "coding_agent.run", %{})

    Process.exit(node, :kill)

    assert_receive {:lemon_node_result, ^invoke_id,
                    {:error, {:node_disconnected, :disconnected}}},
                   1_000
  end

  test "times out invocations" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("newphy", "coding_agent.run", %{}, timeout_ms: 10)

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}
    assert_receive {:lemon_node_result, ^invoke_id, {:error, :timeout}}, 1_000
  end

  test "cancels destination work when the result recipient exits" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())
    recipient = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("newphy", "coding_agent.run", %{}, recipient: recipient)

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    Process.exit(recipient, :kill)

    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}, 1_000
  end

  test "cancel sends a targeted cancellation event" do
    assert :ok = NodeRegistry.register("node-1", "ophy", self())
    assert {:ok, invoke_id} = NodeRegistry.invoke("ophy", "coding_agent.run", %{})
    assert_receive {:node_event, "node.invoke.request", _}

    assert :ok = NodeRegistry.cancel(invoke_id, :user_requested)

    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}
    assert_receive {:lemon_node_result, ^invoke_id, {:error, :user_requested}}
  end

  test "pins invocation controls to run identity and authenticated connection generation" do
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = NodeRegistry.register_session("control-node", "control-newphy", self(), 7)

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("control-newphy", "coding_agent.run", %{"runId" => "run-1"})

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

    assert {:ok, control_id} = NodeRegistry.control(invoke_id, :steer, "tighten the proof")

    assert_receive {:node_event, "node.invoke.control",
                    %{
                      "controlId" => ^control_id,
                      "invokeId" => ^invoke_id,
                      "runId" => "run-1",
                      "operation" => "steer",
                      "text" => "tighten the proof"
                    }}

    assert {:error, :stale_session} =
             NodeRegistry.complete_control_session(
               "control-node",
               other,
               7,
               control_id,
               invoke_id,
               "run-1",
               true
             )

    assert :ok =
             NodeRegistry.complete_control_session(
               "control-node",
               self(),
               7,
               control_id,
               invoke_id,
               "run-1",
               true
             )

    assert_receive {:lemon_node_control_result, ^control_id, ^invoke_id, :ok}
    Process.exit(other, :kill)
  end

  test "fails pending controls closed when invocation becomes terminal" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("newphy", "coding_agent.run", %{"runId" => "run-1"})

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    assert {:ok, control_id} = NodeRegistry.control(invoke_id, :redirect, "change course")
    assert_receive {:node_event, "node.invoke.control", %{"controlId" => ^control_id}}

    assert :ok = NodeRegistry.complete("node-1", invoke_id, %{"ok" => true})
    assert_receive {:lemon_node_control_result, ^control_id, ^invoke_id, {:error, :terminal}}
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => true}}}
    assert {:error, :terminal} = NodeRegistry.control(invoke_id, :steer, "too late")
  end

  test "times out an unacknowledged control without claiming acceptance" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("newphy", "coding_agent.run", %{"runId" => "run-timeout"})

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}

    assert {:ok, control_id} =
             NodeRegistry.control(invoke_id, :steer, "acknowledge me", timeout_ms: 10)

    assert_receive {:node_event, "node.invoke.control", %{"controlId" => ^control_id}}

    assert_receive {:lemon_node_control_result, ^control_id, ^invoke_id, {:error, :timeout}},
                   1_000

    assert :ok = NodeRegistry.complete("node-1", invoke_id, %{"ok" => true})
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"ok" => true}}}
  end

  test "fails pending controls closed when the owning connection disconnects" do
    parent = self()
    node = spawn(fn -> relay(parent, :control_connection) end)
    assert :ok = NodeRegistry.register("node-1", "newphy", node)

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("newphy", "coding_agent.run", %{"runId" => "run-disconnect"})

    assert_receive {:control_connection,
                    {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}}

    assert {:ok, control_id} =
             NodeRegistry.control(invoke_id, :redirect, "change direction")

    assert_receive {:control_connection,
                    {:node_event, "node.invoke.control", %{"controlId" => ^control_id}}}

    Process.exit(node, :kill)

    assert_receive {:lemon_node_control_result, ^control_id, ^invoke_id,
                    {:error, {:node_disconnected, :disconnected}}},
                   1_000

    assert_receive {:lemon_node_result, ^invoke_id,
                    {:error, {:node_disconnected, :disconnected}}},
                   1_000
  end

  test "rejects oversized correction text before it crosses the node boundary" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    assert {:ok, invoke_id} =
             NodeRegistry.invoke("newphy", "coding_agent.run", %{"runId" => "run-1"})

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    oversized = String.duplicate("x", NodeRegistry.max_control_text_bytes() + 1)

    assert {:error, {:text_too_large, 16_384}} =
             NodeRegistry.control(invoke_id, :steer, oversized)

    refute_receive {:node_event, "node.invoke.control", _payload}
  end

  test "streams ordered events only to the invocation recipient and deduplicates retries" do
    parent = self()
    recipient = spawn(fn -> relay(parent, :stream_recipient) end)
    on_exit(fn -> Process.exit(recipient, :kill) end)
    node_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)

    assert {:ok, invoke_id} =
             NodeRegistry.invoke(node_id, "coding_agent.run", %{}, recipient: recipient)

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    first = %{"type" => "delta", "text" => "one"}
    second = %{"type" => "delta", "text" => "two"}

    assert {:error, :sequence_gap} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 2, second)

    refute_receive {:stream_recipient, {:lemon_node_event, _, _, _}}

    assert {:ok, :accepted} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, first)

    assert {:ok, :duplicate} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, first)

    assert {:error, :sequence_gap} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 3, second)

    assert {:ok, :accepted} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 2, second)

    assert {:ok, :duplicate} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, first)

    assert_receive {:stream_recipient, {:lemon_node_event, ^invoke_id, first_seq, first_event}}
    assert first_seq == 1
    assert first_event == first
    assert_receive {:stream_recipient, {:lemon_node_event, ^invoke_id, second_seq, second_event}}
    assert second_seq == 2
    assert second_event == second
    refute_receive {:stream_recipient, {:lemon_node_event, _, _, _}}
    refute_receive {:lemon_node_event, _, _, _}
  end

  test "stream ownership rejects wrong nodes and stale connections or generations" do
    node_id = stream_node_id()
    other = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(other, :kill) end)
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 7)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    event = %{"type" => "started"}

    assert {:error, :wrong_node} =
             NodeRegistry.event_session("wrong-node", self(), 7, invoke_id, 1, event)

    assert {:error, :stale_session} =
             NodeRegistry.event_session(node_id, other, 7, invoke_id, 1, event)

    assert {:error, :stale_session} =
             NodeRegistry.event_session(node_id, self(), 6, invoke_id, 1, event)

    refute_receive {:lemon_node_event, _, _, _}

    assert {:ok, :accepted} =
             NodeRegistry.event_session(node_id, self(), 7, invoke_id, 1, event)

    assert_receive {:lemon_node_event, ^invoke_id, 1, ^event}

    assert {:error, :stale_session} =
             NodeRegistry.event_session(node_id, other, 7, invoke_id, 1, event)
  end

  test "streams only coding-agent invocations and rejects invalid sequence or event types" do
    node_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)
    assert {:ok, other_id} = NodeRegistry.invoke(node_id, "node.host.info", %{})
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    event = %{"type" => "delta", "text" => "valid"}

    assert {:error, :unsupported} =
             NodeRegistry.event_session(node_id, self(), 1, other_id, 1, event)

    for seq <- [0, -1, 1.0, "1", nil] do
      assert {:error, :invalid_seq} =
               NodeRegistry.event_session(node_id, self(), 1, invoke_id, seq, event)
    end

    for invalid <- [%{"type" => "completed"}, %{"type" => "checkpoint_unknown"}, %{}, []] do
      assert {:error, :invalid_event_type} =
               NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, invalid)
    end

    refute_receive {:lemon_node_event, _, _, _}
  end

  test "accepts each allowlisted event envelope without decoding its typed fields" do
    node_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})

    types =
      ~w(delta started action checkpoint_created checkpoint_restored checkpoint_deleted approval_requested)

    for {type, seq} <- Enum.with_index(types, 1) do
      event = %{"type" => type, "data" => %{"arbitrary" => [true, nil, 42]}}

      assert {:ok, :accepted} =
               NodeRegistry.event_session(node_id, self(), 1, invoke_id, seq, event)

      assert_receive {:lemon_node_event, ^invoke_id, ^seq, ^event}
    end
  end

  test "event byte depth item and JSON-safety limits reject without advancing sequence" do
    node_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    base = %{"type" => "delta", "text" => ""}
    text_bytes = 65_536 - byte_size(Jason.encode!(base))
    exact = %{base | "text" => String.duplicate("x", text_bytes)}
    oversized = %{base | "text" => String.duplicate("x", text_bytes + 1)}

    assert {:error, {:invalid_payload, :max_bytes}} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, oversized)

    deep = Enum.reduce(1..33, nil, fn _, acc -> [acc] end)
    wide = List.duplicate(nil, LemonCore.JSONPayload.default_max_items())

    for {value, kind} <- [{deep, :max_depth}, {wide, :max_items}, {self(), :not_json_safe}] do
      event = %{"type" => "action", "data" => value}

      assert {:error, {:invalid_payload, ^kind}} =
               NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, event)
    end

    refute_receive {:lemon_node_event, _, _, _}

    assert {:ok, :accepted} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, exact)

    assert_receive {:lemon_node_event, ^invoke_id, 1, ^exact}

    assert {:error, {:invalid_payload, :max_bytes}} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, oversized)
  end

  test "completed and cancelled invocations reject further events and approval decisions" do
    node_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)
    event = %{"type" => "delta", "text" => "before completion"}

    for terminal <- [:complete, :cancel] do
      assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})

      assert {:ok, :accepted} =
               NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, event)

      assert_receive {:lemon_node_event, ^invoke_id, 1, ^event}

      case terminal do
        :complete ->
          assert :ok = NodeRegistry.complete_session(node_id, self(), 1, invoke_id, %{})

        :cancel ->
          assert :ok = NodeRegistry.cancel(invoke_id)
      end

      assert_receive {:lemon_node_result, ^invoke_id, _}

      assert {:error, :terminal} =
               NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, event)

      assert {:error, :terminal} = NodeRegistry.approval(invoke_id, "approval-1", "deny")
    end
  end

  test "disconnect fails closed and reconnect never replays an old invocation stream" do
    node_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    event = %{"type" => "delta", "text" => "before disconnect"}

    assert {:ok, :accepted} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, event)

    assert_receive {:lemon_node_event, ^invoke_id, 1, ^event}
    assert :ok = NodeRegistry.unregister(node_id, self())

    assert_receive {:lemon_node_result, ^invoke_id, {:error, {:node_disconnected, :disconnected}}}

    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 2)

    for generation <- [1, 2] do
      assert {:error, :terminal} =
               NodeRegistry.event_session(node_id, self(), generation, invoke_id, 1, event)
    end

    assert {:error, :terminal} = NodeRegistry.approval(invoke_id, "approval-1", "approve_once")
    refute_receive {:lemon_node_event, _, _, _}
    refute_receive {:node_event, "node.invoke.approval", _}
    assert {:ok, new_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})

    assert {:ok, :accepted} =
             NodeRegistry.event_session(node_id, self(), 2, new_id, 1, event)

    assert_receive {:lemon_node_event, ^new_id, 1, ^event}
  end

  test "approval dispatch requires the invocation recipient caller and targets only its node" do
    parent = self()
    recipient = spawn(fn -> approval_recipient(parent) end)
    other = spawn(fn -> relay(parent, :other_node) end)

    on_exit(fn ->
      Process.exit(recipient, :kill)
      Process.exit(other, :kill)
    end)

    node_id = stream_node_id()
    other_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)
    assert :ok = NodeRegistry.register_session(other_id, other_id, other, 1)

    assert {:ok, invoke_id} =
             NodeRegistry.invoke(node_id, "coding_agent.run", %{"runId" => "bound-run"},
               recipient: recipient
             )

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    assert {:error, :forbidden} = NodeRegistry.approval(invoke_id, "approval-1", "approve_once")
    refute_receive {:node_event, "node.invoke.approval", _}

    for decision <- ~w(approve_once approve_session approve_agent approve_global deny) do
      send(recipient, {:resolve, invoke_id, "approval-1", decision})
      assert_receive {:approval_reply, :ok}

      assert_receive {:node_event, "node.invoke.approval",
                      %{
                        "nodeId" => ^node_id,
                        "invokeId" => ^invoke_id,
                        "runId" => "bound-run",
                        "approvalId" => "approval-1",
                        "decision" => ^decision
                      }}
    end

    refute_receive {:other_node, {:node_event, "node.invoke.approval", _}}
  end

  test "approval validates decision identity payload bounds and supported invocation method" do
    node_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})

    for decision <- ["allow", "approve", :approve_once, nil] do
      assert {:error, :invalid_decision} =
               NodeRegistry.approval(invoke_id, "approval-1", decision)
    end

    for approval_id <- ["", "  ", nil, 123] do
      assert {:error, :invalid_approval_id} =
               NodeRegistry.approval(invoke_id, approval_id, "deny")
    end

    assert {:error, {:invalid_payload, :max_bytes}} =
             NodeRegistry.approval(invoke_id, String.duplicate("x", 65_536), "deny")

    assert {:ok, other_id} = NodeRegistry.invoke(node_id, "node.host.info", %{})
    assert {:error, :unsupported} = NodeRegistry.approval(other_id, "approval-1", "deny")
    refute_receive {:node_event, "node.invoke.approval", _}
    assert :ok = NodeRegistry.approval(invoke_id, "approval-1", "deny")
    assert_receive {:node_event, "node.invoke.approval", %{"invokeId" => ^invoke_id}}
  end

  test "credential replacement cancels streams and approvals pinned to the previous session" do
    node_id = stream_node_id()
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 2)

    assert_receive {:lemon_node_result, ^invoke_id, {:error, {:node_disconnected, :reconnected}}}

    assert {:error, :terminal} =
             NodeRegistry.event_session(
               node_id,
               self(),
               2,
               invoke_id,
               1,
               %{"type" => "started"}
             )

    assert {:error, :terminal} = NodeRegistry.approval(invoke_id, "approval-1", "deny")
    refute_receive {:node_event, "node.invoke.approval", _}
  end

  test "node process death closes an active stream before any late retry can be delivered" do
    parent = self()
    node_id = stream_node_id()
    node = spawn(fn -> relay(parent, :stream_connection) end)
    assert :ok = NodeRegistry.register_session(node_id, node_id, node, 1)
    assert {:ok, invoke_id} = NodeRegistry.invoke(node_id, "coding_agent.run", %{})
    assert_receive {:stream_connection, {:node_event, "node.invoke.request", _}}
    event = %{"type" => "delta", "text" => "live"}

    assert {:ok, :accepted} =
             NodeRegistry.event_session(node_id, node, 1, invoke_id, 1, event)

    assert_receive {:lemon_node_event, ^invoke_id, 1, ^event}
    Process.exit(node, :kill)

    assert_receive {:lemon_node_result, ^invoke_id,
                    {:error, {:node_disconnected, :disconnected}}},
                   1_000

    assert {:error, :terminal} =
             NodeRegistry.event_session(node_id, node, 1, invoke_id, 1, event)

    assert {:error, :terminal} = NodeRegistry.approval(invoke_id, "approval-1", "deny")
    refute_receive {:lemon_node_event, _, _, _}
  end

  test "recipient death cancels a streaming invocation and invalidates its approvals" do
    parent = self()
    node_id = stream_node_id()
    recipient = spawn(fn -> relay(parent, :dying_recipient) end)
    assert :ok = NodeRegistry.register_session(node_id, node_id, self(), 1)

    assert {:ok, invoke_id} =
             NodeRegistry.invoke(node_id, "coding_agent.run", %{}, recipient: recipient)

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invoke_id}}
    event = %{"type" => "started"}

    assert {:ok, :accepted} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 1, event)

    assert_receive {:dying_recipient, {:lemon_node_event, ^invoke_id, 1, ^event}}
    Process.exit(recipient, :kill)
    assert_receive {:node_event, "node.invoke.cancel", %{"invokeId" => ^invoke_id}}, 1_000

    assert {:error, :terminal} =
             NodeRegistry.event_session(node_id, self(), 1, invoke_id, 2, event)

    assert {:error, :terminal} = NodeRegistry.approval(invoke_id, "approval-1", "deny")
    refute_receive {:dying_recipient, {:lemon_node_event, _, _, _}}
  end

  defp stream_node_id, do: "stream-node-#{System.unique_integer([:positive])}"

  defp approval_recipient(parent) do
    receive do
      {:resolve, invoke_id, approval_id, decision} ->
        send(parent, {:approval_reply, NodeRegistry.approval(invoke_id, approval_id, decision)})
        approval_recipient(parent)

      _message ->
        approval_recipient(parent)
    end
  end

  defp relay(parent, tag) do
    receive do
      message ->
        send(parent, {tag, message})
        relay(parent, tag)
    end
  end
end
