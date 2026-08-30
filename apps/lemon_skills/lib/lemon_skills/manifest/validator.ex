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

  # Prompt-facing metadata is deliberately much smaller than a SKILL.md body.
  # These limits are enforced at ingestion so every downstream renderer and
  # relevance query can treat the normalized manifest as bounded data.
  @max_name_bytes 128
  @max_description_bytes 1_024
  @max_list_items 32
  @max_list_item_bytes 128
  @unsafe_metadata ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

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

    if Enum.any?(v2_keys, &Map.has_key?(manifest, &1)) or lemon_metadata_present?(manifest) do
      :v2
    else
      :v1
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy field validation (v1 contract)
  # ---------------------------------------------------------------------------

  defp validate_legacy_fields(manifest) do
    with :ok <- validate_optional_metadata_string(manifest, "name", @max_name_bytes),
         :ok <-
           validate_optional_metadata_string(
             manifest,
             "description",
             @max_description_bytes
           ),
         :ok <- validate_metadata_list(manifest, "tags"),
         :ok <- validate_metadata_list(manifest, "keywords"),
         :ok <- validate_requires(manifest),
         :ok <- validate_lemon_metadata(manifest) do
      :ok
    end
  end

  defp validate_requires(manifest) do
    case Map.get(manifest, "requires") do
      nil ->
        :ok

      requires when is_map(requires) ->
        with :ok <- validate_metadata_list(requires, "bins"),
             :ok <- validate_metadata_list(requires, "config") do
          :ok
        end

      _ ->
        {:error, "requires must be a map"}
    end
  end

  defp validate_lemon_metadata(manifest) do
    case Map.get(manifest, "metadata") do
      nil ->
        :ok

      metadata when is_map(metadata) ->
        case Map.get(metadata, "lemon") do
          nil ->
            :ok

          lemon when is_map(lemon) ->
            validate_optional_metadata_string(lemon, "category", @max_list_item_bytes)

          _ ->
            {:error, "metadata.lemon must be a map"}
        end

      _ ->
        {:error, "metadata must be a map"}
    end
  end

  defp validate_optional_metadata_string(manifest, key, max_bytes) do
    case Map.fetch(manifest, key) do
      :error ->
        :ok

      {:ok, value} when not is_binary(value) ->
        {:error, "#{key} must be a string"}

      {:ok, value} ->
        validate_metadata_string(value, key, max_bytes)
    end
  end

  defp validate_metadata_string(value, key, max_bytes) do
    cond do
      not String.valid?(value) ->
        {:error, "#{key} must be valid UTF-8"}

      String.trim(value) == "" ->
        {:error, "#{key} must not be empty"}

      byte_size(value) > max_bytes ->
        {:error, "#{key} is too long (max #{max_bytes} bytes)"}

      String.contains?(value, ["\n", "\r"]) ->
        {:error, "#{key} must be a single line"}

      Regex.match?(@unsafe_metadata, value) ->
        {:error, "#{key} contains control or bidirectional characters"}

      true ->
        :ok
    end
  end

  defp validate_metadata_list(manifest, key) do
    case Map.get(manifest, key) do
      nil ->
        :ok

      list when is_list(list) and length(list) <= @max_list_items ->
        Enum.reduce_while(list, :ok, fn value, :ok ->
          case value do
            value when is_binary(value) ->
              case validate_metadata_string(value, "#{key} entry", @max_list_item_bytes) do
                :ok -> {:cont, :ok}
                {:error, _} = error -> {:halt, error}
              end

            _ ->
              {:halt, {:error, "#{key} must be a list of strings"}}
          end
        end)

      list when is_list(list) ->
        {:error, "#{key} has too many entries (max #{@max_list_items})"}

      _ ->
        {:error, "#{key} must be a list"}
    end
  end

  # ---------------------------------------------------------------------------
  # v2 field validation
  # ---------------------------------------------------------------------------

  defp validate_v2_fields(manifest) do
    with :ok <- validate_platforms(manifest),
         :ok <- validate_metadata_list(manifest, "requires_tools"),
         :ok <- validate_metadata_list(manifest, "fallback_for_tools"),
         :ok <- validate_metadata_list(manifest, "required_environment_variables"),
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
        with :ok <- validate_metadata_list(manifest, "platforms") do
          invalid = Enum.reject(platforms, &(&1 in @v2_platforms))

          if Enum.empty?(invalid) do
            :ok
          else
            {:error,
             "platforms contains unknown values: #{Enum.join(invalid, ", ")}. " <>
               "Allowed: #{Enum.join(@v2_platforms, ", ")}"}
          end
        end

      _ ->
        {:error, "platforms must be a list"}
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
        %{"metadata" => %{"hermes" => %{"prerequisites" => value}}} -> value
        _ -> nil
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
    if match?(%{"metadata" => %{"hermes" => hermes}} when is_map(hermes), manifest) do
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

  defp lemon_metadata_present?(manifest) do
    with metadata when is_map(metadata) <- Map.get(manifest, "metadata"),
         lemon when not is_nil(lemon) <- Map.get(metadata, "lemon") do
      true
    else
      _ -> false
    end
  end
end
