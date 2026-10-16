defmodule LemonAgent.ToolRegistryTest do
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

  alias LemonAgent.ToolRegistry

  defmodule RegistryFakeBash do
    def tool(_cwd, _opts), do: %LemonAgent.Types.AgentTool{name: "bash", label: "satellite"}
  end

  defmodule RegistryWeather do
    def tool(_cwd, _opts), do: %LemonAgent.Types.AgentTool{name: "weather", label: "satellite"}
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

      assert available == [{:weather, RegistryWeather, :unknown}]
    end

    test "available/1 keeps registration order" do
      ToolRegistry.register(:weather, RegistryWeather)
      ToolRegistry.register(:bash, RegistryFakeBash)

      assert ToolRegistry.available([]) == [
               {:weather, RegistryWeather, :unknown},
               {:bash, RegistryFakeBash, :unknown}
             ]
    end

    test "re-registering a name replaces it in place" do
      ToolRegistry.register(:weather, RegistryWeather)
      ToolRegistry.register(:bash, RegistryFakeBash)
      ToolRegistry.register(:weather, RegistryFakeBash)

      assert ToolRegistry.all() == [
               {:weather, RegistryFakeBash, :unknown},
               {:bash, RegistryFakeBash, :unknown}
             ]
    end
  end

  describe "loadability" do
    test "all/0 omits a module that is not in this build" do
      ToolRegistry.register(:weather, RegistryWeather)
      ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")

      assert ToolRegistry.all() == [{:weather, RegistryWeather, :unknown}]
    end

    test "callers can build tools from all/0 without guarding" do
      ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")
      ToolRegistry.register(:weather, RegistryWeather)

      built =
        Enum.map(ToolRegistry.all(), fn {_name, module, _ownership} -> module.tool(".", []) end)

      assert [%LemonAgent.Types.AgentTool{name: "weather"}] = built
    end

    test "registering one tool does not drop another whose module is absent" do
      # `all/0` filters, so a read-modify-write through it would delete the
      # absent entry — which is a real state during boot, before the app that
      # owns the module has started.
      ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")
      ToolRegistry.register(:weather, RegistryWeather)

      assert {:ghost, :"Elixir.NoSuchToolModule", :unknown} in stored()
    end

    test "unregister removes only its own entry" do
      ToolRegistry.register(:ghost, :"Elixir.NoSuchToolModule")
      ToolRegistry.register(:weather, RegistryWeather)

      ToolRegistry.unregister(:weather)

      assert stored() == [{:ghost, :"Elixir.NoSuchToolModule", :unknown}]
    end
  end

  test "native ownership is explicit and replacement defaults back to unknown" do
    ToolRegistry.register(:weather, RegistryWeather, native_process_ownership: :managed)
    assert ToolRegistry.available([]) == [{:weather, RegistryWeather, :managed}]

    ToolRegistry.register(:weather, RegistryFakeBash)
    assert ToolRegistry.available([]) == [{:weather, RegistryFakeBash, :unknown}]
  end

  describe "build_tool/2 ownership" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      original = Application.fetch_env(:lemon_core, :native_process_ledger)
      :ok = LemonCore.NativeProcess.configure!(Path.join(tmp_dir, "native-ledger.dets"))
      ledger = Process.whereis(LemonCore.NativeProcess)

      on_exit(fn ->
        if Process.alive?(ledger), do: GenServer.stop(ledger)

        case original do
          {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
          :error -> Application.delete_env(:lemon_core, :native_process_ledger)
        end
      end)

      :ok
    end

    test "managed construction and failed execution leave the ledger empty" do
      tool =
        ToolRegistry.build_tool(:managed, fn ->
          assert LemonCore.NativeProcess.snapshot() == []

          %LemonAgent.Types.AgentTool{
            name: "managed",
            execute: fn _, _, _, _ ->
              assert LemonCore.NativeProcess.snapshot() == []
              {:error, :execution_failed}
            end
          }
        end)

      assert {:error, :execution_failed} = tool.execute.("call", %{}, nil, nil)
      assert LemonCore.NativeProcess.snapshot() == []
    end

    test "unknown construction and failed execution retain records before effects" do
      tool =
        ToolRegistry.build_tool(:unknown, fn ->
          assert [{_, %{backend: :unsupported, capacity_held: true}, _}] =
                   LemonCore.NativeProcess.snapshot()

          %LemonAgent.Types.AgentTool{
            name: "unknown",
            execute: fn _, _, _, _ ->
              assert length(LemonCore.NativeProcess.snapshot()) == 2
              raise "execution failed"
            end
          }
        end)

      assert_raise RuntimeError, "execution failed", fn ->
        tool.execute.("call", %{}, nil, nil)
      end

      records = LemonCore.NativeProcess.snapshot()
      assert length(records) == 2

      assert Enum.all?(records, fn
               {_, %{backend: :unsupported, capacity_held: true}, _} -> true
               _ -> false
             end)
    end

    test "unknown constructor errors retain the pre-dispatch record" do
      assert_raise RuntimeError, "constructor failed", fn ->
        ToolRegistry.build_tool(:unknown, fn ->
          assert [{_, %{backend: :unsupported, capacity_held: true}, _}] =
                   LemonCore.NativeProcess.snapshot()

          raise "constructor failed"
        end)
      end

      assert [{_, %{backend: :unsupported, capacity_held: true}, _}] =
               LemonCore.NativeProcess.snapshot()
    end
  end

  defp stored, do: :persistent_term.get({ToolRegistry, :registered}, [])
end
