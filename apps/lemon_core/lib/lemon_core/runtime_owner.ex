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
  `LemonCore.Application`) and never start this process. Their store calls
  `held?/1`, which takes and immediately releases the lock, to defer every
  write to a running owner; a runtime booting meanwhile waits up to a second
  for such a probe to finish instead of becoming a follower.
  """

  use GenServer

  require Logger

  alias LemonCore.Service.Lock

  @acquire_timeout_ms 5_000
  @contention_timeout_ms 1_000

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
  Whether a live runtime holds the ownership lock at `lock_path`. Takes the
  lock without waiting and releases it at once; a lock that cannot be checked
  counts as held (fail closed). Probes from a separate unlinked process, so a
  caller that traps exits (the store) never receives exits from the lock's
  liveness-check helpers.
  """
  @spec held?(Path.t()) :: boolean()
  def held?(lock_path) when is_binary(lock_path) do
    {pid, ref} =
      spawn_monitor(fn ->
        exit({:probed, Lock.with_lock_path(lock_path, [], fn -> :free end)})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:probed, result}} -> result != :free
      {:DOWN, ^ref, :process, ^pid, _crashed} -> true
    end
  end

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
  # killed holder leaves a record the next local acquisition can reclaim.
  defp acquire(path) do
    parent = self()
    ref = make_ref()

    holder =
      spawn_link(fn ->
        result =
          Lock.with_lock_path(path, [timeout: @contention_timeout_ms], fn ->
            send(parent, {ref, :locked})

            receive do
              {^ref, :release} -> :ok
            end
          end)

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
