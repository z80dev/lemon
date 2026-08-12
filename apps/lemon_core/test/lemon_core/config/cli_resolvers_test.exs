defmodule LemonCore.Config.CliResolversTest do
  @moduledoc """
  The generic half of the CLI config contract.

  Core resolves the `cli` section through whatever resolvers are registered;
  what any vendor's section means lives with that vendor. So these tests use a
  stub resolver only — the five real vendors' defaults are asserted in
  lemon_cli_runners' CliResolversTest, against what its application registered
  at boot.
  """

  # async: false — registration is global (application env), and the cache
  # invalidation test below observes the shared default ConfigCache instance.
  use ExUnit.Case, async: false

  alias LemonCore.Config.CliResolvers

  @engine "stub_vendor"

  setup do
    # Vendor packages may have registered their real resolvers in this VM
    # (other suites boot them); run each test against an empty registry and
    # restore the previous one — and drop config the empty registry resolved —
    # when the test ends.
    original = Application.fetch_env(:lemon_core, :cli_resolvers)
    Application.put_env(:lemon_core, :cli_resolvers, [])

    on_exit(fn ->
      case original do
        {:ok, resolvers} -> Application.put_env(:lemon_core, :cli_resolvers, resolvers)
        :error -> Application.delete_env(:lemon_core, :cli_resolvers)
      end

      LemonCore.ConfigCache.clear()
    end)

    :ok
  end

  defp stub_resolver(section) do
    %{flag: section["flag"] || "default", extra: section["extra"] || []}
  end

  test "applies a registered resolver to its section under the atom id" do
    :ok = CliResolvers.register(@engine, &stub_resolver/1)

    resolved = CliResolvers.resolve_all(%{@engine => %{"flag" => "on"}})

    assert resolved[:stub_vendor] == %{flag: "on", extra: []}
  end

  test "calls the resolver with %{} for an unconfigured section, so defaults materialize" do
    :ok = CliResolvers.register(@engine, &stub_resolver/1)

    resolved = CliResolvers.resolve_all(%{})

    assert resolved[:stub_vendor] == %{flag: "default", extra: []}
  end

  test "passes unknown sections through as raw maps" do
    :ok = CliResolvers.register(@engine, &stub_resolver/1)

    resolved =
      CliResolvers.resolve_all(%{
        @engine => %{"flag" => "on"},
        "mystery" => %{"anything" => 1}
      })

    assert resolved["mystery"] == %{"anything" => 1}
    assert resolved[:stub_vendor] == %{flag: "on", extra: []}
  end

  test "registering again replaces the resolver for that engine" do
    :ok = CliResolvers.register(@engine, &stub_resolver/1)
    :ok = CliResolvers.register(@engine, fn _section -> %{replaced: true} end)

    assert Enum.count(CliResolvers.list_ids(), &(&1 == @engine)) == 1
    assert CliResolvers.resolve_all(%{})[:stub_vendor] == %{replaced: true}
  end

  test "unregister drops the resolver and the section passes through again" do
    :ok = CliResolvers.register(@engine, &stub_resolver/1)
    :ok = CliResolvers.unregister(@engine)

    refute @engine in CliResolvers.list_ids()

    assert CliResolvers.resolve_all(%{@engine => %{"flag" => "on"}}) ==
             %{@engine => %{"flag" => "on"}}
  end

  test "Agent.resolve routes the cli section through registered resolvers" do
    :ok = CliResolvers.register(@engine, &stub_resolver/1)

    config =
      LemonCore.Config.Agent.resolve(%{
        "runtime" => %{"cli" => %{@engine => %{"flag" => "on"}}}
      })

    assert config.cli[:stub_vendor] == %{flag: "on", extra: []}
  end

  test "registering clears the default ConfigCache so stale resolutions are dropped" do
    assert LemonCore.ConfigCache.available?()

    table = LemonCore.ConfigCache.table_for(LemonCore.ConfigCache)

    # Prime the cache with an entry resolved under the current resolver set.
    _config = LemonCore.ConfigCache.get(System.tmp_dir!())
    assert :ets.info(table, :size) > 0

    :ok = CliResolvers.register(@engine, &stub_resolver/1)

    assert :ets.info(table, :size) == 0
  end
end
