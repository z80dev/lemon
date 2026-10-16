defmodule LemonChannels.Outbox.Dedupe do
  @moduledoc """
  Deduplication for outbound messages.

  Uses idempotency keys to prevent duplicate deliveries. Keys are marked only
  after a delivery is confirmed (`{:ok, _}`). A delivery with an unknown outcome
  is retried at-least-once by the outbox and does not mark its key until a retry
  is confirmed, so dedupe suppresses re-sends of confirmed deliveries only.
  """

  use GenServer

  require Logger

  alias LemonCore.Dedupe.Ets

  # 1 hour
  @default_ttl_ms 60 * 60 * 1000
  @call_timeout_ms 2_000
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
    GenServer.call(__MODULE__, {:check, channel_id, key}, @call_timeout_ms)
  catch
    :exit, _reason ->
      Logger.warning("Dedupe.check timed out channel=#{channel_id} key=#{inspect(key)}")
      :new
  end

  @doc """
  Mark an idempotency key as delivered. Call only for a confirmed delivery.
  """
  @spec mark(channel_id :: binary(), key :: binary()) :: :ok
  def mark(channel_id, key) do
    GenServer.cast(__MODULE__, {:mark, channel_id, key})
  end

  @impl true
  def init(_opts) do
    _ = Ets.init(@table)
    schedule_cleanup()
    {:ok, %{ttl_ms: @default_ttl_ms}}
  end

  @impl true
  def handle_call({:check, channel_id, key}, _from, state) do
    full_key = {channel_id, key}

    if Ets.seen?(@table, full_key, state.ttl_ms) do
      {:reply, :duplicate, state}
    else
      {:reply, :new, state}
    end
  end

  @impl true
  def handle_cast({:mark, channel_id, key}, state) do
    full_key = {channel_id, key}
    _ = Ets.mark(@table, full_key)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    _ = Ets.cleanup_expired(@table, state.ttl_ms)
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
