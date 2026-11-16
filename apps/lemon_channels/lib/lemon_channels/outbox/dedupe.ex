defmodule LemonChannels.Outbox.Dedupe do
  @moduledoc """
  Confirmed-delivery deduplication using atomic ETS inserts.

  Checks never reserve a key: unknown deliveries remain eligible for the outbox's
  bounded at-least-once retry. Only confirmed deliveries call `mark/2`.
  """

  use GenServer

  alias LemonCore.Dedupe.Ets

  @default_ttl_ms 60 * 60 * 1000
  @cleanup_interval_ms 60_000
  @table :lemon_channels_outbox_dedupe

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The existing confirmed-delivery retention policy, in milliseconds."
  def ttl_ms, do: @default_ttl_ms

  @spec check(binary(), binary()) :: :new | :duplicate
  def check(channel_id, key) do
    if Ets.seen?(@table, {channel_id, key}, 0), do: :duplicate, else: :new
  end

  @doc "Mark a confirmed delivery, refreshing the existing one-hour TTL."
  @spec mark(binary(), binary()) :: :ok
  def mark(channel_id, key) do
    _ = mark_new(channel_id, key)
    :ok
  end

  @doc "Atomically mark a confirmed key, reporting which caller inserted it."
  @spec mark_new(binary(), binary()) :: :new | :duplicate
  def mark_new(channel_id, key) do
    restore(channel_id, key, @default_ttl_ms)
  end

  @doc false
  def restore(channel_id, key, remaining_ms) do
    case Ets.retain(@table, {channel_id, key}, remaining_ms, 0) do
      :new -> :new
      :seen -> :duplicate
    end
  end

  @impl true
  def init(_opts) do
    :ok = Ets.init(@table)

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Ets.cleanup_expired(@table, 0)
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
