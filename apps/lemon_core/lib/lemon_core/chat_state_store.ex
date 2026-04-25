defmodule LemonCore.ChatStateStore do
  @moduledoc """
  Typed wrapper for chat-state persistence.
  """

  alias LemonCore.ChatState
  alias LemonCore.Store

  @spec get(term()) :: ChatState.t() | map() | nil
  def get(scope), do: Store.get_chat_state(scope)

  @spec put(term(), ChatState.t() | map()) :: :ok | {:error, term()}
  def put(scope, state), do: Store.put_chat_state(scope, state)

  @spec delete(term()) :: :ok | {:error, term()}
  def delete(scope), do: Store.delete_chat_state(scope)
end
