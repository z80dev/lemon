defmodule LemonWeb.LoginController do
  @moduledoc """
  Token login and logout for the operator web UI.

  The token is posted from a form (never put in a URL by the UI) and is not
  stored; the session receives only `LemonWeb.Auth`'s derived marker and is
  renewed to prevent fixation. `/login#token=…` is supported client-side: the
  page reads the fragment (which browsers never send to the server), removes
  it from history and submits the form.
  """

  use LemonWeb, :controller

  alias LemonWeb.{Auth}
  alias LemonCore.RateLimiter

  # Supervised by LemonWeb.Application with the core limiter's :login profile.
  @throttle LemonWeb.LoginThrottle

  plug(:put_layout, false)
  plug(:put_root_layout, html: {LemonWeb.Layouts, :root})

  def new(conn, params) do
    return_to = safe_return_to(params["return_to"])

    case Auth.verify(get_session(conn, Auth.session_key()), conn.remote_ip) do
      {:ok, _access} ->
        redirect(conn, to: return_to)

      {:error, :not_configured} ->
        conn |> put_status(503) |> render_login(return_to, :not_configured)

      {:error, :unauthenticated} ->
        render_login(conn, return_to, nil)
    end
  end

  def create(conn, params) do
    peer = conn.remote_ip
    return_to = safe_return_to(params["return_to"])

    with :ok <- RateLimiter.check(@throttle, peer),
         {:ok, marker} <- Auth.login(params["token"], peer) do
      RateLimiter.clear(@throttle, peer)

      conn
      |> configure_session(renew: true)
      |> put_session(Auth.session_key(), marker)
      |> redirect(to: return_to)
    else
      {:error, :throttled, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(429)
        |> render_login(return_to, {:throttled, retry_after})

      {:error, :not_configured} ->
        conn |> put_status(503) |> render_login(return_to, :not_configured)

      {:error, :invalid_token} ->
        RateLimiter.record_failure(@throttle, peer)
        conn |> put_status(401) |> render_login(return_to, :invalid_token)
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  defp render_login(conn, return_to, error) do
    conn
    |> assign(:page_title, "Sign in · Lemon")
    |> assign(:return_to, return_to)
    |> assign(:error, error)
    |> render(:new)
  end

  @doc false
  # Only same-origin absolute paths are accepted: no scheme, no host, no
  # protocol-relative `//`, no backslashes, and never back to /login itself.
  def safe_return_to(path) when is_binary(path) do
    cond do
      byte_size(path) > 2_048 -> "/"
      not String.starts_with?(path, "/") -> "/"
      String.starts_with?(path, "//") -> "/"
      String.contains?(path, ["\\", "\r", "\n", "\t"]) -> "/"
      String.starts_with?(path, "/login") -> "/"
      true -> path
    end
  end

  def safe_return_to(_path), do: "/"
end
