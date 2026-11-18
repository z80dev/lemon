defmodule LemonCore.PathsTest do
  # Mutates :lemon_core app env, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  alias LemonCore.Paths

  doctest LemonCore.Paths

  setup do
    original = Application.get_env(:lemon_core, :paths)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :paths)
      else
        Application.put_env(:lemon_core, :paths, original)
      end
    end)

    :ok
  end

  defp put_paths(settings) do
    original = Application.get_env(:lemon_core, :paths, [])
    Application.put_env(:lemon_core, :paths, Keyword.merge(original, settings))
  end

  describe "defaults" do
    test "are the reference runtime's layout" do
      assert Paths.state_dir_name() == ".lemon"
      assert Paths.config_file_name() == "config.toml"
      assert Paths.home_state_dir(home_dir: "/home/x") == "/home/x/.lemon"
      assert Paths.global_config(home_dir: "/home/x") == "/home/x/.lemon/config.toml"
      assert Paths.project_config("/srv/app") == "/srv/app/.lemon/config.toml"
      assert Paths.home_path("store", home_dir: "/home/x") == "/home/x/.lemon/store"
      assert Paths.project_path("/srv/app", "extensions") == "/srv/app/.lemon/extensions"
    end

    test "home comes from HOME when no option is given" do
      original = System.get_env("HOME")
      System.put_env("HOME", "/test/home")
      on_exit(fn -> if original, do: System.put_env("HOME", original) end)

      assert Paths.home_dir() == "/test/home"
      assert Paths.global_config() == "/test/home/.lemon/config.toml"
    end
  end

  describe "app env configuration" do
    test "renaming the state directory moves every derived path" do
      put_paths(state_dir: ".myapp")

      assert Paths.home_state_dir(home_dir: "/home/x") == "/home/x/.myapp"
      assert Paths.global_config(home_dir: "/home/x") == "/home/x/.myapp/config.toml"
      assert Paths.project_config("/srv/app") == "/srv/app/.myapp/config.toml"
      assert Paths.project_path("/srv/app", "extensions") == "/srv/app/.myapp/extensions"
    end

    test "renaming the config file moves both config paths" do
      put_paths(config_file: "lemon.toml")

      assert Paths.global_config(home_dir: "/home/x") == "/home/x/.lemon/lemon.toml"
      assert Paths.project_config("/srv/app") == "/srv/app/.lemon/lemon.toml"
    end

    test "home_state_dir can be pinned outright" do
      put_paths(home_state_dir: "/var/lib/myapp")

      assert Paths.home_state_dir(home_dir: "/home/x") == "/var/lib/myapp"
      assert Paths.home_path("store", home_dir: "/home/x") == "/var/lib/myapp/store"
      assert Paths.global_config(home_dir: "/home/x") == "/var/lib/myapp/config.toml"
    end

    test "global_config can be pinned outside any state directory" do
      put_paths(global_config: "/etc/myapp/config.toml")

      assert Paths.global_config() == "/etc/myapp/config.toml"
      # The project config is unaffected by a global override.
      assert Paths.project_config("/srv/app") == "/srv/app/.lemon/config.toml"
    end

    test "options win over app env" do
      put_paths(state_dir: ".myapp")

      assert Paths.project_config("/srv/app", state_dir: ".other") ==
               "/srv/app/.other/config.toml"
    end
  end

  describe "store directory" do
    @tag :tmp_dir
    test "resolves companion databases beside explicit primary files", %{tmp_dir: dir} do
      for extension <- [".db", ".sqlite", ".sqlite3", ".SQLITE3"] do
        assert Paths.store_dir(Path.join(dir, "primary" <> extension)) == dir
      end

      assert Paths.store_dir(Path.join(dir, "store")) == Path.join(dir, "store")
    end

    @tag :tmp_dir
    test "preserves database-named directories and explicit directory paths", %{tmp_dir: dir} do
      existing = Path.join(dir, "existing.db")
      File.mkdir_p!(existing)

      assert Paths.store_dir(existing) == existing

      assert Paths.store_dir(Path.join(dir, "new.sqlite3") <> "/") ==
               Path.join(dir, "new.sqlite3")
    end
  end

  describe "checkpoint directory" do
    test "defaults under the system temp dir, resolved per call" do
      assert Paths.checkpoint_dir() == Path.join(System.tmp_dir!(), "lemon_checkpoints")
    end

    test "tracks TMPDIR at call time rather than compile time" do
      original = System.get_env("TMPDIR")
      # System.tmp_dir!/0 only accepts a directory that exists and is writable.
      probe = "/tmp/lemon-paths-checkpoint-probe"
      File.mkdir_p!(probe)
      on_exit(fn -> File.rm_rf!(probe) end)
      System.put_env("TMPDIR", probe)

      on_exit(fn ->
        if original, do: System.put_env("TMPDIR", original), else: System.delete_env("TMPDIR")
      end)

      assert Paths.checkpoint_dir() == "/tmp/lemon-paths-checkpoint-probe/lemon_checkpoints"
    end

    test "can be pinned somewhere durable" do
      put_paths(checkpoint_dir: "/var/lib/lemon/checkpoints")

      assert Paths.checkpoint_dir() == "/var/lib/lemon/checkpoints"
    end

    test "Checkpoint and its diagnostics resolve to the same directory" do
      put_paths(checkpoint_dir: "/var/lib/lemon/checkpoints")

      assert LemonCore.Checkpoint.checkpoint_dir() == "/var/lib/lemon/checkpoints"

      assert LemonCore.Doctor.CheckpointDiagnostics.summary(:operator, limit: 1).store ==
               LemonCore.Doctor.Redaction.path_ref("/var/lib/lemon/checkpoints")
    end

    test "an explicit :checkpoint_dir option still wins in diagnostics" do
      put_paths(checkpoint_dir: "/var/lib/lemon/checkpoints")

      summary =
        LemonCore.Doctor.CheckpointDiagnostics.summary(:operator,
          checkpoint_dir: "/tmp/elsewhere"
        )

      assert summary.store == LemonCore.Doctor.Redaction.path_ref("/tmp/elsewhere")
    end
  end

  describe "consumers follow the configuration" do
    test "Config and Config.Modular resolve through Paths" do
      put_paths(state_dir: ".myapp", config_file: "lemon.toml")

      assert LemonCore.Config.project_path("/srv/app") == "/srv/app/.myapp/lemon.toml"
      assert LemonCore.Config.Modular.project_path("/srv/app") == "/srv/app/.myapp/lemon.toml"
      assert LemonCore.Config.global_path() == LemonCore.Config.Modular.global_path()
      assert LemonCore.Config.global_path() =~ ".myapp/lemon.toml"
    end
  end
end
