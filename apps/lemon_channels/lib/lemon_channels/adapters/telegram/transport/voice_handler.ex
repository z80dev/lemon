defmodule LemonChannels.Adapters.Telegram.Transport.VoiceHandler do
  @moduledoc """
  Telegram-local inbound voice-transcription helper for the transport pipeline.

  This module handles extracting voice metadata from inbound Telegram messages,
  fetching the Telegram voice blob, running configured transcription, and
  sending user-visible system message errors when needed.
  """

  @doc """
  Attempt to transcribe an inbound voice message and return a normalized inbound
  payload, or signal that the message should be skipped.
  """
  def maybe_transcribe_voice(state, inbound, send_system_message_fn, extract_message_ids_fn)
      when is_function(send_system_message_fn, 5) and is_function(extract_message_ids_fn, 1) do
    voice = inbound.meta && inbound.meta[:voice]

    cond do
      not is_map(voice) or map_size(voice) == 0 ->
        {:ok, inbound}

      not state.voice_transcription ->
        if is_binary(inbound.message.text) and inbound.message.text != "" do
          {:ok, inbound}
        else
          _ =
            maybe_send_voice_error(
              state,
              inbound,
              "Voice transcription is disabled.",
              send_system_message_fn,
              extract_message_ids_fn
            )

          {:skip, state}
        end

      not is_binary(state.voice_transcription_api_key) or state.voice_transcription_api_key == "" ->
        _ =
          maybe_send_voice_error(
            state,
            inbound,
            "Voice transcription requires an API key.",
            send_system_message_fn,
            extract_message_ids_fn
          )

        {:skip, state}

      true ->
        case transcribe_voice(state, voice) do
          {:ok, transcript} ->
            message = Map.put(inbound.message, :text, String.trim(transcript || ""))
            meta = Map.put(inbound.meta || %{}, :voice_transcribed, true)
            {:ok, %{inbound | message: message, meta: meta}}

          {:error, reason} ->
            _ =
              maybe_send_voice_error(
                state,
                inbound,
                format_voice_error(reason),
                send_system_message_fn,
                extract_message_ids_fn
              )

            {:skip, state}
        end
    end
  end

  defp transcribe_voice(state, voice) do
    file_id = voice[:file_id] || voice["file_id"]
    file_size = parse_int(voice[:file_size] || voice["file_size"])
    max_bytes = parse_int(state.voice_max_bytes)

    if is_integer(max_bytes) and is_integer(file_size) and file_size > max_bytes do
      {:error, :voice_too_large}
    else
      ensure_httpc()

      with {:ok, audio_bytes} <- fetch_telegram_file_bytes(state, file_id),
           :ok <- enforce_voice_size(audio_bytes, max_bytes) do
        transcriber = state.voice_transcriber
        mime_type = voice[:mime_type] || voice["mime_type"]

        transcriber.transcribe(%{
          model: state.voice_transcription_model,
          base_url: state.voice_transcription_base_url,
          api_key: state.voice_transcription_api_key,
          audio_bytes: audio_bytes,
          mime_type: mime_type
        })
      end
    end
  end

  defp fetch_telegram_file_bytes(state, file_id) when is_binary(file_id) do
    with {:ok, file_path} <- file_url_from_result(state.api_mod.get_file(state.token, file_id)),
         {:ok, bytes} <- download_telegram_file_bytes(state, file_path) do
      {:ok, bytes}
    end
  end

  defp fetch_telegram_file_bytes(_state, _file_id), do: {:error, :missing_file_id}

  defp file_url_from_result({:ok, result_map} = response) when is_map(result_map) do
    with {:ok, result_data} <- extract_file_result(result_map),
         {:ok, file_path} <- file_path_from_result(result_data) do
      {:ok, file_path}
    else
      _ -> {:error, response}
    end
  end

  defp file_url_from_result(other), do: {:error, other}

  defp extract_file_result(%{"ok" => true, "result" => result}) when is_map(result) do
    {:ok, result}
  end

  defp extract_file_result(%{"result" => result}) when is_map(result), do: {:ok, result}
  defp extract_file_result(_result_map), do: {:error, :invalid_file_response}

  defp file_path_from_result(%{"file_path" => file_path}) when is_binary(file_path) do
    {:ok, file_path}
  end

  defp file_path_from_result(_result), do: {:error, :missing_file_path}

  defp download_telegram_file_bytes(state, file_path) do
    case state.api_mod.download_file(state.token, file_path) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      other -> {:error, {:telegram_download_failed, other}}
    end
  end

  defp enforce_voice_size(_bytes, max_bytes) when not is_integer(max_bytes), do: :ok

  defp enforce_voice_size(bytes, max_bytes) when is_binary(bytes) do
    if byte_size(bytes) > max_bytes do
      {:error, :voice_too_large}
    else
      :ok
    end
  end

  defp maybe_send_voice_error(
         state,
         inbound,
         text,
         send_system_message_fn,
         extract_message_ids_fn
       )
       when is_binary(text) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids_fn.(inbound)

    if is_integer(chat_id) do
      send_system_message_fn.(state, chat_id, thread_id, user_msg_id, text)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp format_voice_error(:voice_too_large), do: "Voice message is too large to transcribe."
  defp format_voice_error(:missing_api_key), do: "Voice transcription requires an API key."

  defp format_voice_error({:http_error, status, msg}) do
    msg =
      if is_binary(msg) and msg != "" do
        String.slice(msg, 0, 200)
      else
        "request failed"
      end

    "Voice transcription failed (#{status}): #{msg}"
  end

  defp format_voice_error({:telegram_file_lookup_failed, _}), do: "Failed to fetch voice file."
  defp format_voice_error({:telegram_download_failed, _}), do: "Failed to download voice file."
  defp format_voice_error(other), do: "Voice transcription failed: #{inspect(other)}"

  defp ensure_httpc do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp parse_int(nil), do: nil

  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end
end
