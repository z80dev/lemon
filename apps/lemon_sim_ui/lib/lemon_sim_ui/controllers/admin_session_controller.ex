defmodule LemonSimUi.AdminSessionController do
  use LemonSimUi, :controller

  alias LemonSimUi.Plugs.RequireAccessToken

  def new(conn, _params) do
    if RequireAccessToken.authenticated?(conn) do
      redirect(conn, to: ~p"/admin")
    else
      render_login(conn)
    end
  end

  def create(conn, params) do
    case RequireAccessToken.sign_in(conn, Map.get(params, "token")) do
      {:ok, conn} ->
        {conn, return_to} = RequireAccessToken.take_return_to(conn)
        redirect(conn, to: return_to)

      {:error, conn} ->
        status =
          if RequireAccessToken.configured?(), do: :unauthorized, else: :service_unavailable

        conn
        |> put_status(status)
        |> render_login(error: true)
    end
  end

  def delete(conn, _params) do
    conn
    |> RequireAccessToken.sign_out()
    |> redirect(to: ~p"/admin/login")
  end

  defp render_login(conn, opts \\ []) do
    render(conn, :new,
      page_title: "Admin sign in · LemonSim",
      auth_configured: RequireAccessToken.configured?(),
      error: Keyword.get(opts, :error, false),
      session_duration: format_session_duration(RequireAccessToken.session_ttl_seconds())
    )
  end

  defp format_session_duration(seconds) when rem(seconds, 60 * 60) == 0 do
    "#{div(seconds, 60 * 60)} hours"
  end

  defp format_session_duration(seconds), do: "#{div(seconds, 60)} minutes"
end
