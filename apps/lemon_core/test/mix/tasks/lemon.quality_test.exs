defmodule Mix.Tasks.Lemon.QualityTest do
  @moduledoc """
  Tests for the lemon.quality mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.Quality.ArchitecturePolicy
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
    test "--validate-config passes when config is valid", %{
      mock_home: mock_home,
      repo_root: repo_root
    } do
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

    test "--validate-config fails when config is invalid", %{
      mock_home: mock_home,
      repo_root: repo_root
    } do
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
        {:docs_v1, _, _, _, %{} = module_doc, _, _} ->
          doc = module_doc["en"]
          assert doc =~ "--validate-config"

        _ ->
          # If docs aren't available in test, at least verify module loads
          assert Code.ensure_loaded?(Mix.Tasks.Lemon.Quality)
          assert function_exported?(Mix.Tasks.Lemon.Quality, :run, 1)
      end
    end
  end

  describe "architecture docs integration" do
    test "reports stale architecture docs as a failing quality check" do
      tmp_dir = create_tmp_quality_repo()

      try do
        stderr =
          capture_io(:stderr, fn ->
            stdout =
              capture_io(:stdio, fn ->
                try do
                  Quality.run(["--root", tmp_dir])
                rescue
                  Mix.Error -> :ok
                end
              end)

            send(self(), {:captured_stdout, stdout})
          end)

        assert_received {:captured_stdout, stdout}
        output = stdout <> stderr

        assert output =~ "[error] architecture_docs check failed"
        assert output =~ "Architecture boundaries doc is stale"
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  defp create_tmp_quality_repo do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_quality_repo_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    File.write!(Path.join(tmp_dir, "docs/README.md"), "# Docs\n")

    File.write!(
      Path.join(tmp_dir, "docs/architecture_boundaries.md"),
      """
      # Architecture Boundaries

      ## Direct Dependency Policy

      <!-- architecture_policy:start -->
      stale
      <!-- architecture_policy:end -->

      ## Enforcement
      """
    )

    File.write!(
      Path.join(tmp_dir, "docs/catalog.exs"),
      """
      [
        %{path: "docs/README.md", owner: "@test", last_reviewed: ~D[2026-03-10], max_age_days: 60},
        %{path: "docs/architecture_boundaries.md", owner: "@test", last_reviewed: ~D[2026-03-10], max_age_days: 60}
      ]
      """
    )

    ArchitecturePolicy.allowed_direct_deps()
    |> Enum.each(fn {app, deps} ->
      app_dir = Path.join(tmp_dir, "apps/#{app}")
      File.mkdir_p!(app_dir)
      File.write!(Path.join(app_dir, "mix.exs"), mix_file_for(app, deps))
    end)

    tmp_dir
  end

  defp mix_file_for(app, deps) do
    deps_source =
      deps
      |> Enum.map_join(",\n      ", fn dep -> "{:#{dep}, in_umbrella: true}" end)

    deps_body =
      case deps_source do
        "" -> "[]"
        _ -> "[\n      #{deps_source}\n    ]"
      end

    module_name =
      app
      |> Atom.to_string()
      |> Macro.camelize()

    """
    defmodule #{module_name}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: "0.1.0",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        #{deps_body}
      end
    end
    """
  end
end
