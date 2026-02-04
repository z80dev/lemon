defmodule LemonControlPlane.Methods.ConnectChallenge do
  @moduledoc """
  Handler for the connect.challenge control plane method.

  Handles challenge-response authentication for connections.
  This is typically used for secure device pairing or node authentication.

  ## Token Lifecycle

  1. Client obtains a challenge code from pairing flow
  2. Client calls connect.challenge with the challenge
  3. Server verifies challenge and issues a session token
  4. Token is stored in TokenStore with associated identity
  5. Client uses token in subsequent requests (auth.token)
  6. Token is validated by Authorize module
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonControlPlane.Auth.TokenStore

  # Token TTL: 7 days (node/device sessions are long-lived)
  @token_ttl_ms 7 * 24 * 60 * 60 * 1000

  @impl true
  def name, do: "connect.challenge"

  @impl true
  def scopes, do: []  # No auth required - this IS the auth

  @impl true
  def handle(params, ctx) do
    challenge = params["challenge"]

    if is_nil(challenge) or challenge == "" do
      {:error, Errors.invalid_request("challenge is required")}
    else
      case verify_challenge(challenge, ctx) do
        {:ok, identity} ->
          # Generate session token
          token = generate_session_token()

          # Store token with identity for later validation
          {:ok, _token_info} = TokenStore.store(token, identity,
            ttl_ms: @token_ttl_ms,
            conn_id: ctx[:conn_id]
          )

          {:ok, %{
            "verified" => true,
            "identity" => identity,
            "token" => token
          }}

        {:error, reason} ->
          {:error, Errors.unauthorized(reason)}
      end
    end
  end

  defp verify_challenge(challenge, ctx) do
    # Check if this is a device pairing verification
    case LemonCore.Store.get(:device_pairing_challenges, challenge) do
      nil ->
        # Check if it's a node pairing verification
        verify_node_challenge(challenge, ctx)

      pairing_info when is_map(pairing_info) ->
        # Verify the challenge matches a pending pairing
        expires_at = pairing_info[:expires_at_ms] || pairing_info["expires_at_ms"]
        if expires_at && expires_at > System.system_time(:millisecond) do
          # Clean up the challenge after successful verification (one-time use)
          LemonCore.Store.delete(:device_pairing_challenges, challenge)

          {:ok, %{
            "type" => "device",
            "deviceId" => pairing_info[:device_id] || pairing_info["device_id"],
            "deviceName" => pairing_info[:device_name] || pairing_info["device_name"]
          }}
        else
          # Clean up expired challenge
          LemonCore.Store.delete(:device_pairing_challenges, challenge)
          {:error, "Challenge expired"}
        end

      _ ->
        verify_node_challenge(challenge, ctx)
    end
  end

  defp verify_node_challenge(challenge, _ctx) do
    # Check against stored node challenges
    case LemonCore.Store.get(:node_challenges, challenge) do
      nil ->
        {:error, "Invalid challenge"}

      node_info when is_map(node_info) ->
        expires_at = node_info[:expires_at_ms] || node_info["expires_at_ms"]
        if expires_at && expires_at > System.system_time(:millisecond) do
          # Clean up the challenge after successful verification (one-time use)
          LemonCore.Store.delete(:node_challenges, challenge)

          {:ok, %{
            "type" => "node",
            "nodeId" => node_info[:node_id] || node_info["node_id"],
            "nodeName" => node_info[:node_name] || node_info["node_name"]
          }}
        else
          # Clean up expired challenge
          LemonCore.Store.delete(:node_challenges, challenge)
          {:error, "Challenge expired"}
        end

      _ ->
        {:error, "Invalid challenge"}
    end
  end

  defp generate_session_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
