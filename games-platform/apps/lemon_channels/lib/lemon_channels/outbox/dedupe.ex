defmodule LemonChannels.Outbox.Dedupe do
  @moduledoc """
  Deduplication for outbound messages.

  Uses idempotency keys to prevent duplicate deliveries.
  """

  use GenServer

  @default_ttl_ms 60 * 60 * 1000  # 1 hour
  @cleanup_interval_ms 60_000
  @table :lemon_channels_outbox_dedupe

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
    _ = LemonCore.Dedupe.Ets.init(@table)
    schedule_cleanup()
    {:ok, %{ttl_ms: @default_ttl_ms}}
  end

  @impl true
  def handle_call({:check, channel_id, key}, _from, state) do
    full_key = {channel_id, key}
    if LemonCore.Dedupe.Ets.seen?(@table, full_key, state.ttl_ms) do
      {:reply, :duplicate, state}
    else
      {:reply, :new, state}
    end
  end

  @impl true
  def handle_cast({:mark, channel_id, key}, state) do
    full_key = {channel_id, key}
    _ = LemonCore.Dedupe.Ets.mark(@table, full_key)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    _ = LemonCore.Dedupe.Ets.cleanup_expired(@table, state.ttl_ms)
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
