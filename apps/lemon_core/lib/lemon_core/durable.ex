defmodule LemonCore.Durable do
  @moduledoc """
  Flush helpers for writes that must survive a host crash.

  `sync_file/1` fsyncs one file's contents. `sync_directory/1` makes directory
  entries durable: a rename or a newly created file is only on stable storage
  once its parent directory is synced.

  On OTP 29, directories are opened as raw directory descriptors and synced
  natively, without Python or an external process. On Darwin this is the
  filesystem's `F_BARRIERFSYNC` barrier, not a device-wide `F_FULLFSYNC`.
  File contents retain the stronger Python-backed `F_FULLFSYNC` barrier on
  Darwin for every `sync_file/1` caller: Store JSONL journals (acknowledged
  mutations), native-process cleanup ledgers (recovery authority), eval paired
  cleanup manifests (cleanup authority), and coding-session atomic snapshots
  (history replacement). Directory sync orders namespace changes only.

  The Darwin subprocess runs in an unlinked monitored owner. Its port messages
  never enter the calling process's mailbox, including when that caller traps
  exits. Returning still waits for the same full file barrier.
  """

  @spec sync_file(Path.t()) :: :ok | {:error, term()}
  def sync_file(path) do
    if match?({:unix, :darwin}, :os.type()) do
      isolated_darwin_sync(path)
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
    with {:ok, device} <- :file.open(dir, [:read, :raw, :directory]) do
      try do
        :file.sync(device)
      after
        :file.close(device)
      end
    end
  end

  defp isolated_darwin_sync(path) do
    {worker, monitor} =
      spawn_monitor(fn ->
        outcome =
          try do
            {:returned, darwin_sync(path, "file", :file_sync_unsupported)}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        # Carry the outcome in the single monitor message: no reply or normal
        # port EXIT can remain in the caller's mailbox after this receive.
        exit({__MODULE__, outcome})
      end)

    receive do
      {:DOWN, ^monitor, :process, ^worker, {__MODULE__, {:returned, result}}} ->
        result

      {:DOWN, ^monitor, :process, ^worker, {__MODULE__, {:raised, kind, reason, stacktrace}}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        exit(reason)
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
end
