defmodule LemonChannels.Adapters.Telegram.Inbound do
  @moduledoc """
  Inbound message normalization for Telegram.
  """

  require Logger

  alias LemonCore.InboundMessage

  @doc """
  Normalize a raw Telegram update to an InboundMessage.
  """
  @spec normalize(term()) :: {:ok, InboundMessage.t()} | {:error, term()}
  def normalize(%{"message" => message} = update) do
    Logger.debug("Telegram inbound normalizing message: message_id=#{message["message_id"]}")
    normalize_message(message, update)
  end

  def normalize(%{"edited_message" => message} = update) do
    Logger.debug(
      "Telegram inbound normalizing edited_message: message_id=#{message["message_id"]}"
    )

    normalize_message(message, update)
  end

  def normalize(%{"channel_post" => message} = update) do
    Logger.debug("Telegram inbound normalizing channel_post: message_id=#{message["message_id"]}")
    normalize_message(message, update)
  end

  def normalize(update) when is_map(update) do
    Logger.warning("Telegram inbound unsupported update type: #{inspect(Map.keys(update))}")
    {:error, :unsupported_update_type}
  end

  def normalize(update) do
    Logger.warning("Telegram inbound unsupported non-map update: #{inspect(update)}")
    {:error, :unsupported_update_type}
  end

  defp normalize_message(message, update) do
    if forum_topic_created_message?(message) do
      Logger.debug("Telegram inbound skipping forum_topic_created message")
      {:error, :forum_topic_created}
    else
      chat = message["chat"]
      from = message["from"]
      chat_id = chat["id"]
      message_id = message["message_id"]

      Logger.debug(
        "Telegram inbound parsing message: chat_id=#{chat_id} message_id=#{message_id} " <>
          "chat_type=#{chat["type"]}"
      )

      peer_kind =
        case chat["type"] do
          "private" -> :dm
          "group" -> :group
          "supergroup" -> :group
          "channel" -> :channel
          _ -> :dm
        end

      sender =
        if from do
          %{
            id: to_string(from["id"]),
            username: from["username"],
            display_name:
              [from["first_name"], from["last_name"]]
              |> Enum.filter(& &1)
              |> Enum.join(" ")
          }
        else
          nil
        end

      text = message["text"] || message["caption"] || ""
      voice = message["voice"] || %{}
      document = message["document"] || %{}
      photo = select_photo(message["photo"])

      routing_hint = "telegram:default:#{peer_kind}:#{chat["id"]}"

      Logger.debug(
        "Telegram inbound routing hint generated: routing_hint=#{routing_hint} " <>
          "peer_kind=#{peer_kind} sender_id=#{if(sender, do: sender.id, else: "nil")}"
      )

      inbound = %InboundMessage{
        channel_id: "telegram",
        # Will be set by transport
        account_id: "default",
        peer: %{
          kind: peer_kind,
          id: to_string(chat["id"]),
          thread_id: message["message_thread_id"] && to_string(message["message_thread_id"])
        },
        sender: sender,
        message: %{
          id: to_string(message["message_id"]),
          text: text,
          timestamp: message["date"],
          reply_to_id:
            message["reply_to_message"] && to_string(message["reply_to_message"]["message_id"])
        },
        raw: update,
        meta: %{
          chat_id: chat["id"],
          user_msg_id: message["message_id"],
          chat_type: chat["type"],
          chat_title: chat["title"],
          chat_username: chat["username"],
          chat_display_name: chat_display_name(chat),
          topic_id: message["message_thread_id"],
          topic_name: topic_name(message),
          media_group_id: message["media_group_id"],
          photo: photo,
          document:
            if is_map(document) and map_size(document) > 0 do
              %{
                file_id: document["file_id"],
                file_name: document["file_name"],
                mime_type: document["mime_type"],
                file_size: document["file_size"]
              }
            else
              nil
            end,
          voice:
            if is_map(voice) and map_size(voice) > 0 do
              %{
                file_id: voice["file_id"],
                mime_type: voice["mime_type"],
                file_size: voice["file_size"],
                duration: voice["duration"]
              }
            else
              nil
            end
        }
      }

      Logger.debug(
        "Telegram inbound normalized successfully: message_id=#{message_id} " <>
          "text_length=#{String.length(text || "")} has_voice=#{voice != %{}} " <>
          "has_document=#{is_map(document) and map_size(document) > 0}"
      )

      {:ok, inbound}
    end
  end

  defp forum_topic_created_message?(%{"forum_topic_created" => %{} = _topic}), do: true
  defp forum_topic_created_message?(_), do: false

  defp topic_name(message) when is_map(message) do
    (message["forum_topic_created"] && message["forum_topic_created"]["name"]) ||
      (message["forum_topic_edited"] && message["forum_topic_edited"]["name"]) ||
      get_in(message, ["reply_to_message", "forum_topic_created", "name"]) ||
      get_in(message, ["reply_to_message", "forum_topic_edited", "name"])
  end

  defp topic_name(_), do: nil

  defp chat_display_name(%{"type" => "private"} = chat) do
    [chat["first_name"], chat["last_name"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" ")
    |> case do
      "" -> chat["username"]
      name -> name
    end
  end

  defp chat_display_name(chat) when is_map(chat) do
    chat["title"] || chat["username"]
  end

  defp chat_display_name(_), do: nil

  defp select_photo(photos) when is_list(photos) do
    photos
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(
      fn photo ->
        cond do
          is_integer(photo["file_size"]) ->
            photo["file_size"]

          is_integer(photo["width"]) and is_integer(photo["height"]) ->
            photo["width"] * photo["height"]

          true ->
            0
        end
      end,
      fn -> nil end
    )
    |> case do
      nil ->
        nil

      selected ->
        %{
          file_id: selected["file_id"],
          width: selected["width"],
          height: selected["height"],
          file_size: selected["file_size"]
        }
    end
  end

  defp select_photo(_), do: nil
end
