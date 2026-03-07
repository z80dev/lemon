defmodule LemonGateway.Sms.InboxStore do
  @moduledoc """
  Typed wrapper for the SMS inbox table.
  """

  alias LemonCore.Store

  @table :sms_inbox

  @spec get(binary()) :: map() | nil
  def get(message_sid) when is_binary(message_sid), do: Store.get(@table, message_sid)

  @spec put(binary(), map()) :: :ok
  def put(message_sid, value) when is_binary(message_sid) and is_map(value),
    do: Store.put(@table, message_sid, value)

  @spec delete(binary()) :: :ok
  def delete(message_sid) when is_binary(message_sid), do: Store.delete(@table, message_sid)

  @spec list() :: list()
  def list, do: Store.list(@table)
end
