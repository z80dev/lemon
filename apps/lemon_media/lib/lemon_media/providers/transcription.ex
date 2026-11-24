defmodule LemonMedia.Providers.Transcription do
  @moduledoc """
  Speech-to-text drivers: `local_transcript` preview, OpenAI
  `/audio/transcriptions` and Deepgram `/listen`.

  `request.input.audio` carries the audio (`:bytes`, `:name`, `:mime_type`,
  `:hash`). `openai_transcribe/2` is also the channel voice-note client.
  """

  alias LemonMedia.Artifact
  alias LemonMedia.Providers.{Http, Vision}

  import LemonMedia.Providers.Http, only: [optional_string: 1, reject_blank_values: 1]

  @doc false
  def run(%{provider: "local_transcript", artifact_path: path, input: %{audio: audio}}) do
    transcript = "local transcript preview for audio #{String.slice(audio.hash, 0, 12)}"
    store(path, Jason.encode!(%{"text" => transcript}, pretty: true), transcript)
  end

  def run(%{provider: "openai_transcribe"} = request) do
    %{artifact_path: path, generation: generation, runtime: runtime, input: %{audio: audio}} =
      request

    with {:ok, api_key} <- Http.api_key(runtime),
         {:ok, response} <-
           openai_transcribe(
             %{
               base_url: runtime.base_url,
               api_key: api_key,
               http_post: runtime.http_post,
               audio: audio,
               fields: %{
                 "model" => generation.model,
                 "response_format" => generation.format,
                 "language" => generation.language,
                 "prompt" => generation.prompt
               }
             },
             generation.max_retries
           ),
         {:ok, transcript, content} <- normalize_openai(response, generation.format) do
      store(path, content, transcript)
    end
  end

  def run(%{provider: "deepgram_transcribe"} = request) do
    %{artifact_path: path, generation: generation, runtime: runtime, input: %{audio: audio}} =
      request

    with {:ok, api_key} <- Http.api_key(runtime),
         {:ok, response} <- post_deepgram(audio, generation, runtime, api_key),
         {:ok, transcript, content} <- normalize_deepgram(response, generation.format) do
      store(path, content, transcript)
    end
  end

  @doc """
  Posts `request.audio` to an OpenAI-compatible `/audio/transcriptions`
  endpoint and returns the decoded response body.

  `request` carries `:base_url`, `:api_key`, `:audio` (`:bytes`, `:name`,
  `:mime_type`), multipart `:fields` (blank values dropped) and optionally
  `:http_post` (defaults to `Req.post/2`) and `:receive_timeout`.
  """
  @spec openai_transcribe(map(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def openai_transcribe(request, retries \\ 0) do
    boundary = "lemon-media-#{System.unique_integer([:positive])}"
    audio = request.audio
    http_post = Map.get(request, :http_post) || (&Req.post/2)

    request_opts = [
      headers: [
        {"authorization", "Bearer #{request.api_key}"},
        {"content-type", "multipart/form-data; boundary=#{boundary}"}
      ],
      body: multipart_body(boundary, reject_blank_values(request.fields), audio),
      receive_timeout: Map.get(request, :receive_timeout, 300_000)
    ]

    url = Http.url(request.base_url, "/audio/transcriptions")
    Http.request(fn -> http_post.(url, request_opts) end, retries, :openai_transcription)
  end

  defp post_deepgram(audio, generation, runtime, api_key) do
    query =
      %{"model" => generation.model, "smart_format" => "true", "language" => generation.language}
      |> reject_blank_values()
      |> URI.encode_query()

    request_opts = [
      headers: [{"authorization", "Token #{api_key}"}, {"content-type", audio.mime_type}],
      body: audio.bytes,
      receive_timeout: 300_000
    ]

    url = Http.url(runtime.base_url, "/listen?" <> query)

    Http.request(
      fn -> Http.post_fun(runtime).(url, request_opts) end,
      generation.max_retries,
      :deepgram_transcription
    )
  end

  defp multipart_body(boundary, fields, audio) do
    field_parts =
      Enum.map(fields, fn {name, value} ->
        [
          "--",
          boundary,
          "\r\ncontent-disposition: form-data; name=\"",
          name,
          "\"\r\n\r\n",
          to_string(value),
          "\r\n"
        ]
      end)

    file_part = [
      "--",
      boundary,
      "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"",
      audio.name,
      "\"\r\ncontent-type: ",
      audio.mime_type,
      "\r\n\r\n",
      audio.bytes,
      "\r\n--",
      boundary,
      "--\r\n"
    ]

    IO.iodata_to_binary([field_parts, file_part])
  end

  defp normalize_openai(response, "json") when is_map(response) do
    text = optional_string(response["text"]) || optional_string(response[:text]) || ""
    {:ok, text, Jason.encode!(stringify_keys(response), pretty: true)}
  end

  defp normalize_openai(response, "json") when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> normalize_openai(decoded, "json")
      _ -> {:ok, response, Jason.encode!(%{"text" => response}, pretty: true)}
    end
  end

  defp normalize_openai(response, "text") when is_binary(response), do: {:ok, response, response}

  defp normalize_openai(response, "text") when is_map(response) do
    text =
      optional_string(response["text"]) || optional_string(response[:text]) ||
        Jason.encode!(response)

    {:ok, text, text}
  end

  defp normalize_deepgram(response, "json") when is_map(response) do
    transcript = deepgram_transcript(response)

    content =
      response
      |> stringify_keys()
      |> Map.put("text", transcript)
      |> Jason.encode!(pretty: true)

    {:ok, transcript, content}
  end

  defp normalize_deepgram(response, "json") when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> normalize_deepgram(decoded, "json")
      _ -> {:ok, response, Jason.encode!(%{"text" => response}, pretty: true)}
    end
  end

  defp normalize_deepgram(response, "text") when is_map(response) do
    transcript = deepgram_transcript(response)
    {:ok, transcript, transcript}
  end

  defp normalize_deepgram(response, "text") when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> normalize_deepgram(decoded, "text")
      _ -> {:ok, response, response}
    end
  end

  defp deepgram_transcript(response) do
    get_in(response, [
      "results",
      "channels",
      Access.at(0),
      "alternatives",
      Access.at(0),
      "transcript"
    ]) ||
      get_in(response, [
        :results,
        :channels,
        Access.at(0),
        :alternatives,
        Access.at(0),
        :transcript
      ]) ||
      optional_string(response["text"]) ||
      optional_string(response[:text]) ||
      ""
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp store(path, content, transcript) do
    Artifact.store(path, content, Vision.text_mime_type(path), %{transcript: transcript})
  end
end
