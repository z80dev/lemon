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

  @doc """
  Decides whether a request may proceed, **before** its body is read.

  Optional. Implement it whenever authentication needs nothing but the request
  line and headers — a shared token, an API key — and the router will reject
  unauthorized callers with a 401 without parsing anything. Skipping it means
  an unauthenticated stranger can make the server read and parse a
  megabytes-long body before being turned away, which is free work for them and
  expensive for you.

  Do *not* implement it for provider signatures computed over the raw body:
  those need the body, so they belong in `c:handle_inbound/1`. An adapter that
  omits this callback is not treated as unauthenticated — it is treated as
  authenticating later, and the router lets the request through to it.

  Must not raise; the router treats an exception here as "not authorized".
  """
  @callback authorized?(Plug.Conn.t()) :: boolean()

  @optional_callbacks authorized?: 1
end
