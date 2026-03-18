defmodule LemonSimUi.HealthController do
  use LemonSimUi, :controller

  def index(conn, _params) do
    text(conn, "ok")
  end
end
