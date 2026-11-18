defmodule LemonSkills.Tools.MediaGenerateImage do
  @moduledoc """
  Supervised image-generation preview tool backed by LemonMedia.MediaJobSupervisor.

  Wired into CodingAgent.ToolRegistry's builtin tool list. Supports deterministic local SVG previews,
  OpenAI image generation (OpenAI credentials) and Vertex AI Imagen (Google
  service-account credentials).
  """

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.ProviderConfigResolver
  alias LemonAgent.Tools.AbortHelpers
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.Config
  alias LemonSkills.Tools.MediaCommon
  alias LemonMedia.MediaJobSupervisor

  import LemonSkills.Tools.MediaCommon,
    only: [
      bounded_integer: 3,
      optional_string: 1,
      provider_error_kind: 1,
      reject_blank_values: 1,
      transient_status?: 1,
      wait_for_job: 3
    ]

  @topic "media_jobs"
  @default_timeout_ms 5_000
  @max_timeout_ms 30_000
  @local_provider "local_svg"
  @openai_provider "openai_image"
  @vertex_provider "vertex_imagen"
  @local_model "local_svg_preview"
  @default_openai_model "gpt-image-1"
  @default_vertex_model "imagen-4.0-generate-001"
  @default_vertex_location "us-central1"
  @image_formats %{
    "png" => "image/png",
    "jpeg" => "image/jpeg",
    "jpg" => "image/jpeg",
    "webp" => "image/webp"
  }

  @doc """
  Returns the `LemonAgent.Types.AgentTool.t()` definition for the
  `"media_generate_image"` tool, wired to `execute/6`.

  `cwd` is the project directory; it seeds the default artifacts directory
  and is used to load config for provider credentials. The `opts` keyword is
  read for: `:media_artifacts_dir` (defaults to
  `MediaJobs.default_artifacts_dir(cwd)`), `:media_jobs_dir`,
  `:media_image_config` (lazily `Config.load(cwd)`), `:openai_image_api_key`,
  `:openai_image_base_url`, `:media_image_http_post` (defaults to
  `&Req.post/2`), `:vertex_imagen_access_token`, `:vertex_imagen_project`,
  `:vertex_imagen_location`, `:vertex_imagen_service_account_json`, and
  `:vertex_token_http_post` (defaults to `&Req.post/2`).
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_generate_image",
      timeout_ms: :infinity,
      description:
        "Generate a supervised image through Lemon's BEAM media worker path. Supports deterministic local SVG previews, OpenAI image generation, and Vertex AI Imagen, records redacted media-job metadata, and can opt into final Telegram/Discord attachment delivery.",
      label: "Media Generate Image",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "description" => "Image prompt. Stored only as redacted metadata."
          },
          "provider" => %{
            "type" => "string",
            "enum" => [@local_provider, @openai_provider, @vertex_provider],
            "description" =>
              "Image provider. local_svg is deterministic; openai_image uses OpenAI image credentials; vertex_imagen uses Google Vertex AI Imagen credentials."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Optional provider model. Defaults to local_svg_preview, gpt-image-1, or imagen-4.0-generate-001."
          },
          "filename" => %{
            "type" => "string",
            "description" =>
              "Optional artifact filename. The tool always writes under .lemon/media-artifacts."
          },
          "size" => %{
            "type" => "string",
            "description" => "Optional provider image size, for example 1024x1024."
          },
          "quality" => %{
            "type" => "string",
            "description" => "Optional provider quality setting."
          },
          "outputFormat" => %{
            "type" => "string",
            "enum" => ["png", "jpeg", "webp"],
            "description" => "OpenAI image artifact format. Defaults to png."
          },
          "maxRetries" => %{
            "type" => "integer",
            "description" => "Maximum transient provider retries for OpenAI image jobs."
          },
          "sendToChannel" => %{
            "type" => "boolean",
            "description" => "When true, request final Telegram/Discord attachment delivery."
          },
          "timeoutMs" => %{
            "type" => "integer",
            "description" => "Maximum time to wait for the supervised media worker."
          }
        },
        "required" => ["prompt"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Tool callback invoked by the agent loop with, in order: `tool_call_id`,
  `params` map, `signal`, `on_update` callback, `cwd`, and `opts`.

  Reads `"prompt"` (required, non-empty after trimming), `"provider"`
  (defaults to `"local_svg"`; the other accepted values are `"openai_image"`
  and `"vertex_imagen"`), `"model"` (defaults to `"local_svg_preview"`,
  `"gpt-image-1"`, or `"imagen-4.0-generate-001"` per provider), `"filename"`,
  `"size"` (for Vertex, `"1024x1024"` maps to aspect ratio `"1:1"`),
  `"quality"` (OpenAI only), `"outputFormat"`/`"output_format"` (defaults to
  `"png"`; `"jpg"` maps to `"jpeg"`), `"maxRetries"` (defaults to `1`, clamped
  0-3), `"sendToChannel"` (defaults to `false`), and `"timeoutMs"` (defaults
  to `5_000`, clamped 100-30_000).

  On success returns a `%LemonAgent.Types.AgentToolResult{}` with `content`
  the pretty-printed JSON payload and `details` the payload map (`job_id`,
  `status`, `type`, `provider`, `model`, `prompt_hash`, `prompt_chars`,
  `artifact`, `media_job`, and — when `"sendToChannel"` is true —
  `auto_send_files`). Failures return `{:error, message}` with a string
  message, e.g. a missing prompt, unsupported provider/format, an aborted
  operation, or a failed or timed-out media job.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with :ok <- AbortHelpers.check_abort(signal),
         {:ok, prompt} <- required_prompt(params),
         {:ok, provider} <- provider(params),
         {:ok, generation} <- generation(provider, params),
         {:ok, timeout_ms} <- MediaCommon.timeout_ms(params, @default_timeout_ms, @max_timeout_ms),
         {:ok, artifact_path} <-
           MediaCommon.artifact_path(params, cwd, opts, generation.format, "media-preview"),
         :ok <- Phoenix.PubSub.subscribe(LemonCore.PubSub, @topic),
         {:ok, _pid, queued_job} <-
           MediaJobSupervisor.start_job(
             %{
               type: :image,
               provider: provider,
               model: generation.model,
               prompt: prompt,
               artifact_name: Path.basename(artifact_path),
               mime_type: generation.mime_type
             },
             MediaCommon.media_job_opts(
               cwd,
               opts,
               artifact_path,
               runner(cwd, opts, artifact_path, generation)
             )
           ),
         :ok <- AbortHelpers.check_abort(signal),
         {:ok, completed_job} <- wait_for_job(queued_job.job_id, timeout_ms, signal) do
      payload = payload(completed_job, artifact_path, params)

      %AgentToolResult{
        content: [%TextContent{type: :text, text: Jason.encode!(payload, pretty: true)}],
        details: payload
      }
    end
  end

  defp required_prompt(%{"prompt" => prompt}) when is_binary(prompt) do
    prompt = String.trim(prompt)
    if prompt == "", do: {:error, "prompt is required"}, else: {:ok, prompt}
  end

  defp required_prompt(_params), do: {:error, "prompt is required"}

  defp provider(params) do
    case Map.get(params, "provider", @local_provider) do
      @local_provider -> {:ok, @local_provider}
      @openai_provider -> {:ok, @openai_provider}
      @vertex_provider -> {:ok, @vertex_provider}
      other when is_binary(other) -> {:error, "unsupported media provider: #{other}"}
      _other -> {:error, "provider must be a string"}
    end
  end

  defp generation(@local_provider, _params) do
    {:ok,
     %{
       provider: @local_provider,
       model: @local_model,
       format: "svg",
       mime_type: "image/svg+xml"
     }}
  end

  defp generation(@openai_provider, params) do
    with {:ok, format} <- image_format(params) do
      {:ok,
       %{
         provider: @openai_provider,
         model: optional_string(params["model"]) || @default_openai_model,
         format: format,
         mime_type: Map.fetch!(@image_formats, format),
         size: optional_string(params["size"]),
         quality: optional_string(params["quality"]),
         max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3)
       }}
    end
  end

  defp generation(@vertex_provider, params) do
    with {:ok, format} <- image_format(params) do
      {:ok,
       %{
         provider: @vertex_provider,
         model: optional_string(params["model"]) || @default_vertex_model,
         format: format,
         mime_type: Map.fetch!(@image_formats, format),
         aspect_ratio: vertex_aspect_ratio(params["size"]),
         max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3)
       }}
    end
  end

  defp runner(_cwd, _opts, artifact_path, %{provider: @local_provider}) do
    &run_local_svg(&1, artifact_path)
  end

  defp runner(cwd, opts, artifact_path, %{provider: @openai_provider} = generation) do
    runtime = openai_runtime(cwd, opts)
    &run_openai_image(&1, artifact_path, generation, runtime)
  end

  defp runner(cwd, opts, artifact_path, %{provider: @vertex_provider} = generation) do
    runtime = vertex_runtime(cwd, opts)
    &run_vertex_image(&1, artifact_path, generation, runtime)
  end

  defp run_local_svg(attrs, artifact_path) do
    prompt_hash = prompt_hash(Map.get(attrs, :prompt) || Map.get(attrs, "prompt"))
    content = svg(prompt_hash)

    with :ok <- MediaCommon.write_artifact(artifact_path, content),
         {:ok, stat} <- File.stat(artifact_path) do
      {:ok,
       %{
         artifact_path: artifact_path,
         artifact_name: Path.basename(artifact_path),
         mime_type: "image/svg+xml",
         bytes: stat.size
       }}
    end
  end

  defp run_openai_image(attrs, artifact_path, generation, runtime) do
    with {:ok, api_key} <- MediaCommon.provider_api_key(runtime, :missing_openai_image_api_key),
         {:ok, response} <- post_openai_image(attrs, generation, runtime, api_key),
         {:ok, bytes} <- decode_image_response(response) do
      write_artifact(artifact_path, bytes, generation.mime_type)
    end
  end

  defp run_vertex_image(attrs, artifact_path, generation, runtime) do
    with {:ok, access_token} <- vertex_access_token(runtime),
         {:ok, response} <- post_vertex_image(attrs, generation, runtime, access_token),
         {:ok, {bytes, mime_type}} <- decode_vertex_image_response(response, generation.mime_type) do
      write_artifact(artifact_path, bytes, mime_type)
    end
  end

  defp openai_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_image_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :openai) || %{}

    {:ok, endpoint} =
      MediaCommon.openai_compatible_endpoint(
        :openai,
        provider_cfg,
        Keyword.get(opts, :openai_image_api_key),
        Keyword.get(opts, :openai_image_base_url)
      )

    Map.put(endpoint, :http_post, Keyword.get(opts, :media_image_http_post, &Req.post/2))
  end

  defp vertex_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_image_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :google_vertex) || %{}

    resolved =
      ProviderConfigResolver.resolve_for_provider(
        :google_vertex,
        Map.merge(provider_cfg, %{cwd: cwd})
      )

    %{
      access_token: Keyword.get(opts, :vertex_imagen_access_token),
      project: Keyword.get(opts, :vertex_imagen_project) || resolved[:project],
      location:
        Keyword.get(opts, :vertex_imagen_location) ||
          resolved[:location] ||
          @default_vertex_location,
      service_account_json:
        Keyword.get(opts, :vertex_imagen_service_account_json) ||
          resolved[:service_account_json],
      http_post: Keyword.get(opts, :media_image_http_post, &Req.post/2),
      token_http_post: Keyword.get(opts, :vertex_token_http_post, &Req.post/2)
    }
  end

  defp vertex_access_token(%{access_token: token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp vertex_access_token(%{service_account_json: json} = runtime)
       when is_binary(json) and json != "" do
    with {:ok, credentials} <- Jason.decode(json),
         {:ok, jwt, token_uri} <- vertex_service_account_jwt(credentials),
         {:ok, token} <- exchange_vertex_jwt(jwt, token_uri, runtime) do
      {:ok, token}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_vertex_service_account_json}
    end
  end

  defp vertex_access_token(_runtime), do: {:error, :missing_vertex_imagen_credentials}

  defp vertex_service_account_jwt(credentials) do
    client_email = credentials["client_email"]
    private_key = credentials["private_key"]
    token_uri = credentials["token_uri"] || "https://oauth2.googleapis.com/token"

    if is_binary(client_email) and client_email != "" and is_binary(private_key) and
         private_key != "" do
      now = System.system_time(:second)

      header = %{"alg" => "RS256", "typ" => "JWT"}

      claims = %{
        "iss" => client_email,
        "sub" => client_email,
        "scope" => "https://www.googleapis.com/auth/cloud-platform",
        "aud" => token_uri,
        "iat" => now,
        "exp" => now + 3600
      }

      signing_input =
        Base.url_encode64(Jason.encode!(header), padding: false) <>
          "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

      with [pem_entry | _] <- :public_key.pem_decode(private_key),
           private_key <- :public_key.pem_entry_decode(pem_entry) do
        signature = :public_key.sign(signing_input, :sha256, private_key)
        jwt = signing_input <> "." <> Base.url_encode64(signature, padding: false)
        {:ok, jwt, token_uri}
      else
        _ -> {:error, :invalid_vertex_service_account_private_key}
      end
    else
      {:error, :invalid_vertex_service_account_json}
    end
  end

  defp exchange_vertex_jwt(jwt, token_uri, runtime) do
    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    request_opts = [
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: body,
      receive_timeout: 60_000
    ]

    case runtime.token_http_post.(token_uri, request_opts) do
      {:ok, %{status: status, body: %{"access_token" => token}}}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:vertex_imagen_token_http_error, status, provider_error_kind(response_body)}}

      {:error, reason} ->
        {:error, {:vertex_imagen_token_request_failed, provider_error_kind(reason)}}
    end
  end

  defp post_openai_image(attrs, generation, runtime, api_key) do
    prompt = Map.get(attrs, :prompt) || Map.get(attrs, "prompt")
    url = String.trim_trailing(runtime.base_url, "/") <> "/images/generations"

    body =
      %{
        "model" => generation.model,
        "prompt" => prompt,
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

    do_post_openai_image(runtime, url, request_opts, generation.max_retries)
  end

  defp post_vertex_image(attrs, generation, runtime, access_token) do
    with {:ok, project} <- required_vertex_value(runtime.project, :missing_vertex_imagen_project),
         {:ok, location} <-
           required_vertex_value(runtime.location, :missing_vertex_imagen_location) do
      prompt = Map.get(attrs, :prompt) || Map.get(attrs, "prompt")

      url =
        "https://#{location}-aiplatform.googleapis.com/v1/projects/#{project}/locations/#{location}/publishers/google/models/#{generation.model}:predict"

      parameters =
        %{
          "sampleCount" => 1,
          "outputOptions" => %{"mimeType" => generation.mime_type},
          "aspectRatio" => generation.aspect_ratio
        }
        |> reject_blank_values()

      body = %{
        "instances" => [%{"prompt" => prompt}],
        "parameters" => parameters
      }

      request_opts = [
        headers: [{"authorization", "Bearer #{access_token}"}],
        json: body,
        receive_timeout: 300_000
      ]

      do_post_vertex_image(runtime, url, request_opts, generation.max_retries)
    end
  end

  defp required_vertex_value(value, _reason) when is_binary(value) and value != "",
    do: {:ok, value}

  defp required_vertex_value(_value, reason), do: {:error, reason}

  defp do_post_vertex_image(runtime, url, request_opts, remaining_retries) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        if transient_status?(status) and remaining_retries > 0 do
          do_post_vertex_image(runtime, url, request_opts, remaining_retries - 1)
        else
          {:error, {:vertex_imagen_http_error, status, provider_error_kind(response_body)}}
        end

      {:error, _reason} when remaining_retries > 0 ->
        do_post_vertex_image(runtime, url, request_opts, remaining_retries - 1)

      {:error, reason} ->
        {:error, {:vertex_imagen_request_failed, provider_error_kind(reason)}}
    end
  end

  defp do_post_openai_image(runtime, url, request_opts, remaining_retries) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        if transient_status?(status) and remaining_retries > 0 do
          do_post_openai_image(runtime, url, request_opts, remaining_retries - 1)
        else
          {:error, {:openai_image_http_error, status, provider_error_kind(response_body)}}
        end

      {:error, _reason} when remaining_retries > 0 ->
        do_post_openai_image(runtime, url, request_opts, remaining_retries - 1)

      {:error, reason} ->
        {:error, {:openai_image_request_failed, provider_error_kind(reason)}}
    end
  end

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

  defp write_artifact(artifact_path, bytes, mime_type) when is_binary(bytes) do
    with :ok <- MediaCommon.write_artifact(artifact_path, bytes),
         {:ok, stat} <- File.stat(artifact_path) do
      {:ok,
       %{
         artifact_path: artifact_path,
         artifact_name: Path.basename(artifact_path),
         mime_type: mime_type,
         bytes: stat.size
       }}
    end
  end

  defp payload(job, artifact_path, params) do
    job
    |> MediaCommon.payload(artifact_path, mime_type_from_path(artifact_path), "prompt")
    |> MediaCommon.maybe_auto_send(params, "generated image preview")
  end

  defp prompt_hash(prompt) do
    :crypto.hash(:sha256, to_string(prompt))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp image_format(params) do
    value =
      params
      |> Map.get("outputFormat", Map.get(params, "output_format", "png"))
      |> optional_string()

    format = String.downcase(value || "png")

    cond do
      format == "jpg" -> {:ok, "jpeg"}
      Map.has_key?(@image_formats, format) -> {:ok, format}
      true -> {:error, "unsupported image output format: #{format}"}
    end
  end

  defp vertex_aspect_ratio(value) do
    value
    |> optional_string()
    |> case do
      ratio when ratio in ["1:1", "3:4", "4:3", "16:9", "9:16"] -> ratio
      "1024x1024" -> "1:1"
      _ -> nil
    end
  end

  defp mime_type_from_path(path) do
    case String.downcase(Path.extname(path)) do
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      ".jpeg" -> "image/jpeg"
      ".jpg" -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
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
