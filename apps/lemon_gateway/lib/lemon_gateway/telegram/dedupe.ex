defmodule LemonGateway.Telegram.Dedupe do
  @moduledoc false

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
