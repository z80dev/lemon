defmodule LemonWeb.HealthController do
  @moduledoc """
  Simple health check controller for load balancers and monitoring.
  """
  use LemonWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
