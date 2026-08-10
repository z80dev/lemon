defmodule LemonPlatformTest.HelpersTest do
  use ExUnit.Case, async: true

  doctest LemonPlatformTest

  defmodule IncompleteBackend do
    @moduledoc false
    # Deliberately not a compliant backend: two of the six required callbacks,
    # and no `@behaviour` declaration (which is how a real one arrives — the
    # author copied the callbacks they needed and stopped).
    def init(_opts), do: {:ok, %{}}
    def get(state, _table, _key), do: {:ok, nil, state}
  end

  describe "declares_behaviour?/2" do
    test "sees a declared behaviour" do
      assert LemonPlatformTest.declares_behaviour?(
               LemonCore.Store.EtsBackend,
               LemonCore.Store.Backend
             )

      assert LemonPlatformTest.declares_behaviour?(
               LemonChannels.Adapters.Telegram,
               LemonChannels.Plugin
             )

      assert LemonPlatformTest.declares_behaviour?(LemonGateway.Engines.Echo, LemonGateway.Engine)

      assert LemonPlatformTest.declares_behaviour?(
               LemonMemory.Providers.Local,
               LemonMemory.Provider
             )
    end

    test "is false for a module that implements the callbacks without declaring them" do
      refute LemonPlatformTest.declares_behaviour?(
               LemonCore.Store.EtsBackend,
               LemonChannels.Plugin
             )
    end

    test "is false for a module that does not exist" do
      refute LemonPlatformTest.declares_behaviour?(No.Such.Module, LemonCore.Store.Backend)
    end
  end

  describe "callbacks/1" do
    test "splits required from optional" do
      %{required: required, optional: optional} =
        LemonPlatformTest.callbacks(LemonCore.Store.Backend)

      assert Enum.sort(optional) == [list_recent: 3, ping: 1]
      assert {:put_new, 4} in required
      refute {:ping, 1} in required
    end

    test "raises for a module that is not a behaviour" do
      assert_raise ArgumentError, fn -> LemonPlatformTest.callbacks(No.Such.Behaviour) end
    end
  end

  describe "missing_callbacks/2" do
    test "is empty for a compliant implementation" do
      assert LemonPlatformTest.missing_callbacks(
               LemonCore.Store.EtsBackend,
               LemonCore.Store.Backend
             ) ==
               []
    end

    test "lists what an incomplete implementation still owes" do
      missing = LemonPlatformTest.missing_callbacks(IncompleteBackend, LemonCore.Store.Backend)

      assert Enum.sort(missing) == [delete: 3, list: 2, put: 4, put_new: 4]
    end
  end

  describe "resolve/2" do
    test "calls a {module, function} supplier with the context" do
      assert LemonPlatformTest.resolve({__MODULE__, :supplier}, %{tmp_dir: "/somewhere"}) ==
               [path: "/somewhere"]
    end

    test "passes any other value through untouched" do
      assert LemonPlatformTest.resolve([path: "/fixed"], %{}) == [path: "/fixed"]
      assert LemonPlatformTest.resolve(nil, %{}) == nil
    end
  end

  def supplier(context), do: [path: context.tmp_dir]
end
