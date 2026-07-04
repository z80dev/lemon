defmodule LemonSkills.Tools.MediaGenerateSpeech do
  @moduledoc """
  Supervised speech-generation preview tool backed by LemonMedia.MediaJobSupervisor.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias AgentCore.Tools.AbortHelpers
  alias AgentCore.ModelRuntime.ProviderNames
  alias LemonCore.Config
  alias LemonMedia.MediaJobSupervisor
  alias LemonMedia.MediaJobs
  alias LemonCore.ProviderConfigResolver

  @topic "media_jobs"
  @default_timeout_ms 10_000
  @max_timeout_ms 120_000
  @local_provider "local_wav"
  @openai_provider "openai_tts"
  @elevenlabs_provider "elevenlabs_tts"
  @google_provider "google_tts"
  @local_model "local_wav_preview"
  @default_openai_model "gpt-4o-mini-tts"
  @default_openai_base_url "https://api.openai.com/v1"
  @default_elevenlabs_model "eleven_turbo_v2_5"
  @default_elevenlabs_voice_id "21m00Tcm4TlvDq8ikWAM"
  @default_elevenlabs_base_url "https://api.elevenlabs.io/v1"
  @default_google_model "cloud_tts_v1"
  @default_google_voice "en-US-Neural2-C"
  @default_google_language_code "en-US"
  @default_google_base_url "https://texttospeech.googleapis.com/v1"
  @audio_formats %{
    "mp3" => "audio/mpeg",
    "opus" => "audio/opus",
    "aac" => "audio/aac",
    "flac" => "audio/flac",
    "wav" => "audio/wav",
    "pcm" => "application/octet-stream"
  }

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_generate_speech",
      description:
        "Generate supervised speech audio through Lemon's BEAM media worker path. Supports deterministic local WAV previews, OpenAI TTS, ElevenLabs TTS, and Google Cloud Text-to-Speech, records redacted media-job metadata, and can opt into final Telegram/Discord attachment delivery.",
      label: "Media Generate Speech",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "Speech text. Stored only as redacted metadata."
          },
          "provider" => %{
            "type" => "string",
            "enum" => [@local_provider, @openai_provider, @elevenlabs_provider, @google_provider],
            "description" =>
              "Speech provider. local_wav is deterministic; openai_tts uses OpenAI audio credentials; elevenlabs_tts uses ElevenLabs credentials; google_tts uses Google Cloud Text-to-Speech credentials."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Optional provider model. Defaults to local_wav_preview or gpt-4o-mini-tts."
          },
          "voice" => %{
            "type" => "string",
            "description" =>
              "Optional provider voice. Defaults to alloy for OpenAI TTS, the configured ElevenLabs voice id, or en-US-Neural2-C for Google TTS."
          },
          "languageCode" => %{
            "type" => "string",
            "description" => "Optional Google TTS language code. Defaults to en-US."
          },
          "instructions" => %{
            "type" => "string",
            "description" => "Optional voice style instructions for supported OpenAI TTS models."
          },
          "filename" => %{
            "type" => "string",
            "description" =>
              "Optional artifact filename. The tool always writes under .lemon/media-artifacts."
          },
          "responseFormat" => %{
            "type" => "string",
            "enum" => ["mp3", "opus", "aac", "flac", "wav", "pcm"],
            "description" =>
              "Provider speech artifact format. Defaults to mp3; google_tts currently supports mp3."
          },
          "speed" => %{
            "type" => "number",
            "description" => "Optional OpenAI speech speed from 0.25 to 4.0."
          },
          "maxRetries" => %{
            "type" => "integer",
            "description" => "Maximum transient provider retries for OpenAI speech jobs."
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
        "required" => ["text"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with :ok <- AbortHelpers.check_abort(signal),
         {:ok, text} <- required_text(params),
         {:ok, provider} <- provider(params),
         {:ok, generation} <- generation(provider, params),
         {:ok, timeout_ms} <- timeout_ms(params),
         {:ok, artifact_path} <- artifact_path(params, cwd, opts, generation.format),
         :ok <- Phoenix.PubSub.subscribe(LemonCore.PubSub, @topic),
         {:ok, _pid, queued_job} <-
           MediaJobSupervisor.start_job(
             %{
               type: :tts,
               provider: provider,
               model: generation.model,
               prompt: text,
               artifact_name: Path.basename(artifact_path),
               mime_type: generation.mime_type
             },
             media_job_opts(cwd, opts, artifact_path, generation)
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

  defp required_text(%{"text" => text}) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, "text is required"}
      String.length(text) > 4096 -> {:error, "text must be 4096 characters or fewer"}
      true -> {:ok, text}
    end
  end

  defp required_text(_params), do: {:error, "text is required"}

  defp provider(params) do
    case Map.get(params, "provider", @local_provider) do
      @local_provider -> {:ok, @local_provider}
      @openai_provider -> {:ok, @openai_provider}
      @elevenlabs_provider -> {:ok, @elevenlabs_provider}
      @google_provider -> {:ok, @google_provider}
      other when is_binary(other) -> {:error, "unsupported media speech provider: #{other}"}
      _other -> {:error, "provider must be a string"}
    end
  end

  defp generation(@local_provider, _params) do
    {:ok,
     %{
       provider: @local_provider,
       model: @local_model,
       format: "wav",
       mime_type: "audio/wav"
     }}
  end

  defp generation(@openai_provider, params) do
    with {:ok, format} <- audio_format(params) do
      {:ok,
       %{
         provider: @openai_provider,
         model: optional_string(params["model"]) || @default_openai_model,
         voice: optional_string(params["voice"]) || "alloy",
         instructions: optional_string(params["instructions"]),
         format: format,
         mime_type: Map.fetch!(@audio_formats, format),
         speed: speed(params["speed"]),
         max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3)
       }}
    end
  end

  defp generation(@elevenlabs_provider, params) do
    {:ok,
     %{
       provider: @elevenlabs_provider,
       model: optional_string(params["model"]) || @default_elevenlabs_model,
       voice: optional_string(params["voice"]),
       format: "mp3",
       mime_type: "audio/mpeg",
       max_retries: bounded_integer(Map.get(params, "maxRetries", 1), 0, 3)
     }}
  end

  defp generation(@google_provider, params) do
    with {:ok, format} <- google_audio_format(params) do
      {:ok,
       %{
         provider: @google_provider,
         model: optional_string(params["model"]) || @default_google_model,
         voice: optional_string(params["voice"]) || @default_google_voice,
         language_code:
           optional_string(params["languageCode"]) || optional_string(params["language_code"]) ||
             @default_google_language_code,
         format: format,
         mime_type: Map.fetch!(@audio_formats, format),
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
    "media-speech-#{System.unique_integer([:positive])}.#{format}"
  end

  defp ensure_extension(name, format) do
    if String.downcase(Path.extname(name)) == ".#{format}" do
      name
    else
      "#{Path.rootname(name)}.#{format}"
    end
  end

  defp media_job_opts(cwd, opts, artifact_path, generation) do
    [
      project_dir: cwd,
      dir: Keyword.get(opts, :media_jobs_dir),
      artifacts_dir: Path.dirname(artifact_path),
      runner: runner(cwd, opts, artifact_path, generation)
    ]
  end

  defp runner(_cwd, _opts, artifact_path, %{provider: @local_provider}) do
    &run_local_wav(&1, artifact_path)
  end

  defp runner(cwd, opts, artifact_path, %{provider: @openai_provider} = generation) do
    runtime = openai_runtime(cwd, opts)
    &run_openai_tts(&1, artifact_path, generation, runtime)
  end

  defp runner(cwd, opts, artifact_path, %{provider: @elevenlabs_provider} = generation) do
    runtime = elevenlabs_runtime(cwd, opts, generation)
    &run_elevenlabs_tts(&1, artifact_path, generation, runtime)
  end

  defp runner(cwd, opts, artifact_path, %{provider: @google_provider} = generation) do
    runtime = google_runtime(cwd, opts)
    &run_google_tts(&1, artifact_path, generation, runtime)
  end

  defp run_local_wav(_attrs, artifact_path) do
    audio = wav_silence()
    write_artifact(artifact_path, audio, "audio/wav")
  end

  defp run_openai_tts(attrs, artifact_path, generation, runtime) do
    with {:ok, api_key} <- openai_api_key(runtime),
         {:ok, audio} <- post_openai_tts(attrs, generation, runtime, api_key) do
      write_artifact(artifact_path, audio, generation.mime_type)
    end
  end

  defp run_elevenlabs_tts(attrs, artifact_path, generation, runtime) do
    with {:ok, api_key} <- generic_api_key(runtime, :missing_elevenlabs_tts_api_key),
         {:ok, audio} <- post_elevenlabs_tts(attrs, generation, runtime, api_key) do
      write_artifact(artifact_path, audio, generation.mime_type)
    end
  end

  defp run_google_tts(attrs, artifact_path, generation, runtime) do
    with {:ok, access_token} <- google_access_token(runtime),
         {:ok, audio} <- post_google_tts(attrs, generation, runtime, access_token) do
      write_artifact(artifact_path, audio, generation.mime_type)
    end
  end

  defp openai_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_speech_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :openai) || %{}

    %{
      api_key: Keyword.get(opts, :openai_tts_api_key),
      base_url:
        Keyword.get(opts, :openai_tts_base_url) ||
          optional_string(provider_config_value(provider_cfg, :base_url)) ||
          @default_openai_base_url,
      provider_cfg: provider_cfg,
      http_post: Keyword.get(opts, :media_speech_http_post, &Req.post/2)
    }
  end

  defp elevenlabs_runtime(cwd, opts, generation) do
    config = Keyword.get_lazy(opts, :media_speech_config, fn -> Config.load(cwd) end)
    voice_cfg = get_in(config.gateway, [:voice]) || %{}

    %{
      api_key: Keyword.get(opts, :elevenlabs_tts_api_key),
      api_key_secret: provider_config_value(voice_cfg, :elevenlabs_api_key_secret),
      env_var: "ELEVENLABS_API_KEY",
      default_secret_names: ["ELEVENLABS_API_KEY", "elevenlabs_api_key"],
      config_api_key: provider_config_value(voice_cfg, :elevenlabs_api_key),
      base_url:
        Keyword.get(opts, :elevenlabs_tts_base_url) ||
          optional_string(provider_config_value(voice_cfg, :elevenlabs_base_url)) ||
          @default_elevenlabs_base_url,
      voice:
        generation.voice ||
          optional_string(provider_config_value(voice_cfg, :elevenlabs_voice_id)) ||
          @default_elevenlabs_voice_id,
      http_post: Keyword.get(opts, :media_speech_http_post, &Req.post/2)
    }
  end

  defp google_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_speech_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :google_vertex) || %{}

    resolved =
      ProviderConfigResolver.resolve_for_provider(
        :google_vertex,
        Map.merge(provider_cfg, %{cwd: cwd})
      )

    %{
      access_token: Keyword.get(opts, :google_tts_access_token),
      service_account_json:
        Keyword.get(opts, :google_tts_service_account_json) ||
          resolved[:service_account_json],
      base_url:
        Keyword.get(opts, :google_tts_base_url) ||
          optional_string(provider_config_value(provider_cfg, :text_to_speech_base_url)) ||
          @default_google_base_url,
      http_post: Keyword.get(opts, :media_speech_http_post, &Req.post/2),
      token_http_post: Keyword.get(opts, :google_token_http_post, &Req.post/2)
    }
  end

  defp openai_api_key(%{api_key: key}) when is_binary(key) and key != "", do: {:ok, key}

  defp openai_api_key(%{provider_cfg: provider_cfg}) do
    case AgentCore.ModelRuntime.Credentials.resolve_provider_api_key(:openai, provider_cfg,
           provider_cfg: true
         ) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_openai_tts_api_key}
    end
  end

  defp post_openai_tts(attrs, generation, runtime, api_key) do
    text = Map.get(attrs, :prompt) || Map.get(attrs, "prompt")
    url = String.trim_trailing(runtime.base_url, "/") <> "/audio/speech"

    body =
      %{
        "model" => generation.model,
        "input" => text,
        "voice" => generation.voice,
        "instructions" => generation.instructions,
        "response_format" => generation.format,
        "speed" => generation.speed
      }
      |> reject_blank_values()

    request_opts = [
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: body,
      receive_timeout: 300_000
    ]

    do_post_openai_tts(runtime, url, request_opts, generation.max_retries)
  end

  defp do_post_openai_tts(runtime, url, request_opts, remaining_retries) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        if transient_status?(status) and remaining_retries > 0 do
          do_post_openai_tts(runtime, url, request_opts, remaining_retries - 1)
        else
          {:error, {:openai_tts_http_error, status, provider_error_kind(response_body)}}
        end

      {:error, _reason} when remaining_retries > 0 ->
        do_post_openai_tts(runtime, url, request_opts, remaining_retries - 1)

      {:error, reason} ->
        {:error, {:openai_tts_request_failed, provider_error_kind(reason)}}
    end
  end

  defp post_elevenlabs_tts(attrs, generation, runtime, api_key) do
    text = Map.get(attrs, :prompt) || Map.get(attrs, "prompt")

    url =
      String.trim_trailing(runtime.base_url, "/") <>
        "/text-to-speech/#{URI.encode(runtime.voice)}/stream?output_format=mp3_44100_128"

    body =
      %{
        "text" => text,
        "model_id" => generation.model
      }
      |> reject_blank_values()

    request_opts = [
      headers: [{"xi-api-key", api_key}],
      json: body,
      receive_timeout: 300_000
    ]

    do_post_elevenlabs_tts(runtime, url, request_opts, generation.max_retries)
  end

  defp google_access_token(%{access_token: token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp google_access_token(%{service_account_json: json} = runtime)
       when is_binary(json) and json != "" do
    with {:ok, credentials} <- Jason.decode(json),
         {:ok, jwt, token_uri} <- google_service_account_jwt(credentials),
         {:ok, token} <- exchange_google_jwt(jwt, token_uri, runtime) do
      {:ok, token}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_google_tts_service_account_json}
    end
  end

  defp google_access_token(_runtime), do: {:error, :missing_google_tts_credentials}

  defp google_service_account_jwt(credentials) do
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
        _ -> {:error, :invalid_google_tts_service_account_private_key}
      end
    else
      {:error, :invalid_google_tts_service_account_json}
    end
  end

  defp exchange_google_jwt(jwt, token_uri, runtime) do
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
        {:error, {:google_tts_token_http_error, status, provider_error_kind(response_body)}}

      {:error, reason} ->
        {:error, {:google_tts_token_request_failed, provider_error_kind(reason)}}
    end
  end

  defp post_google_tts(attrs, generation, runtime, access_token) do
    text = Map.get(attrs, :prompt) || Map.get(attrs, "prompt")
    url = String.trim_trailing(runtime.base_url, "/") <> "/text:synthesize"

    body = %{
      "input" => %{"text" => text},
      "voice" => %{"languageCode" => generation.language_code, "name" => generation.voice},
      "audioConfig" => %{"audioEncoding" => "MP3"}
    }

    request_opts = [
      headers: [{"authorization", "Bearer #{access_token}"}],
      json: body,
      receive_timeout: 300_000
    ]

    with {:ok, response} <- do_post_google_tts(runtime, url, request_opts, generation.max_retries) do
      decode_google_tts_response(response)
    end
  end

  defp do_post_google_tts(runtime, url, request_opts, remaining_retries) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        if transient_status?(status) and remaining_retries > 0 do
          do_post_google_tts(runtime, url, request_opts, remaining_retries - 1)
        else
          {:error, {:google_tts_http_error, status, provider_error_kind(response_body)}}
        end

      {:error, _reason} when remaining_retries > 0 ->
        do_post_google_tts(runtime, url, request_opts, remaining_retries - 1)

      {:error, reason} ->
        {:error, {:google_tts_request_failed, provider_error_kind(reason)}}
    end
  end

  defp decode_google_tts_response(%{"audioContent" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, audio} -> {:ok, audio}
      :error -> {:error, :invalid_google_tts_audio_base64}
    end
  end

  defp decode_google_tts_response(%{audioContent: encoded}) when is_binary(encoded) do
    decode_google_tts_response(%{"audioContent" => encoded})
  end

  defp decode_google_tts_response(_response), do: {:error, :missing_google_tts_audio}

  defp do_post_elevenlabs_tts(runtime, url, request_opts, remaining_retries) do
    case runtime.http_post.(url, request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        if transient_status?(status) and remaining_retries > 0 do
          do_post_elevenlabs_tts(runtime, url, request_opts, remaining_retries - 1)
        else
          {:error, {:elevenlabs_tts_http_error, status, provider_error_kind(response_body)}}
        end

      {:error, _reason} when remaining_retries > 0 ->
        do_post_elevenlabs_tts(runtime, url, request_opts, remaining_retries - 1)

      {:error, reason} ->
        {:error, {:elevenlabs_tts_request_failed, provider_error_kind(reason)}}
    end
  end

  defp transient_status?(status) when status in [408, 409, 425, 429], do: true
  defp transient_status?(status) when is_integer(status) and status >= 500, do: true
  defp transient_status?(_status), do: false

  defp write_artifact(artifact_path, audio, mime_type) when is_binary(audio) do
    with :ok <- File.mkdir_p(Path.dirname(artifact_path)),
         :ok <- File.write(artifact_path, audio),
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
      "prompt_hash" => job.prompt_hash,
      "prompt_chars" => job.prompt_chars,
      "artifact" => artifact,
      "media_job" => redacted_job(job)
    }
    |> maybe_auto_send(artifact_path, artifact_name, Map.get(params, "sendToChannel") == true)
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
        "caption" => "generated speech",
        "source" => "generated"
      }
    ])
  end

  defp artifact_bytes(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> nil
    end
  end

  defp audio_format(params) do
    value =
      params
      |> Map.get("responseFormat", Map.get(params, "response_format", "mp3"))
      |> optional_string()

    format = String.downcase(value || "mp3")

    if Map.has_key?(@audio_formats, format) do
      {:ok, format}
    else
      {:error, "unsupported speech response format: #{format}"}
    end
  end

  defp google_audio_format(params) do
    with {:ok, format} <- audio_format(params) do
      if format == "mp3" do
        {:ok, format}
      else
        {:error, "unsupported Google TTS response format: #{format}"}
      end
    end
  end

  defp speed(value) when is_number(value), do: value |> max(0.25) |> min(4.0)

  defp speed(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> speed(float)
      _ -> nil
    end
  end

  defp speed(_value), do: nil

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

  defp mime_type_from_path(path) do
    case String.downcase(Path.extname(path)) do
      ".mp3" -> "audio/mpeg"
      ".opus" -> "audio/opus"
      ".aac" -> "audio/aac"
      ".flac" -> "audio/flac"
      ".wav" -> "audio/wav"
      ".pcm" -> "application/octet-stream"
      _ -> "application/octet-stream"
    end
  end

  defp wav_silence do
    sample_rate = 16_000
    sample_count = div(sample_rate, 4)
    data = :binary.copy(<<0, 0>>, sample_count)
    data_size = byte_size(data)
    riff_size = 36 + data_size

    "RIFF" <>
      <<riff_size::little-32>> <>
      "WAVEfmt " <>
      <<16::little-32, 1::little-16, 1::little-16, sample_rate::little-32,
        sample_rate * 2::little-32, 2::little-16, 16::little-16>> <>
      "data" <> <<data_size::little-32>> <> data
  end
end
