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

  defmodule SmsInboxStub do
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
      assert EngineInfoBridge.sms_inbox_preview_clear() == {:error, :unavailable}
    end
  end

  describe "configure/1" do
    test "registers retained capabilities and leaves others alone" do
      assert EngineInfoBridge.configure(transport_registry: BridgeTransportRegistryStub) == :ok
      assert EngineInfoBridge.impl(:transport_registry) == BridgeTransportRegistryStub
      assert EngineInfoBridge.impl(:sms_inbox) == nil

      assert EngineInfoBridge.configure(sms_inbox: SmsInboxStub) == :ok
      assert EngineInfoBridge.impl(:transport_registry) == BridgeTransportRegistryStub
      assert EngineInfoBridge.impl(:sms_inbox) == SmsInboxStub
    end

    # #697: gateway config is read from `LemonCore.GatewayConfig`, not the bridge.
    test "has no gateway config capability" do
      assert EngineInfoBridge.configure(gateway_config: SmsInboxStub) == :ok
      assert EngineInfoBridge.config() == %{}
      refute function_exported?(EngineInfoBridge, :gateway_config, 0)
    end

    test "rejects a non-module value" do
      assert EngineInfoBridge.configure(transport_registry: "nope") == {:error, :invalid_config}
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
