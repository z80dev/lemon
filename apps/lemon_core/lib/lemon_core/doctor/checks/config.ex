defmodule LemonCore.Doctor.Checks.Config do
  @moduledoc "Validates Lemon configuration files."

  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.{Check, Redaction}

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
      Check.pass("config.global_exists", "Global config found: #{Redaction.path_label(path)}")
    else
      Check.warn(
        "config.global_exists",
        "Global config not found: #{Redaction.path_label(path)}",
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
                  Enum.map_join(warnings, "\n", &"  • #{shareable(&1, File.cwd!())}"),
                "Run `lemon config migrate` to rewrite them; the original is kept as a backup."
              )
          end

        {:error, errors} ->
          message =
            "Config validation errors:\n" <>
              Enum.map_join(errors, "\n", &"  • #{shareable(&1, File.cwd!())}")

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
      Check.skip(
        "config.project_valid",
        "No project config at #{Redaction.path_label(path)} — skipping."
      )
    else
      case Modular.load_with_validation(project_dir: project_dir) do
        {:ok, _config} ->
          Check.pass(
            "config.project_valid",
            "Project config is valid: #{Redaction.path_label(path)}"
          )

        {:error, errors} ->
          message =
            "Project config errors:\n" <>
              Enum.map_join(errors, "\n", &"  • #{shareable(&1, project_dir)}")

          Check.fail(
            "config.project_valid",
            message,
            "Run `lemon config validate --verbose` for details; use `lemon config migrate` for removed settings."
          )
      end
    end
  end

  # Validation messages name the config files they come from and the provider
  # keys they concern; doctor output is shared, so known paths become labels
  # and custom provider names their public projection before interpolation.
  defp shareable(message, project_dir) do
    config_paths = [Modular.global_path(), Modular.project_path(project_dir)]

    message
    |> to_string()
    |> Redaction.replace_paths(config_paths ++ [project_dir])
    |> replace_provider_names(config_paths)
  end

  defp replace_provider_names(message, config_paths) do
    config_paths
    |> Enum.flat_map(&provider_keys/1)
    |> Enum.uniq()
    |> Enum.map(&{&1, LemonCore.ProviderIdentity.public_name(&1)})
    |> Enum.reject(fn {name, public} -> public == name end)
    |> Enum.sort_by(fn {name, _} -> -byte_size(name) end)
    |> Enum.reduce(message, fn {name, public}, acc ->
      Regex.replace(~r/(?<![\w-])#{Regex.escape(name)}(?![\w-])/, acc, public)
    end)
  end

  defp provider_keys(path) do
    with {:ok, content} <- File.read(Path.expand(path)),
         {:ok, %{"providers" => providers}} when is_map(providers) <- Toml.decode(content) do
      Map.keys(providers)
    else
      _ -> []
    end
  end
end
