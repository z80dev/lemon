defmodule LemonCore.Rpc.Handler do
  @moduledoc """
  Product-owned reverse RPC request and notification handler.

  `handle_message/2` executes in a supervised task, never the RPC mailbox.
  The reply function sends a framed response without registering a request.
  Handlers own protocol policy, including authorization and error responses.
  """
  @callback handle_message(term(), (term() -> :ok | {:error, term()})) :: term()
end
