defmodule LemonChannels.Telegram.TransportShared do
  @moduledoc false

  @channels_transport LemonChannels.Adapters.Telegram.Transport

  @channels_dedupe_table :lemon_channels_telegram_dedupe

  def channels_transport_running? do
    Code.ensure_loaded?(@channels_transport) and is_pid(Process.whereis(@channels_transport))
  end

  def init_dedupe(:channels) do
    :ok = LemonCore.Dedupe.Ets.init(@channels_dedupe_table)
    _ = :ets.delete_all_objects(@channels_dedupe_table)
    :ok
  rescue
    _ -> :ok
  end

  def check_and_mark_dedupe(:channels, key, ttl_ms) do
    LemonCore.Dedupe.Ets.check_and_mark(@channels_dedupe_table, key, ttl_ms)
  end

  def message_dedupe_key(peer_id, thread_id, message_id) do
    {peer_id, thread_id, message_id}
  end

  def inbound_message_dedupe_key(inbound) when is_map(inbound) do
    peer = Map.get(inbound, :peer) || %{}
    message = Map.get(inbound, :message) || %{}
    message_dedupe_key(Map.get(peer, :id), Map.get(peer, :thread_id), Map.get(message, :id))
  end
end
