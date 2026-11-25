defmodule LemonCore.RuntimeOwner do
  @moduledoc """
  Cross-VM ownership of the runtime state in a file-backed `LemonCore.Store`.

  Several VMs can open the same SQLite store: the daemon, a node worker that
  shares the credential store, an `iex` session. Only the first runtime VM to
  start holds a `LemonCore.Service.Lock` on `<database>.runtime.lock` for its
  lifetime; that VM alone may run recovery that assumes every other runtime is
  gone, such as `LemonCore.ExecApprovalExpiry` expiring approvals owned by an
  earlier incarnation. A VM that finds the lock held by a live runtime is a
  follower and must leave other runtimes' records alone. An in-memory store
  cannot be shared, so its VM always owns it.

  One-shot CLI VMs boot `:lemon_core` in client mode (see
  `LemonCore.Application`) and never start this process. A writable client
  store takes the same lock for its whole lifetime with `client_lease/3`, so
  at most one VM writes the database whichever starts first:

    * a runtime already holds the lock: the client store refuses every write;
    * the client holds it: a booting runtime writes a takeover request
      (`<lock>.takeover`) and waits up to three seconds; the client lease
      turns its store read-only (after any write in progress), then releases
      the lock, and the runtime becomes the owner. A runtime's store takes no
      writes before this process has settled ownership: it starts before
      every store writer in the supervision tree.
  """

  use GenServer

  require Logger

  alias LemonCore.Service.Lock

  @acquire_timeout_ms 5_000
  @contention_timeout_ms 3_000
  # A client lease polls for a takeover request this often and ignores
  # requests older than a runtime's whole wait (left by a crashed runtime).
  @takeover_poll_ms 50
  @takeover_stale_s 10

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether this VM owns its store's runtime state. `false` when this process is
  not running or ownership could not be established (fail closed).
  """
  @spec owner?() :: boolean()
  def owner? do
    GenServer.call(__MODULE__, :owner?)
  catch
    :exit, _ -> false
  end

  @doc "The ownership lock path for a store database file."
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(database) when is_binary(database), do: database <> ".runtime.lock"

  @doc """
  Takes the ownership lock at `lock_path` for a writable one-shot client
  without waiting. Returns `:leased` when this client is now the only writer,
  or `:held` when a live runtime holds the lock (or it cannot be taken: fail
  closed). The lease lasts until `owner` exits. When a runtime asks to take
  over, the lease calls `step_aside` (which must stop `owner` writing and
  return only after any write in progress) and then releases the lock.

  The lease runs in an unlinked process, so an `owner` that traps exits (the
  store) never receives exits from the lock's liveness-check helpers.
  """
  @spec client_lease(Path.t(), pid(), (-> term())) :: :leased | :held
  def client_lease(lock_path, owner, step_aside)
      when is_binary(lock_path) and is_pid(owner) and is_function(step_aside, 0) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        owner_monitor = Process.monitor(owner)

        result =
          Lock.with_lock_path(lock_path, [], fn ->
            send(parent, {ref, :leased})
            hold_lease(takeover_path(lock_path), owner_monitor, step_aside)
          end)

        exit({:lease, result})
      end)

    receive do
      {^ref, :leased} ->
        Process.demonitor(monitor, [:flush])
        :leased

      {:DOWN, ^monitor, :process, ^pid, _not_leased} ->
        :held
    end
  end

  defp hold_lease(takeover, owner_monitor, step_aside) do
    receive do
      {:DOWN, ^owner_monitor, :process, _owner, _reason} -> :released
    after
      @takeover_poll_ms ->
        if takeover_requested?(takeover) do
          step_aside.()
          :stepped_aside
        else
          hold_lease(takeover, owner_monitor, step_aside)
        end
    end
  end

  defp takeover_requested?(takeover) do
    case File.stat(takeover, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime <= @takeover_stale_s
      {:error, _} -> false
    end
  end

  defp takeover_path(lock_path), do: lock_path <> ".takeover"

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Keyword.get_lazy(opts, :database, &store_database/0) do
      nil -> {:ok, %{owner?: true, holder: nil}}
      {:error, _} -> {:ok, %{owner?: false, holder: nil}}
      database -> {:ok, acquire(lock_path(database))}
    end
  end

  @impl true
  def handle_call(:owner?, _from, state), do: {:reply, state.owner?, state}

  @impl true
  def handle_info({:EXIT, holder, _reason}, %{holder: {holder, _ref}} = state) do
    Logger.warning("runtime ownership lock holder exited; this VM no longer owns the store")
    {:noreply, %{state | owner?: false, holder: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{holder: {holder, ref}}) do
    monitor = Process.monitor(holder)
    send(holder, {ref, :release})

    receive do
      {:DOWN, ^monitor, :process, ^holder, _} -> :ok
    after
      1_000 -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp store_database do
    case LemonCore.Store.location() do
      {_backend, path} when is_binary(path) -> path
      {_backend, nil} -> nil
    end
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  # The lock is held by a linked process for as long as this one lives; a
  # killed holder leaves a record the next local acquisition can reclaim. The
  # takeover request asks a client lease holding the lock to step aside.
  defp acquire(path) do
    parent = self()
    ref = make_ref()
    takeover = takeover_path(path)
    _ = File.write(takeover, "")

    holder =
      spawn_link(fn ->
        result =
          Lock.with_lock_path(path, [timeout: @contention_timeout_ms], fn ->
            _ = File.rm(takeover)
            send(parent, {ref, :locked})

            receive do
              {^ref, :release} -> :ok
            end
          end)

        _ = File.rm(takeover)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, :locked} ->
        %{owner?: true, holder: {holder, ref}}

      {^ref, {:error, :lock_timeout}} ->
        %{owner?: false, holder: nil}

      {^ref, {:error, reason}} ->
        Logger.warning("runtime ownership lock unavailable: #{inspect(reason)}")
        %{owner?: false, holder: nil}
    after
      @acquire_timeout_ms ->
        Process.unlink(holder)
        Process.exit(holder, :kill)
        %{owner?: false, holder: nil}
    end
  end
end
