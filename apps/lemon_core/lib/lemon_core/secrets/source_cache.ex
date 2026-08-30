defmodule LemonCore.Secrets.SourceCache do
  @moduledoc false

  use GenServer

  @max_entries 32

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec get(term(), non_neg_integer()) :: {:ok, map()} | :miss
  def get(key, now_ms \\ System.monotonic_time(:millisecond)) do
    call({:get, key, now_ms}, :miss)
  end

  @spec put(term(), map(), non_neg_integer()) :: :ok
  def put(key, value, expires_at_ms) do
    call({:put, key, value, expires_at_ms}, :ok)
  end

  @spec clear() :: :ok
  def clear, do: call(:clear, :ok)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:get, key, now_ms}, _from, state) do
    case Map.get(state, key) do
      %{expires_at_ms: expires_at_ms, value: value} when expires_at_ms > now_ms ->
        {:reply, {:ok, value}, state}

      nil ->
        {:reply, :miss, state}

      _expired ->
        {:reply, :miss, Map.delete(state, key)}
    end
  end

  def handle_call({:put, key, value, expires_at_ms}, _from, state) do
    state =
      state
      |> Map.put(key, %{value: value, expires_at_ms: expires_at_ms})
      |> cap_entries()

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  defp cap_entries(state) when map_size(state) <= @max_entries, do: state

  defp cap_entries(state) do
    {oldest_key, _entry} = Enum.min_by(state, fn {_key, entry} -> entry.expires_at_ms end)
    Map.delete(state, oldest_key)
  end

  defp call(message, fallback) do
    case Process.whereis(__MODULE__) do
      nil -> fallback
      _pid -> GenServer.call(__MODULE__, message, 5_000)
    end
  catch
    :exit, _reason -> fallback
  end
end
