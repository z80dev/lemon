defmodule LemonControlPlane.Methods.NodePairVerify do
  @moduledoc """
  Handler for the node.pair.verify control plane method.

  Verifies a pairing code (called by the node during pairing).
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.pair.verify"

  @impl true
  # No auth required - node uses code
  def scopes, do: []

  @impl true
  def handle(params, _ctx) do
    code = params["code"]

    if is_nil(code) or code == "" do
      {:error, Errors.invalid_request("code is required")}
    else
      # Find pairing by code
      pairing_id = NodeStore.get_pairing_id_by_code(code)

      case pairing_id && NodeStore.get_pairing(pairing_id) do
        nil ->
          {:error, Errors.not_found("Invalid pairing code")}

        request ->
          now = System.system_time(:millisecond)

          # Safe access supporting both atom and string keys (for JSONL reload)
          expires_at_ms = get_field(request, :expires_at_ms)
          status = get_field(request, :status)

          cond do
            expires_at_ms && expires_at_ms < now ->
              {:error, Errors.invalid_request("Pairing code has expired")}

            status == :rejected or status == "rejected" ->
              {:ok, response(false, "rejected")}

            status == :approved or status == "approved" ->
              # Return the node credentials
              {:ok, response(true, "approved", pairing_id)}

            status == :pending or status == "pending" ->
              {:ok, response(true, "pending", pairing_id)}

            true ->
              {:ok, response(false, to_string(status))}
          end
      end
    end
  end

  defp response(valid, status, pairing_id \\ nil) do
    %{
      "valid" => valid,
      "status" => status,
      "summary" => %{
        "valid" => valid,
        "status" => status,
        "hasPairingId" => not is_nil(pairing_id),
        "cleanup" => %{
          "includesPairingCode" => false,
          "includesApprovedTokens" => false,
          "includesChallengeTokens" => false,
          "includesSecretValues" => false
        }
      }
    }
    |> maybe_put_pairing_id(pairing_id)
  end

  defp maybe_put_pairing_id(response, nil), do: response
  defp maybe_put_pairing_id(response, pairing_id), do: Map.put(response, "pairingId", pairing_id)

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
