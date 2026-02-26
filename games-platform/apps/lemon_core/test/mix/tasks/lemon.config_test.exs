defmodule Mix.Tasks.Lemon.ConfigTest do
  @moduledoc """
  Tests for the lemon.config mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Config

  setup do
    # Create a temporary directory for test configs
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_config_task_test_#{System.unique_integer([:positive])}"
      )

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

  describe "validate command" do
    test "passes with valid configuration", %{mock_home: mock_home} do
      # Create a valid config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "claude-sonnet-4"
      default_provider = "anthropic"
      """)

      output =
        capture_io(fn ->
          Config.run(["validate"])
        end)

      assert output =~ "Validating Lemon configuration"
      assert output =~ "✓ Configuration is valid"
    end

    test "fails with invalid configuration", %{mock_home: mock_home} do
      # Create an invalid config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      # Capture both stdout and stderr
      stdout = capture_io(:stdio, fn ->
        capture_io(:stderr, fn ->
          # Mix.raise raises a Mix.Error exception
          try do
            Config.run(["validate"])
          rescue
            Mix.Error -> :ok
          end
        end)
      end)

      stderr = capture_io(:stderr, fn ->
        capture_io(:stdio, fn ->
          try do
            Config.run(["validate"])
          rescue
            Mix.Error -> :ok
          end
        end)
      end)

      output = stdout <> stderr

      # Check combined output
      assert output =~ "Validating Lemon configuration"
      assert output =~ "✗ Configuration has errors"
      assert output =~ "agent.default_model"
    end

    test "shows verbose output when --verbose flag is used", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "claude-sonnet-4"
      """)

      output =
        capture_io(fn ->
          Config.run(["validate", "--verbose"])
        end)

      assert output =~ "✓ Configuration is valid"
      assert output =~ "Agent:"
      assert output =~ "Default model:"
    end

    test "validates project directory when specified", %{mock_home: mock_home, tmp_dir: tmp_dir} do
      # Create global config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "global-model"
      """)

      # Create project config with errors
      project_dir = Path.join(tmp_dir, "my-project")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      # Capture both stdout and stderr
      stdout = capture_io(:stdio, fn ->
        capture_io(:stderr, fn ->
          try do
            Config.run(["validate", "--project-dir", project_dir])
          rescue
            Mix.Error -> :ok
          end
        end)
      end)

      stderr = capture_io(:stderr, fn ->
        capture_io(:stdio, fn ->
          try do
            Config.run(["validate", "--project-dir", project_dir])
          rescue
            Mix.Error -> :ok
          end
        end)
      end)

      output = stdout <> stderr

      assert output =~ "Project directory: #{project_dir}"
      assert output =~ "✗ Configuration has errors"
    end
  end

  describe "show command" do
    test "displays current configuration", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "claude-sonnet-4"
      default_provider = "anthropic"

      [logging]
      level = "info"
      """)

      output =
        capture_io(fn ->
          Config.run(["show"])
        end)

      assert output =~ "Current Lemon Configuration"
      assert output =~ "claude-sonnet-4"
      assert output =~ "anthropic"
      assert output =~ "info"
    end

    test "shows configuration sources", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)
      File.write!(Path.join(global_config, "config.toml"), "")

      output =
        capture_io(fn ->
          Config.run(["show"])
        end)

      assert output =~ "Configuration sources:"
      assert output =~ "Global:"
    end

    test "handles missing configuration gracefully", %{mock_home: _mock_home} do
      output =
        capture_io(fn ->
          Config.run(["show"])
        end)

      assert output =~ "Current Lemon Configuration"
      assert output =~ "(not set)"
    end
  end

  describe "help/usage" do
    test "shows help when no command is given" do
      output =
        capture_io(fn ->
          Config.run([])
        end)

      assert output =~ "mix lemon.config validate"
      assert output =~ "mix lemon.config show"
    end

    test "shows help for unknown commands" do
      output =
        capture_io(fn ->
          Config.run(["unknown"])
        end)

      assert output =~ "mix lemon.config validate"
      assert output =~ "mix lemon.config show"
    end
  end

  describe "exit codes" do
    test "exits with code 0 on valid config", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "valid-model"
      """)

      # Should not exit
      capture_io(fn ->
        Config.run(["validate"])
      end)

      # If we get here, no exit was called
      assert true
    end

    test "raises Mix.Error on invalid config", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      assert_raise Mix.Error, fn ->
        capture_io(fn -> Config.run(["validate"]) end)
      end
    end
  end
end
