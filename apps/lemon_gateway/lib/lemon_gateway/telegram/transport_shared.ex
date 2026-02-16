defmodule LemonGateway.Telegram.TransportShared do
  @moduledoc false

  @legacy_transport LemonGateway.Telegram.Transport
  @channels_transport LemonChannels.Adapters.Telegram.Transport

  @legacy_dedupe_table :lemon_gateway_telegram_dedupe
  @channels_dedupe_table :lemon_channels_telegram_dedupe

  def legacy_start_decision(opts \\ []) when is_list(opts) do
    force? = Keyword.get(opts, :force, false)
    legacy_start_decision(force?, channels_transport_running?())
  end

  def legacy_start_decision(force?, channels_running?)
      when is_boolean(force?) and is_boolean(channels_running?) do
    cond do
      not force? -> :disabled
      channels_running? -> :channels_running
      true -> :start
    end
  end

  def channels_transport_running? do
    Code.ensure_loaded?(@channels_transport) and is_pid(Process.whereis(@channels_transport))
  end

  def stop_legacy_transport do
    if Code.ensure_loaded?(@legacy_transport) do
      case Process.whereis(@legacy_transport) do
        pid when is_pid(pid) ->
          GenServer.stop(pid, :normal)

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def init_dedupe(:legacy), do: LemonCore.Dedupe.Ets.init(@legacy_dedupe_table)
  def init_dedupe(:channels), do: LemonCore.Dedupe.Ets.init(@channels_dedupe_table)

  def check_and_mark_dedupe(:legacy, key, ttl_ms) do
    LemonCore.Dedupe.Ets.check_and_mark(@legacy_dedupe_table, key, ttl_ms)
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
