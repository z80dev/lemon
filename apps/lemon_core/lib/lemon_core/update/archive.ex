defmodule LemonCore.Update.Archive do
  @moduledoc """
  Fail-closed release archive confinement checks.

  Lemon runtime/TUI archives may contain only relative regular files and
  directories. Links, devices, fifos, sockets, absolute paths, `..`
  components, oversized member sets, and oversized extracted trees are
  rejected before a staged directory can be promoted.
  """

  @default_max_entries 200_000
  @default_max_expanded_bytes 4_294_967_296
  @default_table_timeout_ms 60_000

  @spec preflight({String.t(), String.t() | nil}, keyword()) :: :ok | {:error, term()}
  def preflight({runtime, tui}, opts \\ []) do
    Enum.reduce_while([runtime, tui], :ok, fn
      nil, :ok ->
        {:cont, :ok}

      tarball, :ok ->
        case validate(tarball, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  @spec validate(String.t(), keyword()) :: :ok | {:error, term()}
  def validate(tarball, opts \\ []) do
    max_entries = Keyword.get(opts, :max_archive_entries, @default_max_entries)
    max_bytes = Keyword.get(opts, :max_expanded_bytes, @default_max_expanded_bytes)

    with {:ok, entries} <- table(tarball, opts) do
      entries
      |> Enum.reduce_while({:ok, 0, 0}, fn entry, {:ok, count, bytes} ->
        validate_entry(entry, count, bytes, max_entries, max_bytes)
      end)
      |> case do
        {:ok, _count, _bytes} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec validate_tree(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_tree(root, opts \\ []) do
    max_entries = Keyword.get(opts, :max_archive_entries, @default_max_entries)
    max_bytes = Keyword.get(opts, :max_expanded_bytes, @default_max_expanded_bytes)

    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce_while({:ok, 0, 0}, fn path, {:ok, count, bytes} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} when count + 1 <= max_entries ->
          {:cont, {:ok, count + 1, bytes}}

        {:ok, %File.Stat{type: :regular, size: size}}
        when count + 1 <= max_entries and bytes + size <= max_bytes ->
          {:cont, {:ok, count + 1, bytes + size}}

        {:ok, %File.Stat{type: type}} ->
          {:halt, {:error, {:unsafe_staged_entry, type}}}

        {:error, reason} ->
          {:halt, {:error, {:staged_tree_stat_failed, reason}}}
      end
    end)
    |> case do
      {:ok, _count, _bytes} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp table(tarball, opts) do
    task =
      Task.async(fn ->
        :erl_tar.table(String.to_charlist(tarball), [:compressed, :verbose])
      end)

    case Task.yield(task, Keyword.get(opts, :archive_timeout_ms, @default_table_timeout_ms)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, entries}} when is_list(entries) -> {:ok, entries}
      {:ok, {:error, _reason}} -> {:error, :invalid_archive}
      {:exit, _reason} -> {:error, :invalid_archive}
      nil -> {:error, :archive_list_timeout}
    end
  end

  defp validate_entry(
         {name, type, size, _mtime, _mode, _uid, _gid},
         count,
         bytes,
         max_entries,
         max_bytes
       )
       when is_list(name) and is_integer(size) and size >= 0 do
    name = List.to_string(name)

    cond do
      count + 1 > max_entries ->
        {:halt, {:error, :archive_entry_limit}}

      not safe_name?(name) ->
        {:halt, {:error, :archive_path_escape}}

      type not in [:regular, :directory] ->
        {:halt, {:error, :archive_unsafe_entry_type}}

      bytes + size > max_bytes ->
        {:halt, {:error, :archive_expanded_size_limit}}

      true ->
        {:cont, {:ok, count + 1, bytes + size}}
    end
  end

  defp validate_entry(_entry, _count, _bytes, _max_entries, _max_bytes),
    do: {:halt, {:error, :invalid_archive_entry}}

  defp safe_name?(name) do
    if name in [".", "./"] do
      true
    else
      normalized = name |> strip_dot_prefix() |> String.trim_trailing("/")
      components = Path.split(normalized)

      normalized != "" and String.valid?(name) and Path.type(name) != :absolute and
        not String.contains?(name, ["\0", "\n", "\r"]) and
        Enum.all?(components, &(&1 not in ["", ".", ".."]))
    end
  end

  defp strip_dot_prefix("./" <> rest), do: strip_dot_prefix(rest)
  defp strip_dot_prefix(name), do: name
end
