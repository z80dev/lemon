defmodule LemonChannels.Telegram.KnownTargetStore do
  @moduledoc """
  Typed wrapper for Telegram known-target metadata.
  """

  alias LemonCore.Store

  @table :telegram_known_targets

  @spec get(term()) :: term()
  def get(key), do: Store.get(@table, key)

  @spec put(term(), map()) :: :ok
  def put(key, value), do: Store.put(@table, key, value)

  @spec list() :: list()
  def list, do: Store.list(@table)
end
