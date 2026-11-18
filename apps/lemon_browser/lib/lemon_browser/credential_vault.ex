defmodule LemonBrowser.CredentialVault do
  @moduledoc """
  Session-scoped holder for inline browser-provider credentials.

  Hosted and Camofox sessions must authenticate cleanup (close, DELETE, idle
  expiry, terminate) with the credentials that created them, but must not keep
  those credentials in their own inspectable GenServer state. A session stores
  them here under an opaque reference and keeps only that reference.

  Entries live in a `:private` ETS table: only this process can read it, and
  this process's state holds just the table id and owner monitors. An entry is
  deleted explicitly on close or automatically when its owner exits. This keeps
  credentials out of `:sys.get_state/1`, crash reports and supervisor child
  specs; it is not a boundary against arbitrary code running in the same VM.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "Stores `credentials` for `owner`; the entry is removed when `owner` exits."
  @spec put(pid(), map()) :: reference()
  def put(owner, credentials) when is_pid(owner) and is_map(credentials),
    do: GenServer.call(@name, {:put, owner, credentials})

  @spec fetch(reference() | nil) :: map()
  def fetch(nil), do: %{}
  def fetch(ref) when is_reference(ref), do: GenServer.call(@name, {:fetch, ref})

  @spec delete(reference() | nil) :: :ok
  def delete(nil), do: :ok
  def delete(ref) when is_reference(ref), do: GenServer.call(@name, {:delete, ref})

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:message, _} -> {:message, :redacted}
      {:reason, _} -> {:reason, :redacted}
      {:log, _} -> {:log, []}
      pair -> pair
    end)
  end

  @impl true
  def init(_opts), do: {:ok, %{table: :ets.new(__MODULE__, [:private]), monitors: %{}}}

  @impl true
  def handle_call({:put, owner, credentials}, _from, state) do
    ref = make_ref()
    monitor = Process.monitor(owner)
    true = :ets.insert(state.table, {ref, monitor, credentials})
    {:reply, ref, put_in(state.monitors[monitor], ref)}
  end

  def handle_call({:fetch, ref}, _from, state) do
    case :ets.lookup(state.table, ref) do
      [{^ref, _monitor, credentials}] -> {:reply, credentials, state}
      [] -> {:reply, %{}, state}
    end
  end

  def handle_call({:delete, ref}, _from, state), do: {:reply, :ok, drop(state, ref)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} -> {:noreply, state}
      {ref, monitors} -> {:noreply, drop(%{state | monitors: monitors}, ref)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drop(state, ref) do
    case :ets.lookup(state.table, ref) do
      [{^ref, monitor, _credentials}] ->
        Process.demonitor(monitor, [:flush])
        :ets.delete(state.table, ref)
        %{state | monitors: Map.delete(state.monitors, monitor)}

      [] ->
        state
    end
  end
end
