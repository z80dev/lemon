defmodule LemonRouter.InboundMessage do
  @moduledoc """
  Backwards-compatible wrapper for `LemonCore.InboundMessage`.

  This module used to own the normalized inbound message struct. The struct now
  lives in `:lemon_core` (`LemonCore.InboundMessage`) so producers (channels)
  do not need a compile-time dependency on `:lemon_router`.
  """

  @type t :: LemonCore.InboundMessage.t()

  @deprecated "Use LemonCore.InboundMessage.new/1"
  defdelegate new(opts), to: LemonCore.InboundMessage

  @deprecated "Use LemonCore.InboundMessage.from_telegram/3"
  defdelegate from_telegram(transport, chat_id, message), to: LemonCore.InboundMessage
end

