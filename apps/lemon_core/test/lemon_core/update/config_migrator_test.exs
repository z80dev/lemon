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

    test "reports every removed top-level engine configuration surface" do
      content = """
      engine = "codex"
      default_engine = "claude"
      engine_preference = "claude"
      preferred_engine = "pi"
      known_engines = ["lemon", "codex"]
      custom_engines = ["acme"]
      engines = ["acme"]

      [defaults]
      engine = "codex"
      default_engine = "claude"
      preferred_engine = "pi"

      [profiles.default]
      engine = "codex"
      default_engine = "claude"
      preferred_engine = "pi"

      [gateway]
      engine = "codex"
      default_engine = "claude"
      preferred_engine = "pi"
      known_engines = ["lemon", "codex"]
      custom_engines = ["acme"]

      [gateway.projects.docs]
      engine = "codex"
      default_engine = "claude"
      preferred_engine = "pi"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 42
      engine = "codex"
      default_engine = "claude"
      preferred_engine = "pi"

      [gateway.webhook]
      default_engine = "codex"

      [integrations.webhook]
      default_engine = "claude"

      [gateway.engines.acme]
      module = "Acme.Engine"
      known_engines = ["acme"]
      """

      path = tmp_config(content)

      try do
        assert {:needs_migration, issues} = ConfigMigrator.check(path)

        for config_path <- [
              "engine",
              "default_engine",
              "engine_preference",
              "preferred_engine",
              "known_engines",
              "custom_engines",
              "engines",
              "defaults.engine",
              "defaults.default_engine",
              "defaults.preferred_engine",
              "profiles.default.engine",
              "profiles.default.default_engine",
              "profiles.default.preferred_engine",
              "gateway.engine",
              "gateway.default_engine",
              "gateway.preferred_engine",
              "gateway.known_engines",
              "gateway.custom_engines",
              "gateway.projects.docs.engine",
              "gateway.projects.docs.default_engine",
              "gateway.projects.docs.preferred_engine",
              "gateway.bindings[0].engine",
              "gateway.bindings[0].default_engine",
              "gateway.bindings[0].preferred_engine",
              "gateway.webhook.default_engine",
              "integrations.webhook.default_engine",
              "gateway.engines",
              "gateway.engines.acme.known_engines"
            ] do
          assert Enum.any?(issues, &String.contains?(&1, config_path)),
                 "expected diagnostic for #{config_path}, got: #{inspect(issues)}"
        end

        assert Enum.all?(issues, &String.contains?(&1, "native Lemon"))

        assert Enum.any?(issues, fn issue ->
                 String.contains?(issue, "gateway.engines") and
                   String.contains?(issue, "LemonGateway.Engine")
               end)
      after
        File.rm(path)
      end
    end

    test "reports removed runtime CLI configuration" do
      content = """
      [runtime.cli.codex]
      engine = "codex"
      default_engine = "codex"
      """

      path = tmp_config(content)

      try do
        assert {:needs_migration, issues} = ConfigMigrator.check(path)

        assert "The [runtime.cli] section has been removed; all subagent tasks run natively." in issues
        assert Enum.any?(issues, &String.contains?(&1, "runtime.cli.codex.engine"))
      after
        File.rm(path)
      end
    end

    test "migrate! refuses success when removed runner settings remain" do
      content = """
      [agent]
      provider = "anthropic"

      [runtime.cli.codex]
      model = "gpt-4"
      """

      path = tmp_config(content)

      try do
        assert {:error, {:manual_steps_required, errors}} = ConfigMigrator.migrate!(path)

        assert "The [runtime.cli] section has been removed; all subagent tasks run natively." in errors
      after
        File.rm_rf(path)
        File.rm_rf(ConfigMigrator.backup_path(path))
      end
    end

    test "skips [agent] migration when canonical tables already exist" do
      content = """
      [agent]
      provider = "anthropic"

      [defaults]
      model = "claude-opus"
      """

      path = tmp_config(content)

      try do
        assert {:error, {:manual_steps_required, errors}} = ConfigMigrator.migrate!(path)
        assert Enum.any?(errors, &String.contains?(&1, "[agent]"))
        assert File.read!(path) == content
      after
        File.rm_rf(path)
        File.rm_rf(ConfigMigrator.backup_path(path))
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
