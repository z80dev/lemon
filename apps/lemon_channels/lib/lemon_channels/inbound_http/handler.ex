defmodule LemonChannels.InboundHttp.Handler do
  @moduledoc """
  Contract for adapters that receive inbound HTTP.

  Kept separate from `LemonChannels.Plugin` on purpose: needing a webhook is an
  implementation detail of *how* an adapter receives messages, not part of what
  a channel is. Adapters implement `Plugin` to be a channel and additionally
  implement this only if they must bind a path.
  """

  @doc """
  Handles a request routed to this adapter's registered segment.

  Receives a `Plug.Conn` whose body has already been parsed by
  `LemonChannels.InboundHttp.Router`, and must return the conn having sent a
  response. Raising is caught by the router and answered with a 500.
  """
  @callback handle_inbound(Plug.Conn.t()) :: Plug.Conn.t()
end
