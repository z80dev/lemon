defmodule LemonCore.Durable do
  @moduledoc """
  Flush helpers for writes that must survive a host crash.

  `sync_file/1` fsyncs one file's contents. `sync_directory/1` makes directory
  entries durable: a rename or a newly created file is only on stable storage
  once its parent directory is synced.

  The BEAM cannot open a directory. GNU coreutils `sync DIR` provides the
  synchronous per-directory barrier on supported Unix hosts. Darwin uses the
  packaged Python 3 helper to open the exact file/directory descriptor, fsync
  it, then issue `F_FULLFSYNC` so the device flushes buffered writes. Literal
  argv is used, not a shell, and leaf symlinks are rejected. macOS `sync(8)`
  is never substituted: it only schedules a system-wide flush.
  Missing prerequisites or a refused barrier fail closed; no path or raw
  helper exception is exposed in its failure classification.
  """

  @spec sync_file(Path.t()) :: :ok | {:error, term()}
  def sync_file(path) do
    if match?({:unix, :darwin}, :os.type()) do
      darwin_sync(path, "file", :file_sync_unsupported)
    else
      with {:ok, device} <- :file.open(path, [:read, :raw, :binary]) do
        result = :file.sync(device)
        :ok = :file.close(device)
        result
      end
    end
  end

  @spec sync_directory(Path.t()) :: :ok | {:error, term()}
  def sync_directory(dir) do
    if match?({:unix, :darwin}, :os.type()) do
      darwin_sync(dir, "directory", :directory_sync_unsupported)
    else
      case directory_sync_command() do
        {:ok, sync} -> run(sync, [dir])
        :error -> {:error, :directory_sync_unsupported}
      end
    end
  end

  defp darwin_sync(path, kind, unsupported) do
    with {:ok, _stat} <- File.stat(path),
         python when is_binary(python) <- System.find_executable("python3"),
         helper = Application.app_dir(:lemon_core, "priv/durable_sync.py"),
         true <- File.regular?(helper) do
      case System.cmd(python, ["-I", helper, kind, path], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {_output, status} -> {:error, {:full_sync_failed, status}}
      end
    else
      {:error, reason} -> {:error, reason}
      _missing -> {:error, unsupported}
    end
  rescue
    _error in [ErlangError, ArgumentError] ->
      {:error, {:full_sync_failed, :helper_unavailable}}
  end

  defp directory_sync_command do
    with false <- match?({:unix, :darwin}, :os.type()),
         sync when is_binary(sync) <- System.find_executable("sync"),
         {:ok, version} <- output(sync, ["--version"]),
         true <- version =~ "GNU coreutils",
         {:ok, help} <- output(sync, ["--help"]),
         true <- help =~ "If one or more files are specified, sync only them" do
      {:ok, sync}
    else
      _unsupported -> :error
    end
  end

  defp output(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _failed -> :error
    end
  rescue
    _error -> :error
  end

  defp run(sync, args) do
    case System.cmd(sync, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:sync_failed, status}}
    end
  rescue
    error in ErlangError -> {:error, {:sync_failed, Exception.message(error)}}
  end
end
