defmodule LemonControlPlane.Methods.NodePairApprove do
  @moduledoc """
  Handler for the node.pair.approve control plane method.

  Approves a pending pairing request.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.pair.approve"

  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(params, _ctx) do
    pairing_id = params["pairingId"] || params["pairing_id"]
    code = params["code"]

    cond do
      is_nil(pairing_id) and is_nil(code) ->
        {:error, Errors.invalid_request("pairingId or code is required")}

      true ->
        # Find pairing request
        pairing_id =
          if pairing_id do
            pairing_id
          else
            LemonCore.Store.get(:nodes_pairing_by_code, code)
          end

        case LemonCore.Store.get(:nodes_pairing, pairing_id) do
          nil ->
            {:error, Errors.not_found("Pairing request not found")}

          request ->
            now = System.system_time(:millisecond)

            # Safe access supporting both atom and string keys (for JSONL reload)
            status = get_field(request, :status)
            expires_at_ms = get_field(request, :expires_at_ms)
            node_name = get_field(request, :node_name)
            node_type = get_field(request, :node_type)
            capabilities = get_field(request, :capabilities)

            cond do
              status != :pending and status != "pending" ->
                {:error, Errors.invalid_request("Pairing request is not pending")}

              expires_at_ms && expires_at_ms < now ->
                {:error, Errors.invalid_request("Pairing request has expired")}

              true ->
                # Generate node ID, token, and challenge token
                node_id = LemonCore.Id.uuid()
                node_token = generate_node_token()
                challenge_token = generate_challenge_token()
                challenge_expires_at = now + 60_000  # Challenge valid for 1 minute

                # Update pairing request
                updated_request = Map.merge(request, %{
                  status: :approved,
                  node_id: node_id,
                  challenge_token: challenge_token
                })
                LemonCore.Store.put(:nodes_pairing, pairing_id, updated_request)

                # Register node
                node = %{
                  id: node_id,
                  name: node_name,
                  type: node_type,
                  capabilities: capabilities,
                  token_hash: hash_token(node_token),
                  paired_at_ms: now,
                  last_seen_ms: now,
                  status: :online
                }
                LemonCore.Store.put(:nodes_registry, node_id, node)

                # Store challenge for connect.challenge verification
                LemonCore.Store.put(:node_challenges, challenge_token, %{
                  node_id: node_id,
                  node_name: node_name,
                  node_type: node_type,
                  pairing_id: pairing_id,
                  expires_at_ms: challenge_expires_at
                })

                # Broadcast event
                event = LemonCore.Event.new(:node_pair_resolved, %{
                  pairing_id: pairing_id,
                  node_id: node_id,
                  approved: true
                })
                LemonCore.Bus.broadcast("nodes", event)

                {:ok, %{
                  "nodeId" => node_id,
                  "token" => node_token,
                  "challengeToken" => challenge_token,
                  "approved" => true
                }}
            end
        end
    end
  end

  defp generate_node_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_challenge_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
