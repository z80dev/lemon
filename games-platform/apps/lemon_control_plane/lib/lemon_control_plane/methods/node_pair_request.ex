defmodule LemonControlPlane.Methods.NodePairRequest do
  @moduledoc """
  Handler for the node.pair.request control plane method.

  Initiates a pairing request for a new node.
  """

  @behaviour LemonControlPlane.Method

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

    if is_nil(node_name) or node_name == "" do
      {:error, Errors.invalid_request("nodeName is required")}
    else
      pairing_code = generate_pairing_code()
      pairing_id = LemonCore.Id.uuid()
      expires_at_ms = System.system_time(:millisecond) + 300_000  # 5 minutes

      request = %{
        id: pairing_id,
        code: pairing_code,
        node_type: node_type,
        node_name: node_name,
        capabilities: capabilities,
        status: :pending,
        expires_at_ms: expires_at_ms,
        created_at_ms: System.system_time(:millisecond)
      }

      # Store pairing request
      LemonCore.Store.put(:nodes_pairing, pairing_id, request)
      LemonCore.Store.put(:nodes_pairing_by_code, pairing_code, pairing_id)

      # Broadcast event
      event = LemonCore.Event.new(:node_pair_requested, %{
        pairing_id: pairing_id,
        code: pairing_code,
        node_type: node_type,
        node_name: node_name,
        expires_at_ms: expires_at_ms
      })
      LemonCore.Bus.broadcast("nodes", event)

      {:ok, %{
        "pairingId" => pairing_id,
        "code" => pairing_code,
        "expiresAtMs" => expires_at_ms
      }}
    end
  end

  defp generate_pairing_code do
    # Generate a 6-digit numeric code
    :rand.uniform(899_999) + 100_000
    |> Integer.to_string()
  end
end
