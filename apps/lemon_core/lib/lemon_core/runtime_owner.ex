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

  A writable one-shot client (`client: true`, see `LemonCore.Application`)
  runs this process too. Its store starts refusing writes
  (`defer_to_runtime: true`); this process takes `<database>.client.lock` and
  then the runtime lock without waiting, holds both for the VM's lifetime and
  only then lets the store write (`LemonCore.Store.claim_writes/1`). When a
  runtime holds the lock the store keeps refusing (`:runtime_owned`). A runtime
  booting while a client holds the lock waits up to `@contention_timeout_ms`,
  then refuses to start (`{:stop, :store_held_by_client}`) rather than run a
  second writer; it starts before every other store writer in its tree.
  """

  use GenServer

  require Logger

  alias LemonCore.Service.Lock

  @acquire_timeout_ms 5_000
  @contention_timeout_ms 3_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether this VM owns its store's runtime state. `false` when this process is
  not running or ownership could not be established (fail closed). A client
  VM is never the runtime owner.
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

  @doc "The lock a writable one-shot client holds beside the runtime lock."
  @spec client_lock_path(Path.t()) :: Path.t()
  def client_lock_path(database) when is_binary(database), do: database <> ".client.lock"

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    client? = Keyword.get(opts, :client, false)

    case Keyword.get_lazy(opts, :database, &store_database/0) do
      nil when client? -> claim(opts, %{owner?: false, holder: nil})
      nil -> {:ok, %{owner?: true, holder: nil}}
      {:error, _} -> {:ok, %{owner?: false, holder: nil}}
      database when client? -> client_init(database, opts)
      database -> runtime_init(database)
    end
  end

  @impl true
  def handle_call(:owner?, _from, state), do: {:reply, state.owner?, state}

  @impl true
  # A client that lost its locks stops, and its store stops writing with it.
  def handle_info({:EXIT, holder, _reason}, %{holder: {holder, _ref}, client?: true} = state),
    do: {:stop, :ownership_lock_lost, %{state | holder: nil}}

  def handle_info({:EXIT, holder, _reason}, %{holder: {holder, _ref}} = state) do
    Logger.warning("store ownership lock holder exited; this VM no longer holds the store")
    {:noreply, %{state | owner?: false, holder: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{holder: {holder, ref}}) do
    monitor = Process.monitor(holder)
    send(holder, {ref, :release})

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    after
      1_000 -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp runtime_init(database) do
    case hold([lock_path(database)], @contention_timeout_ms) do
      {:ok, holder} ->
        {:ok, %{owner?: true, holder: holder}}

      {:error, :lock_timeout} ->
        if held?(client_lock_path(database)),
          do: {:stop, :store_held_by_client},
          else: {:ok, %{owner?: false, holder: nil}}

      {:error, reason} ->
        Logger.warning("runtime ownership lock unavailable: #{inspect(reason)}")
        {:ok, %{owner?: false, holder: nil}}
    end
  end

  # Client lock first, so a runtime that times out on the runtime lock always
  # sees which kind of VM holds it.
  defp client_init(database, opts) do
    case hold([client_lock_path(database), lock_path(database)], 0) do
      {:ok, holder} -> claim(opts, %{owner?: false, holder: holder, client?: true})
      {:error, _held} -> {:ok, %{owner?: false, holder: nil}}
    end
  end

  defp claim(opts, state) do
    :ok = LemonCore.Store.claim_writes(Keyword.get(opts, :store, LemonCore.Store))
    {:ok, state}
  end

  defp held?(path), do: Lock.with_lock_path(path, [], fn -> :free end) != :free

  defp store_database do
    case LemonCore.Store.location() do
      {_backend, path} when is_binary(path) -> path
      {_backend, nil} -> nil
    end
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  # The locks are held by a linked task for as long as this process lives; a
  # killed holder leaves records the next local acquisition can reclaim.
  defp hold(paths, timeout) do
    parent = self()
    ref = make_ref()

    {:ok, holder} =
      Task.start_link(fn ->
        result =
          nest(paths, timeout, fn ->
            send(parent, {ref, :locked})
            receive do: ({^ref, :release} -> :ok)
          end)

        send(parent, {ref, result})
      end)

    receive do
      {^ref, :locked} ->
        {:ok, {holder, ref}}

      {^ref, {:error, _} = error} ->
        error
    after
      @acquire_timeout_ms ->
        Process.unlink(holder)
        Process.exit(holder, :kill)
        {:error, :lock_timeout}
    end
  end

  defp nest([], _timeout, fun), do: fun.()

  defp nest([path | rest], timeout, fun),
    do: Lock.with_lock_path(path, [timeout: timeout], fn -> nest(rest, timeout, fun) end)
end
