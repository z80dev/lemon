defmodule LemonControlPlane.UpdateStoreTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.UpdateStore

  test "stores update config and pending update records through the typed wrapper" do
    config = %{update_url: "https://example.test/releases/latest", auto_restart: false}
    pending = %{version: "1.2.3", path: "/tmp/update.bin"}

    assert :ok = UpdateStore.put_config(config)
    assert UpdateStore.get_config() == config

    assert :ok = UpdateStore.put_pending(pending)
    assert UpdateStore.get_pending() == pending

    assert :ok = UpdateStore.delete_pending()
    assert UpdateStore.get_pending() == nil

    assert :ok = UpdateStore.delete_config()
    assert UpdateStore.get_config() == nil
  end
end
