defmodule Mix.Tasks.Lemon.Config do
  @moduledoc """
  Validate and inspect Lemon configuration.

  ## Usage

      # Validate current configuration
      mix lemon.config validate

      # Validate with verbose output
      mix lemon.config validate --verbose

      # Validate configuration for a specific project
      mix lemon.config validate --project-dir /path/to/project

      # Show validated current configuration
      mix lemon.config show

  ## Exit Codes

  - 0: Configuration is valid
  - 1: Configuration has validation errors
  """

  use Mix.Task

  alias LemonCore.Config.Modular

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          verbose: :boolean,
          project_dir: :string
        ],
        aliases: [
          v: :verbose,
          p: :project_dir
        ]
      )

    case rest do
      ["validate"] ->
        validate_config(opts)

      ["show"] ->
        show_config(opts)

      _ ->
        Mix.shell().info(@moduledoc)
    end
  end

  defp validate_config(opts) do
    project_dir = opts[:project_dir]
    verbose? = opts[:verbose] || false

    load_opts = if project_dir, do: [project_dir: project_dir], else: []

    Mix.shell().info("Validating Lemon configuration...")

    if project_dir do
      Mix.shell().info("  Project directory: #{project_dir}")
    end

    case Modular.load_with_validation(load_opts) do
      {:ok, config} ->
        Mix.shell().info([:green, "✓ Configuration is valid", :reset])

        if verbose? do
          print_config_summary(config)
        end

        :ok

      {:error, errors} ->
        Mix.shell().error([:red, "✗ Configuration has errors:", :reset])

        Enum.each(errors, fn error ->
          Mix.shell().error("  • #{error}")
        end)

        if verbose? do
          Mix.shell().info("")
          Mix.shell().info("Configuration files checked:")
          Mix.shell().info("  Global: #{Modular.global_path()}")

          if project_dir do
            Mix.shell().info("  Project: #{Modular.project_path(project_dir)}")
          else
            Mix.shell().info("  Project: #{Modular.project_path(File.cwd!())}")
          end
        end

        Mix.raise("Configuration validation failed")
    end
  end

  defp show_config(opts) do
    project_dir = opts[:project_dir]
    load_opts = if project_dir, do: [project_dir: project_dir], else: []

    config = Modular.load(load_opts)

    Mix.shell().info("Current Lemon Configuration")
    Mix.shell().info("===========================")
    Mix.shell().info("")

    print_config_summary(config)

    Mix.shell().info("")
    Mix.shell().info("Configuration sources:")
    Mix.shell().info("  Global: #{Modular.global_path()}")

    if project_dir do
      Mix.shell().info("  Project: #{Modular.project_path(project_dir)}")
    else
      Mix.shell().info("  Project: #{Modular.project_path(File.cwd!())}")
    end
  end

  defp print_config_summary(config) do
    Enum.each(LemonCore.Config.Summary.lines(config), fn line -> Mix.shell().info(line) end)
  end
end
