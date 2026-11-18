defmodule CodingAgent.Tools.FileValidation do
  @moduledoc """
  Shared file access validation: type checking, error formatting, and write-access checks.

  Used by Read, Write, Edit, Grep, Ls, Find, and Patch tools to
  eliminate duplicated File.stat dispatch logic.

  Validation is path-based. The mutation I/O helpers (`regular_file_identity/2`,
  `read_regular_file/3`, `write_regular_file/3`, `create_regular_file/3`,
  `replace_regular_file/4`, `delete_regular_file/2`) then perform the reads and
  writes with `LemonCore.ConfinedFS` below the same trusted boundary the checks
  use, so a directory swapped for a symlink after validation is refused instead
  of followed. The explicit `allow_symlinks: true` trusted mode keeps legacy
  path-based I/O and is outside that guarantee.
  """

  alias CodingAgent.Tools.OperatorState
  alias LemonCore.ConfinedFS
  alias LemonCore.ConfinedFS.Stat

  @max_path_length 4096

  # Whole-file reads through the descriptor-bound helper are bounded.
  @max_read_bytes 256 * 1024 * 1024

  @doc """
  Rejects binary data before text matching or newline normalization.

  Text mutation tools accept valid UTF-8 without NUL bytes. Rejection happens
  before mutation, so binary files are never partially rewritten as text.
  """
  @spec check_text_content(binary(), String.t()) :: :ok | {:error, String.t()}
  def check_text_content(content, label) when is_binary(content) do
    if String.valid?(content) and not String.contains?(content, <<0>>) do
      :ok
    else
      {:error, "#{label} contains binary data; text tools require valid UTF-8 without NUL bytes"}
    end
  end

  @doc """
  Adds complete before/after text for diff consumers only when both fit 16 KiB.
  Larger or unreadable snapshots are omitted rather than truncated.
  """
  def put_text_snapshots(details, path, old_text, new_text) do
    details = Map.put(details, :path, path)

    if (is_binary(old_text) or is_binary(new_text)) and
         (is_nil(old_text) or (is_binary(old_text) and byte_size(old_text) <= 16_384)) and
         (is_nil(new_text) or (is_binary(new_text) and byte_size(new_text) <= 16_384)) do
      details |> Map.put(:oldText, old_text) |> Map.put(:newText, new_text)
    else
      details
    end
  end

  @doc """
  Checks that `path` exists and is one of the `allowed_types`.

  Returns `{:ok, stat}` on success or `{:error, message}` with a human-readable
  error string. The `context` parameter (e.g. "file", "directory", "path") is
  used to make error messages specific to the caller.

  ## Examples

      check_path_access("/tmp/foo.txt", [:regular])
      check_path_access("/tmp", [:directory])
      check_path_access("/tmp/foo", [:regular, :directory])
  """
  @spec check_path_access(String.t(), [atom()], String.t()) ::
          {:ok, File.Stat.t()} | {:error, String.t()}
  def check_path_access(path, allowed_types \\ [:regular], context \\ nil) do
    context = context || context_from_types(allowed_types)

    case File.stat(path) do
      {:ok, %File.Stat{type: type} = stat} ->
        if type in allowed_types do
          {:ok, stat}
        else
          {:error, format_type_mismatch(type, path, context)}
        end

      {:error, reason} ->
        {:error, format_file_error(reason, path, context)}
    end
  end

  @doc """
  Checks whether a file exists as a regular file.

  Returns `{:ok, true}` if the file exists and is regular, `{:ok, false}` if not
  found, or `{:error, message}` for other problems (wrong type, permission denied).
  """
  @spec file_exists?(String.t()) :: {:ok, boolean()} | {:error, String.t()}
  def file_exists?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, true}

      {:ok, %File.Stat{type: type}} ->
        {:error, "Path is not a regular file (is #{type}): #{path}"}

      {:error, :enoent} ->
        {:ok, false}

      {:error, reason} ->
        {:error, format_file_error(reason, path, "file")}
    end
  end

  @doc """
  Validates a local filesystem target before a tool creates or overwrites it.

  Existing targets must be writable regular files. New targets are allowed only
  when every caller-controlled parent below the trusted mutation boundary is a
  real directory. Symlinks and special files are rejected by default so a
  model-authored path cannot silently redirect a write outside the path it named.

  Pass `allow_symlinks: true` only for an explicitly trusted caller that needs the
  legacy follow-symlink behavior.

  Resource operations may pass `allow_directories: true` to validate directories
  with the same parent/symlink rules without treating them as writable files.

  A session confined to a directory (`confine_mutations_to:`, e.g. a kanban
  worker's worktree) refuses every target outside it, absolute or relative, and
  checks every component below it for symlinks.

  Lemon operator state and operator toolchain locations are refused
  (`CodingAgent.Tools.OperatorState.check_mutation/2`, which honours Lemon's own
  `:operator_state_grant`/`:operator_state_dir_grant`). Only a target Lemon
  derives itself, never a model-supplied path, may pass `lemon_owned_target:
  true`; it still gets the alias (hard-link) refusal.
  """
  @spec check_mutation_target(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_mutation_target(path, opts \\ [])

  def check_mutation_target(path, opts) when is_binary(path) do
    allow_symlinks = Keyword.get(opts, :allow_symlinks, false)
    root = mutation_root(opts)
    boundary = mutation_boundary(path, root)

    with :ok <- validate_mutation_path(path),
         :ok <- confined(path, opts),
         :ok <- operator_state(path, opts) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          with :ok <- validate_mutation_parent(Path.dirname(path), allow_symlinks, boundary) do
            mutation_target_write_access(path)
          end

        {:ok, %File.Stat{type: :symlink}} when allow_symlinks ->
          with :ok <- validate_mutation_parent(Path.dirname(path), allow_symlinks, boundary) do
            mutation_symlink_target(path)
          end

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, "Cannot write through symlink: #{path}"}

        {:ok, %File.Stat{type: :directory}} ->
          if Keyword.get(opts, :allow_directories, false),
            do: validate_mutation_parent(Path.dirname(path), allow_symlinks, boundary),
            else: {:error, "Cannot write to directory: #{path}"}

        {:ok, %File.Stat{type: type}} ->
          {:error, "Cannot write to special file (#{type}): #{path}"}

        {:error, :enoent} ->
          validate_mutation_parent(Path.dirname(path), allow_symlinks, boundary)

        {:error, reason} ->
          {:error, format_file_error(reason, path, "file")}
      end
    end
  end

  def check_mutation_target(_path, _opts), do: {:error, "Path must be a string"}

  @doc """
  `:ok` unless the session confines file mutations (`confine_mutations_to:`)
  and `path` (after `..` and `~` expansion) lies outside that directory.
  Symlinks below the directory are refused separately by the mutation checks.
  """
  @spec confined(String.t(), keyword()) :: :ok | {:error, String.t()}
  def confined(path, opts) do
    case Keyword.get(opts, :confine_mutations_to) do
      nil ->
        :ok

      root when is_binary(root) ->
        expanded = Path.expand(path)
        root = Path.expand(root)

        if expanded == root or String.starts_with?(expanded, root <> "/"),
          do: :ok,
          else: {:error, "File changes are confined to #{root}; refusing #{expanded}"}

      _ ->
        {:error, "File changes are confined; refusing #{path}"}
    end
  end

  defp operator_state(path, opts) do
    if Keyword.get(opts, :lemon_owned_target) == true,
      do: OperatorState.check_aliases(path),
      else: OperatorState.check_mutation(path, opts)
  end

  # -- Mutation I/O -----------------------------------------------------------
  #
  # Each helper opens a LemonCore.ConfinedFS session at the trusted boundary of
  # the path (the directory check_mutation_target/2 checks below) and walks the
  # remaining components without following symlinks. Errors fail closed; there
  # is no path-based fallback. Identities from `allow_symlinks: true` (legacy
  # `File.Stat` or `%{link:, target:}` maps) keep the path-based behavior.

  @doc """
  Pin a regular file's identity for the read, write, replace and delete helpers.

  `path` is opened below its trusted mutation boundary: `confine_mutations_to:`
  or `mutation_root:` when `path` is inside it, otherwise the first component
  below `/`, exactly as `check_mutation_target/2` decides. Every component below
  the boundary is walked without following symlinks, so a symlink anywhere
  below it, even one swapped in after validation, is refused. The identity holds
  that location, the `LemonCore.ConfinedFS.Stat` and the permission bits as
  `:mode`.

  `allow_symlinks: true` is the trusted legacy mode: it pins the file by path and
  follows symlinks, outside the descriptor-bound guarantee.
  """
  def regular_file_identity(path, opts \\ []) do
    if Keyword.get(opts, :allow_symlinks, false) do
      legacy_identity(path, true)
    else
      with_parent(path, opts, [], fn fs, dir, name, location ->
        case ConfinedFS.stat(fs, dir, name) do
          {:ok, %Stat{type: :regular} = stat} ->
            {:ok, Map.merge(location, %{stat: stat, mode: stat.mode})}

          {:ok, %Stat{}} ->
            identity_error(path)

          {:error, reason} ->
            confined_error(reason, path)
        end
      end)
    end
  end

  @doc """
  Read only the pinned regular file; never expose a replacement path's contents.

  Options: `:max_bytes` (default 256 MiB; a larger file is refused) and
  `prefix: true`, which returns at most the first `:max_bytes` bytes instead.
  """
  def read_regular_file(path, identity, opts \\ [])

  def read_regular_file(path, %{stat: %Stat{} = stat} = identity, opts) do
    max = Keyword.get(opts, :max_bytes, @max_read_bytes)
    prefix = Keyword.get(opts, :prefix, false)

    with_identity(path, identity, fn fs, dir, name ->
      case ConfinedFS.read(fs, dir, name, max, expect: stat, prefix: prefix) do
        {:ok, content, _stat} -> {:ok, content}
        {:error, :too_large} -> too_large(path, max)
        {:error, reason} -> identity_bound_error(reason, path)
      end
    end)
  end

  def read_regular_file(path, identity, opts) do
    max = Keyword.get(opts, :max_bytes, @max_read_bytes)
    prefix = Keyword.get(opts, :prefix, false)

    with_legacy_file(path, identity, [:read, :binary], fn io ->
      case IO.binread(io, if(prefix, do: max, else: :eof)) do
        content when is_binary(content) and byte_size(content) > max -> too_large(path, max)
        content when is_binary(content) -> {:ok, content}
        :eof -> {:ok, ""}
        error -> error
      end
    end)
  end

  @doc """
  Overwrite the pinned regular file in place (same inode, mode and links) through
  a checked handle, never a path that was redirected after checking.
  """
  def write_regular_file(path, %{stat: %Stat{} = stat} = identity, content) do
    with_identity(path, identity, fn fs, dir, name ->
      case ConfinedFS.overwrite(fs, dir, name, content, expect: stat) do
        {:ok, _stat} -> :ok
        {:error, reason} -> identity_bound_error(reason, path)
      end
    end)
  end

  def write_regular_file(path, identity, content) do
    with_legacy_file(path, identity, [:read, :write, :binary], fn io ->
      with {:ok, 0} <- :file.position(io, :bof),
           :ok <- IO.binwrite(io, content),
           :ok <- :file.truncate(io) do
        :ok
      end
    end)
  end

  @doc """
  Exclusively create the regular file `path` with `content`, creating missing
  parent directories, below the boundary `regular_file_identity/2` uses (same
  options). `mode:` sets exact permission bits; otherwise the umask applies. An
  existing entry is `{:error, :eexist}`.
  """
  def create_regular_file(path, content, opts \\ []) do
    mode = Keyword.get(opts, :mode)

    if Keyword.get(opts, :allow_symlinks, false) do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, content, [:exclusive]) do
        if mode, do: File.chmod(path, mode), else: :ok
      end
    else
      mode_opts = if mode, do: [mode: mode, exact_mode: true], else: []

      with_parent(path, opts, [create: true], fn fs, dir, name, _location ->
        case ConfinedFS.create(fs, dir, name, content, mode_opts) do
          {:ok, _stat} -> :ok
          {:error, reason} -> confined_error(reason, path)
        end
      end)
    end
  end

  @doc """
  Atomically replace `path` with `content` through a privately staged temporary
  file renamed over it. With `nil` the file is published only while `path` is
  still absent (atomic no-replace; missing parent directories are created,
  `opts` as for `create_regular_file/3`). With an `identity`, its permission
  bits are kept and the entry is checked to still be that file immediately
  before the rename: best-effort conflict detection, not compare-and-swap.
  """
  def replace_regular_file(path, identity, content, opts \\ [])

  def replace_regular_file(path, %{stat: %Stat{} = stat} = identity, content, _opts) do
    with_identity(path, identity, fn fs, dir, name ->
      case ConfinedFS.replace(fs, dir, name, content, expect: stat, preserve_mode: true) do
        {:ok, _stat} -> :ok
        {:error, reason} -> identity_bound_error(reason, path)
      end
    end)
  end

  def replace_regular_file(path, nil, content, opts) do
    if Keyword.get(opts, :allow_symlinks, false) do
      legacy_replace(path, content)
    else
      with_parent(path, opts, [create: true], fn fs, dir, name, _location ->
        case ConfinedFS.replace(fs, dir, name, content, expect: :absent) do
          {:ok, _stat} -> :ok
          {:error, reason} -> confined_error(reason, path)
        end
      end)
    end
  end

  def replace_regular_file(path, identity, content, _opts) do
    with :ok <- check_legacy_identity(path, identity), do: legacy_replace(path, content)
  end

  @doc """
  Remove the pinned regular file. The entry is checked to still be that file
  immediately before the unlink (best-effort, not compare-and-swap); the
  removal never follows a symlink or leaves the walked directory.
  """
  def delete_regular_file(path, %{stat: %Stat{} = stat} = identity) do
    with_identity(path, identity, fn fs, dir, name ->
      case ConfinedFS.unlink(fs, dir, name, expect: stat) do
        :ok -> :ok
        {:error, reason} -> identity_bound_error(reason, path)
      end
    end)
  end

  def delete_regular_file(path, identity) do
    with :ok <- check_legacy_identity(path, identity), do: File.rm(path)
  end

  defp with_parent(path, opts, dir_opts, fun) do
    with {:ok, root, parts} <- mutation_location(path, opts) do
      with_session(root, path, fn fs ->
        case ConfinedFS.open_parent(fs, :root, parts, dir_opts) do
          {:ok, dir, name} -> fun.(fs, dir, name, %{root: root, parts: parts})
          {:error, reason} -> confined_error(reason, path)
        end
      end)
    end
  end

  defp with_identity(path, %{root: root, parts: parts}, fun) do
    with_session(root, path, fn fs ->
      case ConfinedFS.open_parent(fs, :root, parts) do
        {:ok, dir, name} -> fun.(fs, dir, name)
        {:error, reason} -> identity_bound_error(reason, path)
      end
    end)
  end

  defp with_session(root, path, fun) do
    case ConfinedFS.open(root) do
      {:ok, fs} ->
        try do
          fun.(fs)
        after
          ConfinedFS.close(fs)
        end

      {:error, reason} ->
        confined_error(reason, path)
    end
  end

  @doc """
  The `LemonCore.ConfinedFS` session root and components for mutating `path`:
  the same trusted boundary `check_mutation_target/2` uses with the same
  `opts` (`confine_mutations_to:`/`mutation_root:` when `path` is inside it,
  otherwise the first component below `/`). A path that is the boundary
  itself (e.g. `/name`) is located from its parent. Works for absent paths
  and directories.
  """
  @spec mutation_location(String.t(), keyword()) ::
          {:ok, String.t(), [String.t(), ...]} | {:error, String.t()}
  def mutation_location(path, opts) do
    expanded = Path.expand(path)

    root =
      case mutation_boundary(expanded, mutation_root(opts)) do
        ^expanded -> Path.dirname(expanded)
        boundary -> boundary
      end

    case ConfinedFS.beneath(root, expanded) do
      {:ok, [_ | _] = parts} -> {:ok, root, parts}
      _ -> {:error, "Invalid mutation target: #{path}"}
    end
  end

  defp identity_bound_error(reason, path) when reason in [:symlink, :not_regular, :changed],
    do: identity_error(path)

  defp identity_bound_error(reason, path), do: confined_error(reason, path)

  @doc "The tool error for a `LemonCore.ConfinedFS` failure `reason` on `path`."
  @spec confined_error(atom(), String.t()) :: {:error, term()}
  def confined_error(:symlink, path),
    do: {:error, "Cannot follow a symlink in the path (symlinks are refused): #{path}"}

  def confined_error(reason, path) when reason in [:not_regular, :changed],
    do: identity_error(path)

  def confined_error(reason, path)
      when reason in [:helper_unavailable, :helper_failed, :helper_timeout],
      do: {:error, "Confined file access is unavailable (#{reason}); refusing #{path}"}

  def confined_error(reason, _path), do: {:error, reason}

  defp too_large(path, max), do: {:error, "File exceeds the #{max}-byte read limit: #{path}"}

  # -- Legacy (allow_symlinks: true) path-based I/O ---------------------------

  defp legacy_identity(path, follow_symlinks) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, stat}

      {:ok, %File.Stat{type: :symlink} = link} when follow_symlinks ->
        case File.stat(path) do
          {:ok, %File.Stat{type: :regular} = target} ->
            {:ok, %{link: link, target: target, mode: target.mode}}

          _ ->
            identity_error(path)
        end

      {:ok, _} ->
        identity_error(path)

      error ->
        error
    end
  end

  defp with_legacy_file(path, identity, modes, fun) do
    with :ok <- check_legacy_identity(path, identity),
         {:ok, io} <- File.open(path, modes) do
      try do
        with {:ok, info} <- :file.read_file_info(io),
             true <-
               same_identity?(File.Stat.from_record(info), Map.get(identity, :target, identity)),
             :ok <- check_legacy_identity(path, identity) do
          result = fun.(io)
          with :ok <- check_legacy_identity(path, identity), do: result
        else
          false -> identity_error(path)
          error -> error
        end
      after
        File.close(io)
      end
    end
  end

  defp check_legacy_identity(path, expected) do
    with {:ok, actual} <- legacy_identity(path, Map.has_key?(expected, :link)) do
      if same_identity?(actual, expected), do: :ok, else: identity_error(path)
    end
  end

  defp legacy_replace(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      temp = path <> ".tmp-#{System.unique_integer([:positive])}"

      try do
        with :ok <- File.write(temp, content, [:exclusive]),
             :ok <- legacy_preserve_mode(path, temp) do
          File.rename(temp, path)
        end
      after
        File.rm(temp)
      end
    end
  end

  defp legacy_preserve_mode(path, temp) do
    case File.stat(path) do
      {:ok, stat} -> File.chmod(temp, stat.mode)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_identity?(%{link: actual_link, target: actual_target}, %{
         link: expected_link,
         target: expected_target
       }) do
    same_identity?(actual_link, expected_link) and same_identity?(actual_target, expected_target)
  end

  defp same_identity?(%File.Stat{} = actual, %File.Stat{} = expected) do
    actual.type == expected.type and actual.type in [:regular, :symlink] and
      {actual.major_device, actual.minor_device, actual.inode} ==
        {expected.major_device, expected.minor_device, expected.inode}
  end

  defp same_identity?(_actual, _expected), do: false

  defp identity_error(path),
    do:
      {:error,
       "File identity changed or is no longer regular (symlinks are refused); no retry context is available: #{path}"}

  @doc """
  Formats a file-system error atom into a human-readable message.

  ## Examples

      format_file_error(:enoent, "/tmp/missing", "file")
      #=> "File not found: /tmp/missing"

      format_file_error(:eacces, "/root/secret", "directory")
      #=> "Permission denied: /root/secret"
  """
  @spec format_file_error(atom(), String.t(), String.t()) :: String.t()
  def format_file_error(:enoent, path, context) do
    label = String.capitalize(context)
    "#{label} not found: #{path}"
  end

  def format_file_error(:eacces, path, _context) do
    "Permission denied: #{path}"
  end

  def format_file_error(reason, path, context) do
    "Cannot access #{context}: #{path} (#{reason})"
  end

  # -- Private ----------------------------------------------------------------

  defp format_type_mismatch(:directory, path, _context) do
    "Path is a directory, not a file: #{path}"
  end

  defp format_type_mismatch(:regular, path, _context) do
    "Path is a file, not a directory: #{path}"
  end

  defp format_type_mismatch(type, path, context) do
    "Path is not a #{context} (#{type}): #{path}"
  end

  defp validate_mutation_path(path) do
    cond do
      String.contains?(path, <<0>>) ->
        {:error, "Path contains null bytes which are not allowed"}

      byte_size(path) > @max_path_length ->
        {:error, "Path exceeds maximum length of #{@max_path_length} bytes"}

      String.trim(path) == "" ->
        {:error, "Path cannot be empty"}

      true ->
        :ok
    end
  end

  defp mutation_target_write_access(path) do
    case File.stat(path) do
      {:ok, %File.Stat{access: access}} when access in [:read_write, :write] -> :ok
      {:ok, %File.Stat{}} -> {:error, "Permission denied: #{path}"}
      {:error, reason} -> {:error, format_file_error(reason, path, "file")}
    end
  end

  defp mutation_symlink_target(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, access: access}} when access in [:read_write, :write] ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "Permission denied: #{path}"}

      {:ok, %File.Stat{type: type}} ->
        {:error, "Symlink does not point to a regular file (#{type}): #{path}"}

      {:error, reason} ->
        {:error, format_file_error(reason, path, "symlink target")}
    end
  end

  defp mutation_root(opts),
    do: Keyword.get(opts, :confine_mutations_to) || Keyword.get(opts, :mutation_root)

  defp mutation_boundary(path, root) when is_binary(root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    if expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/") do
      expanded_root
    else
      filesystem_anchor(expanded_path)
    end
  end

  defp mutation_boundary(path, _root), do: path |> Path.expand() |> filesystem_anchor()

  # Treat the first component below a filesystem root as the trusted boundary.
  # This permits platform aliases such as macOS /tmp -> /private/tmp while still
  # checking every caller-controlled component below /tmp with lstat/1.
  defp filesystem_anchor(path) do
    case Path.split(path) do
      [root, first | _rest] -> Path.join(root, first)
      [root] -> root
      [] -> path
    end
  end

  defp validate_mutation_parent(path, allow_symlinks, boundary) do
    if boundary && Path.expand(path) == boundary do
      :ok
    else
      validate_mutation_parent_step(path, allow_symlinks, boundary)
    end
  end

  defp validate_mutation_parent_step(path, allow_symlinks, boundary) do
    case validate_mutation_parent_component(path, allow_symlinks, boundary) do
      {:error, _reason} = error ->
        error

      result when result in [:ok, :missing] ->
        parent = Path.dirname(path)

        cond do
          result == :ok and is_nil(boundary) ->
            :ok

          parent == path ->
            :ok

          true ->
            validate_mutation_parent(parent, allow_symlinks, boundary)
        end
    end
  end

  defp validate_mutation_parent_component(path, allow_symlinks, _boundary) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} when allow_symlinks ->
        case File.stat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            :ok

          {:ok, %File.Stat{type: type}} ->
            {:error, "Parent symlink is not a directory (#{type}): #{path}"}

          {:error, reason} ->
            {:error, format_file_error(reason, path, "parent directory")}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "Parent directory is a symlink: #{path}"}

      {:ok, %File.Stat{type: type}} ->
        {:error, "Parent path is not a directory (#{type}): #{path}"}

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, format_file_error(reason, path, "parent directory")}
    end
  end

  defp context_from_types([:regular]), do: "file"
  defp context_from_types([:directory]), do: "directory"
  defp context_from_types(_), do: "path"
end
