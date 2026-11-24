defmodule LemonChannels.Telegram.TransportShared do
  @moduledoc false

  @channels_dedupe_table :lemon_channels_telegram_dedupe

  # The table outlives a transport restart (its owner is a core dedupe worker)
  # and its entries expire by TTL, so a restarted transport keeps recognising
  # messages it already accepted instead of starting from an empty seen set.
  def init_dedupe do
    LemonCore.Dedupe.Ets.init(@channels_dedupe_table)
  end

  def check_and_mark_dedupe(key, ttl_ms) do
    LemonCore.Dedupe.Ets.check_and_mark(@channels_dedupe_table, key, ttl_ms)
  end

  def forget_dedupe(key) do
    LemonCore.Dedupe.Ets.forget(@channels_dedupe_table, key)
  end

  def inbound_message_dedupe_key(inbound) when is_map(inbound) do
    peer = Map.get(inbound, :peer) || %{}
    message = Map.get(inbound, :message) || %{}
    {Map.get(peer, :id), Map.get(peer, :thread_id), Map.get(message, :id)}
  end
end
