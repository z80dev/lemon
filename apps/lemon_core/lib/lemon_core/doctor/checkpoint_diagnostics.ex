defmodule LemonCore.Doctor.CheckpointDiagnostics do
  @moduledoc """
  Redacted diagnostics for the preview checkpoint store.

  `summary/2` requires an explicit scope. `:operator` (support bundles, doctor)
  summarizes the whole store. `{:session, owner}` is for user-facing callers:
  it only counts and lists checkpoints whose recorded `session_id` equals
  `owner`, and omits unreadable files whose owner cannot be established. A
  missing or blank owner yields an empty summary.
  """

  @type scope :: :operator | {:session, String.t() | nil}

  @spec summary(scope(), keyword()) :: map()
  def summary(scope, opts) when scope == :operator or is_tuple(scope) do
    dir = Keyword.get(opts, :checkpoint_dir) || LemonCore.Paths.checkpoint_dir()
    limit = Keyword.get(opts, :limit, 20)

    entries =
      dir
      |> checkpoint_files()
      |> Enum.map(&load_entry/1)
      |> Enum.filter(&in_scope?(&1, scope))

    valid = Enum.flat_map(entries, &valid_entry/1)

    %{
      store_dir: dir,
      exists: File.dir?(dir),
      count: length(valid),
      filesystem_count: Enum.count(valid, &(&1.kind == "filesystem")),
      invalid_count: Enum.count(entries, &match?({:invalid, _}, &1)),
      total_bytes: total_bytes(entries),
      oldest: valid |> timestamps() |> List.last(),
      newest: valid |> timestamps() |> List.first(),
      recent: valid |> Enum.take(limit),
      cleanup: %{
        managed: false,
        policy: "manual",
        safe_to_delete: true,
        embeds_file_contents_in_support_bundle: false,
        includes_raw_paths: false,
        includes_raw_session_ids: false
      }
    }
  end

  defp checkpoint_files(dir) do
    if File.dir?(dir), do: Path.wildcard(Path.join(dir, "*.json")), else: []
  end

  defp in_scope?(_entry, :operator), do: true

  defp in_scope?({:ok, _entry, _size, owner}, {:session, owner})
       when is_binary(owner) and owner != "",
       do: true

  defp in_scope?(_entry, {:session, _owner}), do: false

  defp load_entry(path) do
    size = file_size(path)

    with {:ok, content} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(content) do
      {:ok, redacted_entry(decoded), size, Map.get(decoded, "session_id")}
    else
      _ -> {:invalid, size}
    end
  end

  defp valid_entry({:ok, entry, _size, _owner}), do: [entry]
  defp valid_entry(_), do: []

  defp total_bytes(entries) do
    Enum.reduce(entries, 0, fn
      {:ok, _entry, size, _owner}, acc -> acc + size
      {:invalid, size}, acc -> acc + size
    end)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _} -> 0
    end
  end

  defp redacted_entry(decoded) do
    metadata = Map.get(decoded, "metadata", %{})
    checkpoint_id = Map.get(decoded, "id")

    %{
      checkpoint_id: checkpoint_id,
      session_hash: hash_value(Map.get(decoded, "session_id")),
      timestamp: Map.get(decoded, "timestamp"),
      kind: Map.get(metadata, "kind", "session"),
      tool: Map.get(metadata, "tool"),
      action: Map.get(metadata, "action"),
      path_count: Map.get(metadata, "path_count"),
      rollback: rollback_controls(checkpoint_id)
    }
  end

  defp rollback_controls(checkpoint_id) when is_binary(checkpoint_id) and checkpoint_id != "" do
    %{
      tui_diff: "/checkpoint diff #{checkpoint_id}",
      tui_restore: "/checkpoint restore #{checkpoint_id}"
    }
  end

  defp rollback_controls(_checkpoint_id), do: nil

  defp timestamps(entries) do
    entries
    |> Enum.map(& &1.timestamp)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(:desc)
  end

  defp hash_value(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_value(_), do: nil
end
