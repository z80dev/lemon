defmodule LemonSkills.Tools.MediaGenerateSpeech do
  @moduledoc """
  Supervised speech-generation preview tool backed by LemonMedia.MediaJobSupervisor.

  Wired into CodingAgent.ToolRegistry's builtin tool list. Supports deterministic local WAV previews,
  OpenAI TTS, ElevenLabs TTS, and Google Cloud Text-to-Speech; the cloud
  providers require their respective credentials.
  """

  alias LemonAgent.ModelRuntime.{Credentials, ProviderNames}
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
      provider_config_value: 2,
      provider_error_kind: 1,
      reject_blank_values: 1,
      transient_status?: 1,
      wait_for_job: 3
    ]

  @topic "media_jobs"
  @default_timeout_ms 10_000
  @max_timeout_ms 120_000
  @local_provider "local_wav"
  @openai_provider "openai_tts"
  @elevenlabs_provider "elevenlabs_tts"
  @google_provider "google_tts"
  @local_model "local_wav_preview"
  @default_openai_model "gpt-4o-mini-tts"
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

  @doc """
  Returns the `LemonAgent.Types.AgentTool.t()` definition for the
  `"media_generate_speech"` tool, wired to `execute/6`.

  `cwd` is the project directory; it seeds the default artifacts directory
  and is used to load config for provider credentials. The `opts` keyword is
  read for: `:media_artifacts_dir` (defaults to
  `MediaJobs.default_artifacts_dir(cwd)`), `:media_jobs_dir`,
  `:media_speech_config` (lazily `Config.load(cwd)`), `:openai_tts_api_key`,
  `:openai_tts_base_url`, `:elevenlabs_tts_api_key`, `:elevenlabs_tts_base_url`,
  `:google_tts_access_token`, `:google_tts_service_account_json`,
  `:google_tts_base_url`, `:media_speech_http_post` (defaults to
  `&Req.post/2`), and `:google_token_http_post` (defaults to `&Req.post/2`).
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "media_generate_speech",
      timeout_ms: :infinity,
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

  @doc """
  Tool callback invoked by the agent loop with, in order: `tool_call_id`,
  `params` map, `signal`, `on_update` callback, `cwd`, and `opts`.

  Reads `"text"` (required, non-empty after trimming, at most 4096
  characters), `"provider"` (defaults to `"local_wav"`; the other accepted
  values are `"openai_tts"`, `"elevenlabs_tts"`, and `"google_tts"`),
  `"model"` (defaults to `"local_wav_preview"`, `"gpt-4o-mini-tts"`,
  `"eleven_turbo_v2_5"`, or `"cloud_tts_v1"` per provider), `"voice"`
  (defaults to `"alloy"` for OpenAI, the configured ElevenLabs voice id, or
  `"en-US-Neural2-C"` for Google), `"languageCode"`/`"language_code"`
  (defaults to `"en-US"`, Google only), `"instructions"` (OpenAI only),
  `"filename"`, `"responseFormat"`/`"response_format"` (defaults to `"mp3"`;
  `google_tts` only supports `"mp3"`), `"speed"` (OpenAI only, clamped
  0.25-4.0), `"maxRetries"` (defaults to `1`, clamped 0-3),
  `"sendToChannel"` (defaults to `false`), and `"timeoutMs"` (defaults to
  `10_000`, clamped 100-120_000).

  On success returns a `%LemonAgent.Types.AgentToolResult{}` with `content`
  the pretty-printed JSON payload and `details` the payload map (`job_id`,
  `status`, `type`, `provider`, `model`, `prompt_hash`, `prompt_chars`,
  `artifact`, `media_job`, and — when `"sendToChannel"` is true —
  `auto_send_files`). Failures return `{:error, message}` with a string
  message, e.g. missing/oversized text, unsupported provider/format, an
  aborted operation, or a failed or timed-out media job.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with :ok <- AbortHelpers.check_abort(signal),
         {:ok, text} <- required_text(params),
         {:ok, provider} <- provider(params),
         {:ok, generation} <- generation(provider, params),
         {:ok, timeout_ms} <- MediaCommon.timeout_ms(params, @default_timeout_ms, @max_timeout_ms),
         {:ok, artifact_path} <-
           MediaCommon.artifact_path(params, cwd, opts, generation.format, "media-speech"),
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
    with {:ok, api_key} <- MediaCommon.provider_api_key(runtime, :missing_openai_tts_api_key),
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

    {:ok, endpoint} =
      MediaCommon.openai_compatible_endpoint(
        :openai,
        provider_cfg,
        Keyword.get(opts, :openai_tts_api_key),
        Keyword.get(opts, :openai_tts_base_url)
      )

    Map.put(endpoint, :http_post, Keyword.get(opts, :media_speech_http_post, &Req.post/2))
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

  defp payload(job, artifact_path, params) do
    job
    |> MediaCommon.payload(artifact_path, mime_type_from_path(artifact_path), "prompt")
    |> MediaCommon.maybe_auto_send(params, "generated speech")
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
