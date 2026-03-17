defmodule LemonChannels.Adapters.WhatsApp.Dedupe do
  @moduledoc """
  ETS-backed TTL dedup cache for WhatsApp messages.

  Prevents processing duplicate messages within the TTL window.
  """

  @table :whatsapp_dedupe
  @ttl_ms 1_200_000
  @max_entries 5_000

  @doc "Creates the ETS dedup table. Call once at startup."
  def init do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ok
  end

  @doc "Returns true if {jid, message_id} has been seen and not yet expired."
  def seen?(jid, message_id) do
    key = {jid, message_id}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, inserted_at}] -> now - inserted_at < @ttl_ms
      [] -> false
    end
  end

  @doc "Marks {jid, message_id} as seen."
  def mark(jid, message_id) do
    key = {jid, message_id}
    now = System.monotonic_time(:millisecond)
    :ets.insert(@table, {key, now})
    maybe_prune()
    :ok
  end

  @doc "Prunes expired entries if the table exceeds max_entries."
  def maybe_prune do
    if :ets.info(@table, :size) > @max_entries do
      now = System.monotonic_time(:millisecond)
      cutoff = now - @ttl_ms

      :ets.select_delete(@table, [
        {{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
      ])
    end

    :ok
  end
end
