defmodule LemonSkills.Tools.MediaAnalyzeImage do
  @moduledoc """
  Supervised image-analysis preview tool backed by LemonMedia.MediaJobSupervisor.

  Wired into CodingAgent.ToolRegistry's builtin tool list. Supports deterministic local vision previews
  and OpenAI vision analysis; OpenAI jobs require OpenAI vision credentials.
  """

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.Security.ExternalContent
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
      transient_status?: 1,
      wait_for_job: 3
    ]

  @topic "media_jobs"
  @default_timeout_ms 15_000
  @max_timeout_ms 120_000
  @max_image_bytes 20 * 1024 * 1024
  @local_provider "local_vision"
  @openai_provider "openai_vision"
  @local_model "local_vision_preview"
  @default_openai_model "gpt-4o-mini"
  @default_prompt "Describe the image and note any visible text."
  @image_mime_types %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".svg" => "image/svg+xml",
    ".webp" => "image/webp"
  }
  @openai_image_mime_types MapSet.new(~w(image/gif image/jpeg image/png image/webp))
  @analysis_formats %{
    "json" => "application/json",
    "text" => "text/plain"
  }

  @doc """
  Returns the `LemonAgent.Types.AgentTool.t()` definition for the
  `"media_analyze_image"` tool, wired to `execute/6`.

  `cwd` is the project directory: `"imagePath"` must resolve under it, and it
  seeds the default artifacts directory. The `opts` keyword is read for:
  `:media_artifacts_dir` (defaults to `MediaJobs.default_artifacts_dir(cwd)`),
  `:media_jobs_dir`, `:media_vision_config` (lazily `Config.load(cwd)`),
  `:openai_vision_api_key`, `:openai_vision_base_url`, and
  `:media_vision_http_post` (defaults to `&Req.post/2`).
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_analyze_image",
      timeout_ms: :infinity,
      description:
        "Analyze a local image artifact through Lemon's BEAM media worker path. Supports deterministic local vision previews and OpenAI vision analysis, records redacted media-job metadata, and can opt into final Telegram/Discord analysis delivery.",
      label: "Media Analyze Image",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "imagePath" => %{
            "type" => "string",
            "description" =>
              "Path to a local image file under the current project. Raw image bytes and paths are never stored in job metadata."
          },
          "prompt" => %{
            "type" => "string",
            "description" => "Optional analysis instruction. Stored only as redacted metadata."
          },
          "provider" => %{
            "type" => "string",
            "enum" => [@local_provider, @openai_provider],
            "description" =>
              "Vision provider. local_vision is deterministic; openai_vision uses OpenAI vision credentials."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Optional provider model. Defaults to local_vision_preview or gpt-4o-mini."
          },
          "detail" => %{
            "type" => "string",
            "enum" => ["auto", "low", "high"],
            "description" => "Optional OpenAI image detail setting. Defaults to auto."
          },
          "filename" => %{
            "type" => "string",
            "description" =>
              "Optional analysis artifact filename. The tool always writes under .lemon/media-artifacts."
          },
          "responseFormat" => %{
            "type" => "string",
            "enum" => ["json", "text"],
            "description" => "Analysis artifact format. Defaults to json."
          },
          "maxRetries" => %{
            "type" => "integer",
            "description" => "Maximum transient provider retries for OpenAI vision jobs."
          },
          "sendToChannel" => %{
            "type" => "boolean",
            "description" =>
              "When true, request final Telegram/Discord analysis attachment delivery."
          },
          "timeoutMs" => %{
            "type" => "integer",
            "description" => "Maximum time to wait for the supervised media worker."
          }
        },
        "required" => ["imagePath"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Tool callback invoked by the agent loop with, in order: `tool_call_id`,
  `params` map, `signal`, `on_update` callback, `cwd`, and `opts`.

  Reads `"imagePath"` (required; must be a regular file of 20MB or less under
  the project), `"prompt"` (defaults to `"Describe the image and note any
  visible text."`), `"provider"` (defaults to `"local_vision"`; the only other
  accepted value is `"openai_vision"`), `"model"` (defaults to
  `"local_vision_preview"` for local jobs and `"gpt-4o-mini"` for OpenAI),
  `"detail"` (defaults to `"auto"`), `"filename"`,
  `"responseFormat"`/`"response_format"` (defaults to `"json"`; `"text"` is
  the other accepted value), `"maxRetries"` (defaults to `1`, clamped 0-3),
  `"sendToChannel"` (defaults to `false`), and `"timeoutMs"` (defaults to
  `15_000`, clamped 100-120_000).

  On success returns a `%LemonAgent.Types.AgentToolResult{}` marked
  `trust: :untrusted`, with `content` the pretty-printed JSON payload and
  `details` the payload map (`job_id`, `status`, `type`, `provider`, `model`,
  `input_hash`, `input_chars`, `text`, `artifact`, `media_job`,
  `trustMetadata`/`trust_metadata`, and — when `"sendToChannel"` is true —
  `auto_send_files`). Failures return `{:error, message}` with a string
  message, e.g. an invalid `"imagePath"`, unsupported provider/format/detail,
  an aborted operation, or a failed or timed-out media job.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with :ok <- AbortHelpers.check_abort(signal),
         {:ok, image} <- image_file(params, cwd),
         {:ok, prompt} <- prompt(params),
         {:ok, provider} <- provider(params),
         {:ok, generation} <- generation(provider, params, image),
         {:ok, runtime} <- runtime(cwd, opts, generation),
         {:ok, timeout_ms} <- MediaCommon.timeout_ms(params, @default_timeout_ms, @max_timeout_ms),
         {:ok, artifact_path} <-
           MediaCommon.artifact_path(params, cwd, opts, generation.format, "media-analysis"),
         :ok <- Phoenix.PubSub.subscribe(LemonCore.PubSub, @topic),
         {:ok, _pid, queued_job} <-
           MediaJobSupervisor.start_job(
             %{
               type: :vision,
               provider: provider,
               model: generation.model,
               prompt: vision_fingerprint(image, prompt),
               artifact_name: Path.basename(artifact_path),
               mime_type: generation.mime_type
             },
             MediaCommon.media_job_opts(
               cwd,
               opts,
               artifact_path,
               runner(artifact_path, image, prompt, generation, runtime)
             )
           ),
         :ok <- AbortHelpers.check_abort(signal),
         {:ok, completed_job} <- wait_for_job(queued_job.job_id, timeout_ms, signal) do
      payload = payload(completed_job, artifact_path, params)

      %AgentToolResult{
        content: [%TextContent{type: :text, text: Jason.encode!(payload, pretty: true)}],
        details: payload,
        trust: :untrusted
      }
    end
  end

  defp image_file(%{"imagePath" => path}, cwd) when is_binary(path) do
    with {:ok, resolved} <- resolve_image_path(path, cwd),
         {:ok, stat} <- File.stat(resolved),
         :ok <- regular_image_file(stat),
         :ok <- image_size(stat),
         {:ok, bytes} <- File.read(resolved) do
      {:ok,
       %{
         path: resolved,
         name: Path.basename(resolved),
         bytes: bytes,
         byte_size: stat.size,
         hash: hash(bytes),
         mime_type: image_mime_type(resolved)
       }}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "unable to read image file: #{inspect(reason)}"}
    end
  end

  defp image_file(_params, _cwd), do: {:error, "imagePath is required"}

  defp resolve_image_path(path, cwd) do
    cwd = Path.expand(cwd)

    resolved =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, cwd)

    cond do
      not String.starts_with?(resolved, cwd <> "/") and resolved != cwd ->
        {:error, "imagePath must be under the current project"}

      true ->
        {:ok, resolved}
    end
  end

  defp regular_image_file(%File.Stat{type: :regular}), do: :ok
  defp regular_image_file(_stat), do: {:error, "imagePath must be a regular file"}

  defp image_size(%File.Stat{size: size}) when size <= @max_image_bytes, do: :ok
  defp image_size(_stat), do: {:error, "image file must be 20MB or smaller"}

  defp prompt(params), do: {:ok, optional_string(params["prompt"]) || @default_prompt}

  defp provider(params) do
    case Map.get(params, "provider", @local_provider) do
      @local_provider -> {:ok, @local_provider}
      @openai_provider -> {:ok, @openai_provider}
      other when is_binary(other) -> {:error, "unsupported media vision provider: #{other}"}
      _other -> {:error, "provider must be a string"}
    end
  end

  defp generation(@local_provider, params, _image) do
    with {:ok, format} <- analysis_format(params) do
      {:ok,
       %{
         provider: @local_provider,
         model: @local_model,
         format: format,
         mime_type: Map.fetch!(@analysis_formats, format)
       }}
    end
  end

  defp generation(@openai_provider, params, image) do
    with :ok <- openai_supported_image(image),
         {:ok, format} <- analysis_format(params),
         {:ok, detail} <- detail(params) do
      {:ok,
       %{
         provider: @openai_provider,
         model: optional_string(params["model"]) || @default_openai_model,
         detail: detail,
         format: format,
         mime_type: Map.fetch!(@analysis_formats, format),
         max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3)
       }}
    end
  end

  defp openai_supported_image(%{mime_type: mime_type}) do
    if MapSet.member?(@openai_image_mime_types, mime_type) do
      :ok
    else
      {:error, "openai_vision supports png, jpeg, webp, or gif images"}
    end
  end

  defp detail(params) do
    value = params |> Map.get("detail", "auto") |> optional_string()
    detail = String.downcase(value || "auto")

    if detail in ["auto", "low", "high"] do
      {:ok, detail}
    else
      {:error, "unsupported image detail: #{detail}"}
    end
  end

  defp runner(artifact_path, image, _prompt, %{provider: @local_provider}, _runtime) do
    &run_local_analysis(&1, artifact_path, image)
  end

  defp runner(artifact_path, image, prompt, %{provider: @openai_provider} = generation, runtime) do
    &run_openai_analysis(&1, artifact_path, image, prompt, generation, runtime)
  end

  defp run_local_analysis(_attrs, artifact_path, image) do
    analysis =
      "local image analysis preview for #{image.mime_type} image #{String.slice(image.hash, 0, 12)}"

    write_analysis_artifact(
      artifact_path,
      Jason.encode!(%{"text" => analysis}, pretty: true),
      analysis
    )
  end

  defp run_openai_analysis(_attrs, artifact_path, image, prompt, generation, runtime) do
    with {:ok, api_key} <-
           MediaCommon.provider_api_key(runtime, :missing_openai_vision_api_key, runtime.provider),
         {:ok, response} <- post_openai_analysis(image, prompt, generation, runtime, api_key),
         {:ok, analysis, content} <- normalize_analysis_response(response, generation.format) do
      write_analysis_artifact(artifact_path, content, analysis)
    end
  end

  defp runtime(_cwd, _opts, %{provider: @local_provider}), do: {:ok, nil}

  defp runtime(cwd, opts, %{provider: @openai_provider} = generation) do
    config = Keyword.get_lazy(opts, :media_vision_config, fn -> Config.load(cwd) end)
    {provider, api_model} = openai_compatible_provider_and_model(generation.model)
    provider_cfg = ProviderNames.provider_config(config.providers, provider)

    with {:ok, endpoint} <-
           MediaCommon.openai_compatible_endpoint(
             provider,
             provider_cfg,
             Keyword.get(opts, :openai_vision_api_key),
             Keyword.get(opts, :openai_vision_base_url)
           ) do
      {:ok,
       Map.merge(endpoint, %{
         api_model: api_model,
         http_post: Keyword.get(opts, :media_vision_http_post, &Req.post/2)
       })}
    end
  end

  defp openai_compatible_provider_and_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, provider_model] ->
        case ProviderNames.canonical_name(provider) do
          nil -> {:openai, model}
          canonical -> {canonical, provider_model}
        end

      _ ->
        {:openai, model}
    end
  end

  defp openai_compatible_provider_and_model(_model), do: {:openai, @default_openai_model}

  defp post_openai_analysis(image, prompt, generation, runtime, api_key) do
    url = String.trim_trailing(runtime.base_url, "/") <> "/chat/completions"

    body = %{
      "model" => runtime.api_model,
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => prompt},
            %{
              "type" => "image_url",
              "image_url" => %{
                "url" => "data:#{image.mime_type};base64,#{Base.encode64(image.bytes)}",
                "detail" => generation.detail
              }
            }
          ]
        }
      ]
    }

    request_opts = [
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: body,
      receive_timeout: 300_000
    ]

    do_post_openai_analysis(runtime, url, request_opts, generation.max_retries)
  end

  defp do_post_openai_analysis(runtime, url, request_opts, remaining_retries) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        if transient_status?(status) and remaining_retries > 0 do
          do_post_openai_analysis(runtime, url, request_opts, remaining_retries - 1)
        else
          {:error, {:openai_vision_http_error, status, provider_error_kind(response_body)}}
        end

      {:error, _reason} when remaining_retries > 0 ->
        do_post_openai_analysis(runtime, url, request_opts, remaining_retries - 1)

      {:error, reason} ->
        {:error, {:openai_vision_request_failed, provider_error_kind(reason)}}
    end
  end

  defp normalize_analysis_response(response, "json") when is_map(response) do
    text = response_text(response)
    content = Jason.encode!(%{"text" => text}, pretty: true)
    {:ok, text, content}
  end

  defp normalize_analysis_response(response, "json") when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> normalize_analysis_response(decoded, "json")
      _ -> {:ok, response, Jason.encode!(%{"text" => response}, pretty: true)}
    end
  end

  defp normalize_analysis_response(response, "text") when is_binary(response) do
    {:ok, response, response}
  end

  defp normalize_analysis_response(response, "text") when is_map(response) do
    text = response_text(response)
    {:ok, text, text}
  end

  defp response_text(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    content_text(content)
  end

  defp response_text(%{choices: [%{message: %{content: content}} | _]}) do
    content_text(content)
  end

  defp response_text(%{"output_text" => text}) when is_binary(text), do: text
  defp response_text(%{output_text: text}) when is_binary(text), do: text
  defp response_text(%{"text" => text}) when is_binary(text), do: text
  defp response_text(%{text: text}) when is_binary(text), do: text
  defp response_text(response), do: Jason.encode!(response)

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp content_text(content), do: to_string(content)

  defp write_analysis_artifact(artifact_path, content, analysis) when is_binary(content) do
    with :ok <- MediaCommon.write_artifact(artifact_path, content),
         {:ok, stat} <- File.stat(artifact_path) do
      {:ok,
       %{
         artifact_path: artifact_path,
         artifact_name: Path.basename(artifact_path),
         mime_type: mime_type_from_path(artifact_path),
         bytes: stat.size,
         analysis: analysis
       }}
    end
  end

  defp payload(job, artifact_path, params) do
    job
    |> MediaCommon.payload(artifact_path, mime_type_from_path(artifact_path), "input")
    |> Map.put("text", analysis_text(artifact_path))
    |> Map.put("trustMetadata", media_trust_metadata(:camel_case))
    |> Map.put("trust_metadata", media_trust_metadata(:snake_case))
    |> MediaCommon.maybe_auto_send(params, "generated image analysis")
  end

  defp media_trust_metadata(key_style) do
    ExternalContent.trust_metadata(:api,
      key_style: key_style,
      warning_included: false,
      wrapped_fields: ["text"]
    )
  end

  defp analysis_text(path) do
    with {:ok, content} <- File.read(path),
         {:json, true} <- {:json, Path.extname(path) == ".json"},
         {:ok, decoded} <- Jason.decode(content) do
      optional_string(decoded["text"]) || optional_string(decoded[:text]) || content
    else
      {:json, false} -> File.read!(path)
      _ -> nil
    end
  end

  defp analysis_format(params) do
    value =
      params
      |> Map.get("responseFormat", Map.get(params, "response_format", "json"))
      |> optional_string()

    format = String.downcase(value || "json")

    if Map.has_key?(@analysis_formats, format) do
      {:ok, format}
    else
      {:error, "unsupported vision response format: #{format}"}
    end
  end

  defp vision_fingerprint(image, prompt) do
    "image:#{image.hash}:#{image.byte_size}:#{image.mime_type}:#{hash(prompt)}"
  end

  defp image_mime_type(path) do
    Map.get(@image_mime_types, String.downcase(Path.extname(path)), "application/octet-stream")
  end

  defp mime_type_from_path(path) do
    case String.downcase(Path.extname(path)) do
      ".json" -> "application/json"
      ".text" -> "text/plain"
      ".txt" -> "text/plain"
      _ -> "text/plain"
    end
  end

  defp hash(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end
end
