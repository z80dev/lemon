defmodule LemonGateway.Health.Router do
  @moduledoc false

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
