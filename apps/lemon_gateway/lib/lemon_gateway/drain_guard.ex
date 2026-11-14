defmodule LemonGateway.DrainGuard do
  @moduledoc """
  Plug for webhook ingress: while the runtime drains for a restart
  (`LemonCore.Drain`), answer `503` with `Retry-After` instead of accepting work
  the stopping runtime might not carry over. Providers that retry deliver again
  to the next runtime; generic webhooks replay safely through their idempotency
  receipts.
  """

  @behaviour Plug

  import Plug.Conn

  @retry_after_s "30"

  @impl true
  def init(opts), do: Keyword.get(opts, :draining?, &LemonCore.Drain.draining?/0)

  @impl true
  def call(conn, draining?) do
    if draining?.() do
      conn
      |> put_resp_header("retry-after", @retry_after_s)
      |> send_resp(503, "restarting")
      |> halt()
    else
      conn
    end
  end
end
