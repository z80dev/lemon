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

    with {names_output, 0} <- System.cmd("tar", ["-tzf", tarball], stderr_to_stdout: true),
         names <- String.split(names_output, "\n", trim: true),
         true <- length(names) <= max_entries || {:error, :archive_entry_limit},
         :ok <- validate_names(names),
         {types_output, 0} <- System.cmd("tar", ["-tvzf", tarball], stderr_to_stdout: true),
         :ok <- validate_types(types_output, length(names)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {_output, code} when is_integer(code) -> {:error, {:archive_list_failed, code}}
      false -> {:error, :invalid_archive}
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

  defp validate_names(names) do
    if Enum.all?(names, &safe_name?/1), do: :ok, else: {:error, :archive_path_escape}
  end

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

  defp validate_types(output, expected_count) do
    lines = String.split(output, "\n", trim: true)

    cond do
      length(lines) != expected_count -> {:error, :archive_listing_mismatch}
      Enum.all?(lines, fn <<type, _rest::binary>> -> type in [?-, ?d] end) -> :ok
      true -> {:error, :archive_unsafe_entry_type}
    end
  end
end
