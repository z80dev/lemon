defmodule LemonCore.Config.ModularTest do
  @moduledoc """
  Tests for the Config.Modular module.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config.Modular
  alias LemonCore.Config.ValidationError

  setup do
    # Store original env vars to restore later
    original_env = System.get_env()

    on_exit(fn ->
      # Clear test env vars
      [
        "LEMON_DEFAULT_MODEL",
        "LEMON_GATEWAY_ENABLE_WEBHOOK",
        "LEMON_LOG_LEVEL",
        "LEMON_TUI_THEME",
        "ANTHROPIC_API_KEY"
      ]
      |> Enum.each(&System.delete_env/1)

      # Restore original values
      original_env
      |> Enum.each(fn {key, value} ->
        System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "load/1" do
    test "returns a Modular config struct" do
      config = Modular.load()

      assert %Modular{} = config
      assert config.agent.__struct__ == LemonCore.Config.Agent
      assert config.tools.__struct__ == LemonCore.Config.Tools
      assert config.gateway.__struct__ == LemonCore.Config.Gateway
      assert config.logging.__struct__ == LemonCore.Config.Logging
      assert config.tui.__struct__ == LemonCore.Config.TUI
      assert config.providers.__struct__ == LemonCore.Config.Providers
    end

    test "uses default values when no config files exist" do
      config = Modular.load(project_dir: "/nonexistent")

      # Just verify the config struct is valid and has expected types
      # (actual values may be overridden by existing config files)
      assert is_binary(config.agent.default_provider)
      assert is_binary(config.agent.default_model)

      # Gateway defaults
      assert is_integer(config.gateway.max_concurrent_runs)
      refute Map.has_key?(config.gateway, :default_engine)
      refute Map.has_key?(config.gateway, :engines)
      assert is_map(config.gateway.enabled_channels)
      assert is_map(config.gateway.channels)

      # TUI defaults
      assert is_binary(config.tui.theme)
      assert is_boolean(config.tui.debug)

      # Logging defaults
      assert config.logging.level == nil or is_atom(config.logging.level)
    end

    test "environment variables override defaults" do
      System.put_env("LEMON_DEFAULT_MODEL", "gpt-4o")
      System.put_env("LEMON_GATEWAY_ENABLE_WEBHOOK", "true")
      System.put_env("LEMON_LOG_LEVEL", "debug")
      System.put_env("LEMON_TUI_THEME", "dark")

      config = Modular.load()

      assert config.agent.default_model == "gpt-4o"
      assert config.gateway.enable_webhook == true
      assert config.logging.level == :debug
      assert config.tui.theme == "dark"
    end
  end

  describe "global_path/0" do
    test "returns path to global config" do
      path = Modular.global_path()

      assert path =~ ".lemon/config.toml"
    end

    test "uses HOME environment variable" do
      original_home = System.get_env("HOME")
      System.put_env("HOME", "/test/home")

      on_exit(fn ->
        if original_home do
          System.put_env("HOME", original_home)
        else
          System.delete_env("HOME")
        end
      end)

      path = Modular.global_path()

      assert path == "/test/home/.lemon/config.toml"
    end
  end

  describe "project_path/1" do
    test "returns path to project config" do
      path = Modular.project_path("/my/project")

      assert path == "/my/project/.lemon/config.toml"
    end
  end

  describe "integration with modular config modules" do
    test "agent config is resolved correctly" do
      config = Modular.load()

      # Check that agent config has expected fields
      assert is_binary(config.agent.default_provider)
      assert is_binary(config.agent.default_model)
      assert is_map(config.agent.compaction)
      assert is_map(config.agent.retry)
    end

    test "tools config is resolved correctly" do
      config = Modular.load()

      assert is_boolean(config.tools.auto_resize_images)
      assert is_map(config.tools.web)
      assert is_map(config.tools.web.search)
      assert is_map(config.tools.web.fetch)
      assert is_map(config.tools.wasm)
    end

    test "gateway config is resolved correctly" do
      config = Modular.load()

      assert is_integer(config.gateway.max_concurrent_runs)
      refute Map.has_key?(config.gateway, :default_engine)
      refute Map.has_key?(config.gateway, :engines)
      assert is_list(config.gateway.bindings)
      assert is_map(config.gateway.enabled_channels)
      assert is_map(config.gateway.channels)
    end

    test "providers config is resolved correctly" do
      config = Modular.load()

      assert is_map(config.providers.providers)
    end

    test "environment variables affect provider config" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")

      config = Modular.load()

      assert config.providers.providers["anthropic"][:api_key] == "sk-ant-test"
    end
  end

  describe "config loading with mock files" do
    test "loads and merges global and project config" do
      # This test verifies the structure works
      # Actual file loading would require temp file setup
      config = Modular.load()

      # Just verify we get a valid config struct
      assert %Modular{} = config
    end
  end

  describe "removed engine routing settings" do
    test "load/1 hard rejects a legacy gateway engine selection" do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "modular_removed_engine_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(project_dir, ".lemon"))

      File.write!(Path.join(project_dir, ".lemon/config.toml"), """
      [gateway]
      default_engine = "codex"
      """)

      on_exit(fn -> File.rm_rf!(project_dir) end)

      error =
        assert_raise ValidationError, fn ->
          Modular.load(project_dir: project_dir)
        end

      assert error.message =~ "Configuration uses removed settings"
      assert Enum.any?(error.errors, &String.contains?(&1, "gateway.default_engine"))
      assert Enum.any?(error.errors, &String.contains?(&1, "Lemon runs natively"))
    end

    test "load/1 hard rejects a legacy gateway engine registry" do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "modular_removed_engine_registry_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(project_dir, ".lemon"))

      File.write!(Path.join(project_dir, ".lemon/config.toml"), """
      [gateway.engines.codex]
      module = "Legacy.CodexEngine"
      """)

      on_exit(fn -> File.rm_rf!(project_dir) end)

      error =
        assert_raise ValidationError, fn ->
          Modular.load(project_dir: project_dir)
        end

      assert error.message =~ "Configuration uses removed settings"
      assert Enum.any?(error.errors, &String.contains?(&1, "gateway.engines"))
      assert Enum.any?(error.errors, &String.contains?(&1, "Lemon runs natively"))
    end

    test "load/1 rejects removed runtime CLI settings" do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "modular_runtime_cli_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(project_dir, ".lemon"))

      File.write!(Path.join(project_dir, ".lemon/config.toml"), """
      [runtime.cli.isolated_vendor]
      engine = "vendor-internal"
      """)

      on_exit(fn -> File.rm_rf!(project_dir) end)

      error =
        assert_raise ValidationError, fn ->
          Modular.load(project_dir: project_dir)
        end

      assert "The [runtime.cli] section has been removed; all subagent tasks run natively." in error.errors
    end
  end
end
