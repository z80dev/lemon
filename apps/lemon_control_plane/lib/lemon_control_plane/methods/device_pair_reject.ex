defmodule LemonControlPlane.Methods.DevicePairReject do
  @moduledoc """
  Handler for the device.pair.reject control plane method.

  Rejects a pending device pairing request.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.Bus

  @impl true
  def name, do: "device.pair.reject"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    pairing_id = params["pairingId"]

    if is_nil(pairing_id) or pairing_id == "" do
      {:error, Errors.invalid_request("pairingId is required")}
    else
      case LemonCore.Store.get(:device_pairing, pairing_id) do
        nil ->
          {:error, Errors.not_found("Pairing request not found")}

        pairing ->
          # Safe access supporting both atom and string keys (for JSONL reload)
          status = get_field(pairing, :status)
          device_type = get_field(pairing, :device_type)
          device_name = get_field(pairing, :device_name)

          if status != :pending and status != "pending" do
            {:error, Errors.conflict("Pairing request already resolved")}
          else
            now = System.system_time(:millisecond)

            updated = Map.merge(pairing, %{
              status: :rejected,
              rejected_at_ms: now
            })

            LemonCore.Store.put(:device_pairing, pairing_id, updated)

            # Emit event
            Bus.broadcast("system", %LemonCore.Event{
              type: :device_pair_resolved,
              ts_ms: now,
              payload: %{
                pairing_id: pairing_id,
                status: :rejected,
                device_type: device_type,
                device_name: device_name
              }
            })

            {:ok, %{"success" => true}}
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
