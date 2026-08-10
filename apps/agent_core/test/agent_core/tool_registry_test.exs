defmodule AgentCore.ToolRegistryTest do
  @moduledoc """
  The registry's two load-bearing rules: `available/1` enforces built-ins-win,
  and a registration is never lost because of when its application started.

  The consumer half of the precedence rule — that the module which actually runs
  for a built-in name is the platform's — is tested from the consumer, in
  `CodingAgent.ToolPrecedenceTest`. It cannot live here: this app is below
  coding_agent, and reaching up would invert the dependency the registry exists
  to keep pointing one way.
  """
  use ExUnit.Case, async: false

  alias AgentCore.ToolRegistry

  defmodule RegistryFakeBash do
    def tool(_cwd, _opts), do: %AgentCore.Types.AgentTool{name: "bash", label: "satellite"}
  end

  defmodule RegistryWeather do
    def tool(_cwd, _opts), do: %AgentCore.Types.AgentTool{name: "weather", label: "satellite"}
  end

  setup do
    original = :persistent_term.get({ToolRegistry, :registered}, [])

    on_exit(fn -> :persistent_term.put({ToolRegistry, :registered}, original) end)

    :persistent_term.put({ToolRegistry, :registered}, [])
    :ok
  end

  describe "precedence" do
    test "available/1 drops a registration colliding with a built-in name" do
      ToolRegistry.register(:bash, RegistryFakeBash)
      ToolRegistry.register(:weather, RegistryWeather)

      available = ToolRegistry.available([:read, :bash, :write])

      assert available == [weather: RegistryWeather]
    end

    test "available/1 keeps registration order" do
      ToolRegistry.register(:weather, RegistryWeather)
      ToolRegistry.register(:bash, RegistryFakeBash)

      assert ToolRegistry.available([]) == [weather: RegistryWeather, bash: RegistryFakeBash]
    end

    test "re-registering a name replaces it in place" do
      ToolRegistry.register(:weather, RegistryWeather)
      ToolRegistry.register(:bash, RegistryFakeBash)
      ToolRegistry.register(:weather, RegistryFakeBash)

      assert ToolRegistry.all() == [weather: RegistryFakeBash, bash: RegistryFakeBash]
    end
  end

  describe "loadability" do
    test "all/0 omits a module that is not in this build" do
      ToolRegistry.register(:weather, RegistryWeather)
      ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")

      assert ToolRegistry.all() == [weather: RegistryWeather]
    end

    test "callers can build tools from all/0 without guarding" do
      ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")
      ToolRegistry.register(:weather, RegistryWeather)

      built = Enum.map(ToolRegistry.all(), fn {_name, module} -> module.tool(".", []) end)

      assert [%AgentCore.Types.AgentTool{name: "weather"}] = built
    end

    test "registering one tool does not drop another whose module is absent" do
      # `all/0` filters, so a read-modify-write through it would delete the
      # absent entry — which is a real state during boot, before the app that
      # owns the module has started.
      ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")
      ToolRegistry.register(:weather, RegistryWeather)

      assert {:ghost, :"Elixir.NoSuchToolModule"} in stored()
    end

    test "unregister removes only its own entry" do
      ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")
      ToolRegistry.register(:weather, RegistryWeather)

      ToolRegistry.unregister(:weather)

      assert stored() == [ghost: :"Elixir.NoSuchToolModule"]
    end
  end

  defp stored, do: :persistent_term.get({ToolRegistry, :registered}, [])
end
