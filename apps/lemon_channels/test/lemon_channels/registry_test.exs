defmodule LemonChannels.RegistryTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Registry

  defmodule SnapshotPlugin do
    @behaviour LemonChannels.Plugin
    @impl true
    def id, do: "registry-snapshot-regression"
    @impl true
    def meta, do: %{label: "Registry snapshot", capabilities: %{}, docs: nil}
    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
    @impl true
    def normalize_inbound(_raw), do: {:error, :unsupported}
    @impl true
    def deliver(_payload), do: {:ok, :delivered}
    @impl true
    def gateway_methods, do: []
  end

  setup do
    on_exit(fn -> Registry.unregister(SnapshotPlugin.id()) end)
    :ok
  end

  test "registration and unregistration synchronously publish the lookup snapshot" do
    assert Registry.get_plugin(SnapshotPlugin.id()) == nil
    assert :ok = Registry.register(SnapshotPlugin)
    assert Registry.get_plugin(SnapshotPlugin.id()) == SnapshotPlugin
    assert {:error, :already_registered} = Registry.register(SnapshotPlugin)
    assert :ok = Registry.unregister(SnapshotPlugin.id())
    assert Registry.get_plugin(SnapshotPlugin.id()) == nil
  end

  test "plugin lookup does not wait for the registry owner" do
    assert :ok = Registry.register(SnapshotPlugin)
    :ok = :sys.suspend(Registry)

    try do
      assert Registry.get_plugin(SnapshotPlugin.id()) == SnapshotPlugin
      assert Registry.get_plugin("nonexistent_plugin") == nil
    after
      :sys.resume(Registry)
    end
  end
end
