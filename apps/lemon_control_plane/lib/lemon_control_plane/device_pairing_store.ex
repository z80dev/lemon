defmodule LemonControlPlane.DevicePairingStore do
  @moduledoc """
  Typed wrapper for device pairing state, registrations, and challenges.
  """

  alias LemonCore.Store

  @pairing_table :device_pairing
  @device_table :devices
  @challenge_table :device_pairing_challenges

  @spec get_pairing(binary()) :: map() | nil
  def get_pairing(pairing_id) when is_binary(pairing_id),
    do: Store.get(@pairing_table, pairing_id)

  @spec put_pairing(binary(), map()) :: :ok
  def put_pairing(pairing_id, value) when is_binary(pairing_id) and is_map(value),
    do: Store.put(@pairing_table, pairing_id, value)

  @spec put_device(binary(), map()) :: :ok
  def put_device(device_token, value) when is_binary(device_token) and is_map(value),
    do: Store.put(@device_table, device_token, value)

  @spec get_challenge(binary()) :: map() | nil
  def get_challenge(token) when is_binary(token), do: Store.get(@challenge_table, token)

  @spec put_challenge(binary(), map()) :: :ok
  def put_challenge(token, value) when is_binary(token) and is_map(value),
    do: Store.put(@challenge_table, token, value)

  @spec delete_challenge(binary()) :: :ok
  def delete_challenge(token) when is_binary(token), do: Store.delete(@challenge_table, token)
end
