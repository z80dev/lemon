defmodule LemonControlPlane.Methods.SkillsMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.SkillsInstall

  describe "SkillsInstall" do
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
end
