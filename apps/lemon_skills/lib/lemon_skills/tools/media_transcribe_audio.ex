defmodule LemonSkills.Tools.MediaTranscribeAudio do
  @moduledoc """
  Supervised audio-transcription preview tool backed by LemonMedia.MediaJobSupervisor.

  Transcribes a local audio artifact through Lemon's BEAM media worker path:
  deterministic local previews, OpenAI speech-to-text, or Deepgram speech-to-text.
  OpenAI/Deepgram runs require the corresponding provider API credentials (explicit
  opts, config, or secrets). Registered as a builtin tool in `CodingAgent.ToolRegistry`.
  """

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.Security.ExternalContent
  alias LemonAgent.Tools.AbortHelpers
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.Config
  alias LemonSkills.Tools.MediaCommon

  import LemonSkills.Tools.MediaCommon,
    only: [
      bounded_integer: 3,
      optional_string: 1,
      provider_config_value: 2
    ]

  @local_timeout_ms 15_000
  @provider_timeout_ms 180_000
  @max_timeout_ms 600_000
  @max_audio_bytes 25 * 1024 * 1024
  @local_provider "local_transcript"
  @openai_provider "openai_transcribe"
  @deepgram_provider "deepgram_transcribe"
  @local_model "local_transcript_preview"
  @default_openai_model "gpt-4o-mini-transcribe"
  @default_deepgram_model "nova-3"
  @default_deepgram_base_url "https://api.deepgram.com/v1"
  @audio_mime_types %{
    ".flac" => "audio/flac",
    ".mp3" => "audio/mpeg",
    ".mp4" => "audio/mp4",
    ".mpeg" => "audio/mpeg",
    ".mpga" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".ogg" => "audio/ogg",
    ".wav" => "audio/wav",
    ".webm" => "audio/webm"
  }
  @transcript_formats %{
    "json" => "application/json",
    "text" => "text/plain"
  }

  @doc """
  Returns the `media_transcribe_audio` tool definition wired to `execute/6`.

  `cwd` is the project directory: it scopes `audioPath` resolution, supplies the
  default media-artifacts directory, and is passed to the supervised media job as
  `project_dir`. `opts` may carry:

  - `:media_artifacts_dir` - transcript artifact directory (defaults to
    `MediaJobs.default_artifacts_dir(cwd)`)
  - `:media_jobs_dir` - media job working directory passed to the supervisor
  - `:media_transcription_config` - config resolving provider base URLs and
    credentials (defaults to `Config.load(cwd)`)
  - `:openai_transcription_api_key` / `:openai_transcription_base_url` - explicit
    OpenAI credentials/endpoint overrides
  - `:deepgram_transcription_api_key` / `:deepgram_transcription_base_url` -
    explicit Deepgram credentials/endpoint overrides
  - `:media_transcription_http_post` - HTTP post fun (defaults to `&Req.post/2`)
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_transcribe_audio",
      timeout_ms: :infinity,
      description:
        "Transcribe a local audio artifact through Lemon's BEAM media worker path. Supports deterministic local transcript previews, OpenAI speech-to-text, and Deepgram speech-to-text, records redacted media-job metadata, and can opt into final Telegram/Discord transcript delivery.",
      label: "Media Transcribe Audio",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "audioPath" => %{
            "type" => "string",
            "description" =>
              "Path to a local audio file under the current project. Raw audio is never stored in job metadata."
          },
          "provider" => %{
            "type" => "string",
            "enum" => [@local_provider, @openai_provider, @deepgram_provider],
            "description" =>
              "Transcription provider. local_transcript is deterministic; openai_transcribe uses OpenAI audio credentials; deepgram_transcribe uses Deepgram credentials."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Optional provider model. Defaults to local_transcript_preview or gpt-4o-mini-transcribe."
          },
          "language" => %{
            "type" => "string",
            "description" => "Optional input language hint for supported providers."
          },
          "prompt" => %{
            "type" => "string",
            "description" => "Optional provider prompt for speech-to-text context."
          },
          "filename" => %{
            "type" => "string",
            "description" =>
              "Optional transcript artifact filename. The tool always writes under .lemon/media-artifacts."
          },
          "responseFormat" => %{
            "type" => "string",
            "enum" => ["json", "text"],
            "description" => "Transcript artifact format. Defaults to json."
          },
          "maxRetries" => %{
            "type" => "integer",
            "description" => "Maximum transient provider retries for OpenAI transcription jobs."
          },
          "sendToChannel" => %{
            "type" => "boolean",
            "description" =>
              "When true, request final Telegram/Discord transcript attachment delivery."
          },
          "timeoutMs" => %{
            "type" => "integer",
            "description" => "Maximum time to wait for the supervised media worker."
          }
        },
        "required" => ["audioPath", "provider"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Tool callback invoked by the agent loop: `execute(tool_call_id, params, signal,
  on_update, cwd, opts)`.

  Reads from `params`:

  - `"audioPath"` (required) - local audio file path under `cwd`
  - `"provider"` (required) - `"local_transcript"`,
    `"openai_transcribe"`, or `"deepgram_transcribe"`
  - `"model"` (optional) - provider model override
  - `"language"` (optional) - input language hint
  - `"prompt"` (optional) - provider speech-to-text context
  - `"filename"` (optional) - transcript artifact filename
  - `"responseFormat"` (default `"json"`, `"response_format"` accepted) -
    `"json"` or `"text"`
  - `"maxRetries"` (default `1`, clamped to 0-3) - transient provider retries
  - `"sendToChannel"` (default `false`) - request final Telegram/Discord delivery
  - `"timeoutMs"` (default `15_000` local or `180_000` provider-backed,
    clamped to 100-600_000) - media worker wait

  Returns `%LemonAgent.Types.AgentToolResult{}` on success with `content` holding
  the pretty-printed JSON payload and `details` the payload map (job id/status/type,
  provider, model, transcript text, artifact info, redacted job metadata, and trust
  metadata). Errors surface directly as `{:error, String.t()}` tuples from the
  `with` chain: abort, param validation, job start, or timeout failures.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with :ok <- AbortHelpers.check_abort(signal),
         {:ok, audio} <- audio_file(params, cwd),
         {:ok, provider} <- provider(params),
         {:ok, generation} <- generation(provider, params),
         {:ok, timeout_ms} <-
           MediaCommon.timeout_ms(params, default_timeout_ms(provider), @max_timeout_ms),
         {:ok, artifact_path} <-
           MediaCommon.artifact_path(params, cwd, opts, generation.format, "media-transcript"),
         {:ok, completed_job} <-
           MediaCommon.run_job(
             %{
               type: :stt,
               provider: provider,
               model: generation.model,
               prompt: audio_fingerprint(audio),
               artifact_name: Path.basename(artifact_path),
               mime_type: generation.mime_type
             },
             MediaCommon.media_job_opts(
               cwd,
               opts,
               artifact_path,
               MediaCommon.runner(generation, artifact_path, runtime(cwd, opts, generation), %{
                 audio: audio
               })
             ),
             timeout_ms,
             signal
           ) do
      payload = payload(completed_job, artifact_path, params)

      %AgentToolResult{
        content: [%TextContent{type: :text, text: Jason.encode!(payload, pretty: true)}],
        details: payload,
        trust: :untrusted
      }
    end
  end

  defp audio_file(%{"audioPath" => path}, cwd) when is_binary(path) do
    # Lexical confinement follows symlinks on read; the credential check does not.
    with {:ok, resolved} <- resolve_audio_path(path, cwd),
         :ok <- LemonCore.CredentialPaths.check_read(resolved),
         {:ok, stat} <- File.stat(resolved),
         :ok <- regular_audio_file(stat),
         :ok <- audio_size(stat),
         {:ok, bytes} <- File.read(resolved) do
      {:ok,
       %{
         path: resolved,
         name: Path.basename(resolved),
         bytes: bytes,
         byte_size: stat.size,
         hash: hash(bytes),
         mime_type: audio_mime_type(resolved)
       }}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "unable to read audio file: #{inspect(reason)}"}
    end
  end

  defp audio_file(_params, _cwd), do: {:error, "audioPath is required"}

  defp resolve_audio_path(path, cwd) do
    cwd = Path.expand(cwd)

    resolved =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, cwd)

    cond do
      not String.starts_with?(resolved, cwd <> "/") and resolved != cwd ->
        {:error, "audioPath must be under the current project"}

      true ->
        {:ok, resolved}
    end
  end

  defp regular_audio_file(%File.Stat{type: :regular}), do: :ok
  defp regular_audio_file(_stat), do: {:error, "audioPath must be a regular file"}

  defp audio_size(%File.Stat{size: size}) when size <= @max_audio_bytes, do: :ok
  defp audio_size(_stat), do: {:error, "audio file must be 25MB or smaller"}

  defp provider(params) do
    case Map.get(params, "provider") do
      @local_provider ->
        {:ok, @local_provider}

      @openai_provider ->
        {:ok, @openai_provider}

      @deepgram_provider ->
        {:ok, @deepgram_provider}

      nil ->
        {:error, "provider is required"}

      other when is_binary(other) ->
        {:error, "unsupported media transcription provider: #{other}"}

      _other ->
        {:error, "provider must be a string"}
    end
  end

  defp default_timeout_ms(@local_provider), do: @local_timeout_ms
  defp default_timeout_ms(_provider), do: @provider_timeout_ms

  defp generation(@local_provider, _params) do
    {:ok,
     %{
       provider: @local_provider,
       model: @local_model,
       format: "json",
       mime_type: "application/json"
     }}
  end

  defp generation(@openai_provider, params) do
    with {:ok, format} <- transcript_format(params) do
      {:ok,
       %{
         provider: @openai_provider,
         model: optional_string(params["model"]) || @default_openai_model,
         language: optional_string(params["language"]),
         prompt: optional_string(params["prompt"]),
         format: format,
         mime_type: Map.fetch!(@transcript_formats, format),
         max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3)
       }}
    end
  end

  defp generation(@deepgram_provider, params) do
    with {:ok, format} <- transcript_format(params) do
      {:ok,
       %{
         provider: @deepgram_provider,
         model: optional_string(params["model"]) || @default_deepgram_model,
         language: optional_string(params["language"]),
         prompt: optional_string(params["prompt"]),
         format: format,
         mime_type: Map.fetch!(@transcript_formats, format),
         max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3)
       }}
    end
  end

  defp runtime(_cwd, _opts, %{provider: @local_provider}), do: nil
  defp runtime(cwd, opts, %{provider: @openai_provider}), do: openai_runtime(cwd, opts)
  defp runtime(cwd, opts, %{provider: @deepgram_provider}), do: deepgram_runtime(cwd, opts)

  defp openai_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_transcription_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :openai) || %{}

    {:ok, endpoint} =
      MediaCommon.openai_compatible_endpoint(
        :openai,
        provider_cfg,
        Keyword.get(opts, :openai_transcription_api_key),
        Keyword.get(opts, :openai_transcription_base_url)
      )

    Map.merge(endpoint, %{
      credential: MediaCommon.credential(endpoint, :missing_openai_transcription_api_key),
      http_post: Keyword.get(opts, :media_transcription_http_post)
    })
  end

  defp deepgram_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_transcription_config, fn -> Config.load(cwd) end)
    voice_cfg = get_in(config.gateway, [:voice]) || %{}

    key_source = %{
      api_key: Keyword.get(opts, :deepgram_transcription_api_key),
      api_key_secret: provider_config_value(voice_cfg, :deepgram_api_key_secret),
      env_var: "DEEPGRAM_API_KEY",
      default_secret_names: ["DEEPGRAM_API_KEY", "deepgram_api_key"],
      config_api_key: provider_config_value(voice_cfg, :deepgram_api_key)
    }

    %{
      credential: fn ->
        MediaCommon.secret_api_key(key_source, :missing_deepgram_transcription_api_key)
      end,
      base_url:
        Keyword.get(opts, :deepgram_transcription_base_url) ||
          optional_string(provider_config_value(voice_cfg, :deepgram_base_url)) ||
          @default_deepgram_base_url,
      http_post: Keyword.get(opts, :media_transcription_http_post)
    }
  end

  defp payload(job, artifact_path, params) do
    job
    |> MediaCommon.payload(artifact_path, mime_type_from_path(artifact_path), "input")
    |> Map.put("text", transcript_text(artifact_path))
    |> Map.put("trustMetadata", media_trust_metadata(:camel_case))
    |> Map.put("trust_metadata", media_trust_metadata(:snake_case))
    |> MediaCommon.maybe_auto_send(params, "generated transcript")
  end

  defp media_trust_metadata(key_style) do
    ExternalContent.trust_metadata(:api,
      key_style: key_style,
      warning_included: false,
      wrapped_fields: ["text"]
    )
  end

  defp transcript_text(path) do
    with {:ok, content} <- File.read(path),
         {:json, true} <- {:json, Path.extname(path) == ".json"},
         {:ok, decoded} <- Jason.decode(content) do
      optional_string(decoded["text"]) || optional_string(decoded[:text]) || content
    else
      {:json, false} -> File.read!(path)
      _ -> nil
    end
  end

  defp transcript_format(params) do
    value =
      params
      |> Map.get("responseFormat", Map.get(params, "response_format", "json"))
      |> optional_string()

    format = String.downcase(value || "json")

    if Map.has_key?(@transcript_formats, format) do
      {:ok, format}
    else
      {:error, "unsupported transcription response format: #{format}"}
    end
  end

  defp audio_fingerprint(audio) do
    "audio:#{audio.hash}:#{audio.byte_size}:#{audio.mime_type}"
  end

  defp audio_mime_type(path) do
    Map.get(@audio_mime_types, String.downcase(Path.extname(path)), "application/octet-stream")
  end

  defp mime_type_from_path(path) do
    case String.downcase(Path.extname(path)) do
      ".json" -> "application/json"
      ".text" -> "text/plain"
      ".txt" -> "text/plain"
      _ -> "text/plain"
    end
  end

  defp hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
