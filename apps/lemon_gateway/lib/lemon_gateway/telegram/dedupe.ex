defmodule LemonGateway.Telegram.Dedupe do
  @moduledoc false

  @table :lemon_gateway_telegram_dedupe

  def init do
    case :ets.info(@table) do
      :undefined ->
        _ = :ets.new(@table, [:set, :public, :named_table])
        :ok

      _info ->
        :ok
    end
  end

  def seen?(key, ttl_ms) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, ts}] when now - ts <= ttl_ms ->
        true

      [{^key, _ts}] ->
        :ets.delete(@table, key)
        false

      _ ->
        false
    end
  end

  def mark(key) do
    :ets.insert(@table, {key, System.monotonic_time(:millisecond)})
    :ok
  end

  def check_and_mark(key, ttl_ms) do
    if seen?(key, ttl_ms) do
      :seen
    else
      mark(key)
      :new
    end
  end
end
