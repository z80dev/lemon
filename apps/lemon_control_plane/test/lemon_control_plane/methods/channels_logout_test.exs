defmodule LemonControlPlane.Methods.ChannelsLogoutTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Registry
  alias LemonControlPlane.Methods.ChannelsLogout

  defmodule FakePlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "cp-logout-test"

    @impl true
    def meta do
      %{label: "Logout Test", capabilities: %{}, docs: nil}
    end

    @impl true
    def child_spec(_opts) do
      %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
    end

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def deliver(_payload), do: {:error, :not_supported}

    @impl true
    def gateway_methods, do: []
  end

  setup do
    _ = Registry.unregister(FakePlugin.id())
    :ok = Registry.register(FakePlugin)

    on_exit(fn ->
      _ = Registry.unregister(FakePlugin.id())
    end)

    :ok
  end

  test "returns logout cleanup summary without credentials or adapter state" do
    {:ok, result} = ChannelsLogout.handle(%{"channelId" => FakePlugin.id()}, %{})

    assert result["success"] == true
    assert result["channelId"] == FakePlugin.id()
    assert result["summary"]["channelId"] == FakePlugin.id()
    assert result["summary"]["loggedOut"] == true
    assert result["summary"]["cleanup"]["includesCredentials"] == false
    assert result["summary"]["cleanup"]["includesSessionTokens"] == false
    assert result["summary"]["cleanup"]["includesAdapterState"] == false
    assert result["summary"]["cleanup"]["includesSecretValues"] == false
  end

  test "requires channelId" do
    assert {:error, {:invalid_request, "channelId is required", nil}} =
             ChannelsLogout.handle(%{}, %{})
  end
end
