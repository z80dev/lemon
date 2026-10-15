defmodule LemonCore.Doctor.Checks.Config do
  @moduledoc "Validates Lemon configuration files."

  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.Check

  @doc """
  Runs all config checks and returns a list of Check results.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    [
      check_global_exists(),
      check_global_valid(),
      check_project_valid(project_dir)
    ]
  end

  defp check_global_exists do
    path = Modular.global_path() |> Path.expand()

    if File.exists?(path) do
      Check.pass("config.global_exists", "Global config found: #{path}")
    else
      Check.warn(
        "config.global_exists",
        "Global config not found: #{path}",
        "Run `lemon setup` to create a config scaffold."
      )
    end
  end

  defp check_global_valid do
    path = Modular.global_path() |> Path.expand()

    if not File.exists?(path) do
      Check.skip("config.global_valid", "Global config does not exist — skipping validation.")
    else
      case Modular.load_with_validation() do
        {:ok, _config} ->
          case Modular.deprecation_warnings() do
            [] ->
              Check.pass(
                "config.global_valid",
                "Global config is valid TOML and passes validation."
              )

            warnings ->
              Check.warn(
                "config.global_valid",
                "Config uses deprecated settings:\n" <>
                  Enum.map_join(warnings, "\n", &"  • #{&1}"),
                "Run `lemon config migrate` to rewrite them; the original is kept as a backup."
              )
          end

        {:error, errors} ->
          message = "Config validation errors:\n" <> Enum.map_join(errors, "\n", &"  • #{&1}")

          Check.fail(
            "config.global_valid",
            message,
            "Run `lemon config validate --verbose` for details; use `lemon config migrate` for removed settings."
          )
      end
    end
  end

  defp check_project_valid(project_dir) do
    path = Modular.project_path(project_dir) |> Path.expand()

    if not File.exists?(path) do
      Check.skip("config.project_valid", "No project config at #{path} — skipping.")
    else
      case Modular.load_with_validation(project_dir: project_dir) do
        {:ok, _config} ->
          Check.pass("config.project_valid", "Project config is valid: #{path}")

        {:error, errors} ->
          message = "Project config errors:\n" <> Enum.map_join(errors, "\n", &"  • #{&1}")

          Check.fail(
            "config.project_valid",
            message,
            "Run `lemon config validate --verbose` for details; use `lemon config migrate` for removed settings."
          )
      end
    end
  end
end
