defmodule LemonChannels.Adapters.Discord.VoiceHandler do
  @moduledoc "Transcribes authorized Discord audio attachments using shared channel voice settings."

  alias LemonChannels.{GatewayConfig, ImageDownload, VoiceTranscriber}

  def config do
    telegram = GatewayConfig.get(:telegram, %{}) || %{}
    providers = LemonCore.Config.load().providers || %{}
    openai = providers["openai"] || providers[:openai] || %{}

    %{
      enabled: get(telegram, :voice_transcription, false) == true,
      provider: get(telegram, :voice_transcription_provider, "openai_transcribe"),
      model: get(telegram, :voice_transcription_model, "gpt-4o-mini-transcribe"),
      base_url: get(telegram, :voice_transcription_base_url, get(openai, :base_url, nil)),
      api_key: get(telegram, :voice_transcription_api_key, get(openai, :api_key, nil)),
      max_bytes: get(telegram, :voice_max_bytes, 10 * 1024 * 1024)
    }
  end

  def transcribe(inbound) do
    if Enum.any?(inbound.meta[:attachments] || [], &audio?/1),
      do: transcribe(inbound, config()),
      else: {inbound, []}
  end

  def transcribe(
        inbound,
        config,
        download \\ &ImageDownload.download/2,
        transcriber \\ VoiceTranscriber
      ) do
    attachments = inbound.meta[:attachments] || []
    audio = Enum.filter(attachments, &audio?/1)

    {remaining, transcripts, errors} =
      Enum.reduce(audio, {attachments, [], []}, fn attachment, {remaining, transcripts, errors} ->
        case transcribe_attachment(attachment, config, download, transcriber) do
          {:ok, text} when is_binary(text) and text != "" ->
            {List.delete(remaining, attachment), transcripts ++ [String.trim(text)], errors}

          {:error, :disabled} ->
            errors =
              if inbound.meta[:voice_message] == true,
                do: errors ++ [error_text(:disabled)],
                else: errors

            {remaining, transcripts, errors}

          {:error, reason} ->
            {remaining, transcripts, errors ++ [error_text(reason)]}

          _ ->
            {remaining, transcripts, errors ++ [error_text(:empty_transcript)]}
        end
      end)

    if transcripts == [] do
      {inbound, errors}
    else
      text =
        [inbound.meta[:typed_content] || "" | transcripts]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      urls = remaining |> Enum.map(& &1[:url]) |> Enum.reject(&is_nil/1)

      text =
        if urls == [],
          do: text,
          else: text <> "\n\nAttachments:\n" <> Enum.map_join(urls, "\n", &"- #{&1}")

      {%{
         inbound
         | message: Map.put(inbound.message, :text, text),
           meta: Map.put(inbound.meta, :voice_transcribed, true)
       }, errors}
    end
  end

  defp transcribe_attachment(_attachment, %{enabled: false}, _download, _transcriber),
    do: {:error, :disabled}

  defp transcribe_attachment(attachment, config, download, transcriber) do
    with true <- ImageDownload.discord_url?(attachment[:url]),
         :ok <- check_size(attachment[:size], config.max_bytes),
         {:ok, bytes} <- download.(attachment.url, config.max_bytes),
         :ok <- check_size(byte_size(bytes), config.max_bytes) do
      transcriber.transcribe(%{
        provider: config.provider,
        model: config.model,
        base_url: config.base_url,
        api_key: config.api_key,
        audio_bytes: bytes,
        mime_type: attachment.content_type
      })
      |> normalize_transcript()
    else
      false -> {:error, :untrusted_url}
      {:error, _} = error -> error
    end
  end

  defp normalize_transcript({:ok, text}) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_transcript}
      text -> {:ok, text}
    end
  end

  defp normalize_transcript(other), do: other

  defp check_size(size, max) when is_integer(size) and size > max,
    do: {:error, :voice_too_large}

  defp check_size(_, _), do: :ok
  defp audio?(%{content_type: "audio/" <> subtype}), do: subtype != ""
  defp audio?(_), do: false
  defp error_text(:disabled), do: "Voice transcription is disabled."
  defp error_text(:too_large), do: VoiceTranscriber.format_voice_error(:voice_too_large)
  defp error_text(reason), do: VoiceTranscriber.format_voice_error(reason)

  defp get(map, key, default) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key))) do
      nil -> default
      "" -> default
      value -> value
    end
  end
end
