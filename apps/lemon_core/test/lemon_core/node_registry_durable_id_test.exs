defmodule LemonCore.NodeRegistryDurableIDTest do
  use ExUnit.Case, async: false
  alias LemonCore.NodeRegistry

  test "ID-only resolution and dispatch never select another node with the victim ID as its name" do
    victim = "victim-#{System.unique_integer([:positive])}"
    attacker = "attacker-#{System.unique_integer([:positive])}"
    owner = self()
    attacker_pid = spawn(fn -> relay(owner) end)

    on_exit(fn ->
      NodeRegistry.unregister(victim, owner)
      NodeRegistry.unregister(attacker, attacker_pid)
      Process.exit(attacker_pid, :kill)
    end)

    assert :ok = NodeRegistry.register(victim, "victim-name-#{victim}", self())
    assert :ok = NodeRegistry.register(attacker, victim, attacker_pid)
    assert {:ok, %{id: ^victim}} = NodeRegistry.resolve_id(victim)
    assert {:ok, %{id: ^victim}} = NodeRegistry.resolve(victim)
    assert NodeRegistry.online?(victim)
    assert {:ok, legacy} = NodeRegistry.invoke(victim, "work.run", %{})

    assert_receive {:node_event, "node.invoke.request",
                    %{"invokeId" => ^legacy, "nodeId" => ^victim}}

    assert :ok = NodeRegistry.complete_session(victim, self(), 0, legacy, %{})
    assert_receive {:lemon_node_result, ^legacy, {:ok, %{}}}
    refute_receive {:attacker_received, _}

    assert {:ok, invoke_id} =
             NodeRegistry.invoke_node(victim, "node.secrets.set", %{
               "name" => "token",
               "value" => "private"
             })

    assert_receive {:node_event, "node.invoke.request",
                    %{"invokeId" => ^invoke_id, "nodeId" => ^victim}}

    refute_receive {:attacker_received, _}
    assert :ok = NodeRegistry.complete_session(victim, self(), 0, invoke_id, %{"set" => true})
    assert_receive {:lemon_node_result, ^invoke_id, {:ok, %{"set" => true}}}

    assert :ok = NodeRegistry.unregister(victim, self())
    assert {:error, :not_found} = NodeRegistry.resolve_id(victim)
    assert {:error, :not_found} = NodeRegistry.resolve(victim)
    refute NodeRegistry.online?(victim)
    assert {:error, {:node_offline, ^victim}} = NodeRegistry.invoke(victim, "work.run", %{})
    assert {:ok, %{id: ^attacker}} = NodeRegistry.resolve(attacker)

    assert {:error, {:node_offline, ^victim}} =
             NodeRegistry.invoke_node(victim, "node.fs.read", %{"path" => "private"})

    assert {:error, {:node_offline, ^victim}} =
             NodeRegistry.invoke_node(victim, "node.shell.open", %{"cwd" => "."})

    refute_receive {:attacker_received, _}
  end

  test "unique live names resolve exact durable identity and privacy descriptor is one predicate" do
    id = "human-id-#{System.unique_integer([:positive])}"
    name = "human-name-" <> id
    owner = self()

    capable = %{
      capabilities: %{
        "coding_agent.run" => %{
          "version" => 2,
          "executionContext" => %{"version" => 1},
          "nativePrivacyContext" => %{"version" => 1}
        }
      }
    }

    on_exit(fn -> NodeRegistry.unregister(id, owner) end)
    assert :ok = NodeRegistry.register_session(id, name, owner, 3, capable)

    assert {:ok, %{id: ^id, pid: ^owner, generation: 3, metadata: metadata}} =
             NodeRegistry.resolve(name)

    assert {:ok, %{id: ^id}} = NodeRegistry.resolve(id)
    assert NodeRegistry.native_privacy_context_supported?(metadata)

    assert NodeRegistry.native_privacy_context_supported?(%{
             "capabilities" => %{
               "coding_agent.run" => %{
                 "version" => 2,
                 "executionContext" => %{"version" => 1},
                 "nativePrivacyContext" => %{"version" => 1}
               }
             }
           })

    refute NodeRegistry.native_privacy_context_supported?(%{
             capabilities: %{"coding_agent.run" => %{"nativePrivacyContext" => %{"version" => 1}}}
           })

    refute NodeRegistry.native_privacy_context_supported?(%{
             capabilities: %{"coding_agent.run" => %{"version" => 1}}
           })

    for context_version <- [nil, 0, 2] do
      refute NodeRegistry.native_privacy_context_supported?(%{
               capabilities: %{
                 "coding_agent.run" => %{
                   "version" => 2,
                   "executionContext" => %{"version" => context_version},
                   "nativePrivacyContext" => %{"version" => 1}
                 }
               }
             })
    end

    refute NodeRegistry.native_privacy_context_supported?(%{})
    refute NodeRegistry.native_privacy_context_supported?(nil)
    assert {:error, :not_found} = NodeRegistry.resolve("missing-" <> name)
  end

  test "native execution grants use their bounded item policy without widening unrelated methods or caller byte limits" do
    id = "large-policy-#{System.unique_integer([:positive])}"
    owner = self()
    assert :ok = NodeRegistry.register(id, id, owner)
    on_exit(fn -> NodeRegistry.unregister(id, owner) end)
    tools = Enum.map(1..16_384, &"mcp:fixture/tool-#{&1}")
    args = %{"version" => 1, "prompt" => "execute", "toolPolicy" => %{"allow" => tools}}

    assert {:ok, invocation} =
             NodeRegistry.invoke_node(id, "coding_agent.run", args, max_payload_bytes: 16_777_216)

    assert_receive {:node_event, "node.invoke.request",
                    %{"invokeId" => ^invocation, "args" => ^args}}

    assert :ok = NodeRegistry.complete_session(id, owner, 0, invocation, %{})
    assert_receive {:lemon_node_result, ^invocation, {:ok, %{}}}

    assert {:error, {:invalid_payload, {:max_items, _}}} =
             NodeRegistry.invoke_node(id, "node.fs.read", args, max_payload_bytes: 16_777_216)

    assert {:error, {:invalid_payload, {:max_bytes, 16_384}}} =
             NodeRegistry.invoke_node(id, "coding_agent.run", args, max_payload_bytes: 16_384)
  end

  test "a reconnect after capability inspection cannot receive session-pinned private arguments" do
    id = "privacy-reconnect-#{System.unique_integer([:positive])}"
    owner = self()
    replacement = spawn(fn -> relay(owner) end)

    capable = %{
      capabilities: %{
        "coding_agent.run" => %{
          "version" => 2,
          "executionContext" => %{"version" => 1},
          "nativePrivacyContext" => %{"version" => 1}
        }
      }
    }

    old_protocol = %{capabilities: %{"coding_agent.run" => %{"version" => 1}}}

    on_exit(fn ->
      NodeRegistry.unregister(id, owner)
      NodeRegistry.unregister(id, replacement)
      Process.exit(replacement, :kill)
    end)

    assert :ok = NodeRegistry.register(id, id, owner, capable)
    assert {:ok, inspected} = NodeRegistry.resolve_id(id)

    assert inspected.metadata.capabilities["coding_agent.run"]["nativePrivacyContext"]["version"] ==
             1

    assert :ok = NodeRegistry.register(id, id, replacement, old_protocol)
    args = %{"version" => 1, "prompt" => "private scope contents"}

    assert {:error, {:node_connection_changed, ^id}} =
             NodeRegistry.invoke_node(id, "coding_agent.run", args,
               expected_pid: inspected.pid,
               required_native_privacy_context: 1
             )

    assert {:error, {:native_privacy_context_unsupported, ^id}} =
             NodeRegistry.invoke_node(id, "coding_agent.run", args,
               required_native_privacy_context: 1
             )

    refute_receive {:attacker_received, {:node_event, "node.invoke.request", _}}
    refute_receive {:node_event, "node.invoke.request", _}

    for version <- [nil, 0, 1, 2, 3] do
      unknown = %{
        capabilities: %{
          "coding_agent.run" => %{
            "version" => version,
            "nativePrivacyContext" => %{"version" => 1}
          }
        }
      }

      assert :ok = NodeRegistry.register(id, id, replacement, unknown)

      assert {:error, {:native_privacy_context_unsupported, ^id}} =
               NodeRegistry.invoke_node(id, "coding_agent.run", args,
                 expected_pid: replacement,
                 required_native_privacy_context: 1
               )

      refute_receive {:attacker_received, {:node_event, "node.invoke.request", _}}
    end

    assert :ok = NodeRegistry.register(id, id, owner, capable)

    assert {:ok, invocation} =
             NodeRegistry.invoke_node(id, "coding_agent.run", args,
               expected_pid: owner,
               required_native_privacy_context: 1
             )

    assert_receive {:node_event, "node.invoke.request",
                    %{"invokeId" => ^invocation, "args" => ^args}}

    assert :ok = NodeRegistry.complete_session(id, owner, 0, invocation, %{})
    assert_receive {:lemon_node_result, ^invocation, {:ok, %{}}}
  end

  test "session pins protect scoped non-native calls and invalid requirements fail before dispatch" do
    id = "scoped-reconnect-#{System.unique_integer([:positive])}"
    owner = self()
    replacement = spawn(fn -> relay(owner) end)

    on_exit(fn ->
      NodeRegistry.unregister(id, replacement)
      Process.exit(replacement, :kill)
    end)

    assert :ok = NodeRegistry.register(id, id, owner)
    assert {:ok, inspected} = NodeRegistry.resolve_id(id)
    assert :ok = NodeRegistry.register(id, id, replacement)

    assert {:error, {:node_connection_changed, ^id}} =
             NodeRegistry.invoke_node(id, "memory.long_term.write", %{"text" => "private"},
               expected_pid: inspected.pid
             )

    assert {:error, :invalid_expected_node_pid} =
             NodeRegistry.invoke_node(id, "memory.long_term.write", %{},
               expected_pid: "not-a-pid"
             )

    assert {:error, :invalid_native_privacy_context_requirement} =
             NodeRegistry.invoke_node(id, "coding_agent.run", %{},
               required_native_privacy_context: 2
             )

    assert {:error, :invalid_native_privacy_context_requirement} =
             NodeRegistry.invoke_node(id, "node.fs.read", %{}, required_native_privacy_context: 1)

    refute_receive {:attacker_received, {:node_event, "node.invoke.request", _}}
  end

  test "proof secret provisioning pins generation even when the same connection PID is reused" do
    id = "proof-generation-#{System.unique_integer([:positive])}"
    owner = self()

    capable = %{
      capabilities: %{
        "coding_agent.run" => %{
          "version" => 2,
          "executionContext" => %{"version" => 1},
          "nativePrivacyContext" => %{"version" => 1}
        }
      }
    }

    on_exit(fn -> NodeRegistry.unregister(id, owner) end)
    assert :ok = NodeRegistry.register_session(id, id, owner, 1, capable)
    assert {:ok, %{pid: ^owner, generation: 1} = inspected} = NodeRegistry.resolve_id(id)
    assert :ok = NodeRegistry.register_session(id, id, owner, 2, capable)

    args = %{
      "name" => "lemon_bot/invocations/followup",
      "value" => "private",
      "operationId" => "followup"
    }

    assert {:error, {:node_connection_changed, ^id}} =
             NodeRegistry.invoke_node(id, "node.secrets.set", args,
               expected_pid: inspected.pid,
               expected_generation: inspected.generation,
               required_native_privacy_context: 1
             )

    refute_receive {:node_event, "node.invoke.request", _}

    assert {:error, :invalid_expected_node_generation} =
             NodeRegistry.invoke_node(id, "node.secrets.set", args, expected_generation: -1)

    assert {:ok, invocation} =
             NodeRegistry.invoke_node(id, "node.secrets.set", args,
               expected_pid: owner,
               expected_generation: 2,
               required_native_privacy_context: 1
             )

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^invocation}}
    assert :ok = NodeRegistry.complete_session(id, owner, 2, invocation, %{"set" => true})
    assert_receive {:lemon_node_result, ^invocation, {:ok, %{"set" => true}}}

    assert :ok =
             NodeRegistry.register_session(id, id, owner, 3, %{
               capabilities: %{"coding_agent.run" => %{"version" => 1}}
             })

    assert {:error, {:native_privacy_context_unsupported, ^id}} =
             NodeRegistry.invoke_node(id, "node.secrets.set", args,
               expected_pid: owner,
               expected_generation: 3,
               required_native_privacy_context: 1
             )

    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "noninteractive process protocol is admitted atomically and broker generation is authoritative" do
    id = "process-admission-#{System.unique_integer([:positive])}"
    owner = self()
    on_exit(fn -> NodeRegistry.unregister(id, owner) end)
    assert :ok = NodeRegistry.register_session(id, id, owner, 7, %{})

    assert {:error, {:process_execution_unsupported, ^id}} =
             NodeRegistry.invoke_node(id, "node.process.run", %{}, required_process_execution: 1)

    refute_receive {:node_event, "node.invoke.request", _}

    assert {:error, :invalid_process_execution_requirement} =
             NodeRegistry.invoke_node(id, "node.shell.open", %{}, required_process_execution: 1)

    assert {:error, :invalid_process_execution_requirement} =
             NodeRegistry.invoke_node(id, "node.process.run", %{}, required_process_execution: 2)

    capabilities =
      Map.new(
        ~w(node.process.run node.process.get node.process.cancel),
        &{&1, %{"version" => 1}}
      )

    assert :ok = NodeRegistry.register_session(id, id, owner, 7, %{capabilities: capabilities})
    args = %{"processId" => "fixed-id", "nodeGeneration" => 999}

    assert {:ok, invocation} =
             NodeRegistry.invoke_node(id, "node.process.run", args,
               expected_pid: owner,
               expected_generation: 7,
               required_process_execution: 1
             )

    assert_receive {:node_event, "node.invoke.request",
                    %{
                      "invokeId" => ^invocation,
                      "nodeId" => ^id,
                      "nodeGeneration" => 7,
                      "args" => ^args
                    }}

    assert :ok = NodeRegistry.complete_session(id, owner, 7, invocation, %{})
    assert_receive {:lemon_node_result, ^invocation, {:ok, %{}}}

    assert {:ok, cancelled} =
             NodeRegistry.invoke_node(id, "node.process.run", args,
               expected_pid: owner,
               expected_generation: 7,
               required_process_execution: 1
             )

    assert_receive {:node_event, "node.invoke.request", %{"invokeId" => ^cancelled}}
    assert :ok = NodeRegistry.cancel(cancelled, :test_cancel)

    assert_receive {:node_event, "node.invoke.cancel",
                    %{"invokeId" => ^cancelled, "nodeId" => ^id, "nodeGeneration" => 7}}

    assert_receive {:lemon_node_result, ^cancelled, {:error, :test_cancel}}
    assert :ok = NodeRegistry.register_session(id, id, owner, 8, %{capabilities: capabilities})

    assert {:error, {:node_connection_changed, ^id}} =
             NodeRegistry.invoke_node(id, "node.process.get", %{},
               expected_pid: owner,
               expected_generation: 7,
               required_process_execution: 1
             )

    assert :ok =
             NodeRegistry.register_session(id, id, owner, 9, %{
               capabilities: Map.delete(capabilities, "node.process.cancel")
             })

    assert {:error, {:process_execution_unsupported, ^id}} =
             NodeRegistry.invoke_node(id, "node.process.run", %{}, required_process_execution: 1)

    refute_receive {:node_event, "node.invoke.request", _}
  end

  defp relay(owner) do
    receive do
      event ->
        send(owner, {:attacker_received, event})
        relay(owner)
    end
  end
end
