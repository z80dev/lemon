defmodule LemonCore.Config.ModularIntegrationTest do
  @moduledoc """
  Integration tests for modular config with validation.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Config.Modular
  alias LemonCore.Config.ValidationError

  setup do
    # Create a temporary directory for test configs
    tmp_dir = Path.join(System.tmp_dir!(), "modular_integration_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME
    original_home = System.get_env("HOME")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "load/1 with validation" do
    test "loads config without validation by default", %{mock_home: mock_home} do
      # Create a minimal valid config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "test-model"
      """)

      config = Modular.load()

      assert is_struct(config, Modular)
      assert config.agent.default_model == "test-model"
    end

    test "validates config when validate: true", %{mock_home: mock_home} do
      # Create an invalid config (empty model)
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      # Should still return config but log warning
      config = Modular.load(validate: true)

      assert is_struct(config, Modular)
    end

    test "returns valid config when validation passes", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "claude-sonnet-4"

      [logging]
      level = "info"
      """)

      config = Modular.load(validate: true)

      assert is_struct(config, Modular)
      assert config.agent.default_model == "claude-sonnet-4"
    end
  end

  describe "load!/1" do
    test "returns config when valid", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "valid-model"
      """)

      config = Modular.load!()

      assert is_struct(config, Modular)
      assert config.agent.default_model == "valid-model"
    end

    test "raises ValidationError when config is invalid", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      assert_raise ValidationError, fn ->
        Modular.load!()
      end
    end

    test "includes error details in exception", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      default_provider = ""
      """)

      try do
        Modular.load!()
        flunk("Expected ValidationError to be raised")
      rescue
        e in ValidationError ->
          assert e.message =~ "Configuration validation failed"
          assert length(e.errors) >= 1
          assert Enum.any?(e.errors, &String.contains?(&1, "agent.default_model"))
      end
    end
  end

  describe "load_with_validation/1" do
    test "returns {:ok, config} for valid config", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "valid-model"
      """)

      assert {:ok, config} = Modular.load_with_validation()
      assert is_struct(config, Modular)
    end

    test "returns {:error, errors} for invalid config", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      assert {:error, errors} = Modular.load_with_validation()
      assert is_list(errors)
      assert length(errors) >= 1
    end

    test "includes specific error messages", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      default_provider = ""

      [gateway]
      max_concurrent_runs = -1
      """)

      assert {:error, errors} = Modular.load_with_validation()

      assert Enum.any?(errors, &String.contains?(&1, "agent.default_model"))
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_provider"))
      assert Enum.any?(errors, &String.contains?(&1, "gateway.max_concurrent_runs"))
    end
  end

  describe "project directory option" do
    test "loads config from specified project directory", %{tmp_dir: tmp_dir, mock_home: mock_home} do
      # Create global config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "global-model"
      """)

      # Create project config
      project_dir = Path.join(tmp_dir, "my-project")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "config.toml"), """
      [agent]
      default_model = "project-model"
      """)

      config = Modular.load(project_dir: project_dir)

      assert config.agent.default_model == "project-model"
    end

    test "validates config from project directory", %{tmp_dir: tmp_dir, mock_home: mock_home} do
      # Create global config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "global-model"
      """)

      # Create project config with invalid values
      project_dir = Path.join(tmp_dir, "my-project")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      assert {:error, errors} = Modular.load_with_validation(project_dir: project_dir)
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_model"))
    end
  end

  describe "empty config handling" do
    test "handles missing config files gracefully", %{mock_home: _mock_home} do
      # No config files created
      config = Modular.load_with_validation()

      # Should return ok with defaults
      assert {:ok, _config} = config
    end

    test "handles empty config with validation", %{mock_home: mock_home} do
      # Create empty config files
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)
      File.write!(Path.join(global_config, "config.toml"), "")

      # Should return ok (all fields are optional)
      assert {:ok, _config} = Modular.load_with_validation()
    end
  end
end
