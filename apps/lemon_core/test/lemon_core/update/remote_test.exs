defmodule LemonCore.Update.RemoteTest do
  use ExUnit.Case, async: false

  alias LemonCore.Update.FixtureServer
  alias LemonCore.Update.Remote

  @moduletag :tmp_dir

  defp manifest(version, artifacts, schema \\ 2) do
    Jason.encode!(%{
      "schema" => schema,
      "version" => version,
      "channel" => "stable",
      "commit" => "deadbeef",
      "built_at" => "2026-08-16T00:00:00Z",
      "otp" => "28",
      "elixir" => "1.19.0",
      "artifacts" => artifacts
    })
  end

  defp artifact(file, profile, platform, sha256, size) do
    %{
      "file" => file,
      "profile" => profile,
      "platform" => platform,
      "os" => "linux",
      "arch" => "x86_64",
      "sha256" => sha256,
      "size" => size
    }
  end

  defp build_fixture_tarball(tmp_dir) do
    src = Path.join(tmp_dir, "src")
    File.mkdir_p!(Path.join(src, "bin"))
    File.write!(Path.join(src, "bin/lemon"), "#!/bin/sh\necho hi\n")
    tarball = Path.join(tmp_dir, "artifact.tar.gz")
    {_output, 0} = System.cmd("tar", ["-czf", tarball, "-C", src, "."])

    bytes = File.read!(tarball)
    sha256 = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    {bytes, sha256, byte_size(bytes)}
  end

  defp start_server(router) do
    {:ok, base_url, socket} = FixtureServer.start(router)
    on_exit(fn -> :gen_tcp.close(socket) end)
    base_url
  end

  defp manifest_router(body) do
    fn
      "/releases/latest/download/manifest.json" -> {:redirect, "/manifest-body.json"}
      "/manifest-body.json" -> {200, "application/json", body}
      _ -> {404, "text/plain", "not found"}
    end
  end

  defp artifact_router(manifest_body, path, bytes) do
    fn
      "/releases/latest/download/manifest.json" -> {:redirect, "/manifest-body.json"}
      "/manifest-body.json" -> {200, "application/json", manifest_body}
      ^path -> {200, "application/gzip", bytes}
      _ -> {404, "text/plain", "not found"}
    end
  end

  defp install_layout(tmp_dir, release_version) do
    home = Path.join(tmp_dir, "home")
    state = Path.join(home, ".lemon")
    release_root = Path.join([state, "versions", release_version])
    File.mkdir_p!(release_root)
    {home, state, release_root}
  end

  describe "check/1" do
    test "rejects a manifest that does not declare schema 2" do
      body = manifest("2020.01.0", [], 1)
      base_url = start_server(manifest_router(body))

      assert {:error, {:unsupported_manifest_schema, 1}} =
               Remote.check(base_url: base_url, channel: "stable")
    end

    test "rejects a manifest with no schema field at all" do
      base_url = start_server(manifest_router(Jason.encode!(%{"version" => "2020.01.0"})))

      assert {:error, :missing_manifest_schema} =
               Remote.check(base_url: base_url, channel: "stable")
    end

    test "selects the artifact matching the given platform and profile" do
      artifacts = [
        artifact("lemon-a.tar.gz", "lemon_runtime_full", "linux-x86_64", "aa", 10),
        artifact("lemon-b.tar.gz", "lemon_runtime_min", "linux-x86_64", "bb", 10),
        artifact("lemon-c.tar.gz", "lemon_runtime_full", "darwin-arm64", "cc", 10)
      ]

      base_url = start_server(manifest_router(manifest("2099.01.0", artifacts)))
      opts = [base_url: base_url, channel: "stable"]

      assert {:ok, %{artifact: %{"file" => "lemon-a.tar.gz"}}} =
               Remote.check(opts ++ [platform: "linux-x86_64", profile: "lemon_runtime_full"])

      assert {:ok, %{artifact: %{"file" => "lemon-b.tar.gz"}}} =
               Remote.check(opts ++ [platform: "linux-x86_64", profile: "lemon_runtime_min"])

      assert {:ok, %{artifact: %{"file" => "lemon-c.tar.gz"}}} =
               Remote.check(opts ++ [platform: "darwin-arm64", profile: "lemon_runtime_full"])

      assert {:ok, %{artifact: nil}} =
               Remote.check(opts ++ [platform: "linux-arm64", profile: "lemon_runtime_full"])
    end

    test "update_available? is false when the manifest carries no version" do
      base_url = start_server(manifest_router(Jason.encode!(%{"schema" => 2, "artifacts" => []})))

      assert {:ok, %{update_available?: false, latest: nil}} =
               Remote.check(base_url: base_url, channel: "stable")
    end

    test "update_available? is true when the manifest version is newer than current" do
      current = LemonCore.Update.Version.current()
      artifacts = [artifact("pkg.tar.gz", "p", "linux-x86_64", "aa", 1)]
      base_url = start_server(manifest_router(manifest("~#{current}~newer", artifacts)))

      assert {:ok, %{update_available?: true}} =
               Remote.check(
                 base_url: base_url,
                 channel: "stable",
                 platform: "linux-x86_64",
                 profile: "p"
               )
    end

    test "a non-stable channel without a pin is rejected before any request is made" do
      assert {:error, {:channel_requires_pin, "preview"}} =
               Remote.check(base_url: "http://127.0.0.1:1", channel: "preview")
    end
  end

  describe "apply/1 — layout guard" do
    test "refuses to run when the release root is not under <state>/versions/", %{
      tmp_dir: tmp_dir
    } do
      home = Path.join(tmp_dir, "home")

      opts = [
        base_url: "http://127.0.0.1:1",
        channel: "stable",
        paths_opts: [home_dir: home],
        release_root: "/opt/lemon/current"
      ]

      assert {:error, {:unsupported_layout, _message}} = Remote.apply(opts)
    end
  end

  describe "apply/1 — checksum" do
    test "rejects a checksum mismatch and deletes the partial download", %{tmp_dir: tmp_dir} do
      {bytes, _sha256, size} = build_fixture_tarball(tmp_dir)

      artifacts = [
        artifact("pkg.tar.gz", "test_profile", "test-platform", String.duplicate("0", 64), size)
      ]

      body = manifest("2099.01.0", artifacts)

      router = artifact_router(body, "/releases/download/v2099.01.0/pkg.tar.gz", bytes)
      base_url = start_server(router)

      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      opts = [
        base_url: base_url,
        channel: "stable",
        platform: "test-platform",
        profile: "test_profile",
        paths_opts: [home_dir: home],
        release_root: release_root
      ]

      assert {:error, {:checksum_mismatch, _}} = Remote.apply(opts)
      refute File.exists?(Path.join([state, "tmp", "pkg.tar.gz"]))
      refute File.dir?(Path.join([state, "versions", "2099.01.0"]))
    end
  end

  describe "apply/1 — success" do
    test "downloads, verifies, extracts, and atomically flips current", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]
      body = manifest("2099.01.0", artifacts)

      router = artifact_router(body, "/releases/download/v2099.01.0/pkg.tar.gz", bytes)
      base_url = start_server(router)

      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      opts = [
        base_url: base_url,
        channel: "stable",
        platform: "test-platform",
        profile: "test_profile",
        paths_opts: [home_dir: home],
        release_root: release_root
      ]

      assert {:ok, %{staged: "2099.01.0", restart_required: true}} = Remote.apply(opts)

      versions_dir = Path.join(state, "versions")
      assert File.dir?(Path.join(versions_dir, "2099.01.0"))
      assert File.exists?(Path.join([versions_dir, "2099.01.0", "bin", "lemon"]))
      assert {:ok, "2099.01.0"} = File.read_link(Path.join(versions_dir, "current"))
      refute File.exists?(Path.join([state, "tmp", "pkg.tar.gz"]))
    end

    test "prunes old versions, keeping the newly staged one plus the 2 most recent others", %{
      tmp_dir: tmp_dir
    } do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]
      body = manifest("2099.01.0", artifacts)

      router = artifact_router(body, "/releases/download/v2099.01.0/pkg.tar.gz", bytes)
      base_url = start_server(router)

      {home, state, release_root} = install_layout(tmp_dir, "2018.01.0")
      versions_dir = Path.join(state, "versions")

      for v <- ["2015.01.0", "2016.01.0", "2017.01.0"] do
        File.mkdir_p!(Path.join(versions_dir, v))
      end

      opts = [
        base_url: base_url,
        channel: "stable",
        platform: "test-platform",
        profile: "test_profile",
        paths_opts: [home_dir: home],
        release_root: release_root
      ]

      assert {:ok, %{staged: "2099.01.0"}} = Remote.apply(opts)

      assert File.dir?(Path.join(versions_dir, "2099.01.0"))
      assert File.dir?(Path.join(versions_dir, "2018.01.0"))
      assert File.dir?(Path.join(versions_dir, "2017.01.0"))
      refute File.dir?(Path.join(versions_dir, "2016.01.0"))
      refute File.dir?(Path.join(versions_dir, "2015.01.0"))
    end

    test "is a no-op when already up to date", %{tmp_dir: tmp_dir} do
      current = LemonCore.Update.Version.current()
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", "aa", 1)]
      body = manifest(current, artifacts)
      base_url = start_server(manifest_router(body))

      {home, _state, release_root} = install_layout(tmp_dir, "2018.01.0")

      opts = [
        base_url: base_url,
        channel: "stable",
        platform: "test-platform",
        profile: "test_profile",
        paths_opts: [home_dir: home],
        release_root: release_root
      ]

      assert {:ok, %{staged: nil, restart_required: false}} = Remote.apply(opts)
    end
  end

  describe "rollback/1" do
    test "refuses to run outside the versions/ layout", %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "home")

      assert {:error, {:unsupported_layout, _}} =
               Remote.rollback(paths_opts: [home_dir: home], release_root: "/opt/lemon/current")
    end

    test "flips current back to the newest retained non-active version", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]
      body = manifest("2099.01.0", artifacts)

      router = artifact_router(body, "/releases/download/v2099.01.0/pkg.tar.gz", bytes)
      base_url = start_server(router)

      {home, state, release_root} = install_layout(tmp_dir, "2018.01.0")
      versions_dir = Path.join(state, "versions")

      opts = [
        base_url: base_url,
        channel: "stable",
        platform: "test-platform",
        profile: "test_profile",
        paths_opts: [home_dir: home],
        release_root: release_root
      ]

      assert {:ok, %{staged: "2099.01.0"}} = Remote.apply(opts)

      rollback_opts = [
        paths_opts: [home_dir: home],
        release_root: Path.join(versions_dir, "2099.01.0")
      ]

      assert {:ok, %{active: "2018.01.0"}} = Remote.rollback(rollback_opts)
      assert {:ok, "2018.01.0"} = File.read_link(Path.join(versions_dir, "current"))
    end

    test "errors when there is no other retained version", %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "home")
      state = Path.join(home, ".lemon")
      versions_dir = Path.join(state, "versions")
      only = Path.join(versions_dir, "2099.01.0")
      File.mkdir_p!(only)
      File.rm(Path.join(versions_dir, "current"))
      :ok = File.ln_s("2099.01.0", Path.join(versions_dir, "current"))

      assert {:error, :no_rollback_candidate} =
               Remote.rollback(paths_opts: [home_dir: home], release_root: only)
    end
  end
end
