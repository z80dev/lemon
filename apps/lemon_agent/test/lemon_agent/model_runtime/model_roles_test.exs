defmodule LemonAgent.ModelRuntime.ModelRolesTest do
  use ExUnit.Case, async: true

  alias LemonAgent.ModelRuntime.ModelRoles

  test "concrete specs and models pass through without inventing role IDs" do
    model = %LemonAi.Types.Model{provider: :openai, id: "gpt-4"}
    assert ModelRoles.resolve("openai:gpt-4", %{}, nil) == {:ok, "openai:gpt-4"}
    assert ModelRoles.resolve("default", %{}, nil) == {:ok, "default"}
    assert ModelRoles.resolve(model, %{}, nil) == {:ok, model}
  end

  test "custom and built-in aliases recursively expand" do
    roles = %{"default" => "@slow", "slow" => "@review", "review" => "openai:gpt-4"}
    assert ModelRoles.resolve("@default", roles, nil) == {:ok, "openai:gpt-4"}
    assert ModelRoles.resolve("@review", roles, nil) == {:ok, "openai:gpt-4"}
  end

  test "plan and commit roles honor configured model and role mappings" do
    roles = %{
      "plan" => "@slow",
      "slow" => "anthropic:planner",
      "commit" => "@smol",
      "smol" => "openai:committer"
    }

    assert ModelRoles.resolve("@plan", roles, "openai:active") ==
             {:ok, "anthropic:planner"}

    assert ModelRoles.resolve("@commit", roles, "openai:active") ==
             {:ok, "openai:committer"}
  end

  test "unconfigured built-ins use only the caller's concrete fallback" do
    for role <- ~w(default smol slow plan commit) do
      assert ModelRoles.resolve("@" <> role, %{}, "anthropic:active") ==
               {:ok, "anthropic:active"}
    end

    assert {:error, reason} = ModelRoles.resolve("@smol", %{}, nil)
    assert reason =~ "concrete model fallback"
  end

  test "cycles and unknown custom roles are actionable errors, not fallbacks" do
    assert {:error, cycle} =
             ModelRoles.resolve("@smol", %{"smol" => "@slow", "slow" => "@smol"}, "active")

    assert cycle =~ "cycle"
    assert cycle =~ "@smol"
    assert cycle =~ "@slow"

    assert {:error, self_cycle} =
             ModelRoles.resolve("@default", %{"default" => "@default"}, "active")

    assert self_cycle =~ "@default -> @default"

    assert {:error, unknown} = ModelRoles.resolve("@missing", %{}, "active")
    assert unknown =~ "configure model_roles.missing"

    assert {:error, _} = ModelRoles.resolve("@default", %{}, "@default")
  end

  test "malformed and unused bad mappings fail instead of being ignored" do
    for roles <- [
          %{"smol" => nil},
          %{"slow" => 2},
          %{"default" => " "},
          %{"@bad" => "active"},
          []
        ] do
      assert {:error, reason} = ModelRoles.resolve("active", roles, "fallback")
      assert reason =~ "model_roles"
    end

    assert {:error, unknown} = ModelRoles.resolve("active", %{"unused" => "@missing"}, "fallback")
    assert unknown =~ "unknown model role @missing"
  end

  test "arbitrary role names are never converted to atoms" do
    role = "custom_role_#{System.unique_integer([:positive])}"

    assert ModelRoles.resolve("@" <> role, %{role => "openai:gpt-4"}, nil) ==
             {:ok, "openai:gpt-4"}

    assert_raise ArgumentError, fn -> String.to_existing_atom(role) end
  end
end
