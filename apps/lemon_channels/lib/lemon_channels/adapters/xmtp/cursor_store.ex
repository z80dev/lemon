defmodule LemonChannels.Adapters.Xmtp.CursorStore do
  @moduledoc false
  # Durable per-conversation inbound high-water marks (`sent_at_ns`) for XMTP.
  # The transport resumes polling after these instead of replaying the whole
  # inbox from the persistent XMTP database after a restart.

  alias LemonCore.Store

  @table :xmtp_inbound_cursors

  @doc "Load every conversation cursor for `account_id`; a failed read is an error, never empty."
  @spec load(binary()) :: {:ok, %{binary() => non_neg_integer()}} | {:error, :store_unavailable}
  def load(account_id) when is_binary(account_id) do
    case Store.fetch_all(@table) do
      {:ok, entries} ->
        cursors =
          for {{^account_id, conversation_id}, sent_at_ns} <- entries,
              is_binary(conversation_id) and is_integer(sent_at_ns),
              into: %{},
              do: {conversation_id, sent_at_ns}

        {:ok, cursors}

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  @spec put(binary(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  def put(account_id, conversation_id, sent_at_ns)
      when is_binary(account_id) and is_binary(conversation_id) and is_integer(sent_at_ns) do
    Store.put(Store, @table, {account_id, conversation_id}, sent_at_ns, durable: true)
  end
end
