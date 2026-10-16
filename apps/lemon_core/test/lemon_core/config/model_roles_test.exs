defmodule LemonCore.Config.ModelRolesTest do
  use ExUnit.Case, async: false

  alias LemonCore.Config
  alias LemonCore.Config.{Modular, ValidationError}

  setup do
    root =
      Path.join(System.tmp_dir!(), "model_roles_config_#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    project = Path.join(root, "project")
    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(Path.join(project, ".lemon"))
    saved_home = System.get_env("HOME")
    saved_paths = Application.get_env(:lemon_core, :paths)
    System.put_env("HOME", home)
    Application.put_env(:lemon_core, :paths, home_dir: home)

    on_exit(fn ->
      if saved_home, do: System.put_env("HOME", saved_home), else: System.delete_env("HOME")

      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)

      File.rm_rf!(root)
    end)

    %{home: home, project: project}
  end

  test "global and project string maps propagate through the canonical facade", context do
    File.write!(Path.join([context.home, ".lemon", "config.toml"]), """
    [model_roles]
    default = "openai:gpt-4"
    smol = "openai:gpt-4o-mini"
    slow = "@default"
    custom = "@slow"
    """)

    File.write!(Path.join([context.project, ".lemon", "config.toml"]), """
    [model_roles]
    smol = "anthropic:claude-sonnet-4"
    task = "@custom"
    """)

    roles = %{
      "default" => "openai:gpt-4",
      "smol" => "anthropic:claude-sonnet-4",
      "slow" => "@default",
      "custom" => "@slow",
      "task" => "@custom"
    }

    assert Modular.load(project_dir: context.project).model_roles == roles
    config = Config.load(context.project, cache: false)
    assert config.model_roles == roles
    assert Config.to_map(config).model_roles == roles
    assert Config.get(config, :model_roles) == roles

    overridden =
      Config.load(context.project,
        cache: false,
        overrides: %{
          "model_roles" => %{"custom" => "openai:gpt-4o", "new_role" => "@default"}
        }
      )

    assert overridden.model_roles ==
             Map.merge(roles, %{"custom" => "openai:gpt-4o", "new_role" => "@default"})

    assert Enum.all?(Map.keys(overridden.model_roles), &is_binary/1)
  end

  test "absent roles default to an empty string map", context do
    assert Modular.load(project_dir: context.project).model_roles == %{}
    assert Config.load(context.project, cache: false).model_roles == %{}
  end

  test "invalid role mappings fail even without optional general validation", context do
    File.write!(Path.join([context.project, ".lemon", "config.toml"]), """
    [model_roles]
    smol = 42
    """)

    assert_raise ValidationError, fn -> Modular.load(project_dir: context.project) end
    assert {:error, errors} = Modular.load_with_validation(project_dir: context.project)
    assert Enum.any?(errors, &String.contains?(&1, "model_roles.smol"))

    for mapping <- [%{"smol" => ""}, %{"@bad" => "model"}, "not-a-table"] do
      assert {:error, errors} = Modular.validate_settings(%{"model_roles" => mapping})
      assert Enum.any?(errors, &String.contains?(&1, "model_roles"))
    end
  end

  test "model_routing defaults to an empty raw table", context do
    assert Modular.load(project_dir: context.project).model_routing == %{}
    assert Config.load(context.project, cache: false).model_routing == %{}
    assert Config.to_map(Config.load(context.project, cache: false)).model_routing == %{}
  end

  test "model_routing raw table merges global then project without resolving models", context do
    File.write!(Path.join([context.home, ".lemon", "config.toml"]), """
    [model_routing]
    enabled = false
    max_cost_usd = 1.5

    [[model_routing.rules]]
    model = "@smol"
    max_chars = 200
    """)

    File.write!(Path.join([context.project, ".lemon", "config.toml"]), """
    [model_routing]
    enabled = true

    [[model_routing.rules]]
    model = "openai:gpt-4o"
    contains = "refactor"
    min_chars = 10
    """)

    expected = %{
      "enabled" => true,
      "max_cost_usd" => 1.5,
      "rules" => [
        %{"model" => "openai:gpt-4o", "contains" => "refactor", "min_chars" => 10}
      ]
    }

    assert Modular.load(project_dir: context.project).model_routing == expected
    config = Config.load(context.project, cache: false)
    assert config.model_routing == expected
    assert Config.get(config, :model_routing) == expected
  end
end
