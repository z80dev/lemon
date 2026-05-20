defmodule LemonCore.Extensions.Manifest do
  @moduledoc """
  Extension package manifest discovery and validation.
  """

  @manifest_names ["lemon_extension.json", "extension.json", ".lemon-extension.json"]
  @max_manifest_bytes 256 * 1024
  @name_pattern ~r/^[a-z0-9][a-z0-9._-]*$/
  @provider_types MapSet.new(["model", "memory", "tool_executor", "storage"])
  @host_types MapSet.new(["beam", "wasm", "mcp", "external"])
  @distribution_sources MapSet.new(["local", "git", "github", "registry", "archive"])
  @audit_statuses MapSet.new(["pending", "passed", "warn", "blocked", "unknown"])

  @type validation :: %{
          path: String.t(),
          path_hash: String.t(),
          valid?: boolean(),
          byte_size: non_neg_integer(),
          errors: [String.t()],
          capabilities: [String.t()],
          provider_types: [String.t()],
          host_types: [String.t()],
          distribution_sources: [String.t()],
          audit_statuses: [String.t()]
        }

  def names, do: @manifest_names
  def max_bytes, do: @max_manifest_bytes

  @spec discover(String.t()) :: [String.t()]
  def discover(path) when is_binary(path) do
    if File.dir?(path) do
      top_level = Enum.map(@manifest_names, &Path.join(path, &1))

      nested =
        @manifest_names
        |> Enum.flat_map(&Path.wildcard(Path.join([path, "*", &1])))

      (top_level ++ nested)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  @spec validate_file(String.t()) :: validation()
  def validate_file(path) when is_binary(path) do
    path = Path.expand(path)
    base = base_validation(path)

    with true <- base.byte_size <= @max_manifest_bytes,
         {:ok, content} <- File.read(path),
         {:ok, manifest} <- Jason.decode(content),
         true <- is_map(manifest) do
      validation_for_map(base, manifest)
    else
      false -> %{base | errors: ["manifest exceeds #{div(@max_manifest_bytes, 1024)} KiB"]}
      {:error, %Jason.DecodeError{}} -> %{base | errors: ["manifest is not valid JSON"]}
      {:error, _reason} -> %{base | errors: ["manifest could not be read"]}
      _ -> %{base | errors: ["manifest JSON must be an object"]}
    end
  end

  @spec validate_map(map(), String.t()) :: validation()
  def validate_map(manifest, label \\ "embedded") when is_map(manifest) and is_binary(label) do
    label
    |> base_validation()
    |> Map.put(:byte_size, byte_size(Jason.encode!(manifest)))
    |> validation_for_map(manifest)
  end

  defp base_validation(path) do
    %{
      path: path,
      path_hash: hash(path),
      valid?: false,
      byte_size: file_size(path),
      errors: [],
      capabilities: [],
      provider_types: [],
      host_types: [],
      distribution_sources: [],
      audit_statuses: []
    }
  end

  defp validate_manifest(manifest) do
    []
    |> require_string(manifest, "name")
    |> require_string(manifest, "version")
    |> validate_schema_version(manifest)
    |> validate_name(manifest)
    |> validate_string_list(manifest, "capabilities")
    |> validate_providers(manifest)
    |> validate_hosts(manifest)
    |> validate_distribution(manifest)
    |> validate_audit(manifest)
    |> Enum.reverse()
  end

  defp validation_for_map(base, manifest) do
    errors = validate_manifest(manifest)

    %{
      base
      | valid?: errors == [],
        errors: errors,
        capabilities: string_list(manifest["capabilities"]),
        provider_types: provider_types(manifest["providers"]),
        host_types: host_types(manifest),
        distribution_sources: distribution_sources(manifest["distribution"]),
        audit_statuses: audit_statuses(manifest["audit"])
    }
  end

  defp require_string(errors, manifest, key) do
    case manifest[key] do
      value when is_binary(value) and value != "" -> errors
      _ -> ["#{key} must be a non-empty string" | errors]
    end
  end

  defp validate_schema_version(errors, %{"schema_version" => value})
       when is_integer(value) or is_binary(value),
       do: errors

  defp validate_schema_version(errors, %{"schemaVersion" => value})
       when is_integer(value) or is_binary(value),
       do: errors

  defp validate_schema_version(errors, _manifest),
    do: ["schema_version must be present" | errors]

  defp validate_name(errors, %{"name" => name}) when is_binary(name) do
    if Regex.match?(@name_pattern, name),
      do: errors,
      else: ["name has invalid characters" | errors]
  end

  defp validate_name(errors, _manifest), do: errors

  defp validate_string_list(errors, manifest, key) do
    case manifest[key] do
      nil ->
        errors

      values when is_list(values) ->
        if Enum.all?(values, &valid_string?/1),
          do: errors,
          else: ["#{key} must contain strings" | errors]

      _ ->
        ["#{key} must be a list of strings" | errors]
    end
  end

  defp validate_providers(errors, %{"providers" => providers}) when is_list(providers) do
    providers
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {provider, index}, acc ->
      validate_provider(acc, provider, index)
    end)
  end

  defp validate_providers(errors, %{"providers" => _}), do: ["providers must be a list" | errors]
  defp validate_providers(errors, _manifest), do: errors

  defp validate_provider(errors, %{"type" => type, "name" => name}, index) do
    errors
    |> validate_enum(type, @provider_types, "providers[#{index}].type")
    |> validate_non_empty_string(name, "providers[#{index}].name")
  end

  defp validate_provider(errors, _provider, index),
    do: ["providers[#{index}] must include type and name" | errors]

  defp validate_hosts(errors, %{"hosts" => hosts}) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {host, index}, acc ->
      case host do
        %{"type" => type} -> validate_enum(acc, type, @host_types, "hosts[#{index}].type")
        type when is_binary(type) -> validate_enum(acc, type, @host_types, "hosts[#{index}]")
        _ -> ["hosts[#{index}] must be a host type or object" | acc]
      end
    end)
  end

  defp validate_hosts(errors, %{"hosts" => _}), do: ["hosts must be a list" | errors]

  defp validate_hosts(errors, %{"host" => %{"type" => type}}),
    do: validate_enum(errors, type, @host_types, "host.type")

  defp validate_hosts(errors, %{"host" => type}) when is_binary(type),
    do: validate_enum(errors, type, @host_types, "host")

  defp validate_hosts(errors, %{"host" => _}), do: ["host must be a host type or object" | errors]
  defp validate_hosts(errors, _manifest), do: errors

  defp validate_distribution(errors, %{"distribution" => distribution})
       when is_map(distribution) do
    case distribution["source"] || distribution["type"] do
      nil -> errors
      source -> validate_enum(errors, source, @distribution_sources, "distribution.source")
    end
  end

  defp validate_distribution(errors, %{"distribution" => source}) when is_binary(source),
    do: validate_enum(errors, source, @distribution_sources, "distribution")

  defp validate_distribution(errors, %{"distribution" => _}),
    do: ["distribution must be a string or object" | errors]

  defp validate_distribution(errors, _manifest), do: errors

  defp validate_audit(errors, %{"audit" => audit}) when is_map(audit) do
    case audit["status"] do
      nil -> errors
      status -> validate_enum(errors, status, @audit_statuses, "audit.status")
    end
  end

  defp validate_audit(errors, %{"audit" => status}) when is_binary(status),
    do: validate_enum(errors, status, @audit_statuses, "audit")

  defp validate_audit(errors, %{"audit" => _}), do: ["audit must be a string or object" | errors]
  defp validate_audit(errors, _manifest), do: errors

  defp validate_enum(errors, value, allowed, field) when is_binary(value) do
    if MapSet.member?(allowed, value), do: errors, else: ["#{field} is not supported" | errors]
  end

  defp validate_enum(errors, _value, _allowed, field), do: ["#{field} must be a string" | errors]

  defp validate_non_empty_string(errors, value, _field) when is_binary(value) and value != "",
    do: errors

  defp validate_non_empty_string(errors, _value, field),
    do: ["#{field} must be a non-empty string" | errors]

  defp valid_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&valid_string?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp string_list(value) when is_binary(value), do: string_list([value])
  defp string_list(_), do: []

  defp provider_types(providers) when is_list(providers) do
    providers
    |> Enum.flat_map(fn
      %{"type" => type} -> string_list(type)
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp provider_types(_), do: []

  defp host_types(%{"hosts" => hosts}) when is_list(hosts) do
    hosts
    |> Enum.flat_map(fn
      %{"type" => type} -> string_list(type)
      type when is_binary(type) -> string_list(type)
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp host_types(%{"host" => %{"type" => type}}), do: string_list(type)
  defp host_types(%{"host" => type}) when is_binary(type), do: string_list(type)
  defp host_types(_), do: []

  defp distribution_sources(%{"source" => source}), do: string_list(source)
  defp distribution_sources(%{"type" => type}), do: string_list(type)
  defp distribution_sources(source) when is_binary(source), do: string_list(source)
  defp distribution_sources(_), do: []

  defp audit_statuses(%{"status" => status}), do: string_list(status)
  defp audit_statuses(status) when is_binary(status), do: string_list(status)
  defp audit_statuses(_), do: []

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
