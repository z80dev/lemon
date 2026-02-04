defmodule LemonControlPlane.Methods.DevicePairApprove do
  @moduledoc """
  Handler for the device.pair.approve control plane method.

  Approves a pending device pairing request.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.Bus

  @impl true
  def name, do: "device.pair.approve"

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
          now = System.system_time(:millisecond)

          # Safe access supporting both atom and string keys (for JSONL reload)
          status = get_field(pairing, :status)
          expires_at_ms = get_field(pairing, :expires_at_ms)
          device_type = get_field(pairing, :device_type)
          device_name = get_field(pairing, :device_name)

          cond do
            status != :pending and status != "pending" ->
              {:error, Errors.conflict("Pairing request already resolved")}

            expires_at_ms < now ->
              {:error, Errors.timeout("Pairing request has expired")}

            true ->
              # Generate device token and challenge token
              device_token = generate_device_token()
              challenge_token = generate_challenge_token()
              challenge_expires_at = now + 60_000  # Challenge valid for 1 minute

              updated = Map.merge(pairing, %{
                status: :approved,
                device_token: device_token,
                challenge_token: challenge_token,
                approved_at_ms: now
              })

              LemonCore.Store.put(:device_pairing, pairing_id, updated)

              # Store device registration
              LemonCore.Store.put(:devices, device_token, %{
                device_type: device_type,
                device_name: device_name,
                pairing_id: pairing_id,
                created_at_ms: now
              })

              # Store challenge for connect.challenge verification
              LemonCore.Store.put(:device_pairing_challenges, challenge_token, %{
                device_id: device_token,
                device_name: device_name,
                device_type: device_type,
                pairing_id: pairing_id,
                expires_at_ms: challenge_expires_at
              })

              # Emit event
              Bus.broadcast("system", %LemonCore.Event{
                type: :device_pair_resolved,
                ts_ms: now,
                payload: %{
                  pairing_id: pairing_id,
                  status: :approved,
                  device_type: device_type,
                  device_name: device_name
                }
              })

              {:ok, %{
                "success" => true,
                "deviceToken" => device_token,
                "challengeToken" => challenge_token
              }}
          end
      end
    end
  end

  defp generate_device_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp generate_challenge_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
