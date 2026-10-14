defmodule LemonControlPlane.Methods.ConnectChallenge do
  @moduledoc """
  Handler for the connect.challenge control plane method.

  Handles challenge-response authentication for paired execution nodes.

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
  alias LemonControlPlane.NodeStore

  # Token TTL: 7 days (node sessions are long-lived)
  @token_ttl_ms 7 * 24 * 60 * 60 * 1000

  @impl true
  def name, do: "connect.challenge"

  @impl true
  # No auth required - this IS the auth
  def scopes, do: []

  @impl true
  def handle(params, ctx) do
    challenge = params["challenge"]

    if is_nil(challenge) or challenge == "" do
      {:error, Errors.invalid_request("challenge is required")}
    else
      case verify_challenge(challenge, ctx) do
        {:ok, identity} ->
          token = generate_session_token()
          issue_session(identity, token, ctx)

        {:error, reason} ->
          {:error, Errors.unauthorized(reason)}
      end
    end
  end

  defp verified_response(identity, token) do
    {:ok,
     %{
       "verified" => true,
       "identity" => identity,
       "token" => token,
       "summary" => %{
         "verified" => true,
         "identityType" => identity["type"],
         "identityId" => identity_id(identity),
         "tokenTtlMs" => @token_ttl_ms,
         "credentialDelivery" => %{
           "includesSessionToken" => true
         },
         "cleanup" => %{
           "includesChallenge" => false,
           "includesChallengeToken" => false,
           "includesSecretValues" => false
         }
       }
     }}
  end

  defp issue_session(%{"type" => "node", "nodeId" => node_id} = identity, token, ctx)
       when is_binary(node_id) do
    with {:ok, token_info} <-
           TokenStore.replace_node_session(token, identity,
             ttl_ms: @token_ttl_ms,
             conn_id: ctx[:conn_id]
           ),
         {:ok, generation} <- session_generation(token_info.identity),
         :ok <- LemonCore.NodeRegistry.revoke_session(node_id, generation) do
      verified_response(token_info.identity, token)
    end
  end

  defp issue_session(identity, token, ctx) do
    with {:ok, _token_info} <-
           TokenStore.store(token, identity,
             ttl_ms: @token_ttl_ms,
             conn_id: ctx[:conn_id]
           ) do
      verified_response(identity, token)
    end
  end

  defp session_generation(%{"sessionGeneration" => generation}) when is_integer(generation),
    do: {:ok, generation}

  defp session_generation(_identity), do: {:error, :invalid_session_generation}

  defp verify_challenge(challenge, ctx) do
    # A restricted enrollment connection may exchange only the challenge issued
    # for its own invite, not another node's challenge.
    with {:ok, info} <- LemonCore.Store.fetch(:node_challenges, challenge),
         true <- challenge_owned?(info, ctx) do
      consume_challenge(challenge)
    else
      _ -> {:error, "Invalid challenge"}
    end
  end

  defp challenge_owned?(info, %{auth: %{role: :enrollment, identity: identity}})
       when is_map(info) do
    is_binary(identity["inviteId"]) and
      identity["inviteId"] == NodeStore.invite_field(info, :invite_id)
  end

  defp challenge_owned?(_info, %{auth: %{role: :enrollment}}), do: false
  defp challenge_owned?(_info, _ctx), do: true

  defp consume_challenge(challenge) do
    case NodeStore.take_challenge(challenge) do
      nil ->
        {:error, "Invalid challenge"}

      node_info when is_map(node_info) ->
        expires_at = node_info[:expires_at_ms] || node_info["expires_at_ms"]

        if expires_at && expires_at > System.system_time(:millisecond) do
          {:ok,
           %{
             "type" => "node",
             "nodeId" => node_info[:node_id] || node_info["node_id"],
             "nodeName" => node_info[:node_name] || node_info["node_name"]
           }}
        else
          {:error, "Challenge expired"}
        end

      {:error, _reason} ->
        {:error, "Challenge store unavailable"}

      _ ->
        {:error, "Invalid challenge"}
    end
  end

  defp generate_session_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp identity_id(%{"nodeId" => node_id}), do: node_id
  defp identity_id(_), do: nil
end
