defmodule LemonCore.Service.Lock do
  @moduledoc """
  Cross-process exclusion for same-user operations on a local filesystem.

  `with_lock/3` locks a service label in its private run directory, without
  waiting by default. `with_lock_path/3` locks an explicit path; its parent must
  exist and its permissions are left unchanged. Callers choose a finite
  `:timeout` in milliseconds (default `0`); skills metadata writers use their
  existing 1,000 ms budget, or 500 ms for usage counters. Locks are not reentrant.
  In-VM-only mutation serialization belongs in the caller's OTP owner instead.

  Each acquisition prepares a private sibling directory, writes a 0600 owner
  file using tmp + rename, then atomically renames the populated directory to
  the lock path. A contender cannot replace a populated directory. Death before
  publication may leave staging files, but never an ownerless held lock.

  Owners record the OS PID/start time and the BEAM PID/node. The own OS
  identity is captured once per VM (`Identity.self_identity/0`), so an
  uncontended acquisition forks no `ps`/`id`. Only a matching current OS
  identity permits local BEAM liveness checks: a killed holder can be
  reclaimed without waiting for its VM to exit. Other VMs (including reused OS
  PIDs) are checked through `LemonCore.Service.Identity`; unreadable records
  and failed identity probes never prove death. Every reclaim is logged.

  Owner filenames contain a unique acquisition token. Release and stale
  recovery remove only that file, then attempt to remove the empty directory.
  A delayed releaser/reclaimer therefore cannot remove a replacement owner's
  record. Older service `owner.json` records retain OS-identity recovery; empty
  legacy skill lockfiles have no provable owner and require operator cleanup
  after stopping all writers. Do not delete a live lock or share these paths
  across hosts. Callbacks run once and are never retried.
  """

  require Logger

  alias LemonCore.Service.{Identity, Role, Unit}

  @retry_interval_ms 10

  @doc "Runs a callback under a service-label lock, returning `:service_locked` on contention."
  def with_lock(label, opts, fun) do
    dir = Keyword.get_lazy(opts, :run_dir, fn -> Role.run_dir(opts) end)
    path = Path.join(dir, label <> ".lock")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      run_locked(path, opts, fun, :service)
    end
  end

  @doc """
  Runs a callback under an explicit filesystem lock path.

  Returns the callback's value, `{:error, :lock_timeout}` on contention, or
  `{:error, {:lock_failed, reason}}` if the owner cannot be published.
  Exceptions, throws and exits from the callback propagate after release.
  """
  def with_lock_path(path, opts, fun) do
    run_locked(path, opts, fun, :file)
  end

  defp run_locked(path, opts, fun, kind) do
    timeout = Keyword.get(opts, :timeout, 0)

    if not (is_integer(timeout) and timeout >= 0) do
      raise ArgumentError, "lock timeout must be a non-negative integer"
    end

    deadline = System.monotonic_time(:millisecond) + timeout

    case acquire(path, opts, deadline) do
      {:ok, owner} ->
        try do
          fun.()
        after
          release(path, owner)
        end

      {:error, :lock_timeout} when kind == :service ->
        {:error, :service_locked}

      {:error, _} when kind == :service ->
        {:error, :service_lock_failed}

      error ->
        error
    end
  end

  defp acquire(path, opts, deadline) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    owner = "owner.#{token}.json"
    staging = path <> ".tmp." <> token

    with {:ok, identity} <- Identity.self_identity(),
         :ok <- File.mkdir(staging) do
      try do
        record =
          Map.merge(identity, %{
            beam_pid: to_string(:erlang.pid_to_list(self())),
            node: to_string(node())
          })

        with :ok <- File.chmod(staging, 0o700),
             :ok <- Unit.atomic_write(Path.join(staging, owner), Jason.encode!(record), 0o600),
             :ok <- publish(path, staging, identity, opts, deadline) do
          {:ok, owner}
        else
          {:error, :lock_timeout} = error -> error
          {:error, reason} -> {:error, {:lock_failed, reason}}
        end
      after
        release(staging, owner)
      end
    else
      {:error, reason} -> {:error, {:lock_failed, reason}}
    end
  end

  defp publish(path, staging, identity, opts, deadline) do
    case try_publish(path, staging, identity, opts) do
      {:error, reason} when reason in [:eexist, :enotempty] ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(@retry_interval_ms, remaining))

          if System.monotonic_time(:millisecond) < deadline do
            publish(path, staging, identity, opts, deadline)
          else
            {:error, :lock_timeout}
          end
        else
          {:error, :lock_timeout}
        end

      result ->
        result
    end
  end

  defp try_publish(path, staging, identity, opts) do
    case File.rename(staging, path) do
      {:error, reason} = error when reason in [:eexist, :enotempty] ->
        case reclaim(path, identity, opts) do
          :ok -> File.rename(staging, path)
          :locked -> error
        end

      result ->
        result
    end
  end

  defp reclaim(path, identity, opts) do
    with {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, [owner]} <- File.ls(path),
         true <- owner == "owner.json" or String.match?(owner, ~r/^owner\.[0-9a-f]{32}\.json$/),
         {:ok, record} <- Identity.read_json(Path.join(path, owner)),
         true <- dead_owner?(record, identity, opts) do
      Logger.warning("Recovered a stale lock left by a dead holder: #{Path.basename(path)}")
      release(path, owner)
    else
      _ -> :locked
    end
  end

  defp dead_owner?(%{"pid" => pid, "started_at" => started} = owner, identity, opts)
       when is_integer(pid) and pid > 1 and is_binary(started) and started != "" do
    if pid == identity.pid and started == identity.started_at and
         owner["node"] == to_string(node()) and is_binary(owner["beam_pid"]) do
      dead_local_owner?(owner["beam_pid"])
    else
      Identity.gone?(%{pid: pid, started_at: started}, opts)
    end
  end

  defp dead_owner?(_, _, _), do: false

  defp dead_local_owner?(encoded_pid) do
    pid = encoded_pid |> String.to_charlist() |> :erlang.list_to_pid()
    node(pid) == node() and not Process.alive?(pid)
  rescue
    ArgumentError -> false
  end

  defp release(path, owner) do
    _ = File.rm(Path.join(path, owner))
    _ = File.rmdir(path)
    :ok
  end
end
