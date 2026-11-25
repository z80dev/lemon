defmodule LemonCore.Secrets.KeyLock do
  @moduledoc """
  Cross-process lock around every operation that creates or replaces the
  secrets master key: `LemonCore.Secrets.MasterKey.init/1`, key rotation and a
  backup restore that installs credentials.

  It is a `LemonCore.FileLock` directory lock named
  `.secrets_master_key.lock` next to the key file (`~/.lemon` by default), so
  separate CLI, Mix and runtime OS processes of one user exclude each other
  even when they use different key providers or different stores: the
  existence check and the write of a key happen as one step. The lock is
  reentrant within a process. Contention waits up to `:key_lock_wait_ms`
  (default 5 seconds), then returns `{:error, :secrets_key_locked}`.
  """

  alias LemonCore.Secrets.KeyProvider

  @lock_name ".secrets_master_key.lock"
  @default_wait_ms 5_000
  @held {__MODULE__, :held}

  @doc "Runs `fun` holding the lock for the key file location `opts` resolve to."
  @spec with_lock(keyword(), (-> result)) :: result | {:error, term()} when result: var
  def with_lock(opts, fun) do
    case KeyProvider.key_file(opts) do
      nil -> {:error, :secrets_key_lock_unavailable}
      key_file -> with_dir_lock(Path.dirname(key_file), opts, fun)
    end
  end

  @doc """
  Runs `fun` holding the locks of every directory in `dirs`, acquired in a
  fixed (sorted) order so two multi-directory holders cannot deadlock.
  """
  @spec with_dirs_lock([Path.t()], keyword(), (-> result)) :: result | {:error, term()}
        when result: var
  def with_dirs_lock(dirs, opts, fun) do
    dirs
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reverse()
    |> Enum.reduce(fun, fn dir, inner -> fn -> with_dir_lock(dir, opts, inner) end end)
    |> then(& &1.())
  end

  @doc "Runs `fun` holding the lock for the key file kept in `dir`."
  @spec with_dir_lock(Path.t(), keyword(), (-> result)) :: result | {:error, term()}
        when result: var
  def with_dir_lock(dir, opts, fun) do
    path = Path.join(Path.expand(dir), @lock_name)
    held = Process.get(@held, MapSet.new())

    if MapSet.member?(held, path) do
      fun.()
    else
      with :ok <- prepare(dir) do
        wait = KeyProvider.option(opts, :key_lock_wait_ms, @default_wait_ms)

        result =
          LemonCore.FileLock.with_lock_path(path, [timeout: wait], fn ->
            Process.put(@held, MapSet.put(held, path))

            try do
              {:locked, fun.()}
            after
              Process.put(@held, held)
            end
          end)

        case result do
          {:locked, value} -> value
          {:error, :lock_timeout} -> {:error, :secrets_key_locked}
          {:error, reason} -> {:error, {:secrets_key_lock_failed, reason}}
        end
      end
    end
  end

  @doc "Lock entry name, excluded from backups and restores."
  @spec lock_name() :: String.t()
  def lock_name, do: @lock_name

  defp prepare(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        _ = File.chmod(dir, 0o700)
        :ok

      {:error, reason} ->
        {:error, {:secrets_key_lock_failed, reason}}
    end
  end
end
