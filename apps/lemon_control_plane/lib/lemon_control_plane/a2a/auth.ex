defmodule LemonControlPlane.A2A.Auth do
  @moduledoc false

  import Plug.Conn

  alias LemonControlPlane.A2A.Config
  alias LemonCore.Secrets

  @spec authenticate(Plug.Conn.t()) :: {:ok, binary()} | {:error, :unauthorized}
  def authenticate(conn) do
    token = bearer(conn)
    peers = Config.current().peers

    case matching_peer(token, peers) do
      {:ok, peer_id} ->
        {:ok, peer_id}

      :error ->
        if is_nil(token) and not token_required?(peers) and loopback?(conn.remote_ip),
          do: {:ok, "local"},
          else: {:error, :unauthorized}
    end
  end

  @spec outbound_token(map()) :: binary() | nil
  def outbound_token(peer) do
    resolve_secret(peer.outbound_token_secret || peer.token_secret)
  end

  defp matching_peer(nil, _peers), do: :error

  defp matching_peer(token, peers) do
    Enum.find_value(peers, :error, fn {peer_id, peer} ->
      expected = resolve_secret(peer.inbound_token_secret || peer.token_secret)

      if secure_equal?(token, expected), do: {:ok, peer_id}, else: false
    end)
  end

  defp token_required?(peers) do
    Enum.any?(peers, fn {_peer_id, peer} ->
      is_binary(peer.inbound_token_secret || peer.token_secret)
    end)
  end

  defp resolve_secret(name) when is_binary(name) and name != "", do: Secrets.fetch_value(name)
  defp resolve_secret(_), do: nil

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> token
      _ -> nil
    end
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_, _), do: false

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
