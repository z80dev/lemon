defmodule LemonControlPlane.Methods.ConfigReloadTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ConfigReload

  describe "metadata" do
    test "name and scopes" do
      assert ConfigReload.name() == "config.reload"
      assert ConfigReload.scopes() == [:admin]
    end
  end

  describe "handle/2" do
    test "reloads config with lifecycle summary and cleanup flags" do
      {:ok, payload} =
        ConfigReload.handle(%{"force" => true, "reason" => "manual"}, %{})

      assert is_binary(payload["reloadId"])
      assert is_list(payload["changedSources"])
      assert is_list(payload["changedPaths"])
      assert is_integer(payload["appliedAtMs"])
      assert is_list(payload["actions"])
      assert payload["warnings"] == []
      assert payload["summary"]["action"] == "config.reload"
      assert payload["summary"]["status"] == "ok"
      assert payload["summary"]["reloadIdReturned"] == true
      assert payload["summary"]["changedSourceCount"] == length(payload["changedSources"])
      assert payload["summary"]["changedPathCount"] == length(payload["changedPaths"])
      assert payload["summary"]["actionCount"] == length(payload["actions"])
      assert payload["summary"]["warningsCount"] == 0
      assert payload["summary"]["appliedAtMs"] == payload["appliedAtMs"]
      assert payload["summary"]["cleanup"]["includesConfigValues"] == false
      assert payload["summary"]["cleanup"]["includesEnvironmentValues"] == false
      assert payload["summary"]["cleanup"]["includesSecretValues"] == false
      assert payload["summary"]["cleanup"]["includesFileContents"] == false
      assert payload["summary"]["cleanup"]["includesCredentialValues"] == false
    end
  end
end
