defmodule LemonCore.FileAccess do
  @moduledoc """
  Shared file containment for chat-channel `/file` transfers and
  the channel-keyed `send_file` tool (`CodingAgent.Tools.SendFile`).

  The active root is the operator-configured project (or the channel default
  cwd). Its own symlinks are resolved once, because the operator chose it;
  everything below it is walked and used through `LemonCore.ConfinedFS`
  directory descriptors, one component at a time, never following a symlink:

    * a symlink anywhere below the root is refused for reads, writes and
      archives, so a link created inside the workspace never reaches outside it;
    * `..` components and absolute paths are refused outright;
    * every existing component is resolved to its actual directory-entry name
      (exact match first, otherwise the entry with the same inode), so a
      differently cased spelling on a case-insensitive filesystem is judged by
      the real name;
    * deny rules are matched per entry (and per ancestor directory) when the
      path is used, so a rule also covers files created later. Matching is
      case-insensitive. Built-in rules always deny `.git`, `.ssh`, `.lemon`,
      `.netrc`, `.env`, `.envrc` and `.env.*`; configured `deny_globs` add to
      them using the `Path.wildcard/2` grammar (`**`, `*`, `?`, `{a,b}`,
      `[abc]`, `[a-z]`, `\\` escapes). A malformed or unsupported pattern
      (unbalanced or nested braces, unterminated or empty classes, `/` inside
      braces or classes) denies every path rather than matching nothing;
    * the walk, the deny decision's entry names and the I/O share one
      descriptor session: reads open the walked entry relative to its
      directory descriptor and require the same inode; directory archives are
      built in memory from regular files only, listed and read through each
      directory's descriptor;
    * uploads are written to a private staged temporary file and renamed
      into the walked directory (`renameat`), never through an existing
      symlink. A new upload is published only if the target is still absent
      (atomic no-replace); a forced overwrite checks that the target is still
      the walked file immediately before the rename (best-effort conflict
      detection). Upload names are reduced to a single basename;
    * tools that queue a file for later delivery send a private copy of the
      validated bytes (`retain_copy/2`), never the source path. Expired copy
      directories are pruned through their own descriptors, so a copy
      directory swapped for a symlink is never followed.

  A concurrent writer inside the root who swaps a walked directory for a
  symlink cannot redirect an operation: it stays bound to the directory that
  was walked. Hard links are not symlinks; a hard link inside the root is the
  same file wherever else it is linked.
  """

  alias LemonCore.ConfinedFS
  alias LemonCore.ConfinedFS.Stat

  @builtin_denied_names ~w(.git .ssh .lemon .netrc .env .envrc)
  @max_archive_entries 10_000
  @max_link_hops 40
  @copy_prefix "lemon-outbound-"
  @copy_ttl_seconds 24 * 60 * 60

  @symlink_error "Symlinks are not allowed in file transfer paths."
  @denied_error "Access denied for that path."
  @escape_error "Path escapes the active working directory root."
  @exists_error "File already exists. Use /file put --force <path> to overwrite."

  @type root :: String.t()

  # ---------------------------------------------------------------------------
  # Root and path resolution
  # ---------------------------------------------------------------------------

  @doc "Resolve the operator-chosen root to its physical directory."
  @spec real_root(term()) :: {:ok, root()} | {:error, String.t()}
  def real_root(root) when is_binary(root) and root != "" do
    case physical_path(Path.expand(root), @max_link_hops) do
      {:ok, real} ->
        case File.lstat(real) do
          {:ok, %File.Stat{type: :directory}} -> {:ok, real}
          _ -> {:error, "No accessible working directory configured."}
        end

      :error ->
        {:error, "No accessible working directory configured."}
    end
  end

  def real_root(_root), do: {:error, "No accessible working directory configured."}

  @doc """
  Resolve `rel` beneath `root` for `mode` (`:get` or `:put`).

  Returns the absolute path and its components, each existing one spelled as
  its actual directory entry. For `:put`, missing trailing components are
  allowed (kept as given); for `:get` the entry must exist. The result is a
  description only: `get/4`, `put/6` and `read_file/4` resolve again inside
  the descriptor session that performs their I/O.
  """
  @spec resolve(root(), term(), :get | :put) ::
          {:ok, %{abs: String.t(), parts: [String.t()]}} | {:error, String.t()}
  def resolve(root, rel, mode) when is_binary(root) and is_binary(rel) do
    with {:ok, parts} <- split_relative(rel) do
      in_root(root, fn fs ->
        with {:ok, %{parts: resolved}} <- walk(fs, parts, mode) do
          {:ok, %{abs: Path.join([root | resolved]), parts: resolved}}
        end
      end)
    end
  end

  def resolve(_root, _rel, _mode), do: {:error, "Invalid path."}

  @doc "Whether built-in rules or configured `globs` deny the relative path."
  @spec denied?([String.t()], term()) :: boolean()
  def denied?(parts, globs) when is_list(parts) do
    patterns = compile_globs(globs)

    parts
    |> prefixes()
    |> Enum.any?(&denied_with?(&1, patterns))
  end

  @doc "Refuse a denied path with the shared chat message."
  @spec ensure_allowed([String.t()], term()) :: :ok | {:error, String.t()}
  def ensure_allowed(parts, globs) do
    if denied?(parts, globs), do: {:error, @denied_error}, else: :ok
  end

  @doc "Reduce an untrusted upload name to one safe path component."
  @spec upload_name(term(), String.t()) :: String.t()
  def upload_name(name, fallback) when is_binary(name) do
    base =
      name
      |> String.replace(<<0>>, "")
      |> String.split(["/", "\\"])
      |> List.last()
      |> to_string()
      |> String.trim()

    if base in ["", ".", ".."], do: fallback, else: base
  end

  def upload_name(_name, fallback), do: fallback

  @doc """
  Sender gate shared by both transports. A non-empty `allowed_user_ids` is
  authoritative for every peer kind; an empty list defers to `fallback`.
  """
  @spec sender_allowed?(term(), term(), (-> boolean())) :: boolean()
  def sender_allowed?(allowed_ids, sender_id, fallback) when is_function(fallback, 0) do
    case normalize_ids(allowed_ids) do
      [] -> fallback.() == true
      allowed -> is_integer(normalize_id(sender_id)) and normalize_id(sender_id) in allowed
    end
  end

  # ---------------------------------------------------------------------------
  # Transfers
  # ---------------------------------------------------------------------------

  @doc """
  Store an upload at `rel` beneath `root`. `fetch` downloads the bytes and is
  called only after the destination passed every check. `cfg` supplies
  `deny_globs` and `max_upload_bytes` (default `default_max`).
  """
  @spec put(
          root(),
          term(),
          map(),
          (-> {:ok, binary()} | {:error, String.t()}),
          boolean(),
          pos_integer()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def put(root, rel, cfg, fetch, force, default_max) when is_function(fetch, 0) do
    case split_relative(rel) do
      {:ok, [_ | _] = parts} ->
        in_root(root, fn fs ->
          with {:ok, walked} <- walk(fs, parts, :put),
               :ok <- ensure_allowed(walked.parts, cfg_value(cfg, :deny_globs)),
               {:ok, bytes} when is_binary(bytes) <- fetch.(),
               :ok <-
                 within_size(byte_size(bytes), max_bytes(cfg, :max_upload_bytes, default_max)),
               :ok <- write(fs, walked, bytes, force) do
            {:ok, Enum.join(walked.parts, "/")}
          else
            {:error, msg} when is_binary(msg) -> {:error, msg}
            _ -> {:error, "Failed to write file."}
          end
        end)

      {:ok, []} ->
        {:error, "Invalid path."}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Read `rel` beneath `root` for sending: `{:ok, filename, bytes}` for a
  regular file, or a zip of a directory's allowed regular files. `cfg`
  supplies `deny_globs` and `max_download_bytes` (default `default_max`).
  """
  @spec get(root(), term(), map(), pos_integer()) ::
          {:ok, String.t(), binary()} | {:error, String.t()}
  def get(root, rel, cfg, default_max) do
    globs = cfg_value(cfg, :deny_globs)
    max = max_bytes(cfg, :max_download_bytes, default_max)

    with {:ok, parts} <- split_relative(rel) do
      in_root(root, fn fs ->
        with {:ok, walked} <- walk(fs, parts, :get),
             :ok <- ensure_allowed(walked.parts, globs) do
          get_entry(fs, root, walked, globs, max)
        end
      end)
    end
  end

  defp get_entry(fs, root, %{parts: []}, globs, max) do
    with {:ok, zip} <- archive(fs, :root, [], globs, max),
         do: {:ok, Path.basename(root) <> ".zip", zip}
  end

  defp get_entry(fs, _root, %{stat: %Stat{type: :regular}} = walked, _globs, max) do
    with {:ok, bytes} <- read_regular(fs, walked, max), do: {:ok, walked.name, bytes}
  end

  defp get_entry(fs, _root, %{stat: %Stat{type: :directory}} = walked, globs, max) do
    with {:ok, dir} <- open_child(fs, walked.dir, walked.name),
         {:ok, zip} <- archive(fs, dir, walked.parts, globs, max),
         do: {:ok, walked.name <> ".zip", zip}
  end

  @doc """
  Read one regular file `rel` beneath the physical `root` with the same walk,
  deny rules (built-ins plus `globs`) and identity-checked read as `get/4`.
  Returns the actual entry name and the bytes; directories are refused.
  """
  @spec read_file(root(), term(), term(), pos_integer()) ::
          {:ok, String.t(), binary()} | {:error, String.t()}
  def read_file(root, rel, globs, max_bytes) do
    case split_relative(rel) do
      {:ok, [_ | _] = parts} ->
        in_root(root, fn fs ->
          with {:ok, walked} <- walk(fs, parts, :get),
               :ok <- ensure_allowed(walked.parts, globs) do
            case walked.stat do
              %Stat{type: :regular} ->
                with {:ok, bytes} <- read_regular(fs, walked, max_bytes),
                     do: {:ok, walked.name, bytes}

              _directory ->
                {:error, "Not a regular file."}
            end
          end
        end)

      {:ok, []} ->
        {:error, "Invalid path."}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Run `fun` with a private temporary copy of `bytes` named `name`; the copy is
  removed afterwards whatever `fun` returns or raises.
  """
  @spec with_temp_file(String.t(), binary(), (String.t() -> result)) :: result when result: term()
  def with_temp_file(name, bytes, fun) when is_function(fun, 1) do
    tmp = System.tmp_dir!()
    dir = "lemon-file-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    file = upload_name(name, "file")

    case private_copy(tmp, dir, file, bytes) do
      :ok ->
        try do
          fun.(Path.join([tmp, dir, file]))
        after
          remove_private_dir(tmp, dir)
        end

      :error ->
        raise File.Error, reason: :eio, action: "write temporary file", path: Path.join(tmp, dir)
    end
  end

  @doc """
  Keep a private copy of validated `bytes` for delivery after the caller
  returns (queued tool attachments). The copy lives in a fresh 0700 directory
  under the system temp dir; copies older than 24 hours are pruned whenever a
  new one is made. Returns the copy's path, never the source path.
  """
  @spec retain_copy(String.t(), binary()) :: {:ok, String.t()} | {:error, String.t()}
  def retain_copy(name, bytes) when is_binary(bytes) do
    tmp = System.tmp_dir!()
    prune_copies(tmp)
    dir = @copy_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    file = upload_name(name, "file")

    case private_copy(tmp, dir, file, bytes) do
      :ok -> {:ok, Path.join([tmp, dir, file])}
      :error -> {:error, "Failed to prepare the file for delivery."}
    end
  end

  # A fresh 0700 directory `dir` in `tmp` holding `file`; removed again on
  # failure.
  defp private_copy(tmp, dir, file, bytes) do
    result =
      ConfinedFS.with_root(tmp, fn fs ->
        with :ok <- ConfinedFS.mkdir(fs, :root, dir, 0o700),
             :ok <- ConfinedFS.chmod(fs, :root, dir, 0o700),
             {:ok, handle} <- ConfinedFS.open_dir(fs, :root, [dir]),
             {:ok, _stat} <- ConfinedFS.create(fs, handle, file, bytes) do
          :ok
        else
          _ ->
            remove_copy_dir(fs, dir)
            :error
        end
      end)

    if result == :ok, do: :ok, else: :error
  end

  defp remove_private_dir(tmp, dir) do
    ConfinedFS.with_root(tmp, &remove_copy_dir(&1, dir))
    :ok
  end

  # Copy directories are opened without following symlinks and emptied
  # through their own descriptor, so one swapped for a symlink is never
  # followed.
  defp prune_copies(tmp) do
    cutoff = System.os_time(:second) - @copy_ttl_seconds

    ConfinedFS.with_root(tmp, fn fs ->
      case ConfinedFS.list(fs, :root, prefix: @copy_prefix) do
        {:ok, entries} ->
          for {name, %Stat{type: :directory, mtime: mtime}} <- entries,
              mtime < cutoff,
              do: remove_copy_dir(fs, name)

        {:error, _} ->
          :ok
      end
    end)

    :ok
  end

  defp remove_copy_dir(fs, name) do
    _ =
      with {:ok, dir} <- ConfinedFS.open_dir(fs, :root, [name]) do
        _ =
          case ConfinedFS.list(fs, dir) do
            {:ok, entries} ->
              for {entry, %Stat{type: type}} <- entries,
                  type != :directory,
                  do: ConfinedFS.unlink(fs, dir, entry)

            {:error, _} ->
              :ok
          end

        ConfinedFS.close_dir(fs, dir)
      end

    _ = ConfinedFS.rmdir(fs, :root, name)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Writes
  # ---------------------------------------------------------------------------

  # Missing directories are created below the deepest walked directory
  # without following symlinks. A new file is published only while still
  # absent (atomic); a forced overwrite checks the walked entry just before
  # the rename (best-effort).
  defp write(fs, %{missing: [_ | _] = missing, dir: dir}, bytes, _force) do
    {dirs, [name]} = Enum.split(missing, -1)

    with {:ok, target} <- create_dirs(fs, dir, dirs) do
      replace(fs, target, name, bytes, :absent)
    end
  end

  defp write(fs, %{stat: %Stat{type: :regular} = stat} = walked, bytes, true),
    do: replace(fs, walked.dir, walked.name, bytes, stat)

  defp write(_fs, %{stat: %Stat{type: :regular}}, _bytes, _force),
    do: {:error, @exists_error}

  defp write(_fs, _walked, _bytes, _force), do: {:error, "Invalid path."}

  defp create_dirs(_fs, dir, []), do: {:ok, dir}

  defp create_dirs(fs, dir, dirs) do
    case ConfinedFS.open_dir(fs, dir, dirs, create: true) do
      {:ok, handle} -> {:ok, handle}
      {:error, :symlink} -> {:error, @symlink_error}
      {:error, reason} when reason in [:enotdir, :eexist] -> {:error, "Invalid path."}
      {:error, _} -> {:error, "Failed to write file."}
    end
  end

  defp replace(fs, dir, name, bytes, expect) do
    case ConfinedFS.replace(fs, dir, name, bytes, expect: expect) do
      {:ok, _stat} -> :ok
      {:error, :symlink} -> {:error, @symlink_error}
      {:error, :eexist} -> {:error, @exists_error}
      {:error, reason} when reason in [:eisdir, :not_regular] -> {:error, "Invalid path."}
      {:error, _} -> {:error, "Failed to write file."}
    end
  end

  defp cfg_value(cfg, key) when is_map(cfg),
    do: Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))

  defp cfg_value(_cfg, _key), do: nil

  defp max_bytes(cfg, key, default) do
    case normalize_id(cfg_value(cfg, key)) do
      max when is_integer(max) and max > 0 -> max
      _ -> default
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # One descriptor session for the walk and the I/O. Session failures (a
  # missing root or helper) are reported without detail.
  defp in_root(root, fun) do
    case ConfinedFS.with_root(root, fun) do
      {:error, reason} when is_atom(reason) -> {:error, "Unable to access the working directory."}
      result -> result
    end
  end

  defp split_relative(rel) do
    rel = String.trim(rel)

    cond do
      rel == "" ->
        {:error, "Invalid path."}

      String.contains?(rel, <<0>>) ->
        {:error, "Invalid path."}

      Path.type(rel) != :relative ->
        {:error, "Path must be relative to the active working directory root."}

      true ->
        rel |> Path.split() |> Enum.reject(&(&1 == ".")) |> check_parts()
    end
  end

  defp check_parts(parts) do
    if Enum.any?(parts, &(&1 == "..")), do: {:error, @escape_error}, else: {:ok, parts}
  end

  # Walks `parts` through directory descriptors. Returns the deepest walked
  # directory handle (`dir`), the final entry's actual name and stat when it
  # exists, the missing trailing components (`:put` only) and every
  # component spelled as its actual directory entry (missing ones as given).
  defp walk(fs, parts, mode), do: walk(fs, :root, parts, [], mode)

  defp walk(fs, :root, [], [], _mode) do
    case ConfinedFS.stat(fs, :root) do
      {:ok, stat} -> {:ok, %{dir: :root, name: nil, stat: stat, missing: [], parts: []}}
      _ -> {:error, "Not found."}
    end
  end

  defp walk(fs, dir, [part | rest], acc, mode) do
    case ConfinedFS.stat(fs, dir, part) do
      {:ok, %Stat{type: :symlink}} ->
        {:error, @symlink_error}

      {:ok, %Stat{type: type} = stat} when type in [:directory, :regular] ->
        with {:ok, name} <- entry_name(fs, dir, part, stat) do
          step(fs, dir, name, stat, rest, [name | acc], mode)
        end

      {:ok, _other} ->
        {:error, "Unsupported file type."}

      {:error, :enoent} when mode == :put ->
        {:ok,
         %{
           dir: dir,
           name: nil,
           stat: nil,
           missing: [part | rest],
           parts: Enum.reverse(acc, [part | rest])
         }}

      {:error, _} ->
        {:error, "Not found."}
    end
  end

  defp step(_fs, dir, name, stat, [], acc, _mode),
    do: {:ok, %{dir: dir, name: name, stat: stat, missing: [], parts: Enum.reverse(acc)}}

  defp step(fs, dir, name, %Stat{type: :directory}, rest, acc, mode) do
    with {:ok, child} <- open_child(fs, dir, name), do: walk(fs, child, rest, acc, mode)
  end

  defp step(_fs, _dir, _name, _stat, _rest, _acc, _mode), do: {:error, "Invalid path."}

  defp open_child(fs, dir, name) do
    case ConfinedFS.open_dir(fs, dir, [name]) do
      {:ok, handle} -> {:ok, handle}
      {:error, :symlink} -> {:error, @symlink_error}
      {:error, :enoent} -> {:error, "Not found."}
      {:error, _} -> {:error, "Invalid path."}
    end
  end

  # The listed name of the entry `part` reached. Case-insensitive or
  # normalization-insensitive filesystems accept other spellings, so a
  # non-exact spelling is mapped to the listed entry with the same inode.
  defp entry_name(fs, dir, part, %Stat{} = stat) do
    case ConfinedFS.list(fs, dir) do
      {:ok, entries} ->
        if List.keymember?(entries, part, 0) do
          {:ok, part}
        else
          folded = fold(part)
          {likely, rest} = Enum.split_with(entries, fn {name, _} -> fold(name) == folded end)

          case Enum.find(likely ++ rest, fn {_name, entry} -> Stat.same_object?(entry, stat) end) do
            {name, _} -> {:ok, name}
            nil -> {:error, "Not found."}
          end
        end

      {:error, _} ->
        {:error, "Not found."}
    end
  end

  # The walked regular file, read relative to its directory descriptor and
  # bound to the walked inode.
  defp read_regular(fs, %{dir: dir, name: name, stat: stat}, max_bytes) do
    with :ok <- within_size(stat.size, max_bytes) do
      read_entry(fs, dir, name, stat, max_bytes)
    end
  end

  defp read_entry(fs, dir, name, stat, max_bytes) do
    case ConfinedFS.read(fs, dir, name, max_bytes, expect: stat) do
      {:ok, bytes, _stat} -> {:ok, bytes}
      {:error, :too_large} -> {:error, "File is too large."}
      {:error, :symlink} -> {:error, @symlink_error}
      {:error, _} -> {:error, "Unable to read file."}
    end
  end

  defp within_size(size, max) when is_integer(max) and max > 0 and size > max,
    do: {:error, "File is too large."}

  defp within_size(_size, _max), do: :ok

  defp archive(fs, dir, parts, globs, max_bytes) do
    patterns = compile_globs(globs)

    budget = %{bytes: max_bytes, entries: @max_archive_entries, base: length(parts)}

    with {:ok, entries, _budget} <- collect(fs, dir, parts, [], patterns, budget) do
      case :zip.create(~c"archive.zip", Enum.reverse(entries), [:memory]) do
        {:ok, {_name, zip}} -> {:ok, zip}
        _ -> {:error, "Failed to zip directory."}
      end
    end
  end

  # `dir` is the directory's handle and `dir_parts` its components from the
  # root (deny rules); entry names in the archive drop the first `base`.
  defp collect(fs, dir, dir_parts, acc, patterns, budget) do
    case ConfinedFS.list(fs, dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, acc, budget}, fn {name, stat}, {:ok, acc, budget} ->
          entry_parts = dir_parts ++ [name]

          if denied_with?(entry_parts, patterns) do
            {:cont, {:ok, acc, budget}}
          else
            case collect_entry(fs, dir, name, stat, entry_parts, acc, patterns, budget) do
              {:ok, acc, budget} -> {:cont, {:ok, acc, budget}}
              {:error, _} = error -> {:halt, error}
            end
          end
        end)

      {:error, _} ->
        {:error, "Unable to read directory."}
    end
  end

  defp collect_entry(fs, dir, name, %Stat{type: :directory}, parts, acc, patterns, budget) do
    case ConfinedFS.open_dir(fs, dir, [name]) do
      {:ok, child} ->
        result = collect(fs, child, parts, acc, patterns, budget)
        _ = ConfinedFS.close_dir(fs, child)
        result

      {:error, _} ->
        {:error, "Unable to read directory."}
    end
  end

  defp collect_entry(fs, dir, name, %Stat{type: :regular} = stat, parts, acc, _patterns, budget) do
    cond do
      budget.entries < 1 -> {:error, "Directory has too many files to send."}
      stat.size > budget.bytes -> {:error, "File is too large."}
      true -> add_entry(fs, dir, name, stat, parts, acc, budget)
    end
  end

  # Symlinks and special files are skipped, never followed.
  defp collect_entry(_fs, _dir, _name, _stat, _parts, acc, _patterns, budget),
    do: {:ok, acc, budget}

  defp add_entry(fs, dir, name, stat, parts, acc, budget) do
    case read_entry(fs, dir, name, stat, budget.bytes) do
      {:ok, bytes} ->
        entry = parts |> Enum.drop(budget.base) |> Enum.join("/") |> String.to_charlist()

        {:ok, [{entry, bytes} | acc],
         %{budget | bytes: budget.bytes - byte_size(bytes), entries: budget.entries - 1}}

      {:error, _} = error ->
        error
    end
  end

  # Resolves every symlink in an absolute path (the trusted root only).
  defp physical_path(path, hops) do
    ["/" | parts] = Path.split(path)
    resolve_parts("/", parts, hops)
  end

  defp resolve_parts(current, [], _hops), do: {:ok, current}
  defp resolve_parts(_current, _parts, 0), do: :error

  defp resolve_parts(current, [part | rest], hops) do
    path = Path.join(current, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} ->
            target = Path.expand(target, current)
            ["/" | target_parts] = Path.split(target)
            resolve_parts("/", target_parts ++ rest, hops - 1)

          _ ->
            :error
        end

      {:ok, _} ->
        resolve_parts(path, rest, hops)

      {:error, _} ->
        :error
    end
  end

  defp prefixes(parts) do
    parts
    |> Enum.with_index(1)
    |> Enum.map(fn {_part, count} -> Enum.take(parts, count) end)
  end

  # ---------------------------------------------------------------------------
  # Deny rules
  # ---------------------------------------------------------------------------

  defp denied_with?(parts, patterns) do
    builtin_denied?(List.last(parts)) or
      Enum.any?(patterns, &glob_match?(&1, fold(Enum.join(parts, "/"))))
  end

  defp builtin_denied?(name) when is_binary(name) do
    name = fold(name)
    name in @builtin_denied_names or String.starts_with?(name, ".env.")
  end

  defp builtin_denied?(_name), do: false

  # Case- and normalization-insensitive comparison key.
  defp fold(name) do
    case :unicode.characters_to_nfc_binary(name) do
      nfc when is_binary(nfc) -> String.downcase(nfc)
      _ -> for <<byte <- name>>, into: "", do: <<ascii_downcase(byte)>>
    end
  end

  defp ascii_downcase(byte) when byte in ?A..?Z, do: byte + 32
  defp ascii_downcase(byte), do: byte

  defp glob_match?(:malformed, _path), do: true

  defp glob_match?({unicode, bytes}, path) do
    if String.valid?(path) do
      Regex.match?(unicode, path)
    else
      bytes == :malformed or Regex.match?(bytes, path)
    end
  end

  defp compile_globs(globs) when is_list(globs) do
    Enum.flat_map(globs, fn
      glob when is_binary(glob) ->
        if String.trim(glob) == "", do: [], else: [glob_regex(glob)]

      _other ->
        [:malformed]
    end)
  end

  defp compile_globs(nil), do: []
  defp compile_globs(_globs), do: [:malformed]

  # Non-enumerating matcher for the `Path.wildcard/2` grammar with
  # `match_dot: true`, compared case-insensitively. Patterns compile in
  # dot-all mode so `**` spans names containing newlines. Anything the grammar
  # does not define compiles to `:malformed`, which denies every path.
  defp glob_regex(glob) do
    source =
      glob
      |> String.trim()
      |> String.trim_leading("./")
      |> String.trim_trailing("/")
      |> fold()

    with true <- String.valid?(source),
         {:ok, regex} <- glob_source(source, ""),
         {:ok, unicode} <- Regex.compile("\\A" <> regex <> "\\z", "ius") do
      bytes =
        case Regex.compile("\\A" <> regex <> "\\z", "is") do
          {:ok, compiled} -> compiled
          {:error, _} -> :malformed
        end

      {unicode, bytes}
    else
      _ -> :malformed
    end
  end

  defp glob_source("", acc), do: {:ok, acc}
  defp glob_source("**/" <> rest, acc), do: glob_source(rest, acc <> "(?:.*/)?")
  defp glob_source("**" <> rest, acc), do: glob_source(rest, acc <> ".*")
  defp glob_source("{" <> rest, acc), do: alternatives(rest, [], "", acc)
  defp glob_source("}" <> _rest, _acc), do: :error
  defp glob_source("]" <> _rest, _acc), do: :error
  defp glob_source(rest, acc), do: single(rest, acc, &glob_source/2)

  # One token valid both at top level and inside an alternative.
  defp single("*" <> rest, acc, next), do: next.(rest, acc <> "[^/]*")
  defp single("?" <> rest, acc, next), do: next.(rest, acc <> "[^/]")

  defp single("[" <> rest, acc, next) do
    with {:ok, class, rest} <- char_class(rest, []), do: next.(rest, acc <> class)
  end

  defp single("\\" <> <<char::utf8, rest::binary>>, acc, next),
    do: next.(rest, acc <> Regex.escape(<<char::utf8>>))

  defp single("\\", _acc, _next), do: :error

  defp single(<<char::utf8, rest::binary>>, acc, next),
    do: next.(rest, acc <> Regex.escape(<<char::utf8>>))

  # `{a,b,...}`: alternatives may hold `*`, `?`, classes and escapes but not
  # `**`, `/` or another brace group (`:filelib` rejects or mis-parses those).
  defp alternatives("", _alts, _current, _acc), do: :error
  defp alternatives("/" <> _rest, _alts, _current, _acc), do: :error
  defp alternatives("**" <> _rest, _alts, _current, _acc), do: :error
  defp alternatives("{" <> _rest, _alts, _current, _acc), do: :error

  defp alternatives("," <> rest, alts, current, acc),
    do: alternatives(rest, [current | alts], "", acc)

  defp alternatives("}" <> rest, alts, current, acc) do
    group = [current | alts] |> Enum.reverse() |> Enum.join("|")
    glob_source(rest, acc <> "(?:" <> group <> ")")
  end

  defp alternatives("]" <> _rest, _alts, _current, _acc), do: :error

  defp alternatives(rest, alts, current, acc) do
    single(rest, current, fn rest, current -> alternatives(rest, alts, current, acc) end)
  end

  # `[abc]`, `[a-z]` (either order); `-` first or last is literal.
  defp char_class("]" <> rest, [_ | _] = items),
    do: {:ok, "[" <> (items |> Enum.reverse() |> Enum.join()) <> "]", rest}

  defp char_class("", _items), do: :error
  defp char_class("]" <> _rest, []), do: :error
  defp char_class("/" <> _rest, _items), do: :error
  defp char_class("[" <> _rest, _items), do: :error

  defp char_class(<<a::utf8, "-", b::utf8, rest::binary>>, items) when b != ?] do
    if a == ?/ or b == ?/ do
      :error
    else
      {low, high} = if a <= b, do: {a, b}, else: {b, a}
      char_class(rest, [class_char(low) <> "-" <> class_char(high) | items])
    end
  end

  defp char_class("\\" <> <<char::utf8, rest::binary>>, items),
    do: char_class(rest, [class_char(char) | items])

  defp char_class(<<char::utf8, rest::binary>>, items),
    do: char_class(rest, [class_char(char) | items])

  defp class_char(char) when char in [?\\, ?], ?[, ?^, ?-], do: "\\" <> <<char::utf8>>
  defp class_char(char), do: <<char::utf8>>

  defp normalize_ids(ids) when is_list(ids),
    do: ids |> Enum.map(&normalize_id/1) |> Enum.filter(&is_integer/1)

  defp normalize_ids(_ids), do: []

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_id(_id), do: nil
end
