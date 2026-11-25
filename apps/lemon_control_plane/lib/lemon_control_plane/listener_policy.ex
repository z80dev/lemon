defmodule LemonControlPlane.ListenerPolicy do
  @moduledoc false

  alias LemonControlPlane.Auth.Authorize

  def validate do
    ip = Application.get_env(:lemon_control_plane, :ip, {127, 0, 0, 1})
    validate_operator_bind(ip, "control plane")
  end

  def validate_operator_bind(ip, listener) do
    cond do
      Authorize.loopback_address?(ip) ->
        :ok

      is_nil(Authorize.configured_operator_token()) ->
        {:error, "Non-loopback #{listener} bind requires LEMON_CONTROL_PLANE_OPERATOR_TOKEN"}

      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false) ->
        {:error,
         "Non-loopback #{listener} bind is incompatible with LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK"}

      true ->
        :ok
    end
  end
end
