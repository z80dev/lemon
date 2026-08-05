defmodule LemonSimUi.Plugs.RequireAccessToken do
  @moduledoc """
  Authentication gate for LemonSim operator surfaces.

  Browser routes accept only a short-lived signed-session marker established by
  the CSRF-protected admin login form. JSON API routes accept only an
  `Authorization: Bearer <token>` header. Tokens are never accepted from query
  strings.
  """

  @behaviour Plug

  import Plug.Conn

  @session_key :lemon_sim_ui_auth
  @return_to_key :lemon_sim_ui_admin_return_to
  @default_session_ttl_seconds 8 * 60 * 60

  def init(opts) do
    %{
      sources: Keyword.get(opts, :sources, [:session]),
      on_failure: Keyword.get(opts, :on_failure, :unauthorized)
    }
  end

  def call(conn, %{sources: sources, on_failure: on_failure}) do
    case configured_token() do
      nil ->
        if insecure_admin_allowed?(), do: conn, else: reject(conn, on_failure)

      expected ->
        cond do
          :authorization in sources and valid_bearer?(conn, expected) -> conn
          :session in sources and valid_session?(conn, expected) -> conn
          true -> conn |> delete_session_if_fetched() |> reject(on_failure)
        end
    end
  end

  def configured?, do: is_binary(configured_token())

  def authenticated?(conn) do
    case configured_token() do
      nil -> insecure_admin_allowed?()
      expected -> valid_session?(conn, expected)
    end
  end

  def sign_in(conn, provided) do
    with expected when is_binary(expected) <- configured_token(),
         provided when is_binary(provided) <- normalize_token(provided),
         true <- secure_equal?(provided, expected) do
      marker = session_marker(expected, System.system_time(:second))

      {:ok,
       conn
       |> configure_session(renew: true)
       |> put_session(@session_key, marker)}
    else
      _ -> {:error, delete_session_if_fetched(conn)}
    end
  end

  def sign_out(conn) do
    conn
    |> delete_session(@session_key)
    |> delete_session(@return_to_key)
    |> configure_session(renew: true)
  end

  def take_return_to(conn) do
    return_to =
      conn
      |> get_session(@return_to_key)
      |> safe_return_to()

    {delete_session(conn, @return_to_key), return_to}
  end

  def session_ttl_seconds do
    case Application.get_env(
           :lemon_sim_ui,
           :admin_session_ttl_seconds,
           @default_session_ttl_seconds
         ) do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ -> @default_session_ttl_seconds
    end
  end

  defp configured_token do
    Application.get_env(:lemon_sim_ui, :access_token)
    |> normalize_token()
  end

  defp insecure_admin_allowed? do
    Application.get_env(:lemon_sim_ui, :allow_insecure_admin, false) == true
  end

  defp valid_bearer?(conn, expected) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token -> secure_equal?(normalize_token(token), expected)
      _ -> false
    end
  end

  defp valid_session?(conn, expected) do
    valid_session_marker?(get_session(conn, @session_key), expected)
  end

  defp session_marker(token, issued_at) do
    %{
      "version" => 1,
      "digest" => token_digest(token),
      "issued_at" => issued_at
    }
  end

  defp valid_session_marker?(
         %{"version" => 1, "digest" => provided, "issued_at" => issued_at},
         expected
       )
       when is_binary(provided) and is_integer(issued_at) and is_binary(expected) do
    now = System.system_time(:second)

    issued_at <= now and now - issued_at <= session_ttl_seconds() and
      secure_equal?(provided, token_digest(expected))
  end

  defp valid_session_marker?(_provided, _expected), do: false

  defp token_digest(token) do
    :crypto.mac(
      :hmac,
      :sha256,
      admin_session_signing_key(),
      "lemon-sim-admin-session:" <> token
    )
    |> Base.encode64(padding: false)
  end

  defp admin_session_signing_key do
    :lemon_sim_ui
    |> Application.fetch_env!(LemonSimUi.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  defp normalize_token(token) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_token(_), do: nil

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp reject(conn, :redirect) do
    conn
    |> put_session(@return_to_key, conn.request_path)
    |> put_resp_header("location", "/admin/login")
    |> send_resp(:see_other, "")
    |> halt()
  end

  defp reject(conn, _mode) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(:unauthorized, "Unauthorized")
    |> halt()
  end

  defp delete_session_if_fetched(%Plug.Conn{private: %{plug_session_fetch: :done}} = conn) do
    delete_session(conn, @session_key)
  end

  defp delete_session_if_fetched(conn), do: conn

  defp safe_return_to(path) when is_binary(path) do
    if path == "/admin" or String.starts_with?(path, "/admin/sims/") do
      path
    else
      "/admin"
    end
  end

  defp safe_return_to(_path), do: "/admin"
end
