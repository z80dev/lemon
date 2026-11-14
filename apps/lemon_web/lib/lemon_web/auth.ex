defmodule LemonWeb.Auth do
  @moduledoc """
  Operator authentication for the web UI.

  The web UI accepts exactly one credential: the control-plane operator token
  (`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`, normally the launcher-managed token).
  A successful login stores only a derived marker in the signed, encrypted,
  httpOnly session cookie. The marker is derived from the *configured* token,
  so rotating the token invalidates every browser session.

  With no configured token the UI is unavailable, unless the operator explicitly
  enabled `LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK` and the actual
  socket peer is a direct loopback address. The peer always comes from the
  connection (`conn.remote_ip` / LiveView `peer_data`), never from headers.
  """

  alias LemonControlPlane.Auth.Authorize

  @session_key "lemon_web_operator"
  @marker_context "lemon-web-operator-session:v1:"

  @type peer :: :inet.ip_address() | nil
  @type access :: :token | :tokenless_loopback

  @doc "Session key holding the derived operator marker."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  # How a request from `peer` may be admitted right now:
  @spec mode(peer()) :: {:login, :token} | {:ok, :tokenless_loopback} | {:error, :not_configured}
  defp mode(peer) do
    cond do
      is_binary(Authorize.configured_operator_token()) -> {:login, :token}
      Authorize.tokenless_loopback_allowed?(peer) -> {:ok, :tokenless_loopback}
      true -> {:error, :not_configured}
    end
  end

  @doc """
  Validates a submitted operator token. Returns the session marker to store.

  Delegates to the control-plane authorizer so the comparison, normalization
  and operator-role requirement are identical to the WebSocket handshake.
  Session tokens of other roles (nodes) are refused.
  """
  @spec login(term(), peer()) :: {:ok, String.t()} | {:error, :invalid_token | :not_configured}
  def login(token, _peer) do
    configured = Authorize.configured_operator_token()

    cond do
      not is_binary(configured) ->
        {:error, :not_configured}

      not is_binary(token) or String.trim(token) == "" ->
        {:error, :invalid_token}

      true ->
        params = %{"role" => "operator", "auth" => %{"token" => String.trim(token)}}

        case Authorize.from_params(params, local?: false) do
          {:ok, %{role: :operator}} -> {:ok, marker(configured)}
          _ -> {:error, :invalid_token}
        end
    end
  end

  @doc """
  Verifies a stored session marker for a request or LiveView connection from
  `peer`. Returns how access was granted.
  """
  @spec verify(term(), peer()) ::
          {:ok, access()} | {:error, :unauthenticated | :not_configured}
  def verify(stored_marker, peer) do
    case mode(peer) do
      {:ok, :tokenless_loopback} ->
        {:ok, :tokenless_loopback}

      {:error, :not_configured} ->
        {:error, :not_configured}

      {:login, :token} ->
        expected = marker(Authorize.configured_operator_token())

        if is_binary(stored_marker) and byte_size(stored_marker) == byte_size(expected) and
             Plug.Crypto.secure_compare(stored_marker, expected) do
          {:ok, :token}
        else
          {:error, :unauthenticated}
        end
    end
  end

  defp marker(token) when is_binary(token) do
    :crypto.hash(:sha256, @marker_context <> token) |> Base.url_encode64(padding: false)
  end
end
