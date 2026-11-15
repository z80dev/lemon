defmodule LemonCore.Secrets.Usage do
  @moduledoc """
  Best-effort secret usage metadata, coalesced outside the read and Store paths.

  Readers cast encrypted snapshots, never plaintext. A batch retains one snapshot
  per Store process and secret; replacement snapshots supersede earlier touches.
  Every write is an exact-record CAS, so delayed touches cannot restore a deleted
  credential, overwrite a replacement or undo rotation staging. Counts may be
  lost on a conflict, worker restart or VM shutdown; they are not an audit log.

  The default 100 ms interval is the usage-metadata batching policy, not a
  credential persistence delay. Tests can flush explicitly without sleeping.
  """

  use GenServer

  alias LemonCore.{Clock, MapHelpers, Secrets, Store}

  @flush_interval 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def touch(store, key, entry, server \\ __MODULE__) when is_pid(store) do
    GenServer.cast(server, {:touch, store, key, entry, Clock.now_ms()})
  end

  @doc false
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @impl true
  def init(opts) do
    {:ok,
     %{pending: %{}, timer: nil, interval: Keyword.get(opts, :flush_interval, @flush_interval)}}
  end

  @impl true
  def handle_cast({:touch, store, key, entry, used_at}, state) do
    batch_key = {store, key}

    touch =
      case Map.get(state.pending, batch_key) do
        {^entry, count, last_used_at} -> {entry, count + 1, max(last_used_at, used_at)}
        _ -> {entry, 1, used_at}
      end

    state = %{state | pending: Map.put(state.pending, batch_key, touch)}
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, persist(state)}

  @impl true
  def handle_info({:flush, token}, %{timer: {token, _timer}} = state) do
    {:noreply, persist(state)}
  end

  def handle_info({:flush, _stale}, state), do: {:noreply, state}

  defp schedule(%{timer: nil, interval: interval} = state) when is_integer(interval) do
    token = make_ref()
    timer = Process.send_after(self(), {:flush, token}, interval)
    %{state | timer: {token, timer}}
  end

  defp schedule(state), do: state

  defp persist(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 1))

    Enum.each(state.pending, fn {{store, key}, {entry, count, used_at}} ->
      updated =
        entry
        |> put_field(:usage_count, (MapHelpers.get_key(entry, :usage_count) || 0) + count)
        |> put_field(:last_used_at, used_at)

      _ = Store.compare_and_swap(store, Secrets.table(), key, entry, updated)
    end)

    %{state | pending: %{}, timer: nil}
  end

  defp put_field(entry, key, value) do
    entry |> Map.put(key, value) |> Map.delete(Atom.to_string(key))
  end
end
