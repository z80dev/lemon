defmodule LemonChannels.Adapters.Discord.Inbound do
  @moduledoc """
  Inbound message normalization for Discord.

  Converts Nostrum message structs to LemonCore.InboundMessage format.
  """

  alias LemonCore.InboundMessage

  @doc """
  Normalize a Discord message to an InboundMessage.
  """
  @spec normalize(Nostrum.Struct.Message.t(), map()) ::
          {:ok, InboundMessage.t()} | {:error, term()}
  def normalize(msg, config \\ %{}) do
    account_id = config[:account_id] || config["account_id"] || "default"

    peer_kind = detect_peer_kind(msg)
    sender = build_sender(msg)
    {thread_id, effective_channel_id} = resolve_thread(msg)
    reply_to_id = extract_reply_to(msg)
    text = build_text_content(msg)

    inbound = %InboundMessage{
      channel_id: "discord",
      account_id: account_id,
      peer: %{
        kind: peer_kind,
        id: to_string(effective_channel_id),
        thread_id: thread_id
      },
      sender: sender,
      message: %{
        id: to_string(msg.id),
        text: text,
        timestamp: extract_timestamp(msg),
        reply_to_id: reply_to_id
      },
      raw: msg,
      meta: build_meta(msg)
    }

    {:ok, inbound}
  rescue
    e ->
      {:error, {:normalization_failed, e}}
  end

  # ============================================================================
  # Peer Kind Detection
  # ============================================================================

  defp detect_peer_kind(msg) do
    cond do
      # DM - no guild_id
      is_nil(msg.guild_id) ->
        :dm

      # Thread or forum post
      msg.thread != nil ->
        :group

      # Regular guild channel
      true ->
        :group
    end
  end

  # ============================================================================
  # Sender Building
  # ============================================================================

  defp build_sender(msg) do
    author = msg.author

    %{
      id: to_string(author.id),
      username: author.username,
      display_name: author.global_name || author.username
    }
  end

  # ============================================================================
  # Thread Resolution
  # ============================================================================

  defp resolve_thread(msg) do
    cond do
      # Message is in a thread - the channel_id IS the thread
      msg.thread != nil ->
        {to_string(msg.thread.id), msg.thread.parent_id || msg.channel_id}

      # Check if message type indicates it's a thread starter
      msg.type == 21 ->  # THREAD_STARTER_MESSAGE
        {to_string(msg.channel_id), msg.channel_id}

      # Regular message - no thread
      true ->
        {nil, msg.channel_id}
    end
  end

  # ============================================================================
  # Reply Extraction
  # ============================================================================

  defp extract_reply_to(msg) do
    case msg.message_reference do
      %{message_id: id} when not is_nil(id) ->
        to_string(id)

      _ ->
        nil
    end
  end

  # ============================================================================
  # Text Content Building
  # ============================================================================

  defp build_text_content(msg) do
    base = msg.content || ""

    # Include embed descriptions if present
    embed_text =
      (msg.embeds || [])
      |> Enum.map(&embed_to_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    # Include attachment info
    attachment_text =
      (msg.attachments || [])
      |> Enum.map(&attachment_to_text/1)
      |> Enum.join("\n")

    parts = [base]
    parts = if embed_text != "", do: parts ++ ["[Embeds]\n#{embed_text}"], else: parts
    parts = if attachment_text != "", do: parts ++ ["[Attachments]\n#{attachment_text}"], else: parts

    Enum.join(parts, "\n\n")
    |> String.trim()
  end

  defp embed_to_text(embed) do
    parts = []
    parts = if embed[:title], do: parts ++ ["**#{embed[:title]}**"], else: parts
    parts = if embed[:description], do: parts ++ [embed[:description]], else: parts
    parts = if embed[:url], do: parts ++ [embed[:url]], else: parts
    Enum.join(parts, "\n")
  end

  defp attachment_to_text(att) do
    filename = att.filename || "attachment"
    url = att.url || ""
    "#{filename}: #{url}"
  end

  # ============================================================================
  # Timestamp Extraction
  # ============================================================================

  defp extract_timestamp(msg) do
    case msg.timestamp do
      %DateTime{} = dt ->
        DateTime.to_unix(dt)

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> DateTime.to_unix(dt)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ============================================================================
  # Meta Building
  # ============================================================================

  defp build_meta(msg) do
    %{
      guild_id: msg.guild_id && to_string(msg.guild_id),
      channel_id: to_string(msg.channel_id),
      message_id: to_string(msg.id),
      message_type: msg.type,
      attachments: normalize_attachments(msg.attachments || []),
      embeds: normalize_embeds(msg.embeds || []),
      mentions: Enum.map(msg.mentions || [], &to_string(&1.id)),
      mention_roles: Enum.map(msg.mention_roles || [], &to_string/1),
      mention_everyone: msg.mention_everyone || false,
      pinned: msg.pinned || false,
      tts: msg.tts || false,
      referenced_message: msg.referenced_message,
      components: msg.components || []
    }
  end

  defp normalize_attachments(attachments) do
    Enum.map(attachments, fn att ->
      %{
        id: to_string(att.id),
        filename: att.filename,
        url: att.url,
        proxy_url: att.proxy_url,
        content_type: att.content_type,
        size: att.size,
        width: att[:width],
        height: att[:height]
      }
    end)
  end

  defp normalize_embeds(embeds) do
    Enum.map(embeds, fn embed ->
      %{
        title: embed[:title],
        description: embed[:description],
        url: embed[:url],
        color: embed[:color],
        author: embed[:author],
        footer: embed[:footer],
        image: embed[:image],
        thumbnail: embed[:thumbnail],
        fields: embed[:fields] || []
      }
    end)
  end
end
