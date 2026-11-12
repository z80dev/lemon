defmodule CodingAgent.Tools.FileValidation do
  @moduledoc """
  Shared file access validation: type checking, error formatting, and write-access checks.

  Used by Read, Write, Edit, Grep, Ls, Find, and Patch tools to
  eliminate duplicated File.stat dispatch logic.
  """

  @max_path_length 4096

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
  Checks that `path` exists and is writable.

  Returns `:ok` if the file has write access, or `{:error, reason_atom}` matching
  the contract expected by the Edit tool.
  """
  @spec check_write_access(String.t()) :: :ok | {:error, atom()}
  def check_write_access(path) do
    case File.stat(path) do
      {:ok, %File.Stat{access: access}} when access in [:read_write, :write] ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :eacces}

      {:error, reason} ->
        {:error, reason}
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
  """
  @spec check_mutation_target(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_mutation_target(path, opts \\ [])

  def check_mutation_target(path, opts) when is_binary(path) do
    allow_symlinks = Keyword.get(opts, :allow_symlinks, false)
    boundary = mutation_boundary(path, Keyword.get(opts, :mutation_root))

    with :ok <- validate_mutation_path(path) do
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

  @doc "Pin a file's device/inode identity, rejecting symlinks unless explicitly trusted."
  def regular_file_identity(path, opts \\ []) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, stat}

      {:ok, %File.Stat{type: :symlink} = link} ->
        if Keyword.get(opts, :allow_symlinks, false) do
          case File.stat(path) do
            {:ok, %File.Stat{type: :regular} = target} ->
              {:ok, %{link: link, target: target, mode: target.mode}}

            _ ->
              identity_error(path)
          end
        else
          identity_error(path)
        end

      {:ok, _} ->
        identity_error(path)

      error ->
        error
    end
  end

  @doc "Read only the pinned regular file; never expose a replacement path's contents."
  def read_regular_file(path, identity) do
    with_regular_file(path, identity, [:read, :binary], fn io ->
      case IO.binread(io, :eof) do
        content when is_binary(content) -> {:ok, content}
        :eof -> {:ok, ""}
        error -> error
      end
    end)
  end

  @doc "Write through a checked handle, not a path that can be redirected after checking."
  def write_regular_file(path, identity, content) do
    with_regular_file(path, identity, [:read, :write, :binary], fn io ->
      with {:ok, 0} <- :file.position(io, :bof),
           :ok <- IO.binwrite(io, content),
           :ok <- :file.truncate(io) do
        :ok
      end
    end)
  end

  defp with_regular_file(path, identity, modes, fun) do
    with :ok <- check_file_identity(path, identity),
         {:ok, io} <- File.open(path, modes) do
      try do
        with {:ok, info} <- :file.read_file_info(io),
             true <-
               same_identity?(File.Stat.from_record(info), Map.get(identity, :target, identity)),
             :ok <- check_file_identity(path, identity) do
          result = fun.(io)
          with :ok <- check_file_identity(path, identity), do: result
        else
          false -> identity_error(path)
          error -> error
        end
      after
        File.close(io)
      end
    end
  end

  defp check_file_identity(path, expected) do
    with {:ok, actual} <-
           regular_file_identity(path, allow_symlinks: Map.has_key?(expected, :link)) do
      if same_identity?(actual, expected), do: :ok, else: identity_error(path)
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
