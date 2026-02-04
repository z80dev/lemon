defmodule LemonChannels.Outbox.Dedupe do
  @moduledoc """
  Deduplication for outbound messages.

  Uses idempotency keys to prevent duplicate deliveries.
  """

  use GenServer

  @default_ttl_ms 60 * 60 * 1000  # 1 hour

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if an idempotency key has been seen.

  Returns `:new` if not seen, `:duplicate` if already delivered.
  """
  @spec check(channel_id :: binary(), key :: binary()) :: :new | :duplicate
  def check(channel_id, key) do
    GenServer.call(__MODULE__, {:check, channel_id, key})
  end

  @doc """
  Mark an idempotency key as delivered.
  """
  @spec mark(channel_id :: binary(), key :: binary()) :: :ok
  def mark(channel_id, key) do
    GenServer.cast(__MODULE__, {:mark, channel_id, key})
  end

  @impl true
  def init(_opts) do
    # Schedule periodic cleanup
    schedule_cleanup()
    {:ok, %{keys: %{}}}
  end

  @impl true
  def handle_call({:check, channel_id, key}, _from, state) do
    full_key = {channel_id, key}
    now = System.system_time(:millisecond)

    case Map.get(state.keys, full_key) do
      nil ->
        {:reply, :new, state}

      ts when now - ts > @default_ttl_ms ->
        # Expired
        keys = Map.delete(state.keys, full_key)
        {:reply, :new, %{state | keys: keys}}

      _ ->
        {:reply, :duplicate, state}
    end
  end

  @impl true
  def handle_cast({:mark, channel_id, key}, state) do
    full_key = {channel_id, key}
    now = System.system_time(:millisecond)
    keys = Map.put(state.keys, full_key, now)
    {:noreply, %{state | keys: keys}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)

    keys =
      state.keys
      |> Enum.reject(fn {_key, ts} -> now - ts > @default_ttl_ms end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | keys: keys}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 60_000)
  end
end
