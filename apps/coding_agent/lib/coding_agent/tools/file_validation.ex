defmodule CodingAgent.Tools.FileValidation do
  @moduledoc """
  Shared file access validation: type checking, error formatting, and write-access checks.

  Used by Read, Edit, Grep, Ls, Find, Patch, and HashlineEdit tools to eliminate
  duplicated File.stat dispatch logic.
  """

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
  the contract expected by Edit and HashlineEdit tools.
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

  defp context_from_types([:regular]), do: "file"
  defp context_from_types([:directory]), do: "directory"
  defp context_from_types(_), do: "path"
end
