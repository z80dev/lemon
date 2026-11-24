defmodule LemonMedia.Providers.Image do
  @moduledoc """
  Image-generation drivers: `local_svg` preview, OpenAI images, Vertex Imagen.
  """

  alias LemonMedia.{Artifact, GoogleAuth}
  alias LemonMedia.Providers.Http

  import LemonMedia.Providers.Http, only: [optional_string: 1, reject_blank_values: 1]

  @doc false
  def run(%{provider: "local_svg", attrs: attrs, artifact_path: path}) do
    Artifact.store(path, svg(prompt_hash(prompt(attrs))), "image/svg+xml")
  end

  def run(%{provider: "openai_image"} = request) do
    %{attrs: attrs, artifact_path: path, generation: generation, runtime: runtime} = request

    with {:ok, api_key} <- Http.api_key(runtime),
         {:ok, response} <- post_openai_image(attrs, generation, runtime, api_key),
         {:ok, bytes} <- decode_image_response(response) do
      Artifact.store(path, bytes, generation.mime_type)
    end
  end

  def run(%{provider: "vertex_imagen"} = request) do
    %{attrs: attrs, artifact_path: path, generation: generation, runtime: runtime} = request

    with {:ok, access_token} <- GoogleAuth.access_token(runtime, :vertex_imagen),
         {:ok, response} <- post_vertex_image(attrs, generation, runtime, access_token),
         {:ok, {bytes, mime_type}} <- decode_vertex_image_response(response, generation.mime_type) do
      Artifact.store(path, bytes, mime_type)
    end
  end

  defp post_openai_image(attrs, generation, runtime, api_key) do
    body =
      %{
        "model" => generation.model,
        "prompt" => prompt(attrs),
        "n" => 1,
        "size" => generation.size,
        "quality" => generation.quality,
        "output_format" => generation.format
      }
      |> reject_blank_values()

    request_opts = [
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: body,
      receive_timeout: 300_000
    ]

    url = Http.url(runtime.base_url, "/images/generations")

    Http.request(
      fn -> Http.post_fun(runtime).(url, request_opts) end,
      generation.max_retries,
      :openai_image
    )
  end

  defp post_vertex_image(attrs, generation, runtime, access_token) do
    with {:ok, project} <- required(runtime.project, :missing_vertex_imagen_project),
         {:ok, location} <- required(runtime.location, :missing_vertex_imagen_location) do
      url =
        "https://#{location}-aiplatform.googleapis.com/v1/projects/#{project}/locations/#{location}/publishers/google/models/#{generation.model}:predict"

      parameters =
        %{
          "sampleCount" => 1,
          "outputOptions" => %{"mimeType" => generation.mime_type},
          "aspectRatio" => generation.aspect_ratio
        }
        |> reject_blank_values()

      request_opts = [
        headers: [{"authorization", "Bearer #{access_token}"}],
        json: %{"instances" => [%{"prompt" => prompt(attrs)}], "parameters" => parameters},
        receive_timeout: 300_000
      ]

      Http.request(
        fn -> Http.post_fun(runtime).(url, request_opts) end,
        generation.max_retries,
        :vertex_imagen
      )
    end
  end

  defp required(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, reason), do: {:error, reason}

  defp decode_image_response(%{"data" => [%{"b64_json" => encoded} | _]})
       when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_openai_image_base64}
    end
  end

  defp decode_image_response(%{data: [%{b64_json: encoded} | _]}) when is_binary(encoded) do
    decode_image_response(%{"data" => [%{"b64_json" => encoded}]})
  end

  defp decode_image_response(%{"data" => [%{"url" => _url} | _]}) do
    {:error, :openai_image_url_response_unsupported}
  end

  defp decode_image_response(_response), do: {:error, :missing_openai_image_data}

  defp decode_vertex_image_response(
         %{"predictions" => [%{"bytesBase64Encoded" => encoded} = row | _]},
         default_mime
       )
       when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, {bytes, optional_string(row["mimeType"]) || default_mime}}
      :error -> {:error, :invalid_vertex_imagen_base64}
    end
  end

  defp decode_vertex_image_response(
         %{predictions: [%{bytesBase64Encoded: encoded} = row | _]},
         default_mime
       )
       when is_binary(encoded) do
    decode_vertex_image_response(
      %{"predictions" => [%{"bytesBase64Encoded" => encoded, "mimeType" => row[:mimeType]}]},
      default_mime
    )
  end

  defp decode_vertex_image_response(_response, _default_mime),
    do: {:error, :missing_vertex_imagen_prediction}

  defp prompt(attrs), do: Map.get(attrs, :prompt) || Map.get(attrs, "prompt")

  defp prompt_hash(prompt) do
    :crypto.hash(:sha256, to_string(prompt))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp svg(prompt_hash) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <defs>
        <linearGradient id="lemon-media-bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#f7d154"/>
          <stop offset="48%" stop-color="#40b6a6"/>
          <stop offset="100%" stop-color="#22314f"/>
        </linearGradient>
      </defs>
      <rect width="1024" height="1024" fill="url(#lemon-media-bg)"/>
      <circle cx="318" cy="342" r="188" fill="#fff7cf" fill-opacity="0.88"/>
      <circle cx="688" cy="628" r="246" fill="#102033" fill-opacity="0.28"/>
      <path d="M265 704 C386 548 571 508 770 604" fill="none" stroke="#fff7cf" stroke-width="46" stroke-linecap="round"/>
      <text x="512" y="498" text-anchor="middle" font-family="Inter, Arial, sans-serif" font-size="54" font-weight="700" fill="#102033">Lemon media preview</text>
      <text x="512" y="576" text-anchor="middle" font-family="Inter, Arial, sans-serif" font-size="28" fill="#102033">job prompt hash #{prompt_hash}</text>
    </svg>
    """
  end
end
