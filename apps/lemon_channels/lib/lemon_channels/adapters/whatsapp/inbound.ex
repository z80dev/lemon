defmodule LemonChannels.Adapters.WhatsApp.Inbound do
  @moduledoc """
  Inbound message normalization for WhatsApp.

  Converts bridge message events (JSON-decoded maps with string keys) into
  `LemonCore.InboundMessage` structs.
  """

  require Logger

  alias LemonCore.InboundMessage

  @doc """
  Normalize a raw WhatsApp bridge event to an InboundMessage.

  Bridge events are maps with string keys from JSON decoding bridge stdout.
  Only events with `"type" => "message"` and `"from_me" => false` are accepted.
  """
  @spec normalize(term()) :: {:ok, InboundMessage.t()} | {:error, term()}
  def normalize(%{"type" => "message"} = event) do
    Logger.debug(
      "WhatsApp inbound normalizing message: message_id=#{event["message_id"]} " <>
        "jid=#{event["jid"]}"
    )

    normalize_message(event)
  end

  def normalize(%{"type" => type} = event) when is_binary(type) do
    Logger.debug(
      "WhatsApp inbound skipping non-message event: type=#{type} " <>
        "keys=#{inspect(Map.keys(event))}"
    )

    {:error, :unsupported_event_type}
  end

  def normalize(event) when is_map(event) do
    Logger.warning("WhatsApp inbound unsupported event (no type): #{inspect(Map.keys(event))}")
    {:error, :unsupported_event_type}
  end

  def normalize(event) do
    Logger.warning("WhatsApp inbound unsupported non-map event: #{inspect(event)}")
    {:error, :unsupported_event_type}
  end

  defp normalize_message(event) do
    from_me = event["from_me"] || false

    if from_me do
      Logger.debug(
        "WhatsApp inbound skipping from_me message: message_id=#{event["message_id"]}"
      )

      {:error, :from_me}
    else
      build_inbound(event)
    end
  end

  defp build_inbound(event) do
    jid = event["jid"]
    sender_jid = event["sender_jid"] || jid
    sender_name = event["sender_name"]
    message_id = event["message_id"]
    timestamp = event["timestamp"]
    is_group = event["is_group"] || false
    text = event["text"] || ""
    reply_to_id = event["reply_to_id"]
    reply_to_text = event["reply_to_text"]
    mentioned_jids = event["mentioned_jids"] || []
    media_type = event["media_type"]
    media_path = event["media_path"]
    media_mime = event["media_mime"]

    peer_kind = if is_group, do: :group, else: :dm

    routing_hint = "whatsapp:default:#{peer_kind}:#{jid}"

    Logger.debug(
      "WhatsApp inbound routing hint generated: routing_hint=#{routing_hint} " <>
        "peer_kind=#{peer_kind} sender_jid=#{sender_jid}"
    )

    sender = %{
      id: to_string(sender_jid),
      username: phone_from_jid(sender_jid),
      display_name: sender_name
    }

    inbound = %InboundMessage{
      channel_id: "whatsapp",
      account_id: "default",
      peer: %{
        kind: peer_kind,
        id: to_string(jid),
        thread_id: nil
      },
      sender: sender,
      message: %{
        id: message_id && to_string(message_id),
        text: text,
        timestamp: timestamp,
        reply_to_id: reply_to_id && to_string(reply_to_id)
      },
      raw: event,
      meta: %{
        chat_id: jid,
        user_msg_id: message_id,
        is_group: is_group,
        mentioned_jids: mentioned_jids,
        media_type: media_type,
        media_path: media_path,
        media_mime: media_mime,
        from_me: false,
        reply_to_text: reply_to_text,
        sender_jid: sender_jid
      }
    }

    Logger.debug(
      "WhatsApp inbound normalized successfully: message_id=#{message_id} " <>
        "text_length=#{String.length(text)} peer_kind=#{peer_kind} " <>
        "has_media=#{not is_nil(media_type)}"
    )

    {:ok, inbound}
  end

  @doc """
  Extracts the phone number from a WhatsApp JID.

  JIDs are typically in the form `phone@s.whatsapp.net` for DMs or
  `phone-timestamp@g.us` for groups. Returns the local part before `@`.
  """
  @spec phone_from_jid(binary() | nil) :: binary() | nil
  def phone_from_jid(nil), do: nil

  def phone_from_jid(jid) when is_binary(jid) do
    case String.split(jid, "@", parts: 2) do
      [local, _domain] when local != "" -> local
      _ -> jid
    end
  end

  def phone_from_jid(_), do: nil
end
