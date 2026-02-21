defmodule LemonGateway.Telegram.TransportShared do
  @moduledoc """
  Shared utilities for Telegram transport deduplication and message processing.

  Provides helpers to check whether the channels transport is running, build
  deduplication keys from inbound messages, and perform ETS-based check-and-mark
  deduplication for the channels adapter.
  """

  @channels_transport LemonChannels.Adapters.Telegram.Transport

  @channels_dedupe_table :lemon_channels_telegram_dedupe

  def channels_transport_running? do
    Code.ensure_loaded?(@channels_transport) and is_pid(Process.whereis(@channels_transport))
  end

  def init_dedupe(:channels), do: LemonCore.Dedupe.Ets.init(@channels_dedupe_table)

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
