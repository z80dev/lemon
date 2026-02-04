defmodule LemonControlPlane.Methods.SkillsMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{SkillsInstall, SkillsUpdate}

  setup do
    # Clean up any existing test data
    :ok
  end

  describe "SkillsInstall" do
    test "name returns correct method name" do
      assert SkillsInstall.name() == "skills.install"
    end

    test "scopes returns admin scope" do
      assert SkillsInstall.scopes() == [:admin]
    end

    test "returns error when skillKey is missing" do
      ctx = %{auth: %{role: :operator}}
      params = %{}

      {:error, error} = SkillsInstall.handle(params, ctx)

      assert error == {:invalid_request, "skillKey is required"}
    end

    test "returns error when skillKey is empty" do
      ctx = %{auth: %{role: :operator}}
      params = %{"skillKey" => ""}

      {:error, error} = SkillsInstall.handle(params, ctx)

      assert error == {:invalid_request, "skillKey is required"}
    end
  end

  describe "SkillsUpdate" do
    test "name returns correct method name" do
      assert SkillsUpdate.name() == "skills.update"
    end

    test "scopes returns admin scope" do
      assert SkillsUpdate.scopes() == [:admin]
    end

    test "returns error when skillKey is missing" do
      ctx = %{auth: %{role: :operator}}
      params = %{}

      {:error, error} = SkillsUpdate.handle(params, ctx)

      assert error == {:invalid_request, "skillKey is required"}
    end

    test "applies enabled config change when provided" do
      ctx = %{auth: %{role: :operator}}
      params = %{
        "skillKey" => "test-skill",
        "enabled" => false,
        "cwd" => "/tmp/test"
      }

      # This will use the fallback path since LemonSkills.Config might not be fully loaded
      {:ok, result} = SkillsUpdate.handle(params, ctx)

      assert result["skillKey"] == "test-skill"
      assert result["enabled"] == false
    end

    test "applies env config change when provided" do
      ctx = %{auth: %{role: :operator}}
      params = %{
        "skillKey" => "test-skill",
        "env" => %{"API_KEY" => "test123"},
        "cwd" => "/tmp/test"
      }

      {:ok, result} = SkillsUpdate.handle(params, ctx)

      assert result["skillKey"] == "test-skill"
      assert result["env"] == %{"API_KEY" => "test123"}
    end
  end
end
