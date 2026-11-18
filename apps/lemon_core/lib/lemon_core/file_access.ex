defmodule LemonCore.FileAccess do
  @moduledoc """
  Shared file containment for chat `/file` transfers (Telegram, Discord) and
  the gateway's file-sending tools (`discord_send_file`, `telegram_send_image`).

  The active root is the operator-configured project (or the channel default
  cwd). Its own symlinks are resolved once, because the operator chose it;
  everything below it is walked component by component with `lstat`:

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
    * reads open the file and compare the opened handle's identity with the
      walked entry, then re-walk the parents; directory archives are built in
      memory from regular files only;
    * uploads are written to an exclusive temporary file in the checked
      directory and renamed into place, never through an existing symlink;
      upload names are reduced to a single basename;
    * tools that queue a file for later delivery send a private copy of the
      validated bytes (`retain_copy/2`), never the source path.

  Known gap (shared finding NEW-6): the walk checks each parent directory by
  path, then a separate syscall opens, writes or renames. A writer who can
  swap a checked parent directory for a symlink between the walk and the
  open/write/rename can redirect that operation outside the root. The
  re-walk after each operation reports such a swap but does not prevent it.
  Closing this needs descriptor-relative, no-follow I/O (`openat` with
  `O_NOFOLLOW`), which is not available here; do not rely on this module for
  containment against a concurrent local writer inside the root.
  """

  @builtin_denied_names ~w(.git .ssh .lemon .netrc .env .envrc)
  @max_archive_entries 10_000
  @max_link_hops 40
  @copy_prefix "lemon-outbound-"
  @copy_ttl_seconds 24 * 60 * 60

  @symlink_error "Symlinks are not allowed in file transfer paths."
  @denied_error "Access denied for that path."
  @escape_error "Path escapes the active working directory root."

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
  allowed (kept as given); for `:get` the entry must exist.
  """
  @spec resolve(root(), term(), :get | :put) ::
          {:ok, %{abs: String.t(), parts: [String.t()]}} | {:error, String.t()}
  def resolve(root, rel, mode) when is_binary(root) and is_binary(rel) do
    with {:ok, parts} <- split_relative(rel),
         {:ok, abs, resolved} <- walk(root, parts, mode) do
      {:ok, %{abs: abs, parts: resolved}}
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
    with {:ok, %{parts: [_ | _] = parts}} <- resolve(root, rel, :put),
         :ok <- ensure_allowed(parts, cfg_value(cfg, :deny_globs)),
         {:ok, bytes} when is_binary(bytes) <- fetch.(),
         :ok <- within_size(byte_size(bytes), max_bytes(cfg, :max_upload_bytes, default_max)) do
      write(root, parts, bytes, force)
    else
      {:ok, %{parts: []}} -> {:error, "Invalid path."}
      {:error, msg} when is_binary(msg) -> {:error, msg}
      _ -> {:error, "Failed to write file."}
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

    with {:ok, %{abs: abs, parts: parts}} <- resolve(root, rel, :get),
         :ok <- ensure_allowed(parts, globs) do
      case File.lstat(abs) do
        {:ok, %File.Stat{type: :regular}} ->
          with {:ok, bytes} <- read_regular(root, parts, max),
               do: {:ok, filename(root, parts), bytes}

        {:ok, %File.Stat{type: :directory}} ->
          with {:ok, zip} <- archive(root, parts, globs, max),
               do: {:ok, filename(root, parts) <> ".zip", zip}

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, @symlink_error}

        {:ok, _other} ->
          {:error, "Unsupported file type."}

        {:error, _} ->
          {:error, "Not found."}
      end
    end
  end

  @doc """
  Read one regular file `rel` beneath the physical `root` with the same walk,
  deny rules (built-ins plus `globs`) and identity-checked read as `get/4`.
  Returns the actual entry name and the bytes; directories are refused.
  """
  @spec read_file(root(), term(), term(), pos_integer()) ::
          {:ok, String.t(), binary()} | {:error, String.t()}
  def read_file(root, rel, globs, max_bytes) do
    with {:ok, %{abs: abs, parts: [_ | _] = parts}} <- resolve(root, rel, :get),
         :ok <- ensure_allowed(parts, globs),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(abs),
         {:ok, bytes} <- read_regular(root, parts, max_bytes) do
      {:ok, List.last(parts), bytes}
    else
      {:ok, %{parts: []}} -> {:error, "Invalid path."}
      {:ok, %File.Stat{type: :symlink}} -> {:error, @symlink_error}
      {:ok, %File.Stat{}} -> {:error, "Not a regular file."}
      {:error, msg} when is_binary(msg) -> {:error, msg}
      _ -> {:error, "Not found."}
    end
  end

  @doc """
  Run `fun` with a private temporary copy of `bytes` named `name`; the copy is
  removed afterwards whatever `fun` returns or raises.
  """
  @spec with_temp_file(String.t(), binary(), (String.t() -> result)) :: result when result: term()
  def with_temp_file(name, bytes, fun) when is_function(fun, 1) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "lemon-file-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    :ok = File.mkdir(dir)

    try do
      :ok = File.chmod(dir, 0o700)
      path = Path.join(dir, upload_name(name, "file"))
      :ok = File.write(path, bytes, [:exclusive])
      fun.(path)
    after
      File.rm_rf(dir)
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

    dir =
      Path.join(
        tmp,
        @copy_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    path = Path.join(dir, upload_name(name, "file"))

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, bytes, [:exclusive]) do
      {:ok, path}
    else
      _ ->
        remove_copy_dir(dir)
        {:error, "Failed to prepare the file for delivery."}
    end
  end

  # lstat only: a symlink named like a copy directory is never followed.
  defp prune_copies(tmp) do
    cutoff = System.os_time(:second) - @copy_ttl_seconds

    case File.ls(tmp) do
      {:ok, names} ->
        for name <- names, String.starts_with?(name, @copy_prefix) do
          dir = Path.join(tmp, name)

          case File.lstat(dir, time: :posix) do
            {:ok, %File.Stat{type: :directory, mtime: mtime}} when mtime < cutoff ->
              remove_copy_dir(dir)

            _ ->
              :ok
          end
        end

        :ok

      {:error, _} ->
        :ok
    end
  end

  defp remove_copy_dir(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names do
          entry = Path.join(dir, name)

          case File.lstat(entry) do
            {:ok, %File.Stat{type: type}} when type != :directory -> File.rm(entry)
            _ -> :ok
          end
        end

      {:error, _} ->
        :ok
    end

    _ = File.rmdir(dir)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Writes
  # ---------------------------------------------------------------------------

  # Missing directories are created one component at a time and re-checked;
  # an existing symlink is never followed or replaced.
  defp write(root, parts, bytes, force) do
    {dirs, [name]} = Enum.split(parts, -1)

    with {:ok, dir} <- ensure_dirs(root, dirs),
         abs = Path.join(dir, name),
         :ok <- check_target(abs, force),
         :ok <- atomic_write(dir, abs, bytes),
         {:ok, ^abs, _parts} <- walk(root, parts, :recheck) do
      {:ok, Enum.join(parts, "/")}
    else
      {:ok, _other, _parts} -> {:error, @symlink_error}
      {:error, msg} when is_binary(msg) -> {:error, msg}
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

  # Returns the absolute path and the components with every existing one
  # replaced by its actual directory-entry name. `:recheck` re-walks already
  # resolved components after an operation and skips the directory listing.
  defp walk(root, parts, mode) do
    Enum.reduce_while(parts, {:ok, root, [], false}, fn part, {:ok, current, acc, missing?} ->
      if missing? do
        {:cont, {:ok, Path.join(current, part), [part | acc], true}}
      else
        walk_step(current, part, acc, mode)
      end
    end)
    |> case do
      {:ok, abs, acc, _missing?} ->
        resolved = Enum.reverse(acc)

        with {:ok, ^abs} <- intermediate_dirs(root, resolved, abs),
             do: {:ok, abs, resolved}

      {:error, _} = error ->
        error
    end
  end

  defp walk_step(current, part, acc, mode) do
    path = Path.join(current, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:halt, {:error, @symlink_error}}

      {:ok, %File.Stat{type: type}} when type in [:directory, :regular] and mode == :recheck ->
        {:cont, {:ok, path, [part | acc], false}}

      {:ok, %File.Stat{type: type} = stat} when type in [:directory, :regular] ->
        case entry_name(current, part, stat) do
          {:ok, name} -> {:cont, {:ok, Path.join(current, name), [name | acc], false}}
          :error -> {:halt, {:error, "Not found."}}
        end

      {:ok, _} ->
        {:halt, {:error, "Unsupported file type."}}

      {:error, :enoent} when mode == :put ->
        {:cont, {:ok, path, [part | acc], true}}

      {:error, _} ->
        {:halt, {:error, "Not found."}}
    end
  end

  # The listed name of the entry `part` reached. Case-insensitive or
  # normalization-insensitive filesystems accept other spellings, so a
  # non-exact spelling is mapped to the listed entry with the same inode.
  defp entry_name(dir, part, %File.Stat{inode: inode, major_device: device}) do
    with {:ok, names} <- File.ls(dir) do
      if part in names do
        {:ok, part}
      else
        folded = fold(part)
        {likely, rest} = Enum.split_with(names, &(fold(&1) == folded))

        Enum.find(likely ++ rest, fn name ->
          match?(
            {:ok, %File.Stat{inode: ^inode, major_device: ^device}},
            File.lstat(Path.join(dir, name))
          )
        end)
        |> case do
          nil -> :error
          name -> {:ok, name}
        end
      end
    else
      _ -> :error
    end
  end

  # Every existing component except the last must be a real directory.
  defp intermediate_dirs(root, parts, abs) do
    parts
    |> Enum.drop(-1)
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.reduce_while({:ok, abs}, fn dir, ok ->
      case File.lstat(dir) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, ok}
        {:error, :enoent} -> {:cont, ok}
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, @symlink_error}}
        _ -> {:halt, {:error, "Invalid path."}}
      end
    end)
  end

  defp read_regular(root, parts, max_bytes) do
    abs = Path.join([root | parts])

    with {:ok, %File.Stat{type: :regular, size: size} = leaf} <- File.lstat(abs),
         :ok <- within_size(size, max_bytes),
         {:ok, result} <- File.open(abs, [:read, :binary], &read_bound(&1, leaf, size)),
         {:ok, bytes} <- result,
         {:ok, ^abs, _parts} <- walk(root, parts, :recheck) do
      {:ok, bytes}
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:ok, %File.Stat{type: :symlink}} -> {:error, @symlink_error}
      _ -> {:error, "Unable to read file."}
    end
  end

  defp within_size(size, max) when is_integer(max) and max > 0 and size > max,
    do: {:error, "File is too large."}

  defp within_size(_size, _max), do: :ok

  defp read_bound(io, %File.Stat{inode: inode, major_device: device}, size) do
    with {:ok, info} <- :file.read_file_info(io),
         %File.Stat{type: :regular, inode: ^inode, major_device: ^device} <-
           File.Stat.from_record(info) do
      case IO.binread(io, size + 1) do
        :eof when size == 0 -> {:ok, ""}
        bytes when is_binary(bytes) and byte_size(bytes) == size -> {:ok, bytes}
        _ -> {:error, :changed}
      end
    else
      _ -> {:error, :identity_mismatch}
    end
  end

  defp archive(root, parts, globs, max_bytes) do
    patterns = compile_globs(globs)

    budget = %{bytes: max_bytes, entries: @max_archive_entries, base: length(parts)}

    with {:ok, entries, _budget} <- collect(root, parts, [], patterns, budget) do
      case :zip.create(~c"archive.zip", Enum.reverse(entries), [:memory]) do
        {:ok, {_name, zip}} -> {:ok, zip}
        _ -> {:error, "Failed to zip directory."}
      end
    end
  end

  # `dir_parts` locates the directory from the root; `rel` is the entry path
  # inside the archive.
  defp collect(root, dir_parts, acc, patterns, budget) do
    dir = Path.join([root | dir_parts])

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, acc, budget}, fn name, {:ok, acc, budget} ->
          entry_parts = dir_parts ++ [name]

          if denied_with?(entry_parts, patterns) do
            {:cont, {:ok, acc, budget}}
          else
            case collect_entry(root, entry_parts, acc, patterns, budget) do
              {:ok, acc, budget} -> {:cont, {:ok, acc, budget}}
              {:error, _} = error -> {:halt, error}
            end
          end
        end)

      {:error, _} ->
        {:error, "Unable to read directory."}
    end
  end

  defp collect_entry(root, parts, acc, patterns, budget) do
    case File.lstat(Path.join([root | parts])) do
      {:ok, %File.Stat{type: :directory}} ->
        collect(root, parts, acc, patterns, budget)

      {:ok, %File.Stat{type: :regular, size: size}} ->
        cond do
          budget.entries < 1 -> {:error, "Directory has too many files to send."}
          size > budget.bytes -> {:error, "File is too large."}
          true -> add_entry(root, parts, acc, budget)
        end

      # Symlinks and special files are skipped, never followed.
      _ ->
        {:ok, acc, budget}
    end
  end

  defp add_entry(root, parts, acc, budget) do
    case read_regular(root, parts, budget.bytes) do
      {:ok, bytes} ->
        name = parts |> Enum.drop(budget.base) |> Enum.join("/") |> String.to_charlist()

        {:ok, [{name, bytes} | acc],
         %{budget | bytes: budget.bytes - byte_size(bytes), entries: budget.entries - 1}}

      {:error, _} = error ->
        error
    end
  end

  defp filename(root, []), do: Path.basename(root)
  defp filename(_root, parts), do: List.last(parts)

  defp ensure_dirs(root, dirs) do
    Enum.reduce_while(dirs, {:ok, root}, fn part, {:ok, current} ->
      path = Path.join(current, part)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, {:ok, path}}

        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, @symlink_error}}

        {:ok, _} ->
          {:halt, {:error, "Invalid path."}}

        {:error, :enoent} ->
          case File.mkdir(path) do
            :ok -> {:cont, {:ok, path}}
            {:error, :eexist} -> {:halt, {:error, "Invalid path."}}
            {:error, _} -> {:halt, {:error, "Failed to write file."}}
          end

        {:error, _} ->
          {:halt, {:error, "Failed to write file."}}
      end
    end)
    |> case do
      {:ok, dir} ->
        case walk(root, dirs, :recheck) do
          {:ok, ^dir, _parts} -> {:ok, dir}
          {:ok, _other, _parts} -> {:error, @symlink_error}
          {:error, _} = error -> error
        end

      error ->
        error
    end
  end

  defp check_target(abs, force) do
    case File.lstat(abs) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, @symlink_error}

      {:ok, %File.Stat{type: :regular}} when force ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "File already exists. Use /file put --force <path> to overwrite."}

      {:ok, _} ->
        {:error, "Invalid path."}

      {:error, _} ->
        {:error, "Failed to write file."}
    end
  end

  defp atomic_write(dir, abs, bytes) do
    tmp =
      Path.join(
        dir,
        ".lemon-upload-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    with :ok <- File.write(tmp, bytes, [:exclusive]),
         :ok <- File.rename(tmp, abs) do
      :ok
    else
      _ ->
        _ = File.rm(tmp)
        {:error, "Failed to write file."}
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
        with {:ok, target} <- File.read_link(path) do
          target = Path.expand(target, current)
          ["/" | target_parts] = Path.split(target)
          resolve_parts("/", target_parts ++ rest, hops - 1)
        else
          _ -> :error
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
