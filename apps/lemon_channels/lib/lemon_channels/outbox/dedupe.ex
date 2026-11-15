defmodule LemonChannels.Outbox.Dedupe do
  @moduledoc """
  Confirmed-delivery deduplication using atomic ETS inserts.

  Checks never reserve a key: unknown deliveries remain eligible for the outbox's
  bounded at-least-once retry. Only confirmed deliveries call `mark/2`.
  """

  use GenServer

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
    full_key = {channel_id, key}

    case :ets.lookup(@table, full_key) do
      [{^full_key, expires_at}] ->
        if expires_at >= System.monotonic_time(:millisecond) do
          :duplicate
        else
          :ets.delete_object(@table, {full_key, expires_at})
          check(channel_id, key)
        end

      [] ->
        :new
    end
  rescue
    ArgumentError -> :new
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
    full_key = {channel_id, key}
    expires_at = System.monotonic_time(:millisecond) + remaining_ms
    insert_mark(full_key, expires_at)
  rescue
    ArgumentError -> :new
  end

  defp insert_mark(full_key, expires_at) do
    if :ets.insert_new(@table, {full_key, expires_at}) do
      :new
    else
      case :ets.lookup(@table, full_key) do
        [{^full_key, previous}] ->
          cond do
            previous < System.monotonic_time(:millisecond) ->
              :ets.delete_object(@table, {full_key, previous})
              insert_mark(full_key, expires_at)

            previous >= expires_at ->
              :duplicate

            true ->
              match_spec = [{{full_key, previous}, [], [{:const, {full_key, expires_at}}]}]

              if :ets.select_replace(@table, match_spec) == 1,
                do: :duplicate,
                else: insert_mark(full_key, expires_at)
          end

        [] ->
          insert_mark(full_key, expires_at)
      end
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
