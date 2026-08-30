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

  defp build_fixture_tarball(tmp_dir, version \\ "2099.01.0", extra_files \\ %{}) do
    src = Path.join(tmp_dir, "src")
    File.mkdir_p!(Path.join(src, "bin"))

    write_executable!(
      Path.join(src, "bin/lemon"),
      "#!/bin/sh\nif [ \"$1\" = version ]; then echo #{version}; else echo hi; fi\n"
    )

    Enum.each(extra_files, fn {relative, contents} ->
      path = Path.join(src, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    tarball = Path.join(tmp_dir, "artifact.tar.gz")
    {_output, 0} = System.cmd("tar", ["-czf", tarball, "-C", src, "."])

    digest(tarball)
  end

  # A tarball shaped like a release but missing the executable bit on its
  # launcher — the staged tree must never be promoted.
  defp build_unusable_tarball(tmp_dir) do
    src = Path.join(tmp_dir, "bad-src")
    File.mkdir_p!(Path.join(src, "bin"))
    File.write!(Path.join(src, "bin/lemon"), "#!/bin/sh\necho hi\n")
    tarball = Path.join(tmp_dir, "bad-artifact.tar.gz")
    {_output, 0} = System.cmd("tar", ["-czf", tarball, "-C", src, "."])

    digest(tarball)
  end

  defp build_unusable_tui_tarball(tmp_dir) do
    src = Path.join(tmp_dir, "bad-tui-src")
    File.mkdir_p!(Path.join(src, "tui/bin"))
    File.write!(Path.join(src, "tui/bin/lemon-tui"), "#!/bin/sh\necho tui\n")
    tarball = Path.join(tmp_dir, "bad-tui-artifact.tar.gz")
    {_output, 0} = System.cmd("tar", ["-czf", tarball, "-C", src, "tui"])

    digest(tarball)
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  # The TUI ships a single top-level tui/ directory so it can be unpacked over
  # the runtime's staging directory without colliding with bin/ or lib/.
  defp build_fixture_tui_tarball(tmp_dir) do
    src = Path.join(tmp_dir, "tui-src")
    File.mkdir_p!(Path.join(src, "tui/bin"))
    write_executable!(Path.join(src, "tui/bin/lemon-tui"), "#!/bin/sh\necho tui\n")
    tarball = Path.join(tmp_dir, "tui-artifact.tar.gz")
    {_output, 0} = System.cmd("tar", ["-czf", tarball, "-C", src, "tui"])

    digest(tarball)
  end

  defp digest(tarball) do
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
    downloads_router(manifest_body, %{path => bytes})
  end

  defp downloads_router(manifest_body, downloads) do
    fn
      "/releases/latest/download/manifest.json" ->
        {:redirect, "/manifest-body.json"}

      "/manifest-body.json" ->
        {200, "application/json", manifest_body}

      path ->
        case Map.fetch(downloads, path) do
          {:ok, bytes} -> {200, "application/gzip", bytes}
          :error -> {404, "text/plain", "not found"}
        end
    end
  end

  defp install_layout(tmp_dir, release_version) do
    home = Path.join(tmp_dir, "home")
    state = Path.join(home, ".lemon")
    release_root = Path.join([state, "versions", release_version])
    File.mkdir_p!(Path.join(release_root, "bin"))

    write_executable!(
      Path.join(release_root, "bin/lemon"),
      "#!/bin/sh\nif [ \"$1\" = version ]; then echo #{release_version}; else echo old; fi\n"
    )

    File.ln_s!(release_version, Path.join([state, "versions", "current"]))
    {home, state, release_root}
  end

  defp remote_opts(base_url, home, release_root) do
    [
      base_url: base_url,
      channel: "stable",
      platform: "test-platform",
      profile: "test_profile",
      paths_opts: [home_dir: home],
      release_root: release_root,
      current_version: Path.basename(release_root)
    ]
  end

  defp apply_confirmed(opts) do
    opts = Keyword.put_new(opts, :current_version, Path.basename(opts[:release_root]))

    with {:ok, plan} <- Remote.plan(opts) do
      Remote.apply(Keyword.put(opts, :confirm, plan.digest))
    end
  end

  defp tree_fingerprint(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        children =
          root
          |> File.ls!()
          |> Enum.sort()
          |> Enum.flat_map(&tree_fingerprint_entry(Path.join(root, &1), &1))

        [{".", :directory, Bitwise.band(mode, 0o777)} | children]

      {:error, :enoent} ->
        :missing
    end
  end

  defp tree_fingerprint_entry(path, relative) do
    case File.lstat!(path) do
      %File.Stat{type: :directory, mode: mode} ->
        children =
          path
          |> File.ls!()
          |> Enum.sort()
          |> Enum.flat_map(fn child ->
            tree_fingerprint_entry(Path.join(path, child), Path.join(relative, child))
          end)

        [{relative, :directory, Bitwise.band(mode, 0o777)} | children]

      %File.Stat{type: :regular, mode: mode} ->
        [{relative, :regular, Bitwise.band(mode, 0o777), digest_bytes(File.read!(path))}]

      %File.Stat{type: :symlink} ->
        [{relative, :symlink, File.read_link!(path)}]

      %File.Stat{type: type} ->
        [{relative, type}]
    end
  end

  defp digest_bytes(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

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

    test "reports the TUI artifact for the same platform alongside the runtime" do
      artifacts = [
        artifact("lemon-a.tar.gz", "lemon_runtime_full", "linux-x86_64", "aa", 10),
        artifact("lemon-tui-x86.tar.gz", "lemon_tui", "linux-x86_64", "bb", 10),
        artifact("lemon-tui-arm.tar.gz", "lemon_tui", "linux-arm64", "cc", 10)
      ]

      base_url = start_server(manifest_router(manifest("2099.01.0", artifacts)))

      assert {:ok, %{artifact: %{"file" => "lemon-a.tar.gz"}, tui_artifact: tui}} =
               Remote.check(
                 base_url: base_url,
                 channel: "stable",
                 platform: "linux-x86_64",
                 profile: "lemon_runtime_full"
               )

      assert tui["file"] == "lemon-tui-x86.tar.gz"
    end

    test "tui_artifact is nil when the release publishes no TUI" do
      artifacts = [artifact("lemon-a.tar.gz", "lemon_runtime_full", "linux-x86_64", "aa", 10)]
      base_url = start_server(manifest_router(manifest("2099.01.0", artifacts)))

      assert {:ok, %{artifact: %{"file" => "lemon-a.tar.gz"}, tui_artifact: nil}} =
               Remote.check(
                 base_url: base_url,
                 channel: "stable",
                 platform: "linux-x86_64",
                 profile: "lemon_runtime_full"
               )
    end

    test "the sim profile never selects a TUI artifact, even when one is published" do
      artifacts = [
        artifact("lemon-sim.tar.gz", "sim_broadcast_platform", "linux-x86_64", "aa", 10),
        artifact("lemon-tui.tar.gz", "lemon_tui", "linux-x86_64", "bb", 10)
      ]

      base_url = start_server(manifest_router(manifest("2099.01.0", artifacts)))

      assert {:ok, %{artifact: %{"file" => "lemon-sim.tar.gz"}, tui_artifact: nil}} =
               Remote.check(
                 base_url: base_url,
                 channel: "stable",
                 platform: "linux-x86_64",
                 profile: "sim_broadcast_platform"
               )
    end

    test "LEMON_NO_TUI=1 opts out of the TUI artifact, as it does in the installer" do
      System.put_env("LEMON_NO_TUI", "1")
      on_exit(fn -> System.delete_env("LEMON_NO_TUI") end)

      artifacts = [
        artifact("lemon-a.tar.gz", "lemon_runtime_full", "linux-x86_64", "aa", 10),
        artifact("lemon-tui.tar.gz", "lemon_tui", "linux-x86_64", "bb", 10)
      ]

      base_url = start_server(manifest_router(manifest("2099.01.0", artifacts)))

      assert {:ok, %{artifact: %{"file" => "lemon-a.tar.gz"}, tui_artifact: nil}} =
               Remote.check(
                 base_url: base_url,
                 channel: "stable",
                 platform: "linux-x86_64",
                 profile: "lemon_runtime_full"
               )
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

      assert {:error, :unsupported_layout} = apply_confirmed(opts)
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

      assert {:error, {:checksum_mismatch, _}} = apply_confirmed(opts)
      refute File.exists?(Path.join([state, "tmp", "pkg.tar.gz"]))
      refute File.dir?(Path.join([state, "versions", "2099.01.0"]))
    end

    test "a bad TUI checksum aborts the whole update, staging neither half", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      {tui_bytes, _tui_sha, tui_size} = build_fixture_tui_tarball(tmp_dir)

      artifacts = [
        artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size),
        artifact("tui.tar.gz", "lemon_tui", "test-platform", String.duplicate("0", 64), tui_size)
      ]

      router =
        downloads_router(manifest("2099.01.0", artifacts), %{
          "/releases/download/v2099.01.0/pkg.tar.gz" => bytes,
          "/releases/download/v2099.01.0/tui.tar.gz" => tui_bytes
        })

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

      assert {:error, {:checksum_mismatch, _}} = apply_confirmed(opts)

      versions_dir = Path.join(state, "versions")
      refute File.dir?(Path.join(versions_dir, "2099.01.0"))
      refute File.exists?(Path.join(versions_dir, "2099.01.0.partial"))
      assert {:ok, "2020.01.0"} = File.read_link(Path.join(versions_dir, "current"))

      # The verified runtime tarball is discarded too — nothing is left staged.
      refute File.exists?(Path.join([state, "tmp", "pkg.tar.gz"]))
      refute File.exists?(Path.join([state, "tmp", "tui.tar.gz"]))
    end
  end

  describe "apply/1 — staging safety" do
    test "refuses to promote a tarball whose bin/lemon is not executable", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_unusable_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]

      router =
        artifact_router(
          manifest("2099.01.0", artifacts),
          "/releases/download/v2099.01.0/pkg.tar.gz",
          bytes
        )

      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      assert {:error, {:incomplete_release, "bin/lemon"}} =
               apply_confirmed(remote_opts(base_url, home, release_root))

      versions_dir = Path.join(state, "versions")
      refute File.exists?(Path.join(versions_dir, "2099.01.0"))
      refute File.exists?(Path.join(versions_dir, "2099.01.0.partial"))
      assert {:ok, "2020.01.0"} = File.read_link(Path.join(versions_dir, "current"))
      assert File.ls!(Path.join(state, "tmp")) == []
    end

    test "refuses to promote when the staged TUI is not executable", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      {tui_bytes, tui_sha, tui_size} = build_unusable_tui_tarball(tmp_dir)

      artifacts = [
        artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size),
        artifact("tui.tar.gz", "lemon_tui", "test-platform", tui_sha, tui_size)
      ]

      router =
        downloads_router(manifest("2099.01.0", artifacts), %{
          "/releases/download/v2099.01.0/pkg.tar.gz" => bytes,
          "/releases/download/v2099.01.0/tui.tar.gz" => tui_bytes
        })

      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      assert {:error, {:incomplete_release, "tui/bin/lemon-tui"}} =
               apply_confirmed(remote_opts(base_url, home, release_root))

      versions_dir = Path.join(state, "versions")
      refute File.exists?(Path.join(versions_dir, "2099.01.0"))
      refute File.exists?(Path.join(versions_dir, "2099.01.0.partial"))
      assert File.ls!(Path.join(state, "tmp")) == []
    end

    test "keeps an existing usable install of the same version instead of re-extracting it", %{
      tmp_dir: tmp_dir
    } do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]

      router =
        artifact_router(
          manifest("2099.01.0", artifacts),
          "/releases/download/v2099.01.0/pkg.tar.gz",
          bytes
        )

      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      # The target version is already on disk and usable — the directory
      # `current` would point at. Deleting it to make room is the failure mode
      # this guards.
      versions_dir = Path.join(state, "versions")
      existing = Path.join(versions_dir, "2099.01.0")
      File.mkdir_p!(Path.join(existing, "bin"))

      write_executable!(
        Path.join(existing, "bin/lemon"),
        "#!/bin/sh\nif [ \"$1\" = version ]; then echo 2099.01.0; else echo existing; fi\n"
      )

      sentinel = Path.join(existing, "SENTINEL")
      File.write!(sentinel, "keep me")

      assert {:ok, %{staged: "2099.01.0"}} =
               apply_confirmed(remote_opts(base_url, home, release_root))

      assert File.exists?(sentinel)
      assert {:ok, "2099.01.0"} = File.read_link(Path.join(versions_dir, "current"))
      refute File.exists?(Path.join(versions_dir, "2099.01.0.partial"))
    end

    test "replaces an existing broken install of the same version", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]

      router =
        artifact_router(
          manifest("2099.01.0", artifacts),
          "/releases/download/v2099.01.0/pkg.tar.gz",
          bytes
        )

      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      versions_dir = Path.join(state, "versions")
      broken = Path.join(versions_dir, "2099.01.0")
      File.mkdir_p!(broken)
      File.write!(Path.join(broken, "TRUNCATED"), "no launcher here")

      assert {:ok, %{staged: "2099.01.0"}} =
               apply_confirmed(remote_opts(base_url, home, release_root))

      assert File.exists?(Path.join([versions_dir, "2099.01.0", "bin", "lemon"]))
      refute File.exists?(Path.join([versions_dir, "2099.01.0", "TRUNCATED"]))

      # The moved-aside copy is discarded once the swap lands, and must not
      # show up as a rollback candidate in the meantime.
      assert versions_dir |> File.ls!() |> Enum.filter(&String.contains?(&1, ".broken.")) == []
    end

    test "an exception during staging returns a stable error and leaves no partial directory", %{
      tmp_dir: tmp_dir
    } do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]

      router =
        artifact_router(
          manifest("2099.01.0", artifacts),
          "/releases/download/v2099.01.0/pkg.tar.gz",
          bytes
        )

      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      # ~/.lemon/tmp occupied by a regular file makes the download's
      # `File.mkdir_p!` raise, the class of failure that used to sail past
      # every explicit cleanup path.
      File.mkdir_p!(state)
      File.write!(Path.join(state, "tmp"), "not a directory")

      assert {:error, :staging_failed} =
               apply_confirmed(remote_opts(base_url, home, release_root))

      versions_dir = Path.join(state, "versions")
      refute File.exists?(Path.join(versions_dir, "2099.01.0.partial"))
      assert {:ok, "2020.01.0"} = File.read_link(Path.join(versions_dir, "current"))
      assert File.dir?(Path.join(versions_dir, "2020.01.0"))
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

      assert {:ok, %{staged: "2099.01.0", restart_required: true}} = apply_confirmed(opts)

      versions_dir = Path.join(state, "versions")
      assert File.dir?(Path.join(versions_dir, "2099.01.0"))
      assert File.exists?(Path.join([versions_dir, "2099.01.0", "bin", "lemon"]))
      assert {:ok, "2099.01.0"} = File.read_link(Path.join(versions_dir, "current"))
      refute File.exists?(Path.join([state, "tmp", "pkg.tar.gz"]))
    end

    test "stages the runtime and the TUI into the same version directory", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      {tui_bytes, tui_sha, tui_size} = build_fixture_tui_tarball(tmp_dir)

      artifacts = [
        artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size),
        artifact("tui.tar.gz", "lemon_tui", "test-platform", tui_sha, tui_size)
      ]

      router =
        downloads_router(manifest("2099.01.0", artifacts), %{
          "/releases/download/v2099.01.0/pkg.tar.gz" => bytes,
          "/releases/download/v2099.01.0/tui.tar.gz" => tui_bytes
        })

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

      assert {:ok, %{staged: "2099.01.0", restart_required: true}} = apply_confirmed(opts)

      versions_dir = Path.join(state, "versions")
      assert File.exists?(Path.join([versions_dir, "2099.01.0", "bin", "lemon"]))
      assert File.exists?(Path.join([versions_dir, "2099.01.0", "tui", "bin", "lemon-tui"]))
      assert {:ok, "2099.01.0"} = File.read_link(Path.join(versions_dir, "current"))
      refute File.exists?(Path.join([state, "tmp", "pkg.tar.gz"]))
      refute File.exists?(Path.join([state, "tmp", "tui.tar.gz"]))
    end

    test "updates the runtime alone when the release publishes no TUI", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]

      router =
        artifact_router(
          manifest("2099.01.0", artifacts),
          "/releases/download/v2099.01.0/pkg.tar.gz",
          bytes
        )

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

      assert {:ok, %{staged: "2099.01.0"}} = apply_confirmed(opts)

      versions_dir = Path.join(state, "versions")
      assert File.exists?(Path.join([versions_dir, "2099.01.0", "bin", "lemon"]))
      refute File.exists?(Path.join([versions_dir, "2099.01.0", "tui"]))
    end

    test "the sim profile stages the runtime without fetching a TUI", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      {_tui_bytes, tui_sha, tui_size} = build_fixture_tui_tarball(tmp_dir)

      artifacts = [
        artifact("pkg.tar.gz", "sim_broadcast_platform", "test-platform", sha256, size),
        artifact("tui.tar.gz", "lemon_tui", "test-platform", tui_sha, tui_size)
      ]

      # The TUI tarball is deliberately not served: reaching for it 404s the
      # update instead of silently succeeding.
      router =
        artifact_router(
          manifest("2099.01.0", artifacts),
          "/releases/download/v2099.01.0/pkg.tar.gz",
          bytes
        )

      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      opts = [
        base_url: base_url,
        channel: "stable",
        platform: "test-platform",
        profile: "sim_broadcast_platform",
        paths_opts: [home_dir: home],
        release_root: release_root
      ]

      assert {:ok, %{staged: "2099.01.0"}} = apply_confirmed(opts)

      versions_dir = Path.join(state, "versions")
      assert File.exists?(Path.join([versions_dir, "2099.01.0", "bin", "lemon"]))
      refute File.exists?(Path.join([versions_dir, "2099.01.0", "tui"]))
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

      assert {:ok, %{staged: "2099.01.0"}} = apply_confirmed(opts)

      assert File.dir?(Path.join(versions_dir, "2099.01.0"))
      assert File.dir?(Path.join(versions_dir, "2018.01.0"))
      assert File.dir?(Path.join(versions_dir, "2017.01.0"))
      assert File.dir?(Path.join(versions_dir, "2016.01.0"))
      refute File.dir?(Path.join(versions_dir, "2015.01.0"))
    end

    test "is a no-op when already up to date", %{tmp_dir: tmp_dir} do
      current = "2018.01.0"

      artifacts = [
        artifact("pkg.tar.gz", "test_profile", "test-platform", String.duplicate("a", 64), 1)
      ]

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

      assert {:ok, %{staged: nil, restart_required: false}} = apply_confirmed(opts)
    end
  end

  describe "plan/apply/rollback transaction receipts" do
    test "plan and wrong or stale digests leave the managed tree byte-for-byte unchanged", %{
      tmp_dir: tmp_dir
    } do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]
      {:ok, manifest_state} = Agent.start_link(fn -> manifest("2099.01.0", artifacts) end)

      router = fn
        "/releases/latest/download/manifest.json" -> {:redirect, "/manifest-body.json"}
        "/manifest-body.json" -> {200, "application/json", Agent.get(manifest_state, & &1)}
        "/releases/download/v2099.01.0/pkg.tar.gz" -> {200, "application/gzip", bytes}
        _ -> {404, "text/plain", "not found"}
      end

      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")
      opts = remote_opts(base_url, home, release_root)
      before = tree_fingerprint(state)

      assert {:ok, plan} = Remote.plan(opts)
      assert before == tree_fingerprint(state)
      refute File.exists?(Path.join(state, "updates"))

      assert {:error, :confirmation_mismatch} =
               Remote.apply(Keyword.put(opts, :confirm, String.duplicate("0", 64)))

      assert before == tree_fingerprint(state)

      changed =
        manifest("2099.01.0", artifacts)
        |> Jason.decode!()
        |> Map.put("commit", "cafebabe")
        |> Jason.encode!()

      Agent.update(manifest_state, fn _ -> changed end)

      assert {:error, :confirmation_mismatch} =
               Remote.apply(Keyword.put(opts, :confirm, plan.digest))

      assert before == tree_fingerprint(state)
      refute File.exists?(Path.join(state, "updates"))
    end

    test "exact apply writes private content-free history, is replay-safe, and exact rollback works",
         %{
           tmp_dir: tmp_dir
         } do
      planted = "PLANTED_UPDATE_TOKEN_8e9d3a"

      {bytes, sha256, size} =
        build_fixture_tarball(tmp_dir, "2099.01.0", %{"lib/planted.txt" => planted})

      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]
      body = manifest("2099.01.0", artifacts)
      router = artifact_router(body, "/releases/download/v2099.01.0/pkg.tar.gz", bytes)
      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")
      opts = remote_opts(base_url, home, release_root)

      assert {:ok, plan} = Remote.plan(opts)

      assert {:ok, %{staged: "2099.01.0", receipt: receipt}} =
               Remote.apply(Keyword.put(opts, :confirm, plan.digest))

      assert {:ok, [history]} = Remote.history(Keyword.put(opts, :limit, 1))
      assert history == receipt
      assert history["status"] == "applied"
      assert history["checkpoint_id"]
      assert history["rollback_digest"]

      updates_root = Path.join(state, "updates")

      for path <- Path.wildcard(Path.join(updates_root, "**/*.json")) do
        assert {:ok, %File.Stat{mode: mode, type: :regular}} = File.stat(path)
        assert Bitwise.band(mode, 0o777) == 0o600
        recorded = File.read!(path)
        refute recorded =~ planted
        refute recorded =~ tmp_dir
        refute recorded =~ base_url
      end

      after_apply = tree_fingerprint(state)

      assert {:error, :stale_running_release} =
               Remote.apply(Keyword.put(opts, :confirm, plan.digest))

      assert after_apply == tree_fingerprint(state)

      rollback_opts = [
        paths_opts: [home_dir: home],
        release_root: Path.join([state, "versions", "2099.01.0"]),
        current_version: "2099.01.0",
        receipt: receipt["id"],
        confirm: receipt["rollback_digest"]
      ]

      assert {:ok, %{active: "2020.01.0", receipt: rollback_receipt}} =
               Remote.rollback(rollback_opts)

      assert rollback_receipt["rolled_back_receipt_id"] == receipt["id"]
      assert {:ok, "2020.01.0"} = File.read_link(Path.join([state, "versions", "current"]))
      assert {:ok, [latest, original]} = Remote.history(Keyword.put(rollback_opts, :limit, 2))
      assert latest["action"] == "rollback"
      assert original["id"] == receipt["id"]
    end

    test "post-promotion verification failure restores the exact old pointer", %{tmp_dir: tmp_dir} do
      {bytes, sha256, size} = build_fixture_tarball(tmp_dir)
      artifacts = [artifact("pkg.tar.gz", "test_profile", "test-platform", sha256, size)]
      body = manifest("2099.01.0", artifacts)
      router = artifact_router(body, "/releases/download/v2099.01.0/pkg.tar.gz", bytes)
      base_url = start_server(router)
      {home, state, release_root} = install_layout(tmp_dir, "2020.01.0")

      opts =
        remote_opts(base_url, home, release_root)
        |> Keyword.put(:active_verify_fun, fn
          "2099.01.0" -> {:error, :injected_active_failure}
          _version -> :ok
        end)

      assert {:ok, plan} = Remote.plan(opts)

      assert {:error, :injected_active_failure} =
               Remote.apply(Keyword.put(opts, :confirm, plan.digest))

      versions = Path.join(state, "versions")
      assert {:ok, "2020.01.0"} = File.read_link(Path.join(versions, "current"))
      assert File.dir?(Path.join(versions, "2099.01.0"))
      assert {:ok, [failed]} = Remote.history(Keyword.put(opts, :limit, 1))
      assert failed["status"] == "failed_injected_active_failure"
    end
  end

  describe "rollback/1" do
    test "refuses to run outside the versions/ layout", %{tmp_dir: tmp_dir} do
      home = Path.join(tmp_dir, "home")

      assert {:error, :unsupported_layout} =
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

      assert {:ok, %{staged: "2099.01.0", receipt: receipt}} = apply_confirmed(opts)

      rollback_opts = [
        paths_opts: [home_dir: home],
        release_root: Path.join(versions_dir, "2099.01.0"),
        current_version: "2099.01.0",
        receipt: receipt["id"],
        confirm: receipt["rollback_digest"]
      ]

      assert {:ok, %{active: "2018.01.0"}} = Remote.rollback(rollback_opts)
      assert {:ok, "2018.01.0"} = File.read_link(Path.join(versions_dir, "current"))
    end

    test "requires an exact update receipt instead of choosing a retained version", %{
      tmp_dir: tmp_dir
    } do
      home = Path.join(tmp_dir, "home")
      state = Path.join(home, ".lemon")
      versions_dir = Path.join(state, "versions")
      only = Path.join(versions_dir, "2099.01.0")
      File.mkdir_p!(Path.join(only, "bin"))
      write_executable!(Path.join(only, "bin/lemon"), "#!/bin/sh\necho 2099.01.0\n")
      File.rm(Path.join(versions_dir, "current"))
      :ok = File.ln_s("2099.01.0", Path.join(versions_dir, "current"))

      assert {:error, :invalid_receipt_id} =
               Remote.rollback(
                 paths_opts: [home_dir: home],
                 release_root: only,
                 current_version: "2099.01.0"
               )
    end
  end
end
