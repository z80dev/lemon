defmodule LemonChannels.Adapters.XAPI do
  @moduledoc """
  X (Twitter) API v2 channel adapter for posting tweets.

  Authentication, token refresh, and HTTP calls live in `XApi`. This module
  keeps the `LemonChannels.Plugin` boundary and outbound payload delivery
  semantics.
  """

  @behaviour LemonChannels.Plugin

  alias LemonChannels.OutboundPayload

  @impl true
  def id, do: "x_api"

  @impl true
  def meta do
    %{
      label: "X (Twitter) API",
      capabilities: %{
        edit_support: true,
        delete_support: true,
        chunk_limit: 280,
        rate_limit: 2400,
        voice_support: false,
        image_support: true,
        file_support: false,
        reaction_support: false,
        thread_support: true
      },
      docs: "https://docs.x.com/x-api"
    }
  end

  @impl true
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker
    }
  end

  def start_link(_opts), do: :ignore

  @impl true
  def normalize_inbound(_raw) do
    {:error, :not_implemented}
  end

  @impl true
  def deliver(%OutboundPayload{kind: :text} = payload) do
    result =
      case payload.reply_to do
        nil -> XApi.Client.post_text(payload.content)
        reply_to -> XApi.Client.reply(reply_to, payload.content)
      end

    case result do
      {:ok, %{"data" => data}} ->
        {:ok, %{tweet_id: data["id"], text: data["text"]}}

      other ->
        other
    end
  end

  def deliver(%OutboundPayload{kind: :edit}) do
    {:error, :edit_not_supported}
  end

  def deliver(%OutboundPayload{kind: :delete} = payload) do
    tweet_id = get_tweet_id_from_meta(payload)

    with {:ok, _result} <- XApi.Client.delete_tweet(tweet_id) do
      {:ok, %{deleted: true, tweet_id: tweet_id}}
    end
  end

  def deliver(%OutboundPayload{kind: :file} = payload) do
    content = payload.content || %{}

    XApi.Client.post_media(
      content[:data] || content["data"],
      content[:mime_type] || content["mime_type"],
      content[:text] || content["text"] || "",
      reply_to: payload.reply_to
    )
  end

  @impl true
  def gateway_methods do
    [
      %{
        name: "x_api.post_tweet",
        scopes: [:agent],
        handler: __MODULE__.GatewayMethods
      },
      %{
        name: "x_api.get_mentions",
        scopes: [:agent],
        handler: __MODULE__.GatewayMethods
      },
      %{
        name: "x_api.reply_to_tweet",
        scopes: [:agent],
        handler: __MODULE__.GatewayMethods
      }
    ]
  end

  defdelegate config, to: XApi
  defdelegate configured?, to: XApi
  defdelegate search_configured?, to: XApi
  defdelegate auth_method, to: XApi

  defp get_tweet_id_from_meta(%OutboundPayload{meta: %{tweet_id: id}}), do: id
  defp get_tweet_id_from_meta(%OutboundPayload{meta: %{"tweet_id" => id}}), do: id
  defp get_tweet_id_from_meta(_), do: nil
end
