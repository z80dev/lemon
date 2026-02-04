defmodule LemonControlPlane.Methods.ChannelsLogout do
  @moduledoc """
  Handler for the channels.logout method.

  Disconnects and logs out a channel adapter.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "channels.logout"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    channel_id = params["channelId"]

    if is_nil(channel_id) do
      {:error, {:invalid_request, "channelId is required", nil}}
    else
      case logout_channel(channel_id) do
        :ok ->
          {:ok, %{"success" => true, "channelId" => channel_id}}

        {:error, :not_found} ->
          {:error, {:not_found, "Channel not found", channel_id}}

        {:error, reason} ->
          {:error, {:internal_error, "Failed to logout", reason}}
      end
    end
  end

  defp logout_channel(channel_id) do
    # Try LemonChannels.Registry first
    if Code.ensure_loaded?(LemonChannels.Registry) and
       function_exported?(LemonChannels.Registry, :logout, 1) do
      LemonChannels.Registry.logout(channel_id)
    else
      # No channel registry available
      {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end
end
