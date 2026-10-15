defmodule LemonCli.Setup.ScaffoldTest do
  use ExUnit.Case, async: true

  alias LemonCli.Setup.Scaffold
  alias LemonCore.Config.Modular

  describe "generate/1" do
    test "names no provider, default or credential reference" do
      result = Scaffold.generate()
      {:ok, settings} = Toml.decode(result)

      refute Map.has_key?(settings, "defaults")
      refute Map.has_key?(settings, "providers")
      refute Map.has_key?(settings, "agent")
    end

    test "includes [runtime] section" do
      result = Scaffold.generate()
      assert String.contains?(result, "[runtime]")
    end

    test "includes [gateway] section" do
      result = Scaffold.generate()
      assert String.contains?(result, "[gateway]")
    end

    test "is valid TOML that passes config validation" do
      {:ok, settings} = Toml.decode(Scaffold.generate())
      assert {:ok, _config} = Modular.validate_settings(settings)
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
    test "project_config_exists? returns false for nonexistent dir" do
      dir = System.tmp_dir!() |> Path.join("no_such_project_#{:rand.uniform(999_999)}")
      refute Scaffold.project_config_exists?(dir)
    end
  end
end
