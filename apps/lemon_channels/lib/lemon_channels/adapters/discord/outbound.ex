defmodule LemonChannels.Adapters.Discord.Outbound do
  @moduledoc """
  Outbound message delivery for Discord.

  Handles delivering OutboundPayload to Discord via Nostrum API.
  Supports text, edit, delete, reactions, files, embeds, typing, and components.
  """

  alias LemonChannels.OutboundPayload

  require Logger

  @doc """
  Deliver an outbound payload to Discord.
  """
  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}

  # ============================================================================
  # Text Messages
  # ============================================================================

  def deliver(%OutboundPayload{kind: :text} = payload) do
    channel_id = parse_id(payload.peer.id)
    content = payload.content

    opts = build_message_opts(payload)

    case Nostrum.Api.Message.create(channel_id, [{:content, content} | opts]) do
      {:ok, msg} ->
        {:ok, %{message_id: to_string(msg.id), channel_id: to_string(msg.channel_id)}}

      {:error, reason} ->
        Logger.warning("Discord: Failed to send message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Edit Messages
  # ============================================================================

  def deliver(%OutboundPayload{kind: :edit, content: %{message_id: msg_id, text: text}} = payload) do
    channel_id = parse_id(payload.peer.id)
    message_id = parse_id(msg_id)

    case Nostrum.Api.Message.edit(channel_id, message_id, content: text) do
      {:ok, msg} ->
        {:ok, %{message_id: to_string(msg.id)}}

      {:error, reason} ->
        Logger.warning("Discord: Failed to edit message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Delete Messages
  # ============================================================================

  def deliver(%OutboundPayload{kind: :delete, content: %{message_id: msg_id}} = payload) do
    channel_id = parse_id(payload.peer.id)
    message_id = parse_id(msg_id)

    case Nostrum.Api.Message.delete(channel_id, message_id) do
      {:ok} ->
        {:ok, :deleted}

      {:error, reason} ->
        Logger.warning("Discord: Failed to delete message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Reactions
  # ============================================================================

  def deliver(%OutboundPayload{kind: :reaction, content: %{message_id: msg_id, emoji: emoji}} = payload) do
    channel_id = parse_id(payload.peer.id)
    message_id = parse_id(msg_id)

    # Emoji can be unicode or custom format "name:id"
    case Nostrum.Api.Message.react(channel_id, message_id, emoji) do
      {:ok} ->
        {:ok, :reacted}

      {:error, reason} ->
        Logger.warning("Discord: Failed to add reaction: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Files
  # ============================================================================

  def deliver(%OutboundPayload{kind: :file, content: content} = payload) do
    channel_id = parse_id(payload.peer.id)

    {files, opts} = build_file_opts(content, payload)

    case Nostrum.Api.Message.create(channel_id, [{:files, files} | opts]) do
      {:ok, msg} ->
        {:ok, %{message_id: to_string(msg.id)}}

      {:error, reason} ->
        Logger.warning("Discord: Failed to send file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Embeds
  # ============================================================================

  def deliver(%OutboundPayload{kind: :embed, content: embed_content} = payload) do
    channel_id = parse_id(payload.peer.id)

    embed = build_embed(embed_content)
    opts = build_message_opts(payload)

    case Nostrum.Api.Message.create(channel_id, [{:embeds, [embed]} | opts]) do
      {:ok, msg} ->
        {:ok, %{message_id: to_string(msg.id)}}

      {:error, reason} ->
        Logger.warning("Discord: Failed to send embed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Typing Indicator
  # ============================================================================

  def deliver(%OutboundPayload{kind: :typing} = payload) do
    channel_id = parse_id(payload.peer.id)

    case Nostrum.Api.Channel.start_typing(channel_id) do
      {:ok} ->
        {:ok, :typing}

      {:error, reason} ->
        Logger.debug("Discord: Failed to trigger typing: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Components (Buttons)
  # ============================================================================

  def deliver(%OutboundPayload{kind: :components, content: content} = payload) do
    channel_id = parse_id(payload.peer.id)

    text = content[:text] || ""
    components = build_components(content[:components] || [])
    opts = build_message_opts(payload)

    message_opts = [{:content, text}, {:components, components} | opts]

    case Nostrum.Api.Message.create(channel_id, message_opts) do
      {:ok, msg} ->
        {:ok, %{message_id: to_string(msg.id)}}

      {:error, reason} ->
        Logger.warning("Discord: Failed to send components: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Voice (placeholder)
  # ============================================================================

  def deliver(%OutboundPayload{kind: :voice} = _payload) do
    # Voice delivery is handled separately via Discord.Voice module
    {:error, :use_voice_module}
  end

  # ============================================================================
  # Fallback
  # ============================================================================

  def deliver(%OutboundPayload{kind: kind}) do
    {:error, {:unsupported_kind, kind}}
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp parse_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_id(id) when is_integer(id), do: id

  defp build_message_opts(payload) do
    opts = []

    # Reply reference
    opts =
      if payload.reply_to do
        message_ref = %{message_id: parse_id(payload.reply_to)}
        [{:message_reference, message_ref} | opts]
      else
        opts
      end

    # Thread handling - if peer has thread_id, post to thread
    opts =
      if payload.peer[:thread_id] do
        # For threads, the channel_id in the API call should be the thread_id
        opts
      else
        opts
      end

    opts
  end

  defp build_file_opts(content, payload) do
    path = content[:path]
    url = content[:url]
    data = content[:data]
    filename = content[:filename] || "file"
    caption = content[:caption]

    files =
      cond do
        path && File.exists?(path) ->
          [path]

        data && is_binary(data) ->
          [{filename, data}]

        url ->
          # Download file from URL first
          case download_file(url) do
            {:ok, data} -> [{filename, data}]
            {:error, _} -> []
          end

        true ->
          []
      end

    opts = build_message_opts(payload)
    opts = if caption, do: [{:content, caption} | opts], else: opts

    {files, opts}
  end

  defp download_file(url) do
    case :httpc.request(:get, {to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_embed(content) when is_map(content) do
    embed = %{}

    embed = if content[:title], do: Map.put(embed, :title, content[:title]), else: embed
    embed = if content[:description], do: Map.put(embed, :description, content[:description]), else: embed
    embed = if content[:url], do: Map.put(embed, :url, content[:url]), else: embed
    embed = if content[:color], do: Map.put(embed, :color, parse_color(content[:color])), else: embed
    embed = if content[:timestamp], do: Map.put(embed, :timestamp, content[:timestamp]), else: embed

    embed =
      if content[:author] do
        Map.put(embed, :author, %{
          name: content[:author][:name],
          url: content[:author][:url],
          icon_url: content[:author][:icon_url]
        })
      else
        embed
      end

    embed =
      if content[:footer] do
        Map.put(embed, :footer, %{
          text: content[:footer][:text],
          icon_url: content[:footer][:icon_url]
        })
      else
        embed
      end

    embed =
      if content[:image] do
        Map.put(embed, :image, %{url: content[:image][:url] || content[:image]})
      else
        embed
      end

    embed =
      if content[:thumbnail] do
        Map.put(embed, :thumbnail, %{url: content[:thumbnail][:url] || content[:thumbnail]})
      else
        embed
      end

    embed =
      if content[:fields] do
        fields = Enum.map(content[:fields], fn field ->
          %{
            name: field[:name] || "",
            value: field[:value] || "",
            inline: field[:inline] || false
          }
        end)
        Map.put(embed, :fields, fields)
      else
        embed
      end

    embed
  end

  defp parse_color(color) when is_integer(color), do: color
  defp parse_color("#" <> hex), do: String.to_integer(hex, 16)
  defp parse_color(color) when is_binary(color), do: String.to_integer(color, 16)
  defp parse_color(_), do: nil

  defp build_components(components) when is_list(components) do
    # Components are organized in action rows
    # Each action row can contain buttons or other components
    Enum.map(components, fn
      %{type: :action_row, components: row_components} ->
        %{
          type: 1,  # ACTION_ROW
          components: Enum.map(row_components, &build_component/1)
        }

      # Single button - wrap in action row
      %{type: :button} = button ->
        %{
          type: 1,
          components: [build_component(button)]
        }

      # Already formatted component
      component when is_map(component) ->
        component
    end)
  end

  defp build_component(%{type: :button} = button) do
    %{
      type: 2,  # BUTTON
      style: button_style(button[:style] || :primary),
      label: button[:label],
      custom_id: button[:custom_id],
      emoji: button[:emoji],
      url: button[:url],
      disabled: button[:disabled] || false
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp build_component(component), do: component

  defp button_style(:primary), do: 1
  defp button_style(:secondary), do: 2
  defp button_style(:success), do: 3
  defp button_style(:danger), do: 4
  defp button_style(:link), do: 5
  defp button_style(style) when is_integer(style), do: style
  defp button_style(_), do: 1
end
