defmodule LemonSkills.Manifest.Validator do
  @moduledoc """
  Semantic validator for skill manifests.

  Validates both legacy v1 fields and manifest v2 fields against the schema
  defined in `docs/reference/skill-manifest-v2.md`. Returns normalised
  manifests with v2 defaults populated so callers never have to guard against
  missing optional fields.

  ## Manifest versions

  - **v1** (legacy): only `name`, `description`, `requires.bins`,
    `requires.config`, `tags`, `version`, `author` are present.
  - **v2**: adds `platforms`, `metadata.lemon.category`, `requires_tools`,
    `fallback_for_tools`, `required_environment_variables`, `verification`,
    and `references`. v2 fields get sensible defaults when absent so all
    legacy skills remain valid.

  The manifest version is inferred automatically from which fields are
  present; there is no explicit `version` discriminator field.
  """

  @v2_platforms ~w(linux darwin win32 any)

  @type manifest :: map()
  @type error :: String.t()

  @doc """
  Validate a parsed manifest and return a normalised copy with defaults.

  ## Returns

  - `{:ok, normalised_manifest}` — valid manifest with defaults applied.
  - `{:error, reason}` — validation failed; `reason` is a human-readable string.
  """
  @spec validate(manifest()) :: {:ok, manifest()} | {:error, error()}
  def validate(manifest) when is_map(manifest) do
    manifest =
      manifest
      |> normalize_platform_aliases()
      |> normalize_hermes_requires_text()
      |> normalize_hermes_prerequisites()
      |> normalize_environment_declarations()

    with :ok <- validate_legacy_fields(manifest),
         :ok <- validate_v2_fields(manifest) do
      {:ok, apply_defaults(manifest)}
    end
  end

  @doc """
  Return the inferred manifest schema version (`:v1` or `:v2`).

  A manifest is considered v2 if it contains any v2-exclusive field.
  """
  @spec version(manifest()) :: :v1 | :v2
  def version(manifest) do
    v2_keys = ~w(platforms requires_tools fallback_for_tools
                 required_environment_variables verification references)

    if Enum.any?(v2_keys, &Map.has_key?(manifest, &1)) or
         get_in(manifest, ["metadata", "lemon"]) != nil do
      :v2
    else
      :v1
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy field validation (v1 contract)
  # ---------------------------------------------------------------------------

  defp validate_legacy_fields(manifest) do
    cond do
      has_field?(manifest, "requires") and not is_map(manifest["requires"]) ->
        {:error, "requires must be a map"}

      has_field?(manifest, "tags") and not is_list(manifest["tags"]) ->
        {:error, "tags must be a list"}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # v2 field validation
  # ---------------------------------------------------------------------------

  defp validate_v2_fields(manifest) do
    with :ok <- validate_platforms(manifest),
         :ok <- validate_string_list(manifest, "requires_tools"),
         :ok <- validate_string_list(manifest, "fallback_for_tools"),
         :ok <- validate_string_list(manifest, "required_environment_variables"),
         :ok <- validate_verification(manifest),
         :ok <- validate_references(manifest) do
      :ok
    end
  end

  defp validate_platforms(manifest) do
    case Map.get(manifest, "platforms") do
      nil ->
        :ok

      platforms when is_list(platforms) ->
        invalid = Enum.reject(platforms, &(&1 in @v2_platforms))

        if Enum.empty?(invalid) do
          :ok
        else
          {:error,
           "platforms contains unknown values: #{Enum.join(invalid, ", ")}. " <>
             "Allowed: #{Enum.join(@v2_platforms, ", ")}"}
        end

      _ ->
        {:error, "platforms must be a list"}
    end
  end

  defp validate_string_list(manifest, key) do
    case Map.get(manifest, key) do
      nil ->
        :ok

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          :ok
        else
          {:error, "#{key} must be a list of strings"}
        end

      _ ->
        {:error, "#{key} must be a list"}
    end
  end

  defp validate_verification(manifest) do
    case Map.get(manifest, "verification") do
      nil -> :ok
      v when is_map(v) -> :ok
      _ -> {:error, "verification must be a map"}
    end
  end

  defp validate_references(manifest) do
    case Map.get(manifest, "references") do
      nil ->
        :ok

      refs when is_list(refs) ->
        invalid =
          Enum.reject(refs, fn
            r when is_binary(r) -> true
            r when is_map(r) -> Map.has_key?(r, "path") or Map.has_key?(r, "url")
            _ -> false
          end)

        if Enum.empty?(invalid) do
          :ok
        else
          {:error, "references entries must be strings or maps with a path or url key"}
        end

      _ ->
        {:error, "references must be a list"}
    end
  end

  # ---------------------------------------------------------------------------
  # Default population
  # ---------------------------------------------------------------------------

  defp apply_defaults(manifest) do
    manifest
    |> Map.put_new("platforms", ["any"])
    |> Map.put_new("requires_tools", [])
    |> Map.put_new("fallback_for_tools", [])
    |> Map.put_new(
      "required_environment_variables",
      legacy_env_vars(manifest)
    )
    |> Map.put_new("references", [])
  end

  defp normalize_platform_aliases(%{"platforms" => platforms} = manifest)
       when is_list(platforms) do
    aliases = %{"macos" => "darwin", "windows" => "win32"}
    Map.put(manifest, "platforms", Enum.map(platforms, &Map.get(aliases, &1, &1)))
  end

  defp normalize_platform_aliases(manifest), do: manifest

  defp normalize_hermes_prerequisites(manifest) do
    prerequisites =
      case manifest do
        %{"prerequisites" => value} when is_map(value) -> value
        _ -> get_in(manifest, ["metadata", "hermes", "prerequisites"])
      end

    normalize_hermes_prerequisites(manifest, prerequisites)
  end

  defp normalize_hermes_prerequisites(manifest, prerequisites) when is_map(prerequisites) do
    commands = ensure_list(prerequisites["commands"])
    env_vars = ensure_list(prerequisites["env_vars"])

    case Map.get(manifest, "requires", %{}) do
      requires when is_map(requires) ->
        requires =
          requires
          |> Map.put_new("bins", commands)
          |> Map.put_new("config", env_vars)

        manifest
        |> Map.put("requires", requires)
        |> Map.put_new("required_environment_variables", env_vars)

      _invalid_requires ->
        manifest
    end
  end

  defp normalize_hermes_prerequisites(manifest, _), do: manifest

  defp normalize_hermes_requires_text(%{"requires" => text} = manifest) when is_binary(text) do
    if get_in(manifest, ["metadata", "hermes"]) do
      manifest |> Map.delete("requires") |> Map.put("hermes_requires", text)
    else
      manifest
    end
  end

  defp normalize_hermes_requires_text(manifest), do: manifest

  defp normalize_environment_declarations(
         %{"required_environment_variables" => declarations} = manifest
       )
       when is_list(declarations) do
    normalized =
      Enum.flat_map(declarations, fn
        value when is_binary(value) -> [value]
        %{"name" => name, "optional" => true} when is_binary(name) -> []
        %{"name" => name} when is_binary(name) -> [name]
        _ -> [:invalid]
      end)

    Map.put(manifest, "required_environment_variables", normalized)
  end

  defp normalize_environment_declarations(manifest), do: manifest

  # Promote legacy requires.config into required_environment_variables so
  # callers can always use the v2 field.
  defp legacy_env_vars(manifest) do
    manifest
    |> Map.get("requires", %{})
    |> Map.get("config", [])
    |> ensure_list()
  end

  defp ensure_list(v) when is_list(v), do: v
  defp ensure_list(_), do: []

  defp has_field?(map, key), do: Map.has_key?(map, key)
end
