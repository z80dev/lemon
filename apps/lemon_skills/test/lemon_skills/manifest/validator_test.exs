defmodule LemonSkills.Manifest.ValidatorTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Manifest.Validator

  describe "validate_string_list - requires_tools" do
    test "accepts a list of strings" do
      manifest = %{"requires_tools" => ["bash", "git"]}
      assert {:ok, _} = Validator.validate(manifest)
    end

    test "accepts an empty list" do
      manifest = %{"requires_tools" => []}
      assert {:ok, _} = Validator.validate(manifest)
    end

    test "rejects a list with non-binary entries" do
      manifest = %{"requires_tools" => ["bash", 42, :atom]}
      assert {:error, reason} = Validator.validate(manifest)
      assert reason =~ "requires_tools"
    end

    test "rejects a list with only non-binary entries" do
      manifest = %{"requires_tools" => [1, 2, 3]}
      assert {:error, reason} = Validator.validate(manifest)
      assert reason =~ "requires_tools"
    end
  end

  describe "validate_string_list - fallback_for_tools" do
    test "rejects non-string list entries" do
      manifest = %{"fallback_for_tools" => [:not_a_string]}
      assert {:error, reason} = Validator.validate(manifest)
      assert reason =~ "fallback_for_tools"
    end
  end

  describe "validate_string_list - required_environment_variables" do
    test "rejects non-string list entries" do
      manifest = %{"required_environment_variables" => [%{"not" => "string"}]}
      assert {:error, reason} = Validator.validate(manifest)
      assert reason =~ "required_environment_variables"
    end
  end
end
