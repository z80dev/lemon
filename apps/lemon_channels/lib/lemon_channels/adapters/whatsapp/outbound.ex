defmodule LemonChannels.Adapters.WhatsApp.Outbound do
  @moduledoc """
  Outbound message delivery for WhatsApp.

  Delivers OutboundPayload structs to WhatsApp by forwarding to
  `LemonChannels.Adapters.WhatsApp.Transport`, which communicates
  with the WhatsApp bridge process via port commands.
  """

  require Logger

  alias LemonChannels.Adapters.WhatsApp.{Formatter, Transport}
  alias LemonChannels.OutboundPayload

  @chunk_limit 4096

  @doc """
  Deliver an outbound payload to WhatsApp.
  """
  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{kind: :text} = payload) do
    Logger.debug(
      "WhatsApp outbound delivering text: peer_id=#{payload.peer.id} " <>
        "text_length=#{String.length(payload.content || "")}"
    )

    text = format_text(payload.content)
    peer = payload.peer

    chunks = chunk_text(text, @chunk_limit)
    chunk_count = length(chunks)

    Logger.debug(
      "WhatsApp outbound text chunks: peer_id=#{peer.id} chunks=#{chunk_count}"
    )

    result =
      chunks
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, nil}, fn {chunk, idx}, _acc ->
        transport_payload = %{
          kind: :send_text,
          jid: peer.id,
          text: chunk,
          reply_to_id: if(idx == 0, do: payload.reply_to, else: nil)
        }

        case Transport.deliver(transport_payload) do
          {:ok, result} ->
            {:cont, {:ok, result}}

          {:error, reason} ->
            Logger.warning(
              "WhatsApp outbound text chunk failed: peer_id=#{peer.id} " <>
                "chunk=#{idx} reason=#{inspect(reason)}"
            )

            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, _} ->
        Logger.debug("WhatsApp outbound text sent successfully: peer_id=#{peer.id}")

      {:error, _} ->
        :ok
    end

    result
  end

  def deliver(%OutboundPayload{kind: :file, content: content} = payload) do
    Logger.debug("WhatsApp outbound delivering file: peer_id=#{payload.peer.id}")

    peer = payload.peer

    with {:ok, normalized} <- normalize_file_content(content) do
      result =
        normalized.files
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, nil}, fn {file, idx}, _acc ->
          transport_payload = %{
            kind: :send_media,
            jid: peer.id,
            path: file.path,
            caption: file.caption,
            mime_type: file.mime_type,
            reply_to_id: if(idx == 0, do: payload.reply_to, else: nil)
          }

          case Transport.deliver(transport_payload) do
            {:ok, result} ->
              {:cont, {:ok, result}}

            {:error, reason} ->
              Logger.warning(
                "WhatsApp outbound file failed: peer_id=#{peer.id} " <>
                  "path=#{file.path} reason=#{inspect(reason)}"
              )

              {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, _} ->
          Logger.debug("WhatsApp outbound file sent successfully: peer_id=#{peer.id}")

        {:error, _} ->
          :ok
      end

      result
    else
      {:error, reason} ->
        Logger.warning(
          "WhatsApp outbound file normalization failed: peer_id=#{payload.peer.id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def deliver(
        %OutboundPayload{kind: :reaction, content: %{message_id: message_id, emoji: emoji}} =
          payload
      ) do
    Logger.debug(
      "WhatsApp outbound delivering reaction: peer_id=#{payload.peer.id} " <>
        "message_id=#{message_id} emoji=#{emoji}"
    )

    transport_payload = %{
      kind: :send_reaction,
      jid: payload.peer.id,
      message_id: to_string(message_id),
      emoji: emoji
    }

    case Transport.deliver(transport_payload) do
      {:ok, result} ->
        Logger.debug(
          "WhatsApp outbound reaction sent successfully: peer_id=#{payload.peer.id}"
        )

        {:ok, result}

      {:error, reason} ->
        Logger.warning(
          "WhatsApp outbound reaction failed: peer_id=#{payload.peer.id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def deliver(%OutboundPayload{kind: kind}) do
    Logger.error("WhatsApp outbound unsupported payload kind: #{inspect(kind)}")
    {:error, {:unsupported_kind, kind}}
  end

  # --- Private helpers ---

  defp format_text(text) when is_binary(text) do
    if whatsapp_use_markdown() do
      text
      |> Formatter.strip_unsupported()
      |> Formatter.format()
    else
      text
    end
  end

  defp format_text(nil), do: ""
  defp format_text(text), do: to_string(text)

  defp chunk_text(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    if String.length(text) <= limit do
      [text]
    else
      do_chunk(text, limit, [])
    end
  end

  defp chunk_text(text, _limit) when is_binary(text), do: [text]
  defp chunk_text(_text, _limit), do: [""]

  defp do_chunk("", _limit, acc), do: Enum.reverse(acc)

  defp do_chunk(text, limit, acc) do
    if String.length(text) <= limit do
      Enum.reverse([text | acc])
    else
      {chunk, rest} = String.split_at(text, limit)
      do_chunk(rest, limit, [chunk | acc])
    end
  end

  defp normalize_file_content(%{} = content) do
    files = Map.get(content, :files) || Map.get(content, "files")

    case files do
      list when is_list(list) ->
        normalize_file_batch(list)

      nil ->
        normalize_single_file(content)

      _ ->
        {:error, :invalid_file_payload}
    end
  end

  defp normalize_file_content(_), do: {:error, :invalid_file_payload}

  defp normalize_single_file(%{} = content) do
    path = Map.get(content, :path) || Map.get(content, "path")
    caption = Map.get(content, :caption) || Map.get(content, "caption")
    mime_type = Map.get(content, :mime_type) || Map.get(content, "mime_type")

    cond do
      not is_binary(path) or path == "" ->
        {:error, :invalid_file_payload}

      not File.regular?(path) ->
        {:error, :file_not_found}

      true ->
        {:ok, %{files: [%{path: path, caption: caption, mime_type: mime_type}]}}
    end
  end

  defp normalize_file_batch(files) when is_list(files) and files != [] do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case normalize_batch_file_entry(file) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, %{files: Enum.reverse(normalized)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_file_batch([]), do: {:error, :invalid_file_payload}
  defp normalize_file_batch(_), do: {:error, :invalid_file_payload}

  defp normalize_batch_file_entry(%{} = content) do
    path = Map.get(content, :path) || Map.get(content, "path")
    caption = Map.get(content, :caption) || Map.get(content, "caption")
    mime_type = Map.get(content, :mime_type) || Map.get(content, "mime_type")

    cond do
      not is_binary(path) or path == "" ->
        {:error, :invalid_file_payload}

      not File.regular?(path) ->
        {:error, :file_not_found}

      true ->
        {:ok, %{path: path, caption: caption, mime_type: mime_type}}
    end
  end

  defp normalize_batch_file_entry(_), do: {:error, :invalid_file_payload}

  defp whatsapp_use_markdown do
    config = LemonChannels.GatewayConfig.get(:whatsapp, %{}) || %{}

    case Map.fetch(config, :use_markdown) do
      {:ok, nil} -> true
      {:ok, v} -> v
      :error ->
        case Map.fetch(config, "use_markdown") do
          {:ok, nil} -> true
          {:ok, v} -> v
          :error -> true
        end
    end
  rescue
    _ -> true
  end
end
