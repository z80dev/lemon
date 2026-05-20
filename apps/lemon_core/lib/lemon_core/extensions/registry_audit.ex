defmodule LemonCore.Extensions.RegistryAudit do
  @moduledoc """
  Code-free extension registry validation and update audit.
  """

  alias LemonCore.Extensions.Manifest

  @installable_audits MapSet.new(["passed"])
  @blocked_audits MapSet.new(["blocked", "pending", "unknown"])

  @type audit :: %{
          valid?: boolean(),
          path_hash: String.t(),
          proof_hash: String.t() | nil,
          entry_count: non_neg_integer(),
          valid_entry_count: non_neg_integer(),
          invalid_entry_count: non_neg_integer(),
          installable_count: non_neg_integer(),
          blocked_count: non_neg_integer(),
          update_candidate_count: non_neg_integer(),
          blocked_update_count: non_neg_integer(),
          source_counts: map(),
          audit_status_counts: map(),
          host_type_counts: map(),
          capability_counts: map(),
          error_count: non_neg_integer(),
          error_hashes: [String.t()],
          cleanup: map()
        }

  @spec validate_file(String.t()) :: audit()
  def validate_file(path) when is_binary(path) do
    case read_index(path) do
      {:ok, index, body} ->
        entries = index_entries(index)
        entry_audits = audit_entries(entries)
        errors = registry_errors(index, entries) ++ Enum.flat_map(entry_audits, & &1.errors)

        build_audit(path, body, entry_audits, errors, 0, 0)

      {:error, errors} ->
        build_audit(path, nil, [], errors, 0, 0)
    end
  end

  @spec validate_update_files(String.t(), String.t()) :: audit()
  def validate_update_files(current_path, candidate_path)
      when is_binary(current_path) and is_binary(candidate_path) do
    with {:ok, current_index, _current_body} <- read_index(current_path),
         {:ok, candidate_index, candidate_body} <- read_index(candidate_path) do
      current_entries = index_entries(current_index)
      candidate_entries = index_entries(candidate_index)
      candidate_audits = audit_entries(candidate_entries)
      current_by_name = entries_by_name(current_entries)

      update_count =
        Enum.count(candidate_audits, fn entry ->
          current = Map.get(current_by_name, entry.name)

          entry.valid? and installable?(entry) and current != nil and
            newer?(entry.version, current.version)
        end)

      blocked_update_count =
        Enum.count(candidate_audits, fn entry ->
          current = Map.get(current_by_name, entry.name)

          current != nil and newer?(entry.version, current.version) and
            (not entry.valid? or blocked?(entry))
        end)

      errors =
        registry_errors(candidate_index, candidate_entries) ++
          Enum.flat_map(candidate_audits, & &1.errors)

      build_audit(
        candidate_path,
        candidate_body,
        candidate_audits,
        errors,
        update_count,
        blocked_update_count
      )
    else
      {:error, errors} ->
        build_audit(candidate_path, nil, [], errors, 0, 0)
    end
  end

  defp read_index(path) do
    with {:ok, body} <- File.read(path),
         {:ok, index} <- Jason.decode(body),
         true <- is_map(index) do
      {:ok, index, body}
    else
      {:error, %Jason.DecodeError{}} -> {:error, ["registry is not valid JSON"]}
      {:error, _} -> {:error, ["registry could not be read"]}
      _ -> {:error, ["registry JSON must be an object"]}
    end
  end

  defp index_entries(%{"extensions" => entries}) when is_list(entries), do: entries
  defp index_entries(%{"packages" => entries}) when is_list(entries), do: entries
  defp index_entries(_), do: []

  defp registry_errors(index, entries) do
    []
    |> require_schema_version(index)
    |> require_entries(index)
    |> duplicate_errors(entries)
  end

  defp require_schema_version(errors, %{"schema_version" => value})
       when is_integer(value) or is_binary(value),
       do: errors

  defp require_schema_version(errors, %{"schemaVersion" => value})
       when is_integer(value) or is_binary(value),
       do: errors

  defp require_schema_version(errors, _), do: ["schema_version must be present" | errors]

  defp require_entries(errors, %{"extensions" => entries}) when is_list(entries), do: errors
  defp require_entries(errors, %{"packages" => entries}) when is_list(entries), do: errors
  defp require_entries(errors, _), do: ["extensions must be a list" | errors]

  defp duplicate_errors(errors, entries) do
    duplicates =
      entries
      |> Enum.map(&entry_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.count(fn {_key, count} -> count > 1 end)

    if duplicates > 0, do: ["registry contains duplicate package versions" | errors], else: errors
  end

  defp audit_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> audit_entry(entry, index) end)
  end

  defp audit_entry(entry, index) when is_map(entry) do
    manifest = manifest_for_entry(entry)
    validation = Manifest.validate_map(manifest, "registry-entry-#{index}")
    audit_statuses = validation.audit_statuses
    source = List.first(validation.distribution_sources)
    audit_status = List.first(audit_statuses) || "unknown"
    name = map_value(manifest, "name")
    version = map_value(manifest, "version")

    errors =
      validation.errors
      |> missing_distribution_error(validation.distribution_sources)
      |> missing_audit_error(audit_statuses)

    %{
      valid?: errors == [],
      name: if(is_binary(name), do: name, else: nil),
      version: if(is_binary(version), do: version, else: nil),
      source: source,
      audit_status: audit_status,
      errors: errors,
      capabilities: validation.capabilities,
      host_types: validation.host_types,
      distribution_sources: validation.distribution_sources,
      audit_statuses: validation.audit_statuses
    }
  end

  defp audit_entry(_entry, index) do
    %{
      valid?: false,
      name: nil,
      version: nil,
      source: nil,
      audit_status: "unknown",
      errors: ["extensions[#{index}] must be an object"],
      capabilities: [],
      host_types: [],
      distribution_sources: [],
      audit_statuses: ["unknown"]
    }
  end

  defp manifest_for_entry(entry) do
    base =
      case map_value(entry, "manifest") do
        manifest when is_map(manifest) -> manifest
        _ -> entry
      end

    base
    |> maybe_put("distribution", map_value(entry, "distribution"))
    |> maybe_put("audit", map_value(entry, "audit"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp missing_distribution_error(errors, []),
    do: ["distribution.source must be present" | errors]

  defp missing_distribution_error(errors, _sources), do: errors

  defp missing_audit_error(errors, []), do: ["audit.status must be present" | errors]
  defp missing_audit_error(errors, _statuses), do: errors

  defp build_audit(path, body, entries, errors, update_count, blocked_update_count) do
    installable_count = Enum.count(entries, &(installable?(&1) and &1.valid?))
    blocked_count = Enum.count(entries, &(blocked?(&1) or not &1.valid?))

    %{
      valid?: errors == [],
      path_hash: hash(Path.expand(path)),
      proof_hash: if(is_binary(body), do: hash(body), else: nil),
      entry_count: length(entries),
      valid_entry_count: Enum.count(entries, & &1.valid?),
      invalid_entry_count: Enum.count(entries, &(not &1.valid?)),
      installable_count: installable_count,
      blocked_count: blocked_count,
      update_candidate_count: update_count,
      blocked_update_count: blocked_update_count,
      source_counts: count_values(entries, & &1.distribution_sources),
      audit_status_counts: count_values(entries, & &1.audit_statuses),
      host_type_counts: count_values(entries, & &1.host_types),
      capability_counts: count_values(entries, & &1.capabilities),
      error_count: length(errors),
      error_hashes: Enum.map(errors, &hash/1),
      cleanup: %{
        includes_raw_registry_paths: false,
        includes_distribution_urls: false,
        includes_package_names: false,
        includes_manifest_contents: false,
        loads_extension_code: false
      }
    }
  end

  defp installable?(entry), do: MapSet.member?(@installable_audits, entry.audit_status)
  defp blocked?(entry), do: MapSet.member?(@blocked_audits, entry.audit_status)

  defp entries_by_name(entries) do
    entries
    |> audit_entries()
    |> Enum.reject(&(is_nil(&1.name) or is_nil(&1.version)))
    |> Map.new(&{&1.name, &1})
  end

  defp entry_key(entry) when is_map(entry) do
    manifest = manifest_for_entry(entry)
    name = map_value(manifest, "name")
    version = map_value(manifest, "version")
    if is_binary(name) and is_binary(version), do: {name, version}
  end

  defp entry_key(_), do: nil

  defp newer?(candidate, current) when is_binary(candidate) and is_binary(current) do
    case {Version.parse(candidate), Version.parse(current)} do
      {{:ok, candidate_version}, {:ok, current_version}} ->
        Version.compare(candidate_version, current_version) == :gt

      _ ->
        candidate != current
    end
  end

  defp newer?(_, _), do: false

  defp count_values(entries, fun) do
    entries
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

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
