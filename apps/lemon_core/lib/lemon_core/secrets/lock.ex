defmodule LemonCore.Secrets.Lock do
  @moduledoc """
  Exclusive lease that serialises secret writes with master-key rotation.

  `LemonCore.Secrets.set/3` and `set_if_revision/4` hold it from resolving the
  master key until persistence; deletion and expiry cleanup hold it around
  conditional removal. `LemonCore.Secrets.KeyRotation.rotate/2` holds it for the
  whole rotation, so no write uses a retiring key and mutations never interleave.

  The lease is a record in the `:secrets_lock` Store table created with
  `LemonCore.Store.put_new/4`. With the SQLite backend that insert is atomic
  across every OS process sharing the store file, so a `lemon secrets set` in
  one terminal and a rotation in another exclude each other.

  ## Reclaiming abandoned leases

  A lease has no expiry: a holder that is merely slow keeps it. The lease
  records the holder's host name, OS pid and BEAM pid, and it is reclaimed
  (with an atomic compare-and-delete) only when its holder is provably gone:

    * same BEAM: the holding process is no longer alive;
    * same host, other OS process: `kill -0` reports that the pid does not
      exist.

  A live holder is waited for, then `{:error, :secrets_locked}` is returned.
  Secret writes wait up to 30 seconds
  (`config :lemon_core, LemonCore.Secrets, write_lock_wait_ms: ...`), a
  rotation 5 seconds. A lease held from another host, or one that cannot be
  read, is never reclaimed automatically: the caller gets
  `{:error, {:secrets_lock_held, host}}` and an operator must confirm that
  holder is gone before deleting the `:secrets_lock` row.
  """

  alias LemonCore.Store

  @table :secrets_lock
  @key :secrets
  @poll_ms 25

  @write_wait_ms 30_000
  @rotation_wait_ms 5_000

  @type error ::
          {:error,
           :secrets_locked | {:secrets_lock_held, String.t() | :unknown} | {:store_failed, term()}}

  @doc "Runs `fun` while holding the lock for one secret write."
  @spec with_write_lock((-> result), Store.server()) :: result | error() when result: term()
  def with_write_lock(fun, server \\ Store) do
    :lemon_core
    |> Application.get_env(LemonCore.Secrets, [])
    |> Keyword.get(:write_lock_wait_ms, @write_wait_ms)
    |> with_lock(fun, server)
  end

  @doc "Runs `fun` while holding the lock for a master-key rotation."
  @spec with_rotation_lock((-> result)) :: result | error() when result: term()
  def with_rotation_lock(fun), do: with_lock(@rotation_wait_ms, fun)

  defp with_lock(wait_ms, fun, server \\ Store) do
    case acquire(server, System.monotonic_time(:millisecond) + wait_ms) do
      {:ok, lease} ->
        try do
          fun.()
        after
          release(server, lease)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp acquire(server, deadline) do
    lease = %{
      owner: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower),
      host: host(),
      os_pid: System.pid(),
      holder: self() |> :erlang.pid_to_list() |> List.to_string()
    }

    case Store.put_new(server, @table, @key, lease) do
      :ok -> {:ok, lease}
      {:error, :exists} -> contended(server, deadline)
      {:error, reason} -> {:error, {:store_failed, reason}}
    end
  end

  defp contended(server, deadline) do
    case Store.fetch(server, @table, @key) do
      {:ok, nil} ->
        acquire(server, deadline)

      {:ok, lease} ->
        case holder_state(lease) do
          :dead -> reclaim(server, lease, deadline)
          :alive -> wait(server, deadline, {:error, :secrets_locked})
          {:unprovable, host} -> wait(server, deadline, {:error, {:secrets_lock_held, host}})
        end

      {:error, reason} ->
        {:error, {:store_failed, reason}}
    end
  end

  # The compare-and-delete only removes the exact lease judged dead, never a
  # lease another contender installed in the meantime.
  defp reclaim(server, lease, deadline) do
    case Store.compare_and_delete_many(server, [{@table, @key, lease}]) do
      :ok -> acquire(server, deadline)
      {:error, :mismatch} -> wait(server, deadline, {:error, :secrets_locked})
      {:error, reason} -> {:error, {:store_failed, reason}}
    end
  end

  # A normal release may still arrive, so keep polling until the deadline.
  defp wait(server, deadline, timeout_error) do
    if System.monotonic_time(:millisecond) >= deadline do
      timeout_error
    else
      Process.sleep(@poll_ms)
      acquire(server, deadline)
    end
  end

  defp release(server, lease), do: Store.compare_and_delete_many(server, [{@table, @key, lease}])

  defp holder_state(%{host: host, os_pid: os_pid, holder: holder})
       when is_binary(host) and is_binary(os_pid) and is_binary(holder) do
    cond do
      host != host() -> {:unprovable, host}
      os_pid == System.pid() -> if local_holder_alive?(holder), do: :alive, else: :dead
      true -> os_process_state(os_pid)
    end
  end

  defp holder_state(_unreadable), do: {:unprovable, :unknown}

  defp local_holder_alive?(holder) do
    holder |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
  rescue
    ArgumentError -> true
  end

  # `kill -0` probes without signalling. Only an explicit "no such process"
  # proves the holder is gone; a permission error means it exists, and any
  # other outcome is treated as alive.
  defp os_process_state(os_pid) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_output, 0} -> :alive
      {output, _status} -> if output =~ ~r/no such process/i, do: :dead, else: :alive
    end
  rescue
    _error -> :alive
  end

  defp host do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end
end
