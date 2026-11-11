defmodule LemonControlPlane.ListenerPolicy do
  @moduledoc false

  alias LemonControlPlane.Auth.Authorize

  def remote_http_apis, do: Application.get_env(:lemon_control_plane, :remote_http_apis, [])

  def api_token(:openai) do
    normalize(Application.get_env(:lemon_control_plane, :openai_compat_api_token)) ||
      normalize(System.get_env("LEMON_OPENAI_COMPAT_API_TOKEN")) ||
      normalize(System.get_env("LEMON_OPENAI_COMPAT_TOKEN"))
  end

  def api_token(:acp) do
    normalize(Application.get_env(:lemon_control_plane, :acp_api_token)) ||
      normalize(System.get_env("LEMON_ACP_API_TOKEN"))
  end

  def validate do
    ip = Application.get_env(:lemon_control_plane, :ip, {127, 0, 0, 1})

    with :ok <- validate_operator_bind(ip, "control plane") do
      if Authorize.loopback_address?(ip) do
        :ok
      else
        case Enum.find(remote_http_apis(), &is_nil(api_token(&1))) do
          nil -> :ok
          api -> {:error, "Remote #{api} HTTP requires its dedicated API token"}
        end
      end
    end
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

  defp normalize(token) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      value -> value
    end
  end

  defp normalize(_), do: nil
end
