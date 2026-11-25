defmodule LemonMedia.Providers.Video do
  @moduledoc """
  Video-generation drivers: `local_mp4` preview, OpenAI video jobs
  (create/poll/download) and Vertex AI Veo long-running predictions.
  """

  alias LemonMedia.{Artifact, GoogleAuth}
  alias LemonMedia.Providers.Http

  import LemonMedia.Providers.Http,
    only: [optional_string: 1, provider_error_kind: 1, reject_blank_values: 1]

  @local_mp4_preview <<0, 0, 0, 24, "ftypmp42", 0, 0, 0, 0, "mp42isom", 0, 0, 0, 8, "free">>

  @doc false
  def run(%{provider: "local_mp4", artifact_path: path}) do
    Artifact.store(path, @local_mp4_preview, "video/mp4")
  end

  def run(%{provider: "openai_video"} = request) do
    %{attrs: attrs, artifact_path: path, generation: generation, runtime: runtime} = request

    with {:ok, api_key} <- Http.api_key(runtime),
         {:ok, video} <- create_openai_video(attrs, generation, runtime, api_key),
         {:ok, completed} <- wait_openai_video(video, generation, runtime, api_key),
         {:ok, bytes} <- download_openai_video(completed, generation, runtime, api_key) do
      Artifact.store(path, bytes, "video/mp4", %{
        provider_job_id: redacted_id(video_id(completed))
      })
    end
  end

  def run(%{provider: "vertex_veo"} = request) do
    %{attrs: attrs, artifact_path: path, generation: generation, runtime: runtime} = request

    with {:ok, access_token} <- GoogleAuth.access_token(runtime, :vertex_veo),
         {:ok, operation} <- create_vertex_veo(attrs, generation, runtime, access_token),
         {:ok, completed} <- wait_vertex_veo(operation, generation, runtime, access_token),
         {:ok, {bytes, mime_type}} <- decode_vertex_veo_response(completed, generation.mime_type) do
      Artifact.store(path, bytes, mime_type, %{
        provider_job_id: redacted_id(operation_name(completed))
      })
    end
  end

  defp create_openai_video(attrs, generation, runtime, api_key) do
    body =
      %{
        "model" => generation.model,
        "prompt" => prompt(attrs),
        "size" => generation.size,
        "seconds" => generation.seconds
      }
      |> reject_blank_values()

    request_opts = [
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: body,
      receive_timeout: 300_000
    ]

    post(
      runtime,
      Http.url(runtime.base_url, "/videos"),
      request_opts,
      generation,
      :openai_video_create
    )
  end

  defp wait_openai_video(video, generation, runtime, api_key) do
    case openai_video_state(video) do
      :pending ->
        poll_openai_video(video_id(video), generation, runtime, api_key, generation.max_polls)

      done ->
        done
    end
  end

  defp openai_video_state(video) do
    case video_status(video) do
      status when status in ["completed", "succeeded"] ->
        {:ok, video}

      status when status in ["failed", "cancelled"] ->
        {:error, {:openai_video_failed, status, provider_error_kind(video)}}

      _status ->
        :pending
    end
  end

  defp poll_openai_video(nil, _generation, _runtime, _api_key, _remaining),
    do: {:error, :missing_openai_video_id}

  defp poll_openai_video(_id, _generation, _runtime, _api_key, 0),
    do: {:error, :openai_video_poll_exhausted}

  defp poll_openai_video(id, generation, runtime, api_key, remaining) do
    if generation.poll_interval_ms > 0, do: Process.sleep(generation.poll_interval_ms)

    request_opts = [headers: [{"authorization", "Bearer #{api_key}"}], receive_timeout: 300_000]
    url = Http.url(runtime.base_url, "/videos/" <> id)

    with {:ok, video} <- get(runtime, url, request_opts, generation, :openai_video_status) do
      case openai_video_state(video) do
        :pending -> poll_openai_video(id, generation, runtime, api_key, remaining - 1)
        done -> done
      end
    end
  end

  defp download_openai_video(video, generation, runtime, api_key) do
    case video_id(video) do
      id when is_binary(id) ->
        request_opts = [
          headers: [{"authorization", "Bearer #{api_key}"}],
          receive_timeout: 300_000
        ]

        url = Http.url(runtime.base_url, "/videos/" <> id <> "/content")
        get(runtime, url, request_opts, generation, :openai_video_download)

      _ ->
        {:error, :missing_openai_video_id}
    end
  end

  defp create_vertex_veo(attrs, generation, runtime, access_token) do
    with {:ok, base} <- vertex_model_url(runtime, generation) do
      parameters =
        %{
          "sampleCount" => 1,
          "durationSeconds" => vertex_duration(generation.seconds),
          "aspectRatio" => vertex_aspect_ratio(generation.size),
          "storageUri" => generation.storage_uri
        }
        |> reject_blank_values()

      request_opts = [
        headers: [{"authorization", "Bearer #{access_token}"}],
        json: %{"instances" => [%{"prompt" => prompt(attrs)}], "parameters" => parameters},
        receive_timeout: 300_000
      ]

      post(runtime, base <> ":predictLongRunning", request_opts, generation, :vertex_veo_create)
    end
  end

  defp wait_vertex_veo(operation, generation, runtime, access_token) do
    case vertex_veo_state(operation) do
      :pending ->
        poll_vertex_veo(
          operation_name(operation),
          generation,
          runtime,
          access_token,
          generation.max_polls
        )

      done ->
        done
    end
  end

  defp vertex_veo_state(operation) do
    cond do
      operation_done?(operation) and operation_error(operation) ->
        {:error, {:vertex_veo_failed, provider_error_kind(operation_error(operation))}}

      operation_done?(operation) ->
        {:ok, operation}

      true ->
        :pending
    end
  end

  defp poll_vertex_veo(nil, _generation, _runtime, _access_token, _remaining),
    do: {:error, :missing_vertex_veo_operation_name}

  defp poll_vertex_veo(_operation_name, _generation, _runtime, _access_token, 0),
    do: {:error, :vertex_veo_poll_exhausted}

  defp poll_vertex_veo(operation_name, generation, runtime, access_token, remaining) do
    if generation.poll_interval_ms > 0, do: Process.sleep(generation.poll_interval_ms)

    with {:ok, base} <- vertex_model_url(runtime, generation) do
      request_opts = [
        headers: [{"authorization", "Bearer #{access_token}"}],
        json: %{"operationName" => operation_name},
        receive_timeout: 300_000
      ]

      with {:ok, operation} <-
             post(
               runtime,
               base <> ":fetchPredictOperation",
               request_opts,
               generation,
               :vertex_veo_status
             ) do
        case vertex_veo_state(operation) do
          :pending ->
            poll_vertex_veo(operation_name, generation, runtime, access_token, remaining - 1)

          done ->
            done
        end
      end
    end
  end

  defp vertex_model_url(runtime, generation) do
    with {:ok, project} <- required(runtime.project, :missing_vertex_veo_project),
         {:ok, location} <- required(runtime.location, :missing_vertex_veo_location) do
      {:ok,
       "https://#{location}-aiplatform.googleapis.com/v1/projects/#{project}/locations/#{location}/publishers/google/models/#{generation.model}"}
    end
  end

  defp required(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, reason), do: {:error, reason}

  defp post(runtime, url, request_opts, generation, tag) do
    Http.request(
      fn -> Http.post_fun(runtime).(url, request_opts) end,
      generation.max_retries,
      tag
    )
  end

  defp get(runtime, url, request_opts, generation, tag) do
    Http.request(fn -> Http.get_fun(runtime).(url, request_opts) end, generation.max_retries, tag)
  end

  defp prompt(attrs), do: Map.get(attrs, :prompt) || Map.get(attrs, "prompt")

  defp video_id(video) when is_map(video),
    do: optional_string(video["id"]) || optional_string(video[:id])

  defp video_id(_video), do: nil

  defp video_status(video) when is_map(video), do: video["status"] || video[:status]
  defp video_status(_video), do: nil

  defp redacted_id(id) when is_binary(id) do
    :crypto.hash(:sha256, id)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp redacted_id(_id), do: nil

  defp operation_name(operation) when is_map(operation),
    do: optional_string(operation["name"]) || optional_string(operation[:name])

  defp operation_name(_operation), do: nil

  defp operation_done?(%{"done" => done}), do: done == true
  defp operation_done?(%{done: done}), do: done == true
  defp operation_done?(_operation), do: false

  defp operation_error(%{"error" => error}) when is_map(error), do: error
  defp operation_error(%{error: error}) when is_map(error), do: error
  defp operation_error(_operation), do: nil

  defp decode_vertex_veo_response(operation, default_mime) do
    response = operation_response(operation)

    cond do
      is_binary(
        get_in(response, ["generatedVideos", Access.at(0), "video", "bytesBase64Encoded"])
      ) ->
        video = get_in(response, ["generatedVideos", Access.at(0), "video"])
        decode_vertex_veo_bytes(video["bytesBase64Encoded"], video["mimeType"], default_mime)

      is_binary(get_in(response, [:generatedVideos, Access.at(0), :video, :bytesBase64Encoded])) ->
        video = get_in(response, [:generatedVideos, Access.at(0), :video])
        decode_vertex_veo_bytes(video[:bytesBase64Encoded], video[:mimeType], default_mime)

      is_binary(get_in(response, ["videos", Access.at(0), "bytesBase64Encoded"])) ->
        video = get_in(response, ["videos", Access.at(0)])
        decode_vertex_veo_bytes(video["bytesBase64Encoded"], video["mimeType"], default_mime)

      is_binary(get_in(response, ["predictions", Access.at(0), "bytesBase64Encoded"])) ->
        video = get_in(response, ["predictions", Access.at(0)])
        decode_vertex_veo_bytes(video["bytesBase64Encoded"], video["mimeType"], default_mime)

      has_vertex_veo_gcs_uri?(response) ->
        {:error, :vertex_veo_gcs_uri_response_unsupported}

      true ->
        {:error, :missing_vertex_veo_video}
    end
  end

  defp operation_response(%{"response" => response}) when is_map(response), do: response
  defp operation_response(%{response: response}) when is_map(response), do: response
  defp operation_response(response) when is_map(response), do: response
  defp operation_response(_operation), do: %{}

  defp decode_vertex_veo_bytes(encoded, mime_type, default_mime) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, {bytes, optional_string(mime_type) || default_mime}}
      :error -> {:error, :invalid_vertex_veo_base64}
    end
  end

  defp has_vertex_veo_gcs_uri?(%{"gcsUris" => [uri | _]}) when is_binary(uri), do: true
  defp has_vertex_veo_gcs_uri?(%{gcsUris: [uri | _]}) when is_binary(uri), do: true

  defp has_vertex_veo_gcs_uri?(%{"generatedVideos" => [%{"video" => %{"uri" => uri}} | _]})
       when is_binary(uri),
       do: true

  defp has_vertex_veo_gcs_uri?(%{generatedVideos: [%{video: %{uri: uri}} | _]})
       when is_binary(uri),
       do: true

  defp has_vertex_veo_gcs_uri?(_response), do: false

  defp vertex_aspect_ratio(value) do
    case optional_string(value) do
      ratio when ratio in ["16:9", "9:16"] -> ratio
      "1280x720" -> "16:9"
      "720x1280" -> "9:16"
      _ -> nil
    end
  end

  defp vertex_duration(value) do
    case optional_string(value) do
      nil -> nil
      value -> bounded_integer(value, 1, 60)
    end
  end

  defp bounded_integer(value, min, max) do
    case Integer.parse(value) do
      {int, ""} -> int |> max(min) |> min(max)
      _ -> min
    end
  end
end
