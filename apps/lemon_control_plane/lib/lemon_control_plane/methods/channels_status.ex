defmodule LemonControlPlane.Methods.ChannelsStatus do
  @moduledoc """
  Handler for the channels.status method.

  Returns the status of all configured channel adapters.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "channels.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    channels = get_channels_status()
    {:ok, %{"channels" => channels}}
  end

  defp get_channels_status do
    if Code.ensure_loaded?(LemonChannels.Registry) do
      case LemonChannels.Registry.list() do
        adapters when is_list(adapters) ->
          Enum.map(adapters, &format_channel_status/1)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp format_channel_status({channel_id, adapter_info}) do
    %{
      "channelId" => channel_id,
      "type" => to_string(adapter_info[:type] || :unknown),
      "status" => to_string(adapter_info[:status] || :unknown),
      "accountId" => adapter_info[:account_id],
      "capabilities" => adapter_info[:capabilities] || %{}
    }
  end

  defp format_channel_status(adapter) when is_map(adapter) do
    %{
      "channelId" => adapter[:channel_id] || adapter[:id],
      "type" => to_string(adapter[:type] || :unknown),
      "status" => to_string(adapter[:status] || :unknown),
      "accountId" => adapter[:account_id],
      "capabilities" => adapter[:capabilities] || %{}
    }
  end

end
