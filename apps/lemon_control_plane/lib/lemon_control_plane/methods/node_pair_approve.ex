defmodule LemonControlPlane.Methods.NodePairApprove do
  @moduledoc """
  Handler for the node.pair.approve control plane method.

  Approves a pending pairing request.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.pair.approve"

  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(params, ctx) do
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
            NodeStore.get_pairing_id_by_code(code)
          end

        case NodeStore.get_pairing(pairing_id) do
          nil ->
            {:error, Errors.not_found("Pairing request not found")}

          request ->
            now = System.system_time(:millisecond)

            # Safe access supporting both atom and string keys (for JSONL reload)
            status = get_field(request, :status)
            expires_at_ms = get_field(request, :expires_at_ms)
            node_name = normalize_name(get_field(request, :node_name))
            node_type = get_field(request, :node_type)
            capabilities = get_field(request, :capabilities)

            cond do
              not may_approve?(ctx, request) ->
                {:error, Errors.unauthorized("Pairing authorization is required")}

              status in [:approved, "approved"] and invite_repair?(request) ->
                {:error, Errors.unauthorized("Repair invitation has already been used")}

              status in [:approved, "approved"] ->
                recover_approved_pairing(pairing_id, request, node_name, node_type, now)

              status not in [:pending, "pending"] ->
                {:error, Errors.invalid_request("Pairing request is not pending")}

              not is_integer(expires_at_ms) or expires_at_ms <= now ->
                {:error, Errors.invalid_request("Pairing request has expired")}

              recovery_request?(request) ->
                approve_recovery_pairing(pairing_id, request, now)

              true ->
                approve_pairing(
                  pairing_id,
                  request,
                  node_name,
                  node_type,
                  capabilities,
                  now
                )
            end
        end
    end
  end

  defp approve_recovery_pairing(pairing_id, request, now) do
    if invite_repair?(request),
      do: approve_invite_repair(pairing_id, request, now),
      else: approve_legacy_recovery(pairing_id, request, now)
  end

  defp approve_legacy_recovery(pairing_id, request, now) do
    node_id = get_field(request, :node_id)

    case NodeStore.get_node(node_id) do
      node when is_map(node) ->
        node_name = normalize_name(get_field(node, :name))
        node_type = get_field(node, :type) || "generic"
        capabilities = get_field(node, :capabilities) || %{}
        {node_token, updated_node} = recovery_credential(request, node)

        with :ok <- NodeStore.reserve_node_name(node_name, node_id),
             :ok <- NodeStore.put_node(node_id, updated_node) do
          issue_challenge(
            pairing_id,
            request,
            node_id,
            node_name,
            node_type,
            capabilities,
            node_token,
            now,
            true
          )
        else
          {:error, {:name_taken, _name}} ->
            {:error, Errors.conflict("Node name is already in use")}

          {:error, reason} ->
            {:error, Errors.internal_error("Failed to recover node pairing", reason)}
        end

      _ ->
        {:error, Errors.conflict("Approved pairing node is no longer available")}
    end
  end
  defp approve_invite_repair(pairing_id, request, now) do
    with {:ok, node} when is_map(node) <- NodeStore.validate_repair_binding(request),
         node_id = get_field(request, :node_id),
         node_name = get_field(node, :name),
         :ok <- NodeStore.reserve_node_name(node_name, node_id) do
      {token, updated} = recovery_credential(request, node)
      updated = put_fields(updated, %{
        purpose: get_field(request, :purpose),
        labels: get_field(request, :labels) || %{},
        enrollment_invite_id: get_field(request, :invite_id)
      })

      case LemonCore.Store.compare_and_swap(:nodes_registry, node_id, node, updated) do
        :ok ->
          issue_challenge(pairing_id, request, node_id, node_name, get_field(node, :type),
            get_field(node, :capabilities) || %{}, token, now, true)

        {:error, :mismatch} ->
          {:error, Errors.unauthorized("Repair invitation generation is stale")}

        {:error, _} ->
          {:error, Errors.unavailable("Node repair store is unavailable")}
      end
    else
      {:error, :store_unavailable} -> {:error, Errors.unavailable("Node repair store is unavailable")}
      _ -> {:error, Errors.unauthorized("Repair invitation generation is stale")}
    end
  end


  defp approve_pairing(pairing_id, request, node_name, node_type, capabilities, now) do
    node_id = LemonCore.Id.uuid()

    case NodeStore.reserve_node_name(node_name, node_id) do
      :ok ->
        # Generate node ID and the compatibility token recorded on the durable
        # node. Authentication itself is issued by connect.challenge.
        node_token = generate_node_token()

        # Register node
        node = %{
          id: node_id,
          name: node_name,
          type: node_type,
          purpose: get_field(request, :purpose),
          labels: get_field(request, :labels) || %{},
          enrollment_invite_id: get_field(request, :invite_id),
          capabilities: capabilities,
          token_hash: hash_token(node_token),
          paired_at_ms: now,
          last_seen_ms: now,
          status: :offline
        }

        with :ok <- NodeStore.put_node(node_id, node) do
          event =
            LemonCore.Event.new(:node_pair_resolved, %{
              pairing_id: pairing_id,
              node_id: node_id,
              approved: true
            })

          LemonCore.Bus.broadcast("nodes", event)

          issue_challenge(
            pairing_id,
            request,
            node_id,
            node_name,
            node_type,
            capabilities,
            node_token,
            now,
            false
          )
        else
          {:error, _} ->
            {:error, Errors.unavailable("Node pairing store is unavailable")}
        end

      {:error, :invalid_name} ->
        {:error, Errors.invalid_request("Node name is required")}

      {:error, {:name_taken, _name}} ->
        {:error, Errors.conflict("Node name is already in use")}

      {:error, reason} ->
        {:error, Errors.internal_error("Failed to reserve node name", reason)}
    end
  end

  # Approval is intentionally recoverable. If the socket drops after approval,
  # or after connect.challenge consumed the prior one-time challenge but before
  # its response arrived, the authorized pairing client can request a fresh
  # challenge for the same durable node identity and name reservation.
  defp recover_approved_pairing(pairing_id, request, node_name, node_type, now) do
    node_id = get_field(request, :node_id)

    case is_binary(node_id) && NodeStore.get_node(node_id) do
      node when is_map(node) ->
        stored_name = get_field(node, :name)

        if stored_name == node_name do
          {node_token, updated_node} = recovery_credential(request, node)

          with :ok <- NodeStore.reserve_node_name(node_name, node_id),
               :ok <- NodeStore.put_node(node_id, updated_node) do
            issue_challenge(
              pairing_id,
              request,
              node_id,
              node_name,
              node_type,
              get_field(node, :capabilities) || %{},
              node_token,
              now,
              true
            )
          else
            {:error, reason} ->
              {:error, Errors.internal_error("Failed to recover node pairing", reason)}
          end
        else
          {:error, Errors.conflict("Approved pairing no longer matches its node name")}
        end

      _ ->
        {:error, Errors.conflict("Approved pairing node is no longer available")}
    end
  end

  defp issue_challenge(
         pairing_id,
         request,
         node_id,
         node_name,
         node_type,
         capabilities,
         node_token,
         now,
         recovered
       ) do
    old_challenge = get_field(request, :challenge_token)
    if is_binary(old_challenge), do: NodeStore.delete_challenge(old_challenge)

    challenge_token = generate_challenge_token()
    challenge_expires_at = now + 60_000

    updated_request =
      put_fields(request, %{
        status: :approved,
        node_id: node_id,
        challenge_token: challenge_token,
        challenge_expires_at_ms: challenge_expires_at
      })

    with {:ok, binding} <- challenge_binding(request, node_id, node_name),
         :ok <- NodeStore.put_pairing(pairing_id, updated_request),
         :ok <-
           NodeStore.put_challenge(challenge_token, %{
             node_id: node_id,
             node_name: node_name,
             node_type: node_type,
             pairing_id: pairing_id,
             expires_at_ms: challenge_expires_at,
             invite_id: get_field(request, :invite_id),
             generation_binding: binding
           }) do
      {:ok,
       %{
         "nodeId" => node_id,
         "challengeToken" => challenge_token,
         "approved" => true,
         "summary" => %{
           "pairingId" => pairing_id,
           "nodeId" => node_id,
           "approved" => true,
           "recovered" => recovered,
           "nodeType" => node_type,
           "challengeExpiresAtMs" => challenge_expires_at,
           "capabilityCount" => capability_count(capabilities),
           "credentialDelivery" => %{
             "includesNodeToken" => is_binary(node_token),
             "includesChallengeToken" => true
           },
           "cleanup" => %{
             "includesCapabilities" => false,
             "includesMetadata" => false,
             "includesStoredTokenHash" => false
           }
         }
       }
       |> maybe_put_node_token(node_token)}
    else
      {:error, :stale_session_generation} ->
        {:error, Errors.unauthorized("Node pairing generation is stale")}

      {:error, reason} ->
        {:error, Errors.internal_error("Failed to issue node pairing challenge", reason)}
    end
  end

  defp may_approve?(%{auth: %{role: :enrollment, identity: identity}}, request) do
    get_field(request, :status) in [:pending, "pending"] and
      is_binary(identity["inviteId"]) and identity["inviteId"] == get_field(request, :invite_id)
  end

  defp may_approve?(%{auth: %{role: :operator, scopes: scopes}}, _request),
    do: :pairing in scopes

  defp may_approve?(_ctx, _request), do: false

  defp capability_count(capabilities) when is_map(capabilities), do: map_size(capabilities)
  defp capability_count(_), do: 0

  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(_name), do: ""

  defp generate_node_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_challenge_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp invite_repair?(request),
    do: get_field(request, :recovery_mode) in [:invite_repair, "invite_repair"]

  defp challenge_binding(request, node_id, node_name) do
    case NodeStore.repair_binding(node_id, node_name) do
      {:ok, binding, _node} ->
        if invite_repair?(request) and
             binding.session_generation != get_field(request, :session_generation),
          do: {:error, :stale_session_generation},
          else: {:ok, Map.put(binding, :node_name, node_name)}

      {:error, _} = error -> error
    end
  end

  defp recovery_request?(request) do
    is_binary(get_field(request, :node_id)) and
      get_field(request, :recovery_mode) in [
        :recovery_token,
        "recovery_token",
        :operator_repair,
        "operator_repair",
        :invite_repair,
        "invite_repair"
      ]
  end

  defp recovery_credential(request, node) do
    if get_field(request, :recovery_mode) in [:recovery_token, "recovery_token"] do
      {nil, node}
    else
      token = generate_node_token()
      {token, put_fields(node, %{token_hash: hash_token(token)})}
    end
  end
  defp put_fields(record, fields) do
    record
    |> Map.drop(Enum.map(Map.keys(fields), &Atom.to_string/1))
    |> Map.merge(fields)
  end


  defp maybe_put_node_token(response, token) when is_binary(token),
    do: Map.put(response, "token", token)

  defp maybe_put_node_token(response, _token), do: response

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
