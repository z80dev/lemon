defmodule LemonGateway.Telegram.Dedupe do
  @moduledoc """
  ETS-based deduplication for Telegram message processing.

  Wraps `LemonCore.Dedupe.Ets` with a dedicated table to track previously
  seen message keys and prevent duplicate processing within a configurable TTL.
  """

  @table :lemon_gateway_telegram_dedupe

  def init do
    LemonCore.Dedupe.Ets.init(@table)
  end

  def seen?(key, ttl_ms) do
    LemonCore.Dedupe.Ets.seen?(@table, key, ttl_ms)
  end

  def mark(key) do
    LemonCore.Dedupe.Ets.mark(@table, key)
  end

  def check_and_mark(key, ttl_ms) do
    LemonCore.Dedupe.Ets.check_and_mark(@table, key, ttl_ms)
  end
end
