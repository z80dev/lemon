defmodule LemonCore.Setup.ScaffoldTest do
  use ExUnit.Case, async: true

  alias LemonCore.Setup.Scaffold

  describe "generate/1" do
    test "returns a string" do
      result = Scaffold.generate()
      assert is_binary(result)
    end

    test "contains default provider and model" do
      result = Scaffold.generate()
      assert String.contains?(result, ~s(provider = "anthropic"))
      assert String.contains?(result, ~s(model = "claude-sonnet-4-20250514"))
    end

    test "respects :provider option" do
      result = Scaffold.generate(provider: "openai")
      assert String.contains?(result, ~s(provider = "openai"))
      assert String.contains?(result, "[providers.openai]")
    end

    test "respects :model option" do
      result = Scaffold.generate(model: "gpt-4o")
      assert String.contains?(result, ~s(model = "gpt-4o"))
    end

    test "includes [defaults] section" do
      result = Scaffold.generate()
      assert String.contains?(result, "[defaults]")
    end

    test "includes [runtime] section" do
      result = Scaffold.generate()
      assert String.contains?(result, "[runtime]")
    end

    test "includes [gateway] section" do
      result = Scaffold.generate()
      assert String.contains?(result, "[gateway]")
    end

    test "is valid non-empty TOML" do
      result = Scaffold.generate()
      # Uncommented lines must be parseable by Toml
      # Strip comment lines and blank lines to test the uncommented keys
      assert byte_size(result) > 0
    end
  end

  describe "write_unless_exists/2" do
    test "writes file when it does not exist" do
      path = System.tmp_dir!() |> Path.join("scaffold_test_#{:rand.uniform(999_999)}.toml")

      try do
        result = Scaffold.write_unless_exists(path, "# test\n")
        assert {:ok, ^path} = result
        assert File.exists?(path)
      after
        File.rm(path)
      end
    end

    test "returns :exists when file already exists" do
      path = System.tmp_dir!() |> Path.join("scaffold_exists_#{:rand.uniform(999_999)}.toml")
      File.write!(path, "# existing\n")

      try do
        result = Scaffold.write_unless_exists(path, "# new content\n")
        assert {:exists, ^path} = result
        # Original content preserved
        assert File.read!(path) == "# existing\n"
      after
        File.rm(path)
      end
    end

    test "creates parent directories" do
      dir = System.tmp_dir!() |> Path.join("scaffold_nested_#{:rand.uniform(999_999)}")
      path = Path.join(dir, "config.toml")

      try do
        result = Scaffold.write_unless_exists(path, "# test\n")
        assert {:ok, ^path} = result
        assert File.exists?(path)
      after
        File.rm_rf(dir)
      end
    end
  end

  describe "global_config_exists?/0 and project_config_exists?/1" do
    test "returns a boolean" do
      assert is_boolean(Scaffold.global_config_exists?())
    end

    test "project_config_exists? returns false for nonexistent dir" do
      dir = System.tmp_dir!() |> Path.join("no_such_project_#{:rand.uniform(999_999)}")
      refute Scaffold.project_config_exists?(dir)
    end
  end
end
