defmodule LemonChannels.Adapters.Discord.Inbound do
  @moduledoc """
  Inbound message normalization for Discord.
  """

  alias LemonCore.InboundMessage

  @spec normalize(map()) :: {:ok, InboundMessage.t()} | {:error, term()}
  def normalize(%{message: message, account_id: account_id} = raw) do
    normalize_message(message, account_id, raw)
  end

  def normalize(%{"message" => message, "account_id" => account_id} = raw) do
    normalize_message(message, account_id, raw)
  end

  def normalize(_), do: {:error, :unsupported_inbound}

  @spec normalize_message(map(), binary(), map()) :: {:ok, InboundMessage.t()} | {:error, term()}
  def normalize_message(message, account_id, raw)
      when is_map(message) and is_binary(account_id) do
    channel_id = fetch_id(message, :channel_id)

    sender =
      message
      |> fetch_map(:author)
      |> to_sender()

    guild_id = fetch_id(message, :guild_id)
    message_id = fetch_id(message, :id)
    reply_to_id = fetch_reply_to_id(message)
    thread_id = fetch_thread_id(message)

    peer_kind = if guild_id, do: :group, else: :dm

    text =
      message
      |> message_content()
      |> enrich_with_attachments(message)

    inbound = %InboundMessage{
      channel_id: "discord",
      account_id: account_id,
      peer: %{
        kind: peer_kind,
        id: integer_to_string(channel_id),
        thread_id: integer_to_string(thread_id)
      },
      sender: sender,
      message: %{
        id: integer_to_string(message_id),
        text: text,
        timestamp: fetch_timestamp(message),
        reply_to_id: integer_to_string(reply_to_id)
      },
      raw: raw,
      meta: %{
        guild_id: guild_id,
        channel_id: channel_id,
        thread_id: thread_id,
        user_msg_id: message_id,
        user_id: sender && sender.id,
        reply_to_id: reply_to_id
      }
    }

    {:ok, inbound}
  end

  def normalize_message(_, _, _), do: {:error, :unsupported_inbound}

  defp to_sender(author) when is_map(author) do
    id = fetch_id(author, :id)

    if is_integer(id) do
      %{
        id: Integer.to_string(id),
        username: fetch_binary(author, :username),
        display_name: fetch_binary(author, :global_name) || fetch_binary(author, :username)
      }
    else
      nil
    end
  end

  defp to_sender(_), do: nil

  defp fetch_reply_to_id(message) do
    message
    |> fetch_map(:referenced_message)
    |> fetch_id(:id)
  end

  defp fetch_thread_id(message) do
    case fetch_id(message, :thread_id) do
      id when is_integer(id) -> id
      _ -> nil
    end
  end

  defp fetch_timestamp(message) do
    message
    |> fetch_binary(:timestamp)
    |> case do
      nil -> nil
      ts -> DateTime.from_iso8601(ts)
    end
    |> case do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp enrich_with_attachments(content, message) do
    attachments = fetch_list(message, :attachments)

    urls =
      attachments
      |> Enum.map(fn att -> fetch_binary(att, :url) end)
      |> Enum.reject(&is_nil/1)

    if urls == [] do
      content
    else
      [content, "", "Attachments:", Enum.map_join(urls, "\n", &"- #{&1}")]
      |> Enum.join("\n")
      |> String.trim()
    end
  end

  defp message_content(message) do
    fetch_binary(message, :content) || ""
  end

  defp fetch_map(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || %{}
  end

  defp fetch_list(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp fetch_binary(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp fetch_id(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {i, _} -> i
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp integer_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_to_string(_), do: nil
end
