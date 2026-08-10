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
      assert Paths.project_path("/srv/app", "proofs") == "/srv/app/.lemon/proofs"
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
      assert Paths.project_path("/srv/app", "proofs") == "/srv/app/.myapp/proofs"
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

  describe "consumers follow the configuration" do
    test "Config and Config.Modular resolve through Paths" do
      put_paths(state_dir: ".myapp", config_file: "lemon.toml")

      assert LemonCore.Config.project_path("/srv/app") == "/srv/app/.myapp/lemon.toml"
      assert LemonCore.Config.Modular.project_path("/srv/app") == "/srv/app/.myapp/lemon.toml"
      assert LemonCore.Config.global_path() == LemonCore.Config.Modular.global_path()
      assert LemonCore.Config.global_path() =~ ".myapp/lemon.toml"
    end

    test "the doctor's skills check follows the state directory" do
      put_paths(home_state_dir: "/tmp/lemon-paths-test-skills")

      [check] = LemonCore.Doctor.Checks.Skills.run()

      assert check.message =~ "/tmp/lemon-paths-test-skills/skills" or
               check.remediation =~ "/tmp/lemon-paths-test-skills/skills"
    end
  end
end
