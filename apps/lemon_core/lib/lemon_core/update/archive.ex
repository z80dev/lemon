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

  @spec preflight(
          {String.t(), String.t() | nil} | {String.t(), String.t() | nil, String.t() | nil},
          keyword()
        ) ::
          :ok | {:error, term()}
  def preflight(tarballs, opts \\ [])
  def preflight({runtime, tui}, opts), do: preflight({runtime, tui, nil}, opts)

  def preflight({runtime, tui, bot}, opts) do
    with :ok <- preflight_list([runtime, tui], opts) do
      if bot, do: validate_bot(bot, opts), else: :ok
    end
  end

  defp preflight_list(tarballs, opts) do
    Enum.reduce_while(tarballs, :ok, fn
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

  @spec validate_bot(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_bot(tarball, opts \\ []) do
    max_entries = Keyword.get(opts, :max_archive_entries, @default_max_entries)
    max_bytes = Keyword.get(opts, :max_expanded_bytes, @default_max_expanded_bytes)

    task =
      Task.async(fn ->
        case read_tar_entries(tarball) do
          {:ok, entries} ->
            validate_bot_entries(entries, max_entries, max_bytes)

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case Task.yield(task, Keyword.get(opts, :archive_timeout_ms, @default_table_timeout_ms)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :invalid_archive}
      nil -> {:error, :archive_list_timeout}
    end
  end

  @doc """
  Post-extraction confinement check for a staged Lemon Bot backend tree.

  The backend ships relocatable `node_modules` symlinks, so unlike a runtime
  tree it may contain links — but only links that resolve back inside the
  staged directory, and never for `bot/bin/lemon-bot` itself. The walk uses
  `lstat` and never descends through a link, so a link cycle cannot make it
  loop.
  """
  @spec validate_bot_tree(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_bot_tree(root, opts \\ []) do
    limits = %{
      max_entries: Keyword.get(opts, :max_archive_entries, @default_max_entries),
      max_bytes: Keyword.get(opts, :max_expanded_bytes, @default_max_expanded_bytes),
      binary: Path.expand(Path.join(root, "bot/bin/lemon-bot")),
      root: Path.expand(root)
    }

    case walk_bot_tree([Path.expand(root)], limits, 0, 0) do
      {:ok, _count, _bytes} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_bot_tree([], _limits, count, bytes), do: {:ok, count, bytes}

  defp walk_bot_tree([path | rest], limits, count, bytes) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} when count + 1 <= limits.max_entries ->
        case File.ls(path) do
          {:ok, entries} ->
            children = Enum.map(entries, &Path.join(path, &1))
            walk_bot_tree(children ++ rest, limits, count + 1, bytes)

          {:error, reason} ->
            {:error, {:staged_tree_stat_failed, reason}}
        end

      {:ok, %File.Stat{type: :regular, size: size}}
      when count + 1 <= limits.max_entries and bytes + size <= limits.max_bytes ->
        walk_bot_tree(rest, limits, count + 1, bytes + size)

      {:ok, %File.Stat{type: :symlink}} when count + 1 <= limits.max_entries ->
        case confined_link(path, limits) do
          :ok -> walk_bot_tree(rest, limits, count + 1, bytes)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{type: :directory}} ->
        {:error, :archive_entry_limit}

      {:ok, %File.Stat{type: :regular, size: size}}
      when bytes + size > limits.max_bytes ->
        {:error, :archive_expanded_size_limit}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :archive_entry_limit}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :archive_entry_limit}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_staged_entry, type}}

      {:error, reason} ->
        {:error, {:staged_tree_stat_failed, reason}}
    end
  end

  defp confined_link(path, %{binary: binary}) when path == binary,
    do: {:error, :archive_unsafe_entry_type}

  defp confined_link(path, limits) do
    case File.read_link(path) do
      {:ok, target} ->
        resolved = Path.expand(target, Path.dirname(path))

        if Path.type(target) == :relative and
             (resolved == limits.root or String.starts_with?(resolved, limits.root <> "/")) do
          :ok
        else
          {:error, :archive_path_escape}
        end

      {:error, reason} ->
        {:error, {:staged_tree_stat_failed, reason}}
    end
  end

  defp read_tar_entries(tarball) do
    data =
      case File.read(tarball) do
        {:ok, <<31, 139, _::binary>> = gz} ->
          try do
            :zlib.gunzip(gz)
          rescue
            _ -> {:error, :invalid_archive}
          end

        {:ok, bytes} ->
          bytes

        {:error, reason} ->
          {:error, reason}
      end

    case data do
      {:error, reason} -> {:error, reason}
      bytes when is_binary(bytes) -> parse_tar_blocks(bytes, [], nil)
    end
  end

  defp parse_tar_blocks(<<>>, acc, _), do: {:ok, Enum.reverse(acc)}

  defp parse_tar_blocks(<<0::size(512)-unit(8), 0::size(512)-unit(8), _::binary>>, acc, _),
    do: {:ok, Enum.reverse(acc)}

  defp parse_tar_blocks(<<0::size(512)-unit(8), rest::binary>>, acc, pending),
    do: parse_tar_blocks(rest, acc, pending)

  defp parse_tar_blocks(<<header::binary-size(512), rest::binary>>, acc, pending_name) do
    <<name_bytes::binary-size(100), _mode::binary-size(8), _uid::binary-size(8),
      _gid::binary-size(8), size_bytes::binary-size(12), _mtime::binary-size(12),
      _chksum::binary-size(8), typeflag::binary-size(1), link_bytes::binary-size(100),
      magic::binary-size(6), _version::binary-size(2), _uname::binary-size(32),
      _gname::binary-size(32), _devmajor::binary-size(8), _devminor::binary-size(8),
      prefix_bytes::binary-size(155), _pad::binary-size(12)>> = header

    size_str = size_bytes |> String.trim_trailing(<<0>>) |> String.trim()

    size =
      case Integer.parse(size_str, 8) do
        {val, _} -> val
        :error -> 0
      end

    content_blocks = div(size + 511, 512) * 512
    padding = content_blocks - size

    if byte_size(rest) < content_blocks do
      {:error, :invalid_archive}
    else
      <<content::binary-size(^size), _pad::binary-size(^padding), remaining::binary>> = rest

      name = name_bytes |> :binary.split(<<0>>) |> hd()

      prefix =
        if String.starts_with?(magic, "ustar"),
          do: prefix_bytes |> :binary.split(<<0>>) |> hd(),
          else: ""

      full_name =
        cond do
          is_binary(pending_name) -> pending_name
          byte_size(prefix) > 0 -> "#{prefix}/#{name}"
          true -> name
        end

      linkname = link_bytes |> :binary.split(<<0>>) |> hd()

      case typeflag do
        "L" ->
          long_name = content |> :binary.split(<<0>>) |> hd()
          parse_tar_blocks(remaining, acc, long_name)

        "x" ->
          parse_tar_blocks(remaining, acc, pending_name)

        "g" ->
          parse_tar_blocks(remaining, acc, pending_name)

        <<0>> ->
          parse_tar_blocks(remaining, [{full_name, :regular, size, linkname} | acc], nil)

        "0" ->
          parse_tar_blocks(remaining, [{full_name, :regular, size, linkname} | acc], nil)

        "1" ->
          parse_tar_blocks(remaining, [{full_name, :hardlink, size, linkname} | acc], nil)

        "2" ->
          parse_tar_blocks(remaining, [{full_name, :symlink, size, linkname} | acc], nil)

        "5" ->
          parse_tar_blocks(remaining, [{full_name, :directory, size, linkname} | acc], nil)

        other ->
          parse_tar_blocks(remaining, [{full_name, {:other, other}, size, linkname} | acc], nil)
      end
    end
  end

  defp parse_tar_blocks(_other, acc, _), do: {:ok, Enum.reverse(acc)}

  defp validate_bot_entries(entries, max_entries, max_bytes) do
    result =
      Enum.reduce_while(entries, {:ok, MapSet.new(), MapSet.new(), 0, 0}, fn
        {raw_name, type, size, linkname}, {:ok, seen, links, count, bytes} ->
          name = raw_name |> strip_dot_prefix() |> String.trim_trailing("/")

          if name in ["", "."] and type == :directory do
            {:cont, {:ok, seen, links, count, bytes}}
          else
            parts = String.split(name, "/")

            cond do
              count + 1 > max_entries ->
                {:halt, {:error, :archive_entry_limit}}

              bytes + size > max_bytes ->
                {:halt, {:error, :archive_expanded_size_limit}}

              String.starts_with?(name, "/") or Enum.any?(parts, &(&1 in ["", ".", ".."])) ->
                {:halt, {:error, :archive_path_escape}}

              hd(parts) != "bot" ->
                {:halt, {:error, :archive_path_escape}}

              MapSet.member?(seen, name) ->
                {:halt, {:error, {:archive_duplicate_entry, name}}}

              type not in [:regular, :directory, :symlink] ->
                {:halt, {:error, :archive_unsafe_entry_type}}

              type == :symlink ->
                target = normalize_link_target(Path.dirname(name), linkname)

                if String.starts_with?(linkname, "/") or
                     not (target == "bot" or String.starts_with?(target, "bot/")) do
                  {:halt, {:error, :archive_path_escape}}
                else
                  {:cont,
                   {:ok, MapSet.put(seen, name), MapSet.put(links, name), count + 1, bytes + size}}
                end

              true ->
                {:cont, {:ok, MapSet.put(seen, name), links, count + 1, bytes + size}}
            end
          end
      end)

    with {:ok, seen, links, _count, _bytes} <- result do
      traverses? =
        Enum.any?(seen, fn name ->
          parts = String.split(name, "/")
          len = length(parts)

          if len > 1 do
            1..(len - 1)
            |> Enum.any?(fn i ->
              prefix = parts |> Enum.take(i) |> Enum.join("/")
              MapSet.member?(links, prefix)
            end)
          else
            false
          end
        end)

      cond do
        traverses? ->
          {:error, :archive_path_escape}

        MapSet.member?(links, "bot/bin/lemon-bot") ->
          {:error, :archive_unsafe_entry_type}

        true ->
          :ok
      end
    end
  end

  defp normalize_link_target(dir, linkname) do
    components =
      (String.split(dir, "/", trim: true) ++ String.split(linkname, "/", trim: true))
      |> Enum.reduce([], fn
        ".", acc -> acc
        "", acc -> acc
        "..", [] -> [".."]
        "..", [".." | _] = acc -> [".." | acc]
        "..", [_head | tail] -> tail
        comp, acc -> [comp | acc]
      end)
      |> Enum.reverse()

    Enum.join(components, "/")
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
