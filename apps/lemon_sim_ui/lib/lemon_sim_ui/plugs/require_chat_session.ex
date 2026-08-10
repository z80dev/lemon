defmodule LemonSimUi.Plugs.RequireChatSession do
  @moduledoc """
  Bearer-token gate for the PhilosopherChat JSON API.

  Accepts only an `Authorization: Bearer <token>` header carrying a token
  issued by `LemonSimUi.PhilosopherChat.Auth.login/1`. When no password is
  configured and the env is not prod, requests pass through (mirrors the
  dev convenience in `Auth`).
  """

  @behaviour Plug

  import Plug.Conn

  alias LemonSimUi.PhilosopherChat.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    if Auth.dev_bypass?() do
      conn
    else
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> case do
        "Bearer " <> token -> verify(conn, token)
        _ -> unauthorized(conn)
      end
    end
  end

  defp verify(conn, token) do
    case Auth.verify(token) do
      {:ok, _user} -> conn
      {:error, _reason} -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
