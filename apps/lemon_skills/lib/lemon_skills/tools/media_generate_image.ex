defmodule LemonSkills.Tools.MediaGenerateImage do
  @moduledoc """
  Supervised image-generation preview tool backed by LemonMedia.MediaJobSupervisor.

  Wired into CodingAgent.ToolRegistry's builtin tool list. Supports deterministic local SVG previews,
  OpenAI image generation (OpenAI credentials) and Vertex AI Imagen (Google
  service-account credentials).
  """

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.ModelRuntime.StreamOptions.ProviderSettings
  alias LemonAgent.Tools.AbortHelpers
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.Config
  alias LemonSkills.Tools.MediaCommon

  import LemonSkills.Tools.MediaCommon,
    only: [
      bounded_integer: 3,
      optional_string: 1
    ]

  @local_timeout_ms 5_000
  @provider_timeout_ms 180_000
  @max_timeout_ms 600_000
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
        "required" => ["prompt", "provider"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Tool callback invoked by the agent loop with, in order: `tool_call_id`,
  `params` map, `signal`, `on_update` callback, `cwd`, and `opts`.

  Reads `"prompt"` (required, non-empty after trimming), `"provider"`
  (required: `"local_svg"`, `"openai_image"`, or
  `"vertex_imagen"`), `"model"` (defaults to `"local_svg_preview"`,
  `"gpt-image-1"`, or `"imagen-4.0-generate-001"` per provider), `"filename"`,
  `"size"` (for Vertex, `"1024x1024"` maps to aspect ratio `"1:1"`),
  `"quality"` (OpenAI only), `"outputFormat"`/`"output_format"` (defaults to
  `"png"`; `"jpg"` maps to `"jpeg"`), `"maxRetries"` (defaults to `1`, clamped
  0-3), `"sendToChannel"` (defaults to `false`), and `"timeoutMs"` (defaults
  to `5_000` local or `180_000` provider-backed, clamped 100-600_000).

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
         {:ok, timeout_ms} <-
           MediaCommon.timeout_ms(params, default_timeout_ms(provider), @max_timeout_ms),
         {:ok, artifact_path} <-
           MediaCommon.artifact_path(params, cwd, opts, generation.format, "media-preview"),
         {:ok, completed_job} <-
           MediaCommon.run_job(
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
               MediaCommon.runner(generation, artifact_path, runtime(cwd, opts, generation))
             ),
             timeout_ms,
             signal
           ) do
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
    case Map.get(params, "provider") do
      @local_provider -> {:ok, @local_provider}
      @openai_provider -> {:ok, @openai_provider}
      @vertex_provider -> {:ok, @vertex_provider}
      nil -> {:error, "provider is required"}
      other when is_binary(other) -> {:error, "unsupported media provider: #{other}"}
      _other -> {:error, "provider must be a string"}
    end
  end

  defp default_timeout_ms(@local_provider), do: @local_timeout_ms
  defp default_timeout_ms(_provider), do: @provider_timeout_ms

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

  defp runtime(_cwd, _opts, %{provider: @local_provider}), do: nil
  defp runtime(cwd, opts, %{provider: @openai_provider}), do: openai_runtime(cwd, opts)
  defp runtime(cwd, opts, %{provider: @vertex_provider}), do: vertex_runtime(cwd, opts)

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

    Map.merge(endpoint, %{
      credential: MediaCommon.credential(endpoint, :missing_openai_image_api_key),
      http_post: Keyword.get(opts, :media_image_http_post)
    })
  end

  defp vertex_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_image_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :google_vertex) || %{}

    resolved =
      ProviderSettings.resolve(
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
      http_post: Keyword.get(opts, :media_image_http_post),
      token_http_post: Keyword.get(opts, :vertex_token_http_post)
    }
  end

  defp payload(job, artifact_path, params) do
    job
    |> MediaCommon.payload(artifact_path, mime_type_from_path(artifact_path), "prompt")
    |> MediaCommon.maybe_auto_send(params, "generated image preview")
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
end
