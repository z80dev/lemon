defmodule LemonMedia.Providers.Speech do
  @moduledoc """
  Text-to-speech drivers: `local_wav` preview, OpenAI TTS, ElevenLabs TTS and
  Google Cloud Text-to-Speech.
  """

  alias LemonMedia.{Artifact, GoogleAuth}
  alias LemonMedia.Providers.Http

  import LemonMedia.Providers.Http, only: [reject_blank_values: 1]

  @doc false
  def run(%{provider: "local_wav", artifact_path: path}) do
    Artifact.store(path, wav_silence(), "audio/wav")
  end

  def run(%{provider: "openai_tts"} = request) do
    %{attrs: attrs, artifact_path: path, generation: generation, runtime: runtime} = request

    with {:ok, api_key} <- Http.api_key(runtime),
         {:ok, audio} <- post_openai_tts(text(attrs), generation, runtime, api_key) do
      Artifact.store(path, audio, generation.mime_type)
    end
  end

  def run(%{provider: "elevenlabs_tts"} = request) do
    %{attrs: attrs, artifact_path: path, generation: generation, runtime: runtime} = request

    with {:ok, api_key} <- Http.api_key(runtime),
         {:ok, audio} <-
           elevenlabs_tts(
             %{
               text: text(attrs),
               model: generation.model,
               voice: runtime.voice,
               base_url: runtime.base_url,
               output_format: "mp3_44100_128",
               api_key: api_key,
               http_post: runtime.http_post
             },
             generation.max_retries
           ) do
      Artifact.store(path, audio, generation.mime_type)
    end
  end

  def run(%{provider: "google_tts"} = request) do
    %{attrs: attrs, artifact_path: path, generation: generation, runtime: runtime} = request

    with {:ok, access_token} <- GoogleAuth.access_token(runtime, :google_tts),
         {:ok, audio} <- post_google_tts(text(attrs), generation, runtime, access_token) do
      Artifact.store(path, audio, generation.mime_type)
    end
  end

  @doc """
  Synthesizes `request.text` with ElevenLabs and returns the audio bytes.

  `request` carries `:api_key`, `:voice`, `:model`, `:output_format`,
  `:base_url` (defaults to the public API) and optionally `:voice_settings`, `:http_post`
  (defaults to `Req.post/2`) and `:receive_timeout`. Shared by the speech tool
  and the gateway voice call path.
  """
  @spec elevenlabs_tts(map(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def elevenlabs_tts(request, retries \\ 0) do
    base_url = Map.get(request, :base_url) || "https://api.elevenlabs.io/v1"
    http_post = Map.get(request, :http_post) || (&Req.post/2)

    url =
      Http.url(base_url, "/text-to-speech/#{URI.encode(request.voice)}/stream") <>
        "?output_format=#{URI.encode_www_form(request.output_format)}"

    request_opts = [
      headers: [{"xi-api-key", request.api_key}],
      json:
        reject_blank_values(%{
          "text" => request.text,
          "model_id" => request.model,
          "voice_settings" => Map.get(request, :voice_settings)
        }),
      receive_timeout: Map.get(request, :receive_timeout, 300_000)
    ]

    Http.request(fn -> http_post.(url, request_opts) end, retries, :elevenlabs_tts)
  end

  defp post_openai_tts(text, generation, runtime, api_key) do
    body =
      %{
        "model" => generation.model,
        "input" => text,
        "voice" => generation.voice,
        "instructions" => generation.instructions,
        "response_format" => generation.format,
        "speed" => generation.speed
      }
      |> reject_blank_values()

    request_opts = [
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: body,
      receive_timeout: 300_000
    ]

    url = Http.url(runtime.base_url, "/audio/speech")

    Http.request(
      fn -> Http.post_fun(runtime).(url, request_opts) end,
      generation.max_retries,
      :openai_tts
    )
  end

  defp post_google_tts(text, generation, runtime, access_token) do
    body = %{
      "input" => %{"text" => text},
      "voice" => %{"languageCode" => generation.language_code, "name" => generation.voice},
      "audioConfig" => %{"audioEncoding" => "MP3"}
    }

    request_opts = [
      headers: [{"authorization", "Bearer #{access_token}"}],
      json: body,
      receive_timeout: 300_000
    ]

    url = Http.url(runtime.base_url, "/text:synthesize")

    with {:ok, response} <-
           Http.request(
             fn -> Http.post_fun(runtime).(url, request_opts) end,
             generation.max_retries,
             :google_tts
           ) do
      decode_google_tts_response(response)
    end
  end

  defp decode_google_tts_response(%{"audioContent" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, audio} -> {:ok, audio}
      :error -> {:error, :invalid_google_tts_audio_base64}
    end
  end

  defp decode_google_tts_response(%{audioContent: encoded}) when is_binary(encoded) do
    decode_google_tts_response(%{"audioContent" => encoded})
  end

  defp decode_google_tts_response(_response), do: {:error, :missing_google_tts_audio}

  defp text(attrs), do: Map.get(attrs, :prompt) || Map.get(attrs, "prompt")

  defp wav_silence do
    sample_rate = 16_000
    sample_count = div(sample_rate, 4)
    data = :binary.copy(<<0, 0>>, sample_count)
    data_size = byte_size(data)
    riff_size = 36 + data_size

    "RIFF" <>
      <<riff_size::little-32>> <>
      "WAVEfmt " <>
      <<16::little-32, 1::little-16, 1::little-16, sample_rate::little-32,
        sample_rate * 2::little-32, 2::little-16, 16::little-16>> <>
      "data" <> <<data_size::little-32>> <> data
  end
end
