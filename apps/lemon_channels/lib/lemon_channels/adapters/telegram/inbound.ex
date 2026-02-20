defmodule LemonChannels.Adapters.Telegram.Inbound do
  @moduledoc """
  Inbound message normalization for Telegram.
  """

  alias LemonCore.InboundMessage

  @doc """
  Normalize a raw Telegram update to an InboundMessage.
  """
  @spec normalize(term()) :: {:ok, InboundMessage.t()} | {:error, term()}
  def normalize(%{"message" => message} = update) do
    normalize_message(message, update)
  end

  def normalize(%{"edited_message" => message} = update) do
    normalize_message(message, update)
  end

  def normalize(%{"channel_post" => message} = update) do
    normalize_message(message, update)
  end

  def normalize(_) do
    {:error, :unsupported_update_type}
  end

  defp normalize_message(message, update) do
    if forum_topic_created_message?(message) do
      {:error, :forum_topic_created}
    else
      chat = message["chat"]
      from = message["from"]

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

      {:ok, inbound}
    end
  end

  defp forum_topic_created_message?(%{"forum_topic_created" => %{} = _topic}), do: true
  defp forum_topic_created_message?(_), do: false

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
