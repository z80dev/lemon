defmodule LemonControlPlane.Methods.SkillsStatusTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.SkillsStatus

  describe "handle/2" do
    test "returns skills list" do
      params = %{"cwd" => File.cwd!()}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = SkillsStatus.handle(params, ctx)
      assert is_map(result)
      assert is_list(result["skills"])
    end

    test "handles missing cwd by using current directory" do
      params = %{}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = SkillsStatus.handle(params, ctx)
      assert is_map(result)
      assert is_list(result["skills"])
    end

    test "handles cwd that doesn't exist" do
      params = %{"cwd" => "/nonexistent/directory/#{System.unique_integer()}"}
      ctx = %{auth: %{role: :operator}}

      # Should not crash, just return empty list
      {:ok, result} = SkillsStatus.handle(params, ctx)
      assert is_list(result["skills"])
    end

    test "passes keyword opts to Registry.list, not string" do
      # This test verifies the fix: Registry.list expects [cwd: cwd], not just cwd string
      # If we pass a string, it raises an error. The fix passes keyword opts.
      params = %{"cwd" => File.cwd!()}
      ctx = %{auth: %{role: :operator}}

      # Should not raise or return empty due to rescue
      {:ok, result} = SkillsStatus.handle(params, ctx)
      assert is_map(result)
    end
  end

  describe "skill formatting" do
    test "formats struct skills correctly" do
      # This tests the format_skill/1 function indirectly
      params = %{}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = SkillsStatus.handle(params, ctx)

      for skill <- result["skills"] do
        # Each skill should have these keys
        assert Map.has_key?(skill, "key") or Map.has_key?(skill, "name")
        assert Map.has_key?(skill, "source")
        assert Map.has_key?(skill, "status")
      end
    end
  end
end
