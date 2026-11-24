defmodule LemonChannels.VoiceTranscriber do
  @moduledoc """
  Channel voice-note transcription through
  `LemonMedia.Providers.Transcription.openai_transcribe/2`.
  """

  alias LemonMedia.Providers.Transcription

  @spec transcribe(map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def transcribe(opts) when is_list(opts) or is_map(opts) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    model = Map.get(opts, :model) || "gpt-4o-mini-transcribe"
    audio_bytes = Map.get(opts, :audio_bytes)
    base_url = Map.get(opts, :base_url) || "https://api.openai.com/v1"
    api_key = Map.get(opts, :api_key)
    mime_type = Map.get(opts, :mime_type) || "audio/ogg"
    provider = Map.get(opts, :provider) || "openai_transcribe"

    cond do
      not is_binary(audio_bytes) -> {:error, :missing_audio}
      provider == "local_transcript" -> {:error, :no_local_stt}
      provider != "openai_transcribe" -> {:error, {:unsupported_provider, provider}}
      not is_binary(api_key) or api_key == "" -> {:error, :missing_api_key}
      true -> do_transcribe(model, audio_bytes, base_url, api_key, mime_type)
    end
  end

  defp do_transcribe(model, audio_bytes, base_url, api_key, mime_type) do
    request = %{
      base_url: base_url,
      api_key: api_key,
      audio: %{bytes: audio_bytes, name: "voice.ogg", mime_type: mime_type},
      fields: %{"model" => model},
      receive_timeout: 120_000
    }

    case Transcription.openai_transcribe(request) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      {:ok, %{"data" => %{"text" => text}}} when is_binary(text) -> {:ok, text}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, _reason} = error -> error
    end
  end

  def format_voice_error(:voice_too_large),
    do:
      "Voice message is too large to transcribe. Send a shorter recording or send the message as text."

  def format_voice_error(:missing_api_key),
    do:
      "Voice transcription requires an OpenAI API key. Set OPENAI_API_KEY or run `lemon secrets set` to configure it."

  def format_voice_error({:openai_transcription_http_error, status, {:safe_error_kind, kind}}),
    do:
      "Voice transcription failed (#{status}): #{String.slice(kind, 0, 80)}. Try again, or send the message as text."

  def format_voice_error({:telegram_file_lookup_failed, _}),
    do: "Failed to fetch voice file. Try again, or send the message as text."

  def format_voice_error({:telegram_download_failed, _}),
    do: "Failed to download voice file. Try again, or send the message as text."

  def format_voice_error(_other),
    do: "Voice transcription failed. Try again, or send the message as text."
end
