defmodule LemonSkills.MetadataFile do
  @moduledoc false

  # Contained reads and atomic replacement of skill metadata files (lockfiles
  # and audit state).
  #
  # Every file lives below a trusted anchor: the agent directory (validated by
  # `LemonSkills.SkillRoot.trusted_dir/1` before writes) or the project
  # directory. Each component between the anchor and the file must be a real
  # directory (`SkillRoot.check_dir/3`), and the file itself must be absent or
  # a regular file with a single link. Writes go to an exclusive, private
  # (0600) temp file beside the destination which is then renamed over it:
  # the destination entry is replaced, never followed or written through.

  alias LemonSkills.SkillRoot

  @max_bytes 16 * 1_048_576
  @mode 0o600
  # Every lock acquisition captures the VM's process identity (`ps`) and
  # publishes an owner record, and waiters poll. A burst of concurrent writers
  # in one VM (for example ten parallel installs on macOS) takes over a second
  # to drain, so the wait bounds a stuck live holder, not ordinary contention.
  @lock_wait_ms 10_000

  @doc "Reads `path` below `anchor`; a missing file or directory is `{:error, :enoent}`."
  @spec read(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(anchor, path) do
    path = Path.expand(path)

    case SkillRoot.check_dir(anchor, Path.dirname(path)) do
      :ok -> read_regular(path)
      {:error, {:enoent, _component}} -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end

  @doc "Atomically replaces `path` below `anchor` with `bytes` (mode 0600)."
  @spec write(String.t(), String.t(), iodata()) :: :ok | {:error, term()}
  def write(anchor, path, bytes) do
    path = Path.expand(path)
    dir = Path.dirname(path)

    with :ok <- SkillRoot.ensure_dir(anchor, dir),
         :ok <- check_destination(path) do
      tmp =
        Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

      try do
        with :ok <- write_exclusive(tmp, bytes),
             :ok <- SkillRoot.check_dir(anchor, dir),
             :ok <- check_destination(path) do
          File.rename(tmp, path)
        end
      after
        _ = File.rm(tmp)
      end
    end
  end

  @doc """
  Runs `fun` holding the file lock of `path`; the lock directory is created
  only after the parent chain below `anchor` is checked. Waits up to ten
  seconds for a live holder, then returns `{:error, :lock_timeout}`.
  """
  @spec with_lock(String.t(), String.t(), (-> result)) :: result | {:error, term()}
        when result: term()
  def with_lock(anchor, path, fun) do
    path = Path.expand(path)

    with :ok <- SkillRoot.ensure_dir(anchor, Path.dirname(path)) do
      LemonCore.Service.Lock.with_lock_path(path <> ".lock", [timeout: @lock_wait_ms], fun)
    end
  end

  defp check_destination(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, {:hard_link, path}}
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink, path}}
      {:ok, _} -> {:error, {:not_regular, path}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  defp read_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1, size: size} = stat} when size <= @max_bytes ->
        read_same_file(path, stat)

      {:ok, %File.Stat{type: :regular, links: 1}} ->
        {:error, :too_large}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :hard_link}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink}

      {:ok, _} ->
        {:error, :not_regular}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The opened handle must be the inode the lstat accepted.
  defp read_same_file(path, %File.Stat{} = stat) do
    with {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(fd),
             true <- elem(info, 2) == :regular and elem(info, 11) == stat.inode,
             {:ok, bytes} <- read_capped(fd) do
          {:ok, bytes}
        else
          {:error, _} = error -> error
          _ -> {:error, :changed}
        end
      after
        :file.close(fd)
      end
    end
  end

  defp read_capped(fd) do
    case :file.read(fd, @max_bytes + 1) do
      {:ok, bytes} when byte_size(bytes) > @max_bytes -> {:error, :too_large}
      {:ok, bytes} -> {:ok, bytes}
      :eof -> {:ok, ""}
      {:error, _} = error -> error
    end
  end

  # O_CREAT|O_EXCL never follows or reuses an existing entry; the mode is
  # narrowed before any byte is written.
  defp write_exclusive(tmp, bytes) do
    with {:ok, fd} <- :file.open(tmp, [:write, :exclusive, :binary, :raw]) do
      try do
        with :ok <- File.chmod(tmp, @mode) do
          :file.write(fd, bytes)
        end
      after
        :file.close(fd)
      end
    end
  end
end
