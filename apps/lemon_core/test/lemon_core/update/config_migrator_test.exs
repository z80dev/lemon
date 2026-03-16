defmodule LemonCore.Update.ConfigMigratorTest do
  use ExUnit.Case, async: true

  alias LemonCore.Update.ConfigMigrator

  defp tmp_config(content) do
    path = System.tmp_dir!() |> Path.join("migrator_test_#{:rand.uniform(999_999)}.toml")
    File.write!(path, content)
    path
  end

  describe "check/1" do
    test "returns :ok for clean config" do
      path = tmp_config("[defaults]\nprovider = \"anthropic\"\n")

      try do
        assert :ok = ConfigMigrator.check(path)
      after
        File.rm(path)
      end
    end

    test "returns :needs_migration for deprecated [agent] section" do
      path = tmp_config("[agent]\ndefault_model = \"claude\"\n")

      try do
        assert {:needs_migration, issues} = ConfigMigrator.check(path)
        assert Enum.any?(issues, &String.contains?(&1, "[agent]"))
      after
        File.rm(path)
      end
    end

    test "returns :needs_migration for deprecated [agents.*] section" do
      path = tmp_config("[agents.myagent]\nname = \"My Agent\"\n")

      try do
        assert {:needs_migration, issues} = ConfigMigrator.check(path)
        assert Enum.any?(issues, &String.contains?(&1, "[agents"))
      after
        File.rm(path)
      end
    end

    test "returns :needs_migration for deprecated [tools] section" do
      path = tmp_config("[tools.web]\nenabled = true\n")

      try do
        assert {:needs_migration, issues} = ConfigMigrator.check(path)
        assert Enum.any?(issues, &String.contains?(&1, "[tools"))
      after
        File.rm(path)
      end
    end

    test "returns error for non-existent file" do
      assert {:error, {:read_failed, _}} = ConfigMigrator.check("/nonexistent/path.toml")
    end
  end

  describe "migrate!/1" do
    test "migrates [agents.*] to [profiles.*]" do
      content = "[agents.myagent]\nname = \"My Agent\"\n"
      path = tmp_config(content)

      try do
        assert :ok = ConfigMigrator.migrate!(path)
        migrated = File.read!(path)
        assert String.contains?(migrated, "[profiles.myagent]")
        refute String.contains?(migrated, "[agents.myagent]")
      after
        File.rm_rf(path)
        File.rm_rf(ConfigMigrator.backup_path(path))
      end
    end

    test "migrates [tools.*] to [runtime.tools.*]" do
      content = "[tools.web]\nenabled = true\n"
      path = tmp_config(content)

      try do
        assert :ok = ConfigMigrator.migrate!(path)
        migrated = File.read!(path)
        assert String.contains?(migrated, "[runtime.tools")
      after
        File.rm_rf(path)
        File.rm_rf(ConfigMigrator.backup_path(path))
      end
    end

    test "creates a backup file" do
      path = tmp_config("[agents.x]\nname = \"x\"\n")

      try do
        ConfigMigrator.migrate!(path)
        assert File.exists?(ConfigMigrator.backup_path(path))
      after
        File.rm_rf(path)
        File.rm_rf(ConfigMigrator.backup_path(path))
      end
    end

    test "migrates [agent] section: provider/model/thinking_level to [defaults], rest to [runtime]" do
      content = """
      [agent]
      provider = "anthropic"
      model = "claude-opus"
      thinking_level = "high"
      max_tokens = 4096
      timeout = 30
      """

      path = tmp_config(content)

      try do
        assert :ok = ConfigMigrator.migrate!(path)
        migrated = File.read!(path)

        # [agent] header must be gone
        refute String.contains?(migrated, "[agent]")

        # defaults-bound keys must appear under [defaults]
        assert String.contains?(migrated, "[defaults]")
        assert String.contains?(migrated, "provider = \"anthropic\"")
        assert String.contains?(migrated, "model = \"claude-opus\"")
        assert String.contains?(migrated, "thinking_level = \"high\"")

        # runtime-bound keys must appear under [runtime]
        assert String.contains?(migrated, "[runtime]")
        assert String.contains?(migrated, "max_tokens = 4096")
        assert String.contains?(migrated, "timeout = 30")

        # No deprecated sections remain
        assert :ok = ConfigMigrator.check(path)
      after
        File.rm_rf(path)
        File.rm_rf(ConfigMigrator.backup_path(path))
      end
    end
  end
end
