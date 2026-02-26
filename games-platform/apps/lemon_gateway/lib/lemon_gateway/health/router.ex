defmodule LemonGateway.Health.Router do
  @moduledoc """
  Plug router that serves the `/healthz` HTTP health-check endpoint.

  Returns a JSON payload with HTTP 200 when healthy or 503 when unhealthy.
  All other routes return a 404 JSON error.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    payload = LemonGateway.Health.status()
    status = if payload.ok, do: 200, else: 503

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  match _ do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, Jason.encode!(%{error: "Not found"}))
  end
end
