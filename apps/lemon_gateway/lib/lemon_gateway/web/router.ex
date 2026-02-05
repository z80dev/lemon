defmodule LemonGateway.Web.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    send_resp(conn, 200, "LemonGateway Web Interface Running")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
