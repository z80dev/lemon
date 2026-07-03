defmodule LemonSkills.Tools.MediaTranscribeAudio do
  @moduledoc """
  Supervised audio-transcription preview tool backed by LemonMedia.MediaJobSupervisor.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias AgentCore.Security.ExternalContent
  alias AgentCore.Tools.AbortHelpers
  alias AgentCore.ModelRuntime.ProviderNames
  alias LemonCore.Config
  alias LemonMedia.MediaJobSupervisor
  alias LemonMedia.MediaJobs

  @topic "media_jobs"
  @default_timeout_ms 15_000
  @max_timeout_ms 120_000
  @max_audio_bytes 25 * 1024 * 1024
  @local_provider "local_transcript"
  @openai_provider "openai_transcribe"
  @deepgram_provider "deepgram_transcribe"
  @local_model "local_transcript_preview"
  @default_openai_model "gpt-4o-mini-transcribe"
  @default_openai_base_url "https://api.openai.com/v1"
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

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_transcribe_audio",
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

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with :ok <- AbortHelpers.check_abort(signal),
         {:ok, audio} <- audio_file(params, cwd),
         {:ok, provider} <- provider(params),
         {:ok, generation} <- generation(provider, params),
         {:ok, timeout_ms} <- timeout_ms(params),
         {:ok, artifact_path} <- artifact_path(params, cwd, opts, generation.format),
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
             media_job_opts(cwd, opts, artifact_path, audio, generation)
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

  defp timeout_ms(params) do
    value = Map.get(params, "timeoutMs", @default_timeout_ms)

    cond do
      is_integer(value) -> {:ok, value |> max(100) |> min(@max_timeout_ms)}
      is_binary(value) -> parse_timeout(value)
      true -> {:error, "timeoutMs must be an integer"}
    end
  end

  defp parse_timeout(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int |> max(100) |> min(@max_timeout_ms)}
      _ -> {:error, "timeoutMs must be an integer"}
    end
  end

  defp artifact_path(params, cwd, opts, format) do
    artifacts_dir =
      opts
      |> Keyword.get(:media_artifacts_dir, MediaJobs.default_artifacts_dir(cwd))
      |> Path.expand()

    name =
      params
      |> Map.get("filename")
      |> sanitize_filename(format)

    path = Path.join(artifacts_dir, name)

    if String.starts_with?(Path.expand(path), artifacts_dir) do
      {:ok, path}
    else
      {:error, "artifact path escaped media artifact directory"}
    end
  end

  defp sanitize_filename(nil, format), do: default_filename(format)

  defp sanitize_filename(value, format) when is_binary(value) do
    value
    |> Path.basename()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    |> String.slice(0, 96)
    |> case do
      "" -> default_filename(format)
      name -> ensure_extension(name, format)
    end
  end

  defp sanitize_filename(_value, format), do: default_filename(format)

  defp default_filename(format) do
    "media-transcript-#{System.unique_integer([:positive])}.#{format}"
  end

  defp ensure_extension(name, format) do
    if String.downcase(Path.extname(name)) == ".#{format}" do
      name
    else
      "#{Path.rootname(name)}.#{format}"
    end
  end

  defp media_job_opts(cwd, opts, artifact_path, audio, generation) do
    [
      project_dir: cwd,
      dir: Keyword.get(opts, :media_jobs_dir),
      artifacts_dir: Path.dirname(artifact_path),
      runner: runner(cwd, opts, artifact_path, audio, generation)
    ]
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
    with {:ok, api_key} <- openai_api_key(runtime),
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

    %{
      api_key: Keyword.get(opts, :openai_transcription_api_key),
      base_url:
        Keyword.get(opts, :openai_transcription_base_url) ||
          optional_string(provider_config_value(provider_cfg, :base_url)) ||
          @default_openai_base_url,
      provider_cfg: provider_cfg,
      http_post: Keyword.get(opts, :media_transcription_http_post, &Req.post/2)
    }
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

  defp openai_api_key(%{api_key: key}) when is_binary(key) and key != "", do: {:ok, key}

  defp openai_api_key(%{provider_cfg: provider_cfg}) do
    case AgentCore.ModelRuntime.Credentials.resolve_provider_api_key(:openai, provider_cfg,
           provider_cfg: true
         ) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_openai_transcription_api_key}
    end
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
        if is_transient_status(status) and remaining_retries > 0 do
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
        if is_transient_status(status) and remaining_retries > 0 do
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

  defp is_transient_status(status) when status in [408, 409, 425, 429], do: true
  defp is_transient_status(status) when is_integer(status) and status >= 500, do: true
  defp is_transient_status(_status), do: false

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

  defp wait_for_job(job_id, timeout_ms, signal) do
    receive do
      {:media_job, :completed, %{job_id: ^job_id} = job} ->
        {:ok, job}

      {:media_job, :failed, %{job_id: ^job_id} = job} ->
        {:error, "media job failed: #{Map.get(job, :error_kind, "unknown")}"}

      {:media_job, _event, %{job_id: ^job_id}} ->
        case AbortHelpers.check_abort(signal) do
          :ok -> wait_for_job(job_id, timeout_ms, signal)
          {:error, reason} -> {:error, reason}
        end

      _other ->
        wait_for_job(job_id, timeout_ms, signal)
    after
      timeout_ms -> {:error, "media job timed out after #{timeout_ms}ms"}
    end
  end

  defp payload(job, artifact_path, params) do
    artifact_name = get_in(job, [:artifact, :name]) || Path.basename(artifact_path)
    mime_type = get_in(job, [:artifact, :mime_type]) || mime_type_from_path(artifact_path)

    artifact = %{
      "path" => artifact_path,
      "filename" => artifact_name,
      "mime_type" => mime_type,
      "bytes" => artifact_bytes(artifact_path)
    }

    %{
      "job_id" => job.job_id,
      "status" => Atom.to_string(job.status),
      "type" => Atom.to_string(job.type),
      "provider" => job.provider,
      "model" => job.model,
      "input_hash" => job.prompt_hash,
      "input_chars" => job.prompt_chars,
      "text" => transcript_text(artifact_path),
      "artifact" => artifact,
      "media_job" => redacted_job(job)
    }
    |> Map.put("trustMetadata", media_trust_metadata(:camel_case))
    |> Map.put("trust_metadata", media_trust_metadata(:snake_case))
    |> maybe_auto_send(artifact_path, artifact_name, Map.get(params, "sendToChannel") == true)
  end

  defp media_trust_metadata(key_style) do
    ExternalContent.trust_metadata(:api,
      key_style: key_style,
      warning_included: false,
      wrapped_fields: ["text"]
    )
  end

  defp redacted_job(job) do
    job
    |> Map.take([
      :job_id,
      :type,
      :status,
      :provider,
      :model,
      :artifact,
      :prompt_hash,
      :prompt_chars,
      :created_at,
      :updated_at
    ])
    |> stringify_atoms()
  end

  defp stringify_atoms(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_atoms(value)} end)
  end

  defp stringify_atoms(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atoms(value), do: value

  defp maybe_auto_send(payload, _artifact_path, _artifact_name, false), do: payload

  defp maybe_auto_send(payload, artifact_path, artifact_name, true) do
    Map.put(payload, "auto_send_files", [
      %{
        "path" => artifact_path,
        "filename" => artifact_name,
        "caption" => "generated transcript",
        "source" => "generated"
      }
    ])
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

  defp artifact_bytes(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> nil
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

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp provider_config_value(nil, _key), do: nil

  defp provider_config_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))
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
    AgentCore.ModelRuntime.Credentials.resolve_secret_api_key(secret_name)
  end

  defp secret_api_key(_), do: nil

  defp bounded_integer(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  defp bounded_integer(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> bounded_integer(int, min, max)
      _ -> min
    end
  end

  defp bounded_integer(_value, min, _max), do: min

  defp reject_blank_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp provider_error_kind(%{"error" => error}) when is_map(error) do
    {:safe_error_kind,
     optional_string(error["type"]) || optional_string(error["status"]) ||
       optional_string(error["code"]) || "provider_error"}
  end

  defp provider_error_kind(%{error: error}) when is_map(error) do
    provider_error_kind(%{
      "error" => %{"type" => error[:type], "status" => error[:status], "code" => error[:code]}
    })
  end

  defp provider_error_kind(%{"detail" => detail}) when is_map(detail) do
    {:safe_error_kind,
     optional_string(detail["status"]) || optional_string(detail["type"]) ||
       optional_string(detail["code"]) || "provider_error"}
  end

  defp provider_error_kind(%{detail: detail}) when is_map(detail) do
    provider_error_kind(%{
      "detail" => %{"status" => detail[:status], "type" => detail[:type], "code" => detail[:code]}
    })
  end

  defp provider_error_kind(reason) when is_atom(reason),
    do: {:safe_error_kind, Atom.to_string(reason)}

  defp provider_error_kind(_reason), do: {:safe_error_kind, "provider_error"}

  defp hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
