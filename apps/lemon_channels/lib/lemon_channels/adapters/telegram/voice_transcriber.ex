defmodule LemonChannels.Adapters.Telegram.VoiceTranscriber do
  @moduledoc """
  OpenAI-compatible voice transcription client for Telegram voice notes.
  """

  require Logger

  @spec transcribe(map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def transcribe(opts) when is_list(opts) or is_map(opts) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    model = Map.get(opts, :model) || "gpt-4o-mini-transcribe"
    audio_bytes = Map.get(opts, :audio_bytes)
    base_url = Map.get(opts, :base_url) || "https://api.openai.com/v1"
    api_key = Map.get(opts, :api_key)
    mime_type = Map.get(opts, :mime_type) || "audio/ogg"

    cond do
      not is_binary(audio_bytes) -> {:error, :missing_audio}
      not is_binary(api_key) or api_key == "" -> {:error, :missing_api_key}
      true -> do_transcribe(model, audio_bytes, base_url, api_key, mime_type)
    end
  end

  defp do_transcribe(model, audio_bytes, base_url, api_key, mime_type) do
    boundary = build_boundary()
    {body, content_type} = build_multipart(boundary, model, audio_bytes, mime_type)

    url =
      base_url
      |> String.trim_trailing("/")
      |> Kernel.<>("/audio/transcriptions")

    headers = [
      {~c"content-type", to_charlist(content_type)},
      {~c"authorization", to_charlist("Bearer " <> api_key)}
    ]

    opts = [timeout: 120_000, connect_timeout: 30_000]

    case :httpc.request(
           :post,
           {to_charlist(url), headers, to_charlist(content_type), body},
           opts,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        decode_text(resp_body)

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:error, format_error(status, resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_boundary do
    "----lemon-voice-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp build_multipart(boundary, model, audio_bytes, mime_type) do
    boundary_line = "--" <> boundary <> "\r\n"
    end_boundary = "--" <> boundary <> "--\r\n"

    parts = [
      boundary_line,
      "Content-Disposition: form-data; name=\"model\"\r\n\r\n",
      to_string(model),
      "\r\n",
      boundary_line,
      "Content-Disposition: form-data; name=\"file\"; filename=\"voice.ogg\"\r\n",
      "Content-Type: ",
      to_string(mime_type),
      "\r\n\r\n",
      audio_bytes,
      "\r\n",
      end_boundary
    ]

    {IO.iodata_to_binary(parts), "multipart/form-data; boundary=#{boundary}"}
  end

  defp decode_text(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      {:ok, %{"data" => %{"text" => text}}} when is_binary(text) -> {:ok, text}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_text(_), do: {:error, :invalid_response}

  defp format_error(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} when is_binary(msg) ->
        {:http_error, status, msg}

      {:ok, %{"error" => msg}} when is_binary(msg) ->
        {:http_error, status, msg}

      {:ok, %{"detail" => msg}} when is_binary(msg) ->
        {:http_error, status, msg}

      _ ->
        {:http_error, status, String.slice(body, 0, 200)}
    end
  end

  defp format_error(status, _), do: {:http_error, status, "request failed"}
end
