defmodule LemonGateway.Sms.InboxStore do
  @moduledoc """
  Typed wrapper for the SMS inbox table and its single reservation lease.

  Writes that must not clobber existing state use strict reads (`fetch/1`,
  `fetch_reservation/0`, which report store failures) and atomic
  insert-if-absent (`put_new/2`), never a lenient `get` that reads a failure as
  "absent".
  """

  alias LemonCore.Store

  @table :sms_inbox
  @reservation_table :sms_inbox_reservation
  @reservation_key "lease"

  @spec get(binary()) :: map() | nil
  def get(message_sid) when is_binary(message_sid), do: Store.get(@table, message_sid)

  @spec put(binary(), map()) :: :ok
  def put(message_sid, value) when is_binary(message_sid) and is_map(value),
    do: Store.put(@table, message_sid, value)

  @doc "Strict read: `{:ok, record | nil}` or `{:error, :store_unavailable}`."
  @spec fetch(binary()) :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch(message_sid) when is_binary(message_sid), do: Store.fetch(@table, message_sid)

  @doc "Atomic insert-if-absent keyed by MessageSid."
  @spec put_new(binary(), map()) :: :ok | {:error, :exists | term()}
  def put_new(message_sid, value) when is_binary(message_sid) and is_map(value),
    do: Store.put_new(@table, message_sid, value)

  @spec delete(binary()) :: :ok
  def delete(message_sid) when is_binary(message_sid), do: Store.delete(@table, message_sid)

  @spec list() :: list()
  def list, do: Store.list(@table)

  @doc "Strict read of the lease: `{:ok, lease | nil}` or `{:error, :store_unavailable}`."
  @spec fetch_reservation() :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_reservation, do: Store.fetch(@reservation_table, @reservation_key)

  @spec put_reservation(map()) :: :ok
  def put_reservation(lease) when is_map(lease),
    do: Store.put(@reservation_table, @reservation_key, lease)

  @spec delete_reservation() :: :ok
  def delete_reservation, do: Store.delete(@reservation_table, @reservation_key)
end
