defmodule LemonCore.EngineInfoBridgeTest do
  # Mutates the bridge configuration, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  alias LemonCore.EngineInfoBridge

  defmodule BridgeTransportRegistryStub do
    def start_link, do: Agent.start_link(fn -> :ok end, name: __MODULE__)
    def list_transports, do: [:email, :webhook]
    def enabled_transports, do: [{:email, EmailTransport}]
    def get_transport(:email), do: EmailTransport
    def get_transport(_id), do: nil
  end

  defmodule NoApiStub do
    @moduledoc false
    def unrelated, do: :ok
  end

  setup do
    original = Application.get_env(:lemon_core, :engine_info_bridge)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :engine_info_bridge)
      else
        Application.put_env(:lemon_core, :engine_info_bridge, original)
      end
    end)

    Application.delete_env(:lemon_core, :engine_info_bridge)
    :ok
  end

  describe "with no runtime capabilities configured" do
    test "retained capabilities degrade rather than raising" do
      refute EngineInfoBridge.available?(:transport_registry)
      refute EngineInfoBridge.running?(:transport_registry)

      assert EngineInfoBridge.list_transports() == {:error, :unavailable}
      assert EngineInfoBridge.enabled_transports() == {:error, :unavailable}
      assert EngineInfoBridge.get_transport(:email) == {:error, :unavailable}
    end
  end

  describe "configure/1" do
    test "registers the capability" do
      assert EngineInfoBridge.configure(transport_registry: BridgeTransportRegistryStub) == :ok
      assert EngineInfoBridge.impl(:transport_registry) == BridgeTransportRegistryStub
    end

    test "rejects a non-module value" do
      assert EngineInfoBridge.configure(transport_registry: "nope") ==
               {:error, {:invalid_implementation, :transport_registry, {:not_a_module, "nope"}}}
    end

    test "rejects a module that does not implement the capability" do
      assert {:error,
              {:invalid_implementation, :transport_registry,
               {:missing_callbacks, NoApiStub, missing}}} =
               EngineInfoBridge.configure(transport_registry: NoApiStub)

      assert Keyword.has_key?(missing, :list_transports)
      assert EngineInfoBridge.impl(:transport_registry) == nil
    end

    test "ignores keys that are not capabilities" do
      assert EngineInfoBridge.configure(transport_registry: BridgeTransportRegistryStub, bogus: 1) ==
               :ok

      assert Map.keys(EngineInfoBridge.config()) == [:transport_registry]
    end
  end

  describe "transport registry capability" do
    setup do
      {:ok, pid} = BridgeTransportRegistryStub.start_link()
      EngineInfoBridge.configure(transport_registry: BridgeTransportRegistryStub)
      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
      :ok
    end

    test "answers the three introspection calls" do
      assert EngineInfoBridge.list_transports() == {:ok, [:email, :webhook]}
      assert EngineInfoBridge.enabled_transports() == {:ok, [{:email, EmailTransport}]}
      assert EngineInfoBridge.get_transport(:email) == {:ok, EmailTransport}
    end

    test "running?/1 tracks the registry process" do
      assert EngineInfoBridge.running?(:transport_registry)
      Agent.stop(BridgeTransportRegistryStub)
      refute EngineInfoBridge.running?(:transport_registry)
    end
  end
end
