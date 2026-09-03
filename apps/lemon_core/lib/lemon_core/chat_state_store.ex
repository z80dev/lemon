defmodule LemonCore.ChatStateStore do
  @moduledoc """
  Typed wrapper for per-scope chat-state persistence.

  Owns the cached `:chat` table and declares its `:expires_at` retention
  policy. Runtime TTL stamping, lazy expiry, periodic sweeping, and cache
  coherence remain in `LemonCore.Store`'s specialized chat-state API.
  """

  use LemonCore.Store.Table,
    tables: [chat: [cached: true, retention: [expires_at: :expires_at]]]

  alias LemonCore.ChatState
  alias LemonCore.Store

  @spec get(term()) :: ChatState.t() | map() | nil
  def get(scope), do: Store.get_chat_state(scope)

  @spec put(term(), ChatState.t() | map()) :: :ok | {:error, term()}
  def put(scope, state), do: Store.put_chat_state(scope, state)

  @spec delete(term()) :: :ok | {:error, term()}
  def delete(scope), do: Store.delete_chat_state(scope)
end
