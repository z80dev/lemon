defmodule LemonChannels.OpenAIVoiceProvider do
  @moduledoc """
  OpenAI-compatible speech client using demand-driven shared HTTP streaming.

  Audio is bounded before requesting each subsequent chunk. Context may inject
  `http_client`, `http_cancel` and `http_stream_next` for transport tests.
  """
  @behaviour LemonChannels.VoiceProvider

  @impl true
  def synthesize(text, config, context) do
    api_key = config[:api_key]

    if is_binary(api_key) and String.trim(api_key) != "" do
      request(text, config, context, api_key)
    else
      {:error, :missing_api_key}
    end
  end

  defp request(text, config, context, api_key) do
    url = String.trim_trailing(config[:base_url] || "https://api.openai.com/v1", "/")

    body =
      Jason.encode!(%{
        model: config[:model] || "gpt-4o-mini-tts",
        voice: config[:voice] || "alloy",
        input: text,
        response_format: "opus"
      })

    headers = [{~c"authorization", to_charlist("Bearer " <> api_key)}]
    client = Map.get(context, :http_client, LemonCore.Httpc)

    case client.request(
           :post,
           {to_charlist(url <> "/audio/speech"), headers, ~c"application/json", body},
           [timeout: 120_000, connect_timeout: 30_000],
           body_format: :binary,
           sync: false,
           stream: {:self, :once}
         ) do
      {:ok, request_id} ->
        deadline = System.monotonic_time(:millisecond) + 120_000

        case receive_audio(request_id, context, deadline, nil, [], 0) do
          {:ok, audio} ->
            {:ok, %{audio_bytes: audio, mime_type: "audio/ogg", filename: "reply.ogg"}}

          {:error, _} = error ->
            cancel = Map.get(context, :http_cancel, &:httpc.cancel_request/1)
            cancel.(request_id)
            error
        end

      {:error, _reason} ->
        {:error, :speech_request_failed}
    end
  end

  defp receive_audio(id, context, deadline, stream, chunks, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:http, {^id, :stream_start, _headers, stream_pid}} ->
        next_chunk(context, stream_pid)
        receive_audio(id, context, deadline, stream_pid, chunks, size)

      {:http, {^id, :stream, chunk}} when is_binary(chunk) ->
        new_size = size + byte_size(chunk)

        if new_size > LemonChannels.VoiceReply.max_audio_bytes() do
          {:error, :audio_too_large}
        else
          next_chunk(context, stream)
          receive_audio(id, context, deadline, stream, [chunk | chunks], new_size)
        end

      {:http, {^id, :stream_end, _headers}} ->
        if size == 0,
          do: {:error, :empty_audio},
          else: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:http, {^id, {{_, status, _}, _headers, _body}}} ->
        {:error, {:http_error, status}}

      {:http, {^id, {:error, _reason}}} ->
        {:error, :speech_request_failed}
    after
      remaining -> {:error, :speech_request_failed}
    end
  end

  defp next_chunk(context, stream) do
    next = Map.get(context, :http_stream_next, &:httpc.stream_next/1)
    next.(stream)
  end
end
