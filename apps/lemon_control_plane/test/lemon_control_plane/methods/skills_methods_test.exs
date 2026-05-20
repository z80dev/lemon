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
      skill_key = "test-skill-#{System.unique_integer([:positive])}"

      params = %{
        "skillKey" => skill_key,
        "enabled" => false,
        "cwd" => "/tmp/test"
      }

      # This will use the fallback path since LemonSkills.Config might not be fully loaded
      {:ok, result} = SkillsUpdate.handle(params, ctx)

      assert result["skillKey"] == skill_key
      assert result["enabled"] == false
      assert result["summary"]["action"] == "skills.update"
      assert result["summary"]["skillKeyReturned"] == true
      assert result["summary"]["enabledReturned"] == true
      assert result["summary"]["versionUpdate"] == false
      assert result["summary"]["envKeyCount"] == 0
      assert result["summary"]["cleanup"]["includesEnvironmentValues"] == false
      assert result["summary"]["cleanup"]["includesApprovalContext"] == false
    end

    test "applies env config change when provided" do
      ctx = %{auth: %{role: :operator}}
      skill_key = "test-skill-#{System.unique_integer([:positive])}"

      params = %{
        "skillKey" => skill_key,
        "env" => %{"API_KEY" => "test123", "PUBLIC_MODE" => "test"},
        "cwd" => "/tmp/test"
      }

      {:ok, result} = SkillsUpdate.handle(params, ctx)

      assert result["skillKey"] == skill_key

      assert result["env"] == %{
               "API_KEY" => %{"redacted" => true, "kind" => "secret"},
               "PUBLIC_MODE" => "test"
             }

      assert result["summary"]["action"] == "skills.update"
      assert result["summary"]["skillKeyReturned"] == true
      assert result["summary"]["envKeyCount"] == 2
      assert result["summary"]["envKeys"] == ["API_KEY", "PUBLIC_MODE"]
      assert result["summary"]["cleanup"]["includesEnvironmentValues"] == true
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "test123"
    end
  end
end
