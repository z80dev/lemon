defmodule LemonControlPlane.Methods.NodePairReject do
  @moduledoc """
  Handler for the node.pair.reject control plane method.

  Rejects a pending pairing request.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.pair.reject"

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
            # Safe access supporting both atom and string keys (for JSONL reload)
            status = get_field(request, :status)

            if status != :pending and status != "pending" do
              {:error, Errors.invalid_request("Pairing request is not pending")}
            else
              # Update pairing request using Map.merge (handles both atom and string keys)
              updated_request = Map.merge(request, %{status: :rejected})
              LemonCore.Store.put(:nodes_pairing, pairing_id, updated_request)

              # Broadcast event
              event = LemonCore.Event.new(:node_pair_resolved, %{
                pairing_id: pairing_id,
                approved: false,
                rejected: true
              })
              LemonCore.Bus.broadcast("nodes", event)

              {:ok, %{
                "pairingId" => pairing_id,
                "rejected" => true
              }}
            end
        end
    end
  end

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
