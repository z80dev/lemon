defmodule LemonControlPlane.Methods.DevicePairRequest do
  @moduledoc """
  Handler for the device.pair.request control plane method.

  Initiates device pairing for mobile/desktop clients.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.{Bus, Id}

  @impl true
  def name, do: "device.pair.request"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    device_type = params["deviceType"]
    device_name = params["deviceName"]
    expires_in_ms = params["expiresInMs"] || 300_000

    cond do
      is_nil(device_type) or device_type == "" ->
        {:error, Errors.invalid_request("deviceType is required")}

      is_nil(device_name) or device_name == "" ->
        {:error, Errors.invalid_request("deviceName is required")}

      true ->
        pairing_id = Id.uuid()
        code = generate_pairing_code()
        expires_at = System.system_time(:millisecond) + expires_in_ms

        pairing = %{
          id: pairing_id,
          device_type: device_type,
          device_name: device_name,
          code: code,
          status: :pending,
          created_at_ms: System.system_time(:millisecond),
          expires_at_ms: expires_at
        }

        LemonCore.Store.put(:device_pairing, pairing_id, pairing)

        # Emit event
        Bus.broadcast("system", %LemonCore.Event{
          type: :device_pair_requested,
          ts_ms: System.system_time(:millisecond),
          payload: %{
            pairing_id: pairing_id,
            device_type: device_type,
            device_name: device_name
          }
        })

        {:ok, %{
          "pairingId" => pairing_id,
          "code" => code,
          "expiresAt" => expires_at
        }}
    end
  end

  defp generate_pairing_code do
    # Generate a 6-digit numeric code
    :rand.uniform(999_999)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
