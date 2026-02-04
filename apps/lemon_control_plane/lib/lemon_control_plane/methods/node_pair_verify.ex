defmodule LemonControlPlane.Methods.NodePairVerify do
  @moduledoc """
  Handler for the node.pair.verify control plane method.

  Verifies a pairing code (called by the node during pairing).
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.pair.verify"

  @impl true
  def scopes, do: []  # No auth required - node uses code

  @impl true
  def handle(params, _ctx) do
    code = params["code"]

    if is_nil(code) or code == "" do
      {:error, Errors.invalid_request("code is required")}
    else
      # Find pairing by code
      pairing_id = LemonCore.Store.get(:nodes_pairing_by_code, code)

      case pairing_id && LemonCore.Store.get(:nodes_pairing, pairing_id) do
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
              {:ok, %{
                "valid" => false,
                "status" => "rejected"
              }}

            status == :approved or status == "approved" ->
              # Return the node credentials
              {:ok, %{
                "valid" => true,
                "status" => "approved",
                "pairingId" => pairing_id
              }}

            status == :pending or status == "pending" ->
              {:ok, %{
                "valid" => true,
                "status" => "pending",
                "pairingId" => pairing_id
              }}

            true ->
              {:ok, %{
                "valid" => false,
                "status" => to_string(status)
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
