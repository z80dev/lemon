defmodule LemonCore.Update.ManagedInstallTest do
  use ExUnit.Case, async: false

  alias LemonCore.Update.ManagedInstall

  @moduletag :tmp_dir

  test "current resolves the managed current symlink without accepting a stale version", %{
    tmp_dir: tmp_dir
  } do
    versions = Path.join([tmp_dir, "actual", ".lemon", "versions"])
    root = Path.join(versions, "2026.10.0")
    File.mkdir_p!(Path.join(root, "bin"))
    launcher = Path.join(root, "bin/lemon")
    File.write!(launcher, "#!/bin/sh\necho 2026.10.0\n")
    File.chmod!(launcher, 0o755)
    File.ln_s!("2026.10.0", Path.join(versions, "current"))

    File.ln_s!("actual", Path.join(tmp_dir, "home"))

    opts = [
      release_root: Path.join(versions, "current"),
      paths_opts: [home_dir: Path.join(tmp_dir, "home")],
      current_version: "2026.10.0"
    ]

    assert {:ok, "2026.10.0"} = ManagedInstall.current(opts)

    assert {:error, :running_version_mismatch} =
             ManagedInstall.current(Keyword.put(opts, :current_version, "2026.09.0"))
  end

  test "version subprocess clears the old release selection but retains external config and port",
       %{
         tmp_dir: tmp_dir
       } do
    names =
      ~w(RELEASE_ROOT RELEASE_VSN RELEASE_NAME RELEASE_SYS_CONFIG RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_TMP LEMON_CONTROL_PLANE_PORT)

    previous = Map.take(System.get_env(), names)
    old_root = Path.join(tmp_dir, "old")
    external_config = Path.join(tmp_dir, "operator.config")

    on_exit(fn ->
      Enum.each(names, &System.delete_env/1)
      System.put_env(previous)
    end)

    System.put_env(%{
      "RELEASE_ROOT" => old_root,
      "RELEASE_VSN" => "2026.09.0",
      "RELEASE_NAME" => "lemon_runtime_min",
      "RELEASE_SYS_CONFIG" => external_config,
      "RELEASE_VM_ARGS" => Path.join(old_root, "releases/2026.09.0/vm.args"),
      "RELEASE_REMOTE_VM_ARGS" => Path.join(old_root, "releases/2026.09.0/remote.vm.args"),
      "RELEASE_TMP" => Path.join(old_root, "tmp"),
      "LEMON_CONTROL_PLANE_PORT" => "4220"
    })

    launcher = Path.join(tmp_dir, "lemon")

    File.write!(launcher, """
    #!/bin/sh
    [ "$1" = version ] || exit 1
    [ -z "${RELEASE_ROOT:-}${RELEASE_VSN:-}${RELEASE_NAME:-}${RELEASE_VM_ARGS:-}${RELEASE_REMOTE_VM_ARGS:-}${RELEASE_TMP:-}" ] || exit 2
    [ "$RELEASE_SYS_CONFIG" = "$(dirname "$0")/operator.config" ] || exit 3
    [ "$LEMON_CONTROL_PLANE_PORT" = 4220 ] || exit 4
    echo 2026.10.0
    """)

    File.chmod!(launcher, 0o755)
    assert :ok = ManagedInstall.verify_launcher_version(launcher, "2026.10.0", [])

    System.put_env("RELEASE_SYS_CONFIG", Path.join(old_root, "releases/2026.09.0/sys"))
    assert {"RELEASE_SYS_CONFIG", nil} in ManagedInstall.command_env()
    assert System.get_env("RELEASE_ROOT") == old_root
  end

  defp bot_layout!(tmp_dir, key) do
    home = Path.join(tmp_dir, "home")
    bot_root = Path.join([home, ".lemon", "lemon_bot"])
    install_bot!(bot_root, key)
    File.ln_s!(Path.join("versions", key), Path.join(bot_root, "current"))
    {home, bot_root}
  end

  defp install_bot!(bot_root, key) do
    dir = Path.join([bot_root, "versions", key])
    File.mkdir_p!(Path.join(dir, "bot/bin"))
    File.mkdir_p!(Path.join(dir, "bot/web"))
    File.write!(Path.join(dir, "bot/web/index.html"), "<html>")
    binary = Path.join(dir, "bot/bin/lemon-bot")
    version = key |> String.split("-") |> hd()
    File.write!(binary, "#!/bin/sh\nprintf 'lemon-bot #{version}\\n'\n")
    File.chmod!(binary, 0o755)
    dir
  end

  describe "lemon bot backend install" do
    test "recognises only a pointer that stays inside the managed versions tree", %{
      tmp_dir: tmp_dir
    } do
      {home, bot_root} = bot_layout!(tmp_dir, "2026.10.0-stable-test-platform")
      opts = [paths_opts: [home_dir: home]]

      assert ManagedInstall.managed_bot?(opts)
      assert ManagedInstall.active_bot(opts) == "2026.10.0-stable-test-platform"

      outside = Path.join(tmp_dir, "elsewhere")
      File.mkdir_p!(outside)
      File.rm!(Path.join(bot_root, "current"))
      File.ln_s!(outside, Path.join(bot_root, "current"))

      refute ManagedInstall.managed_bot?(opts)
      assert ManagedInstall.active_bot(opts) == nil

      File.rm!(Path.join(bot_root, "current"))
      refute ManagedInstall.managed_bot?(opts)
    end

    test "an absent backend install is simply unmanaged", %{tmp_dir: tmp_dir} do
      refute ManagedInstall.managed_bot?(paths_opts: [home_dir: Path.join(tmp_dir, "home")])
    end

    test "flips, verifies, and restores the backend pointer by install key", %{tmp_dir: tmp_dir} do
      previous = "2026.10.0-stable-test-platform"
      target = "2099.01.0-stable-test-platform"
      {home, bot_root} = bot_layout!(tmp_dir, previous)
      install_bot!(bot_root, target)
      opts = [paths_opts: [home_dir: home]]

      assert :ok = ManagedInstall.flip_bot(target, opts)
      assert ManagedInstall.active_bot(opts) == target
      assert :ok = ManagedInstall.verify_active_bot(target, opts)

      assert {:error, :active_bot_verification_failed} =
               ManagedInstall.verify_active_bot(previous, opts)

      assert :ok = ManagedInstall.restore_bot_after_failed_flip(previous, target, opts)
      assert ManagedInstall.active_bot(opts) == previous

      # A pointer that already moved on is left alone.
      assert :ok = ManagedInstall.restore_bot_after_failed_flip(previous, target, opts)
      assert ManagedInstall.active_bot(opts) == previous
    end

    test "refuses a backend target that is not a bare install key", %{tmp_dir: tmp_dir} do
      {home, _bot_root} = bot_layout!(tmp_dir, "2026.10.0-stable-test-platform")
      opts = [paths_opts: [home_dir: home]]

      for bad <- ["../escape", "/abs/path", "versions/2026.10.0", ".hidden", ""] do
        refute ManagedInstall.safe_bot_key?(bad)
        assert {:error, :invalid_bot_target} = ManagedInstall.flip_bot(bad, opts)
        assert {:error, :invalid_bot_target} = ManagedInstall.promote_bot("ignored", bad, opts)
      end

      assert ManagedInstall.active_bot(opts) == "2026.10.0-stable-test-platform"
    end

    test "verify_active_bot refuses a pointer whose binary is missing or linked", %{
      tmp_dir: tmp_dir
    } do
      key = "2026.10.0-stable-test-platform"
      {home, bot_root} = bot_layout!(tmp_dir, key)
      opts = [paths_opts: [home_dir: home]]
      binary = Path.join([bot_root, "versions", key, "bot/bin/lemon-bot"])

      File.rm!(binary)
      assert {:error, :invalid_bot_binary} = ManagedInstall.verify_active_bot(key, opts)

      File.ln_s!("other", binary)
      assert {:error, :invalid_bot_binary} = ManagedInstall.verify_active_bot(key, opts)
    end

    test "promotes a staged backend and reuses an existing usable install", %{tmp_dir: tmp_dir} do
      key = "2099.01.0-stable-test-platform"
      {home, bot_root} = bot_layout!(tmp_dir, "2026.10.0-stable-test-platform")
      opts = [paths_opts: [home_dir: home]]

      partial = Path.join([bot_root, "versions", "#{key}.partial"])
      File.mkdir_p!(Path.join(partial, "bot/bin"))
      staged = Path.join(partial, "bot/bin/lemon-bot")
      File.write!(staged, "#!/bin/sh\n")
      File.chmod!(staged, 0o755)

      assert {:ok, final} = ManagedInstall.promote_bot(partial, key, opts)
      assert final == Path.join([bot_root, "versions", key])
      refute File.exists?(partial)
      assert File.exists?(Path.join(final, "bot/bin/lemon-bot"))

      assert {:ok, ^final} = ManagedInstall.promote_bot(partial, key, opts)
    end

    test "verifies the staged backend version, assets, and host-native addons", %{
      tmp_dir: tmp_dir
    } do
      dir = Path.join(tmp_dir, "staged")
      File.mkdir_p!(Path.join(dir, "bot/bin"))
      binary = Path.join(dir, "bot/bin/lemon-bot")
      File.write!(binary, "#!/bin/sh\nprintf 'lemon-bot 2099.01.0\\n'\n")
      File.chmod!(binary, 0o755)

      assert {:error, {:incomplete_bot_release, "bot/web"}} =
               ManagedInstall.verify_bot_staged(dir, "2099.01.0", "test-platform", [])

      File.mkdir_p!(Path.join(dir, "bot/web"))
      File.write!(Path.join(dir, "bot/web/index.html"), "<html>")

      assert :ok =
               ManagedInstall.verify_bot_staged(dir, "2099.01.0", "test-platform",
                 release_command_env: []
               )

      assert {:error, :staged_bot_version_mismatch} =
               ManagedInstall.verify_bot_staged(dir, "2100.01.0", "test-platform",
                 release_command_env: []
               )

      assert {:error, {:incomplete_bot_release, "bot/node_modules/@img/sharp-darwin-arm64"}} =
               ManagedInstall.verify_bot_staged(dir, "2099.01.0", "darwin-arm64",
                 release_command_env: []
               )

      for sub <- ["@img/sharp-darwin-arm64", "@img/sharp-libvips-darwin-arm64"] do
        File.mkdir_p!(Path.join([dir, "bot/node_modules", sub]))
        File.write!(Path.join([dir, "bot/node_modules", sub, "package.json"]), "{}")
      end

      assert {:error, {:incomplete_bot_release, "bot/node_modules/@img/sharp-darwin-arm64/lib"}} =
               ManagedInstall.verify_bot_staged(dir, "2099.01.0", "darwin-arm64",
                 release_command_env: []
               )

      addon =
        Path.join([dir, "bot/node_modules/@img/sharp-darwin-arm64/lib/sharp-darwin-arm64.node"])

      File.mkdir_p!(Path.dirname(addon))
      File.write!(addon, "")

      assert :ok =
               ManagedInstall.verify_bot_staged(dir, "2099.01.0", "darwin-arm64",
                 release_command_env: []
               )
    end

    test "refuses a staged backend whose launcher is a symlink", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "linked-staged")
      File.mkdir_p!(Path.join(dir, "bot/bin"))
      File.mkdir_p!(Path.join(dir, "bot/web"))
      File.write!(Path.join(dir, "bot/web/index.html"), "<html>")
      File.write!(Path.join(dir, "bot/bin/real"), "#!/bin/sh\n")
      File.ln_s!("real", Path.join(dir, "bot/bin/lemon-bot"))

      assert {:error, :bot_binary_is_symlink} =
               ManagedInstall.verify_bot_staged(dir, "2099.01.0", "test-platform", [])
    end

    test "prunes unprotected backend installs, keeping the two newest others", %{tmp_dir: tmp_dir} do
      {home, bot_root} = bot_layout!(tmp_dir, "2026.10.0-stable-test-platform")
      opts = [paths_opts: [home_dir: home]]

      keys =
        for version <- ["2015.01.0", "2016.01.0", "2017.01.0", "2018.01.0"] do
          key = "#{version}-stable-test-platform"
          install_bot!(bot_root, key)
          key
        end

      assert :ok = ManagedInstall.prune_bot(["2026.10.0-stable-test-platform"], opts)

      versions = Path.join(bot_root, "versions")
      assert File.dir?(Path.join(versions, "2026.10.0-stable-test-platform"))
      assert File.dir?(Path.join(versions, Enum.at(keys, 3)))
      assert File.dir?(Path.join(versions, Enum.at(keys, 2)))
      refute File.dir?(Path.join(versions, Enum.at(keys, 1)))
      refute File.dir?(Path.join(versions, Enum.at(keys, 0)))
    end
  end
end
