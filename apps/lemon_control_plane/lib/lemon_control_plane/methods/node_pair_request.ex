defmodule LemonControlPlane.Methods.NodePairRequest do
  @moduledoc """
  Handler for the node.pair.request control plane method.

  Initiates a pairing request for a new node or rotates credentials for an
  existing durable node identity.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.pair.request"

  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(params, _ctx) do
    node_type = params["nodeType"] || params["node_type"] || "generic"
    node_name = params["nodeName"] || params["node_name"]
    capabilities = params["capabilities"] || %{}
    node_id = params["nodeId"] || params["node_id"]
    recovery_token = params["recoveryToken"] || params["recovery_token"]
    repair = params["repair"] == true

    with {:ok, identity} <-
           pairing_identity(node_id, node_name, node_type, capabilities, recovery_token, repair) do
      pairing_code = generate_pairing_code()
      pairing_id = LemonCore.Id.uuid()
      # 5 minutes
      expires_at_ms = System.system_time(:millisecond) + 300_000

      request = %{
        id: pairing_id,
        code: pairing_code,
        node_type: identity.node_type,
        node_name: identity.node_name,
        capabilities: identity.capabilities,
        node_id: identity.node_id,
        recovery_mode: identity.recovery_mode,
        status: :pending,
        expires_at_ms: expires_at_ms,
        created_at_ms: System.system_time(:millisecond)
      }

      # Store pairing request
      NodeStore.put_pairing(pairing_id, request)
      NodeStore.put_pairing_code(pairing_code, pairing_id)

      # Broadcast event
      event =
        LemonCore.Event.new(:node_pair_requested, %{
          pairing_id: pairing_id,
          code: pairing_code,
          node_type: identity.node_type,
          node_name: identity.node_name,
          expires_at_ms: expires_at_ms
        })

      LemonCore.Bus.broadcast("nodes", event)

      {:ok,
       %{
         "pairingId" => pairing_id,
         "code" => pairing_code,
         "expiresAtMs" => expires_at_ms,
         "summary" => %{
           "pairingId" => pairing_id,
           "nodeType" => identity.node_type,
           "nodeId" => identity.node_id,
           "recovered" => not is_nil(identity.node_id),
           "expiresAtMs" => expires_at_ms,
           "capabilityCount" => capability_count(identity.capabilities),
           "credentialDelivery" => %{
             "includesPairingCode" => true
           },
           "cleanup" => %{
             "includesCapabilities" => false,
             "includesApprovedTokens" => false,
             "includesChallengeTokens" => false,
             "includesSecretValues" => false
           }
         }
       }}
    end
  end

  defp pairing_identity(nil, node_name, node_type, capabilities, nil, false) do
    case normalize_name(node_name) do
      "" -> {:error, Errors.invalid_request("nodeName is required")}
      name -> {:ok, identity(nil, name, node_type, capabilities, nil)}
    end
  end

  defp pairing_identity(node_id, _node_name, _node_type, _capabilities, recovery_token, repair)
       when is_binary(node_id) and node_id != "" do
    case NodeStore.get_node(node_id) do
      node when is_map(node) ->
        cond do
          repair ->
            recovered_identity(node_id, node, :operator_repair)

          valid_recovery_token?(node, recovery_token) ->
            recovered_identity(node_id, node, :recovery_token)

          true ->
            {:error, Errors.unauthorized("Node recovery credential is invalid")}
        end

      _ ->
        {:error, Errors.not_found("Node recovery identity was not found")}
    end
  end

  defp pairing_identity(nil, _node_name, _node_type, _capabilities, recovery_token, _repair)
       when is_binary(recovery_token),
       do: {:error, Errors.invalid_request("nodeId is required for node recovery")}

  defp pairing_identity(_node_id, _node_name, _node_type, _capabilities, _token, _repair),
    do: {:error, Errors.invalid_request("node recovery parameters are invalid")}

  defp recovered_identity(node_id, node, mode) do
    node_name = normalize_name(get_field(node, :name))

    if node_name == "" do
      {:error, Errors.conflict("Node recovery identity has no durable name")}
    else
      {:ok,
       identity(
         node_id,
         node_name,
         get_field(node, :type) || "generic",
         get_field(node, :capabilities) || %{},
         mode
       )}
    end
  end

  defp identity(node_id, node_name, node_type, capabilities, recovery_mode) do
    %{
      node_id: node_id,
      node_name: node_name,
      node_type: node_type,
      capabilities: capabilities,
      recovery_mode: recovery_mode
    }
  end

  defp valid_recovery_token?(node, token) when is_binary(token) and token != "" do
    expected_hash = get_field(node, :token_hash)
    provided_hash = hash_token(token)

    is_binary(expected_hash) and byte_size(expected_hash) == byte_size(provided_hash) and
      Plug.Crypto.secure_compare(expected_hash, provided_hash)
  end

  defp valid_recovery_token?(_node, _token), do: false

  defp hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(_name), do: ""

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp capability_count(capabilities) when is_map(capabilities), do: map_size(capabilities)
  defp capability_count(_), do: 0

  defp generate_pairing_code do
    # Generate a 6-digit numeric code
    (:rand.uniform(899_999) + 100_000)
    |> Integer.to_string()
  end
end
