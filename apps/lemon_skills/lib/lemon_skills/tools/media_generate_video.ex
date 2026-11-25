defmodule LemonSkills.Tools.MediaGenerateVideo do
  @moduledoc """
  Supervised video-generation preview tool backed by LemonMedia.MediaJobSupervisor.

  Wired into CodingAgent.ToolRegistry's builtin tool list. Supports deterministic local MP4 previews,
  OpenAI video jobs (OpenAI credentials) and Vertex AI Veo long-running
  prediction (Google service-account credentials).
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

  @local_timeout_ms 20_000
  @provider_timeout_ms 900_000
  @max_timeout_ms 1_800_000
  @local_provider "local_mp4"
  @openai_provider "openai_video"
  @vertex_provider "vertex_veo"
  @local_model "local_mp4_preview"
  @default_openai_model "sora-2"
  @default_vertex_model "veo-3.1-fast-generate-001"
  @default_vertex_location "us-central1"
  @formats %{"mp4" => "video/mp4"}

  @doc """
  Returns the `LemonAgent.Types.AgentTool.t()` definition for the
  `"media_generate_video"` tool, wired to `execute/6`.

  `cwd` is the project directory; it seeds the default artifacts directory
  and is used to load config for provider credentials. The `opts` keyword is
  read for: `:media_artifacts_dir` (defaults to
  `MediaJobs.default_artifacts_dir(cwd)`), `:media_jobs_dir`,
  `:media_video_config` (lazily `Config.load(cwd)`), `:openai_video_api_key`,
  `:openai_video_base_url`, `:media_video_http_post` (defaults to
  `&Req.post/2`), `:media_video_http_get` (defaults to `&Req.get/2`),
  `:vertex_veo_access_token`, `:vertex_veo_project`, `:vertex_veo_location`,
  `:vertex_veo_service_account_json`, and `:vertex_token_http_post` (defaults
  to `&Req.post/2`).
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_generate_video",
      timeout_ms: :infinity,
      description:
        "Generate a supervised video through Lemon's BEAM media worker path. Supports deterministic local MP4 previews, OpenAI video job create/poll/download, and Vertex AI Veo long-running prediction, records redacted media-job metadata, and can opt into final Telegram/Discord attachment delivery.",
      label: "Media Generate Video",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "description" => "Video prompt. Stored only as redacted metadata."
          },
          "provider" => %{
            "type" => "string",
            "enum" => [@local_provider, @openai_provider, @vertex_provider],
            "description" =>
              "Video provider. local_mp4 is deterministic; openai_video uses OpenAI video credentials; vertex_veo uses Google Vertex AI Veo credentials."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Optional provider model. Defaults to local_mp4_preview, sora-2, or veo-3.1-fast-generate-001."
          },
          "filename" => %{
            "type" => "string",
            "description" =>
              "Optional artifact filename. The tool always writes under .lemon/media-artifacts."
          },
          "size" => %{
            "type" => "string",
            "description" => "Optional provider video size, for example 1280x720."
          },
          "seconds" => %{
            "type" => "string",
            "description" => "Optional provider duration in seconds."
          },
          "storageUri" => %{
            "type" => "string",
            "description" =>
              "Optional Vertex Veo Google Cloud Storage output URI. When omitted, Lemon expects inline video bytes from the operation response."
          },
          "maxRetries" => %{
            "type" => "integer",
            "description" =>
              "Maximum transient provider retries for OpenAI video create/status/download calls."
          },
          "maxPolls" => %{
            "type" => "integer",
            "description" => "Maximum OpenAI video status polls before failing the job."
          },
          "pollIntervalMs" => %{
            "type" => "integer",
            "description" => "Delay between OpenAI video status polls."
          },
          "sendToChannel" => %{
            "type" => "boolean",
            "description" =>
              "When true, request final Telegram/Discord video attachment delivery."
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
  (required: `"local_mp4"`, `"openai_video"`, or
  `"vertex_veo"`), `"model"` (defaults to `"local_mp4_preview"`,
  `"sora-2"`, or `"veo-3.1-fast-generate-001"` per provider), `"filename"`,
  `"size"` (for Vertex, `"1280x720"`/`"720x1280"` map to `"16:9"`/`"9:16"`),
  `"seconds"` (for Vertex, clamped 1-60), `"storageUri"`/`"storage_uri"`
  (Vertex GCS output URI; when omitted the tool expects inline bytes),
  `"maxRetries"` (defaults to `1`, clamped 0-3), `"maxPolls"` (defaults to
  `30`, clamped 1-120), `"pollIntervalMs"` (defaults to `2_000`, clamped
  0-30_000), `"sendToChannel"` (defaults to `false`), and `"timeoutMs"`
  (defaults to `20_000` local or `900_000` provider-backed, clamped
  100-1_800_000).

  On success returns a `%LemonAgent.Types.AgentToolResult{}` with `content`
  the pretty-printed JSON payload and `details` the payload map (`job_id`,
  `status`, `type`, `provider`, `model`, `prompt_hash`, `prompt_chars`,
  `artifact`, `media_job`, and — when `"sendToChannel"` is true —
  `auto_send_files`). Failures return `{:error, message}` with a string
  message, e.g. a missing prompt, unsupported provider, an aborted operation,
  or a failed or timed-out media job.
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
           MediaCommon.artifact_path(params, cwd, opts, generation.format, "media-video"),
         {:ok, completed_job} <-
           MediaCommon.run_job(
             %{
               type: :video,
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
      other when is_binary(other) -> {:error, "unsupported media video provider: #{other}"}
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
       format: "mp4",
       mime_type: "video/mp4"
     }}
  end

  defp generation(@openai_provider, params) do
    {:ok,
     %{
       provider: @openai_provider,
       model: optional_string(params["model"]) || @default_openai_model,
       format: "mp4",
       mime_type: "video/mp4",
       size: optional_string(params["size"]),
       seconds: optional_string(params["seconds"]),
       max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3),
       max_polls: bounded_integer(Map.get(params, "maxPolls", 30), 1, 120),
       poll_interval_ms: bounded_integer(Map.get(params, "pollIntervalMs", 2_000), 0, 30_000)
     }}
  end

  defp generation(@vertex_provider, params) do
    {:ok,
     %{
       provider: @vertex_provider,
       model: optional_string(params["model"]) || @default_vertex_model,
       format: "mp4",
       mime_type: "video/mp4",
       size: optional_string(params["size"]),
       seconds: optional_string(params["seconds"]),
       storage_uri: optional_string(params["storageUri"] || params["storage_uri"]),
       max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3),
       max_polls: bounded_integer(Map.get(params, "maxPolls", 30), 1, 120),
       poll_interval_ms: bounded_integer(Map.get(params, "pollIntervalMs", 2_000), 0, 30_000)
     }}
  end

  defp runtime(_cwd, _opts, %{provider: @local_provider}), do: nil
  defp runtime(cwd, opts, %{provider: @openai_provider}), do: openai_runtime(cwd, opts)
  defp runtime(cwd, opts, %{provider: @vertex_provider}), do: vertex_runtime(cwd, opts)

  defp openai_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_video_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :openai) || %{}

    {:ok, endpoint} =
      MediaCommon.openai_compatible_endpoint(
        :openai,
        provider_cfg,
        Keyword.get(opts, :openai_video_api_key),
        Keyword.get(opts, :openai_video_base_url)
      )

    Map.merge(endpoint, %{
      credential: MediaCommon.credential(endpoint, :missing_openai_video_api_key),
      http_post: Keyword.get(opts, :media_video_http_post),
      http_get: Keyword.get(opts, :media_video_http_get)
    })
  end

  defp vertex_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_video_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :google_vertex) || %{}

    resolved =
      ProviderSettings.resolve(:google_vertex,
      Map.merge(provider_cfg, %{cwd: cwd}))

    %{
      access_token: Keyword.get(opts, :vertex_veo_access_token),
      project: Keyword.get(opts, :vertex_veo_project) || resolved[:project],
      location:
        Keyword.get(opts, :vertex_veo_location) ||
          resolved[:location] ||
          @default_vertex_location,
      service_account_json:
        Keyword.get(opts, :vertex_veo_service_account_json) ||
          resolved[:service_account_json],
      http_post: Keyword.get(opts, :media_video_http_post),
      token_http_post: Keyword.get(opts, :vertex_token_http_post)
    }
  end

  defp payload(job, artifact_path, params) do
    job
    |> MediaCommon.payload(artifact_path, mime_type_from_path(artifact_path), "prompt")
    |> MediaCommon.maybe_auto_send(params, "generated video preview")
  end

  defp mime_type_from_path(path) do
    case String.downcase(Path.extname(path)) do
      ".mp4" -> Map.fetch!(@formats, "mp4")
      _ -> "application/octet-stream"
    end
  end
end
