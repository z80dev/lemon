defmodule LemonCore.Rpc.Transport do
  @moduledoc """
  Lifecycle boundary for an already-open RPC peer.

  Drivers open their transport under their own supervision and supply its opaque
  state to `LemonCore.Rpc.Client`. A transport sends already-framed bytes and
  closes idempotently, including subprocess-group cleanup when appropriate.
  Incoming bytes go to `Client.feed/2`; loss goes to `Client.peer_down/2` (or a
  monitored `:peer` process). The core never imports a product driver.
  """
  @callback send(term(), binary()) :: :ok | {:error, term()}
  @callback close(term()) :: term()
end
