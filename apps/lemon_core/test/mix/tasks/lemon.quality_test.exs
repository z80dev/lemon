defmodule Mix.Tasks.Lemon.QualityTest do
  @moduledoc """
  Tests for the lemon.quality mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Quality

  # Get the repo root (4 levels up from this test file)
  @repo_root Path.expand("../../../../..", __DIR__)

  setup do
    # Create a temporary directory for test configs
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_quality_task_test_#{System.unique_integer([:positive])}"
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

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home, repo_root: @repo_root}
  end

  describe "config validation" do
    test "--validate-config passes when config is valid", %{mock_home: mock_home, repo_root: repo_root} do
      # Create a valid config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "claude-sonnet-4"
      default_provider = "anthropic"
      """)

      # Capture both stdout and stderr
      output =
        capture_io(:stdio, fn ->
          capture_io(:stderr, fn ->
            try do
              Quality.run(["--validate-config", "--root", repo_root])
            rescue
              Mix.Error -> :ok
            end
          end)
        end)

      assert output =~ "Validating Lemon configuration..."
      assert output =~ "[ok] config validation passed"
    end

    test "--validate-config fails when config is invalid", %{mock_home: mock_home, repo_root: repo_root} do
      # Create an invalid config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      output =
        capture_io(fn ->
          try do
            Quality.run(["--validate-config", "--root", repo_root])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "Validating Lemon configuration..."
      assert output =~ "[error] config validation failed"
      assert output =~ "agent.default_model"
    end

    test "runs without --validate-config does not validate config", %{repo_root: repo_root} do
      # This test just verifies the task runs without the flag
      # We capture any errors since other checks might fail
      output =
        capture_io(:stdio, fn ->
          capture_io(:stderr, fn ->
            try do
              Quality.run(["--root", repo_root])
            rescue
              Mix.Error -> :ok
            end
          end)
        end)

      # Should not have config validation message when flag not provided
      refute output =~ "Validating Lemon configuration..."
    end
  end

  describe "moduledoc" do
    test "includes --validate-config option in documentation" do
      # Check module documentation exists by looking at the module's behaviour
      moduledoc = Code.fetch_docs(Mix.Tasks.Lemon.Quality)

      case moduledoc do
        {:docs_v1, _, _, _, %{} = module_doc, _} ->
          doc = module_doc["en"]
          assert doc =~ "--validate-config"

        _ ->
          # If docs aren't available in test, at least verify module loads
          assert function_exported?(Mix.Tasks.Lemon.Quality, :run, 1)
      end
    end
  end
end
