defmodule LemonSkills.Tools.MediaTranscribeAudio do
  @moduledoc """
  Supervised audio-transcription preview tool backed by LemonMedia.MediaJobSupervisor.

  Transcribes a local audio artifact through Lemon's BEAM media worker path:
  deterministic local previews, OpenAI speech-to-text, or Deepgram speech-to-text.
  OpenAI/Deepgram runs require the corresponding provider API credentials (explicit
  opts, config, or secrets). Registered as a builtin tool in `CodingAgent.ToolRegistry`.
  """

  alias LemonAgent.ModelRuntime.{Credentials, ProviderNames}
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
      provider_config_value: 2,
      provider_error_kind: 1,
      reject_blank_values: 1,
      stringify_atoms: 1,
      transient_status?: 1,
      wait_for_job: 3
    ]

  @topic "media_jobs"
  @default_timeout_ms 15_000
  @max_timeout_ms 120_000
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
        "required" => ["audioPath"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Tool callback invoked by the agent loop: `execute(tool_call_id, params, signal,
  on_update, cwd, opts)`.

  Reads from `params`:

  - `"audioPath"` (required) - local audio file path under `cwd`
  - `"provider"` (default `"local_transcript"`) - `"local_transcript"`,
    `"openai_transcribe"`, or `"deepgram_transcribe"`
  - `"model"` (optional) - provider model override
  - `"language"` (optional) - input language hint
  - `"prompt"` (optional) - provider speech-to-text context
  - `"filename"` (optional) - transcript artifact filename
  - `"responseFormat"` (default `"json"`, `"response_format"` accepted) -
    `"json"` or `"text"`
  - `"maxRetries"` (default `1`, clamped to 0-3) - transient provider retries
  - `"sendToChannel"` (default `false`) - request final Telegram/Discord delivery
  - `"timeoutMs"` (default `15_000`, clamped to 100-120_000) - media worker wait

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
         {:ok, timeout_ms} <- MediaCommon.timeout_ms(params, @default_timeout_ms, @max_timeout_ms),
         {:ok, artifact_path} <-
           MediaCommon.artifact_path(params, cwd, opts, generation.format, "media-transcript"),
         :ok <- Phoenix.PubSub.subscribe(LemonCore.PubSub, @topic),
         {:ok, _pid, queued_job} <-
           MediaJobSupervisor.start_job(
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
               runner(cwd, opts, artifact_path, audio, generation)
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

  defp audio_file(%{"audioPath" => path}, cwd) when is_binary(path) do
    with {:ok, resolved} <- resolve_audio_path(path, cwd),
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
    case Map.get(params, "provider", @local_provider) do
      @local_provider ->
        {:ok, @local_provider}

      @openai_provider ->
        {:ok, @openai_provider}

      @deepgram_provider ->
        {:ok, @deepgram_provider}

      other when is_binary(other) ->
        {:error, "unsupported media transcription provider: #{other}"}

      _other ->
        {:error, "provider must be a string"}
    end
  end

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

  defp runner(_cwd, _opts, artifact_path, audio, %{provider: @local_provider}) do
    &run_local_transcript(&1, artifact_path, audio)
  end

  defp runner(cwd, opts, artifact_path, audio, %{provider: @openai_provider} = generation) do
    runtime = openai_runtime(cwd, opts)
    &run_openai_transcription(&1, artifact_path, audio, generation, runtime)
  end

  defp runner(cwd, opts, artifact_path, audio, %{provider: @deepgram_provider} = generation) do
    runtime = deepgram_runtime(cwd, opts)
    &run_deepgram_transcription(&1, artifact_path, audio, generation, runtime)
  end

  defp run_local_transcript(_attrs, artifact_path, audio) do
    transcript = "local transcript preview for audio #{String.slice(audio.hash, 0, 12)}"

    write_transcript_artifact(
      artifact_path,
      Jason.encode!(%{"text" => transcript}, pretty: true),
      transcript
    )
  end

  defp run_openai_transcription(_attrs, artifact_path, audio, generation, runtime) do
    with {:ok, api_key} <-
           MediaCommon.provider_api_key(runtime, :missing_openai_transcription_api_key),
         {:ok, response} <- post_openai_transcription(audio, generation, runtime, api_key),
         {:ok, transcript, content} <-
           normalize_transcription_response(response, generation.format) do
      write_transcript_artifact(artifact_path, content, transcript)
    end
  end

  defp run_deepgram_transcription(_attrs, artifact_path, audio, generation, runtime) do
    with {:ok, api_key} <- generic_api_key(runtime, :missing_deepgram_transcription_api_key),
         {:ok, response} <- post_deepgram_transcription(audio, generation, runtime, api_key),
         {:ok, transcript, content} <-
           normalize_deepgram_response(response, generation.format) do
      write_transcript_artifact(artifact_path, content, transcript)
    end
  end

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

    Map.put(
      endpoint,
      :http_post,
      Keyword.get(opts, :media_transcription_http_post, &Req.post/2)
    )
  end

  defp deepgram_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_transcription_config, fn -> Config.load(cwd) end)
    voice_cfg = get_in(config.gateway, [:voice]) || %{}

    %{
      api_key: Keyword.get(opts, :deepgram_transcription_api_key),
      api_key_secret: provider_config_value(voice_cfg, :deepgram_api_key_secret),
      env_var: "DEEPGRAM_API_KEY",
      default_secret_names: ["DEEPGRAM_API_KEY", "deepgram_api_key"],
      config_api_key: provider_config_value(voice_cfg, :deepgram_api_key),
      base_url:
        Keyword.get(opts, :deepgram_transcription_base_url) ||
          optional_string(provider_config_value(voice_cfg, :deepgram_base_url)) ||
          @default_deepgram_base_url,
      http_post: Keyword.get(opts, :media_transcription_http_post, &Req.post/2)
    }
  end

  defp post_openai_transcription(audio, generation, runtime, api_key) do
    url = String.trim_trailing(runtime.base_url, "/") <> "/audio/transcriptions"
    boundary = "lemon-media-#{System.unique_integer([:positive])}"

    fields =
      %{
        "model" => generation.model,
        "response_format" => generation.format,
        "language" => generation.language,
        "prompt" => generation.prompt
      }
      |> reject_blank_values()

    request_opts = [
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "multipart/form-data; boundary=#{boundary}"}
      ],
      body: multipart_body(boundary, fields, audio),
      receive_timeout: 300_000
    ]

    do_post_openai_transcription(runtime, url, request_opts, generation.max_retries)
  end

  defp do_post_openai_transcription(runtime, url, request_opts, remaining_retries) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        if transient_status?(status) and remaining_retries > 0 do
          do_post_openai_transcription(runtime, url, request_opts, remaining_retries - 1)
        else
          {:error, {:openai_transcription_http_error, status, provider_error_kind(response_body)}}
        end

      {:error, _reason} when remaining_retries > 0 ->
        do_post_openai_transcription(runtime, url, request_opts, remaining_retries - 1)

      {:error, reason} ->
        {:error, {:openai_transcription_request_failed, provider_error_kind(reason)}}
    end
  end

  defp post_deepgram_transcription(audio, generation, runtime, api_key) do
    query =
      %{
        "model" => generation.model,
        "smart_format" => "true",
        "language" => generation.language
      }
      |> reject_blank_values()
      |> URI.encode_query()

    url = String.trim_trailing(runtime.base_url, "/") <> "/listen?" <> query

    request_opts = [
      headers: [
        {"authorization", "Token #{api_key}"},
        {"content-type", audio.mime_type}
      ],
      body: audio.bytes,
      receive_timeout: 300_000
    ]

    do_post_deepgram_transcription(runtime, url, request_opts, generation.max_retries)
  end

  defp do_post_deepgram_transcription(runtime, url, request_opts, remaining_retries) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        if transient_status?(status) and remaining_retries > 0 do
          do_post_deepgram_transcription(runtime, url, request_opts, remaining_retries - 1)
        else
          {:error,
           {:deepgram_transcription_http_error, status, provider_error_kind(response_body)}}
        end

      {:error, _reason} when remaining_retries > 0 ->
        do_post_deepgram_transcription(runtime, url, request_opts, remaining_retries - 1)

      {:error, reason} ->
        {:error, {:deepgram_transcription_request_failed, provider_error_kind(reason)}}
    end
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

  defp normalize_transcription_response(response, "json") when is_map(response) do
    text = optional_string(response["text"]) || optional_string(response[:text]) || ""
    {:ok, text, Jason.encode!(stringify_atoms(response), pretty: true)}
  end

  defp normalize_transcription_response(response, "json") when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> normalize_transcription_response(decoded, "json")
      _ -> {:ok, response, Jason.encode!(%{"text" => response}, pretty: true)}
    end
  end

  defp normalize_transcription_response(response, "text") when is_binary(response) do
    {:ok, response, response}
  end

  defp normalize_transcription_response(response, "text") when is_map(response) do
    text =
      optional_string(response["text"]) || optional_string(response[:text]) ||
        Jason.encode!(response)

    {:ok, text, text}
  end

  defp normalize_deepgram_response(response, "json") when is_map(response) do
    transcript = deepgram_transcript(response)

    content =
      response
      |> stringify_atoms()
      |> Map.put("text", transcript)
      |> Jason.encode!(pretty: true)

    {:ok, transcript, content}
  end

  defp normalize_deepgram_response(response, "json") when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> normalize_deepgram_response(decoded, "json")
      _ -> {:ok, response, Jason.encode!(%{"text" => response}, pretty: true)}
    end
  end

  defp normalize_deepgram_response(response, "text") when is_map(response) do
    transcript = deepgram_transcript(response)
    {:ok, transcript, transcript}
  end

  defp normalize_deepgram_response(response, "text") when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} when is_map(decoded) -> normalize_deepgram_response(decoded, "text")
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

  defp write_transcript_artifact(artifact_path, content, transcript) when is_binary(content) do
    with :ok <- File.mkdir_p(Path.dirname(artifact_path)),
         :ok <- File.write(artifact_path, content),
         {:ok, stat} <- File.stat(artifact_path) do
      {:ok,
       %{
         artifact_path: artifact_path,
         artifact_name: Path.basename(artifact_path),
         mime_type: mime_type_from_path(artifact_path),
         bytes: stat.size,
         transcript: transcript
       }}
    end
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

  defp generic_api_key(%{api_key: key}, _missing) when is_binary(key) and key != "",
    do: {:ok, key}

  defp generic_api_key(runtime, missing) do
    keys =
      [
        System.get_env(runtime.env_var),
        runtime.config_api_key,
        secret_api_key(runtime.api_key_secret)
        | Enum.map(runtime.default_secret_names, &secret_api_key/1)
      ]

    case Enum.find(keys, &(is_binary(&1) and &1 != "")) do
      key when is_binary(key) -> {:ok, key}
      _ -> {:error, missing}
    end
  end

  defp secret_api_key(secret_name) when is_binary(secret_name) and secret_name != "" do
    Credentials.resolve_secret_api_key(secret_name)
  end

  defp secret_api_key(_), do: nil

  defp hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
