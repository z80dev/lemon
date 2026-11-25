defmodule LemonCore.Doctor.ExtensionDiagnostics do
  @moduledoc """
  Redacted extension/plugin directory diagnostics for support bundles.
  """

  alias LemonCore.Config
  alias LemonCore.Extensions.Manifest

  @extension_globs ["*.ex", "*.exs", "*/lib/**/*.ex"]

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    config = Config.load(project_dir, cache: false)
    paths = extension_paths(config)
    directories = Enum.map(paths, &directory_status/1)
    manifests = Enum.flat_map(directories, & &1.manifests)
    host_type_counts = count_manifest_values(manifests, & &1.host_types)
    execution = execution_policy(config)

    %{
      directories: directories,
      directory_count: length(directories),
      existing_directory_count: Enum.count(directories, & &1.exists),
      extension_file_count: Enum.reduce(directories, 0, &(&1.extension_file_count + &2)),
      manifest_count: length(manifests),
      valid_manifest_count: Enum.count(manifests, & &1.valid),
      invalid_manifest_count: Enum.count(manifests, &(not &1.valid)),
      configured_extension_path_count: configured_extension_path_count(config),
      capability_counts: count_manifest_values(manifests, & &1.capabilities),
      provider_type_counts: count_manifest_values(manifests, & &1.provider_types),
      host_type_counts: host_type_counts,
      distribution_source_counts: count_manifest_values(manifests, & &1.distribution_sources),
      audit_status_counts: count_manifest_values(manifests, & &1.audit_statuses),
      execution: execution,
      host_runtime: host_runtime(host_type_counts, execution),
      cleanup: %{
        includes_raw_source_paths: false,
        includes_file_contents: false,
        includes_load_error_messages: false,
        includes_manifest_contents: false,
        includes_distribution_urls: false,
        loads_extension_code: false
      }
    }
  end

  defp host_runtime(host_type_counts, execution) do
    invalid_hosts =
      ["beam", "mcp", "external"]
      |> Map.new(fn host ->
        {host,
         %{
           configured_count: Map.get(host_type_counts, host, 0),
           status: host_status(host, host_type_counts, execution),
           diagnostics_loads_host_code: false
         }}
      end)

    %{
      hosts: invalid_hosts,
      degraded_host_count:
        Enum.count(invalid_hosts, fn {_host, meta} -> meta.status == "degraded" end),
      manifest_only_host_count:
        Enum.count(invalid_hosts, fn {_host, meta} -> meta.status == "manifest_only" end),
      runtime_health_loads_extension_code: false
    }
  end

  defp host_status("beam", host_type_counts, execution) do
    cond do
      execution.enabled == false -> "disabled"
      Map.get(host_type_counts, "beam", 0) == 0 -> "not_configured"
      execution.configured_extension_path_count > 0 -> "loadable"
      execution.default_directories_diagnostics_only -> "diagnostics_only"
      true -> "loadable"
    end
  end

  defp host_status(host, host_type_counts, _execution)
       when host in ["mcp", "external"] do
    if Map.get(host_type_counts, host, 0) > 0, do: "manifest_only", else: "not_configured"
  end

  # Mirrors the coding agent's runtime extension paths: the global extensions
  # directory plus operator `extension_paths`, relative entries anchored at the
  # global config directory. A project's `.lemon/extensions` is never loaded,
  # so it is not reported either.
  defp extension_paths(config) do
    [LemonCore.Paths.home_path(["agent", "extensions"]) | configured_extension_paths(config)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp configured_extension_paths(%Config{agent: agent}) when is_map(agent) do
    operator_root = Path.dirname(LemonCore.Paths.global_config())

    agent
    |> map_value(:extension_paths)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand(&1, operator_root))
  end

  defp configured_extension_paths(_), do: []

  defp configured_extension_path_count(%Config{agent: agent}) when is_map(agent) do
    agent
    |> map_value(:extension_paths)
    |> List.wrap()
    |> Enum.count(&is_binary/1)
  end

  defp configured_extension_path_count(_), do: 0

  defp execution_policy(config) do
    auto_load? = auto_load_default_paths?(config)

    %{
      enabled: extensions_enabled?(config),
      configured_extension_path_count: configured_extension_path_count(config),
      default_directory_count: 1,
      auto_load_default_paths: auto_load?,
      default_directories_diagnostics_only: not auto_load?,
      diagnostics_loads_extension_code: false
    }
  end

  defp auto_load_default_paths?(%Config{agent: agent}) when is_map(agent) do
    agent
    |> map_value(:extensions)
    |> map_value(:auto_load_default_paths)
    |> truthy?()
  end

  defp auto_load_default_paths?(_), do: false

  defp extensions_enabled?(%Config{agent: agent}) when is_map(agent) do
    agent
    |> map_value(:extensions)
    |> map_value(:enabled)
    |> enabled?()
  end

  defp extensions_enabled?(_), do: true

  defp directory_status(path) do
    files = extension_files(path)
    manifests = manifest_files(path) |> Enum.map(&manifest_status/1)

    %{
      path_hash: hash(path),
      exists: File.dir?(path),
      extension_file_count: length(files),
      extension_file_hashes: Enum.map(files, &hash/1),
      nested_lib_file_count: Enum.count(files, &String.contains?(&1, "/lib/")),
      manifest_file_count: length(manifests),
      valid_manifest_count: Enum.count(manifests, & &1.valid),
      invalid_manifest_count: Enum.count(manifests, &(not &1.valid)),
      manifest_file_hashes: Enum.map(manifests, & &1.file_hash),
      manifests: manifests
    }
  end

  defp extension_files(path) do
    if File.dir?(path) do
      @extension_globs
      |> Enum.flat_map(&Path.wildcard(Path.join(path, &1)))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  defp manifest_files(path) do
    Manifest.discover(path)
  end

  defp manifest_status(path) do
    validation = Manifest.validate_file(path)

    %{
      file_hash: validation.path_hash,
      valid: validation.valid?,
      byte_size: validation.byte_size,
      error_count: length(validation.errors),
      error_hashes: Enum.map(validation.errors, &hash/1),
      capabilities: validation.capabilities,
      provider_types: validation.provider_types,
      host_types: validation.host_types,
      distribution_sources: validation.distribution_sources,
      audit_statuses: validation.audit_statuses
    }
  end

  defp count_manifest_values(manifests, fun) do
    manifests
    |> Enum.flat_map(fun)
    |> Enum.frequencies()
    |> Map.new(fn {key, count} -> {key, count} end)
  end

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp map_value(_, _), do: nil

  defp truthy?(value), do: value in [true, "true", 1]

  defp enabled?(value) when value in [false, "false", 0], do: false
  defp enabled?(_), do: true

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
