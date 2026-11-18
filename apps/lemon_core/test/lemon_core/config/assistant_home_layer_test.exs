defmodule LemonCore.Config.AssistantHomeLayerTest do
  # Redirects HOME and LEMON_AGENT_DIR, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias LemonCore.Config.Modular
  alias LemonCore.ConfigCache

  setup do
    # Outside every Git repository, so each directory is its own trusted root.
    base = Path.join(System.tmp_dir!(), "lemon-home-layer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    {:ok, base} = LemonCore.TrustedRoot.realpath(base)
    previous = for key <- ~w(HOME LEMON_AGENT_DIR), into: %{}, do: {key, System.get_env(key)}
    System.put_env("HOME", Path.join(base, "home"))
    System.put_env("LEMON_AGENT_DIR", Path.join(base, "agent"))

    if !ConfigCache.available?(), do: {:ok, _pid} = ConfigCache.start_link([])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(base)
    end)

    write!(Modular.global_path(), "[defaults]\nmodel = \"global-model\"\n")
    {:ok, base: base}
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp model(dir), do: Modular.load(project_dir: dir).agent.default_model
  defp cached_model(dir), do: ConfigCache.get(dir, mtime_check_interval_ms: 0).agent.default_model

  test "an ordinary project directory still merges its project layer", %{base: base} do
    project = Path.join(base, "project")
    write!(Path.join(project, ".lemon/config.toml"), "[defaults]\nmodel = \"project-model\"\n")

    assert model(project) == "project-model"
    assert cached_model(project) == "project-model"
  end

  for home <- [:default, :profile] do
    test "the #{home} assistant home and its descendants never read a project layer" do
      home_dir =
        case unquote(home) do
          :default -> LemonCore.Cwd.assistant_home()
          :profile -> LemonCore.Paths.home_path(["profiles", "p1", "workspace"])
        end

      sub = Path.join(home_dir, "notes/deep")
      File.mkdir_p!(sub)
      write!(Path.join(home_dir, ".lemon/config.toml"), "[defaults]\nmodel = \"home-model\"\n")
      write!(Path.join(sub, ".lemon/config.toml"), "[defaults]\nmodel = \"sub-model\"\n")

      for dir <- [home_dir, sub] do
        assert model(dir) == "global-model", dir
        assert cached_model(dir) == "global-model", dir
        assert Modular.load_with_validation(project_dir: dir) |> elem(0) == :ok
        assert Modular.project_layer_path(dir) == nil
      end
    end
  end

  test "malformed home-local TOML is never parsed and keeps the global config" do
    home_dir = LemonCore.Cwd.assistant_home()
    write!(Path.join(home_dir, ".lemon/config.toml"), "value = \n[[[broken")

    assert model(home_dir) == "global-model"
    assert cached_model(home_dir) == "global-model"
    assert {:ok, _config} = Modular.load_with_validation(project_dir: home_dir)
  end
end
