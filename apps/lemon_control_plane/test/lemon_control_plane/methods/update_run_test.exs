defmodule LemonControlPlane.Methods.UpdateRunTest do
  @moduledoc """
  `update.run` is built on `LemonCore.Update.Remote`, which fetches a
  manifest over HTTP — these tests point it at `LemonControlPlane.ManifestStub`
  via `UpdateStore`'s `update_url` (repurposed as a `base_url` override) and
  run `async: false` because `UpdateStore` is a single global config record.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.UpdateRun
  alias LemonControlPlane.Protocol.Schemas
  alias LemonControlPlane.UpdateStore

  @ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  setup do
    on_exit(fn ->
      UpdateStore.delete_config()
      UpdateStore.delete_pending()
    end)

    :ok
  end

  defp current, do: LemonCore.Update.Version.current()

  defp manifest(version) do
    Jason.encode!(%{
      "schema" => 2,
      "version" => version,
      "channel" => "stable",
      "artifacts" => []
    })
  end

  defp configure_manifest(body) do
    {:ok, base_url, socket} = LemonControlPlane.ManifestStub.start(body)
    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = UpdateStore.put_config(%{update_url: base_url})
    base_url
  end

  describe "method metadata" do
    test "has correct method name and scopes" do
      assert UpdateRun.name() == "update.run"
      assert UpdateRun.scopes() == [:admin]
    end
  end

  describe "checkOnly (default)" do
    test "reports up to date without staging anything" do
      configure_manifest(manifest(current()))

      {:ok, result} = UpdateRun.handle(%{}, @ctx)

      assert result["currentVersion"] == current()
      assert result["updateAvailable"] == false
      assert result["staged"] == false
      assert result["restartRequired"] == false
      assert result["summary"]["action"] == "update.run"
      assert result["summary"]["configured"] == true
      assert result["summary"]["force"] == false
      assert result["summary"]["checkOnly"] == false
      assert result["summary"]["cleanup"]["includesDownloadUrl"] == false
      assert result["summary"]["cleanup"]["includesChecksum"] == false
      assert result["summary"]["cleanup"]["includesDownloadedBytes"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "reports an available update when the manifest is newer" do
      configure_manifest(manifest("~#{current()}~newer"))

      {:ok, result} = UpdateRun.handle(%{}, @ctx)

      assert result["updateAvailable"] == true
      assert result["staged"] == false
      assert String.contains?(result["message"], "force=true")
    end

    test "explicit checkOnly:true never applies, even with force:true" do
      configure_manifest(manifest("~#{current()}~newer"))

      {:ok, result} = UpdateRun.handle(%{"force" => true, "checkOnly" => true}, @ctx)

      assert result["updateApplied"] == false
      assert result["staged"] == false
      assert result["summary"]["force"] == true
      assert result["summary"]["checkOnly"] == true
    end

    test "not configured falls back to Remote's own base URL and still returns a version" do
      {:ok, base_url, socket} = LemonControlPlane.ManifestStub.start(manifest(current()))
      on_exit(fn -> :gen_tcp.close(socket) end)

      Application.put_env(:lemon_core, :update_base_url, base_url)
      on_exit(fn -> Application.delete_env(:lemon_core, :update_base_url) end)

      {:ok, result} = UpdateRun.handle(%{}, @ctx)

      assert result["currentVersion"] == current()
      assert result["summary"]["configured"] == false
    end
  end

  describe "force" do
    # `Remote.apply/1`'s layout guard runs before it ever looks at the
    # manifest, and a `mix test` checkout is never installed under
    # `~/.lemon/versions/<version>/` — so `force` deterministically hits the
    # guard here regardless of what the fixture manifest says. The
    # apply/no-op/staging paths themselves are covered end-to-end (with a
    # scoped, guard-satisfying install layout) in `LemonCore.Update.RemoteTest`.
    test "refuses to apply outside an installed release layout, without leaking the reason" do
      assert {:error, {:internal_error, message}} = UpdateRun.handle(%{"force" => true}, @ctx)

      assert message =~ "Failed to check for updates"
      assert message =~ "unsupported_layout"
      refute message =~ "http://"
    end

    test "checkOnly:true short-circuits before the layout guard ever runs" do
      configure_manifest(manifest(current()))

      assert {:ok, result} = UpdateRun.handle(%{"force" => true, "checkOnly" => true}, @ctx)
      assert result["updateApplied"] == false
      assert result["staged"] == false
    end
  end

  describe "schema" do
    test "accepts checkOnly, force, channel, and version params" do
      params = %{
        "checkOnly" => true,
        "force" => false,
        "channel" => "stable",
        "version" => "2026.09.0"
      }

      assert Schemas.validate("update.run", params) == :ok
    end

    test "rejects a non-boolean force" do
      assert {:error, _} = Schemas.validate("update.run", %{"force" => "yes"})
    end
  end
end
