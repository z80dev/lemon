defmodule LemonCore.EngineInfoBridgeTest do
  # Mutates the bridge configuration, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  alias LemonCore.{EngineInfoBridge, ResumeToken}

  defmodule BridgeEngineRegistryStub do
    def start_link, do: Agent.start_link(fn -> :ok end, name: __MODULE__)
    def list_engines, do: ["stub", "echo"]

    def extract_resume("stub resume " <> value),
      do: {:ok, %ResumeToken{engine: "stub", value: value}}

    def extract_resume(_text), do: :none
  end

  defmodule BridgeTransportRegistryStub do
    def start_link, do: Agent.start_link(fn -> :ok end, name: __MODULE__)
    def list_transports, do: [:email, :webhook]
    def enabled_transports, do: [{:email, EmailTransport}]
    def get_transport(:email), do: EmailTransport
    def get_transport(_id), do: nil
  end

  defmodule GatewayConfigStub do
    def replacement_config, do: %{bindings: [%{transport: :demo}]}
  end

  defmodule KeywordConfigStub do
    def replacement_config, do: [enable_demo: true]
  end

  defmodule ListConfigStub do
    def replacement_config, do: [%{transport: :demo}]
  end

  defmodule EmptyConfigStub do
    def replacement_config, do: nil
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

  describe "with no engine runtime configured" do
    test "every capability degrades rather than raising" do
      refute EngineInfoBridge.available?(:engine_registry)
      refute EngineInfoBridge.running?(:transport_registry)

      assert EngineInfoBridge.extract_resume("codex resume abc") == :none
      assert EngineInfoBridge.list_engines() == []
      assert EngineInfoBridge.list_transports() == {:error, :unavailable}
      assert EngineInfoBridge.enabled_transports() == {:error, :unavailable}
      assert EngineInfoBridge.get_transport(:email) == {:error, :unavailable}
      assert EngineInfoBridge.gateway_config() == :none
    end
  end

  describe "configure/1" do
    test "registers capabilities and leaves others alone" do
      assert EngineInfoBridge.configure(engine_registry: BridgeEngineRegistryStub) == :ok
      assert EngineInfoBridge.impl(:engine_registry) == BridgeEngineRegistryStub
      assert EngineInfoBridge.impl(:transport_registry) == nil

      assert EngineInfoBridge.configure(transport_registry: BridgeTransportRegistryStub) == :ok
      assert EngineInfoBridge.impl(:engine_registry) == BridgeEngineRegistryStub
      assert EngineInfoBridge.impl(:transport_registry) == BridgeTransportRegistryStub
    end

    test "rejects a non-module value" do
      assert EngineInfoBridge.configure(engine_registry: "nope") == {:error, :invalid_config}
    end

    test "ignores keys that are not capabilities" do
      assert EngineInfoBridge.configure(engine_registry: BridgeEngineRegistryStub, bogus: 1) == :ok
      assert Map.keys(EngineInfoBridge.config()) == [:engine_registry]
    end
  end

  describe "engine registry capability" do
    setup do
      {:ok, pid} = BridgeEngineRegistryStub.start_link()
      EngineInfoBridge.configure(engine_registry: BridgeEngineRegistryStub)
      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
      :ok
    end

    test "extracts a resume token through the runtime" do
      assert {:ok, %ResumeToken{engine: "stub", value: "abc"}} =
               EngineInfoBridge.extract_resume("stub resume abc")
    end

    test "reports :none for text the runtime does not recognise" do
      assert EngineInfoBridge.extract_resume("not a resume line") == :none
    end

    test "lists engines" do
      assert EngineInfoBridge.list_engines() == ["stub", "echo"]
    end

    test "a configured but stopped registry degrades" do
      Agent.stop(BridgeEngineRegistryStub)

      assert EngineInfoBridge.extract_resume("stub resume abc") == :none
      assert EngineInfoBridge.list_engines() == []
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

  describe "gateway config capability" do
    test "returns a map as-is" do
      EngineInfoBridge.configure(gateway_config: GatewayConfigStub)

      assert {:ok, %{bindings: [%{transport: :demo}]}} = EngineInfoBridge.gateway_config()
    end

    test "normalizes a keyword list into a map" do
      EngineInfoBridge.configure(gateway_config: KeywordConfigStub)

      assert EngineInfoBridge.gateway_config() == {:ok, %{enable_demo: true}}
    end

    test "treats a bare list as bindings, matching the previous reader" do
      EngineInfoBridge.configure(gateway_config: ListConfigStub)

      assert EngineInfoBridge.gateway_config() == {:ok, %{bindings: [%{transport: :demo}]}}
    end

    test "reports :none when the runtime holds no replacement config" do
      EngineInfoBridge.configure(gateway_config: EmptyConfigStub)

      assert EngineInfoBridge.gateway_config() == :none
    end
  end
end
