defmodule LemonSkills.Tools.MediaGenerateSpeech do
  @moduledoc """
  Supervised speech-generation preview tool backed by LemonMedia.MediaJobSupervisor.

  Wired into CodingAgent.ToolRegistry's builtin tool list. Supports deterministic local WAV previews,
  OpenAI TTS, ElevenLabs TTS, and Google Cloud Text-to-Speech; the cloud
  providers require their respective credentials.
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
      optional_string: 1,
      provider_config_value: 2
    ]

  @local_timeout_ms 10_000
  @provider_timeout_ms 120_000
  @max_timeout_ms 300_000
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
        "required" => ["text", "provider"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Tool callback invoked by the agent loop with, in order: `tool_call_id`,
  `params` map, `signal`, `on_update` callback, `cwd`, and `opts`.

  Reads `"text"` (required, non-empty after trimming, at most 4096
  characters), `"provider"` (required: `"local_wav"`, `"openai_tts"`, `"elevenlabs_tts"`, and `"google_tts"`),
  `"model"` (defaults to `"local_wav_preview"`, `"gpt-4o-mini-tts"`,
  `"eleven_turbo_v2_5"`, or `"cloud_tts_v1"` per provider), `"voice"`
  (defaults to `"alloy"` for OpenAI, the configured ElevenLabs voice id, or
  `"en-US-Neural2-C"` for Google), `"languageCode"`/`"language_code"`
  (defaults to `"en-US"`, Google only), `"instructions"` (OpenAI only),
  `"filename"`, `"responseFormat"`/`"response_format"` (defaults to `"mp3"`;
  `google_tts` only supports `"mp3"`), `"speed"` (OpenAI only, clamped
  0.25-4.0), `"maxRetries"` (defaults to `1`, clamped 0-3),
  `"sendToChannel"` (defaults to `false`), and `"timeoutMs"` (defaults to
  `10_000` local or `120_000` provider-backed, clamped 100-300_000).

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
         {:ok, timeout_ms} <-
           MediaCommon.timeout_ms(params, default_timeout_ms(provider), @max_timeout_ms),
         {:ok, artifact_path} <-
           MediaCommon.artifact_path(params, cwd, opts, generation.format, "media-speech"),
         {:ok, completed_job} <-
           MediaCommon.run_job(
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
    case Map.get(params, "provider") do
      @local_provider -> {:ok, @local_provider}
      @openai_provider -> {:ok, @openai_provider}
      @elevenlabs_provider -> {:ok, @elevenlabs_provider}
      @google_provider -> {:ok, @google_provider}
      nil -> {:error, "provider is required"}
      other when is_binary(other) -> {:error, "unsupported media speech provider: #{other}"}
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

  defp runtime(_cwd, _opts, %{provider: @local_provider}), do: nil
  defp runtime(cwd, opts, %{provider: @openai_provider}), do: openai_runtime(cwd, opts)

  defp runtime(cwd, opts, %{provider: @elevenlabs_provider} = generation),
    do: elevenlabs_runtime(cwd, opts, generation)

  defp runtime(cwd, opts, %{provider: @google_provider}), do: google_runtime(cwd, opts)

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

    Map.merge(endpoint, %{
      credential: MediaCommon.credential(endpoint, :missing_openai_tts_api_key),
      http_post: Keyword.get(opts, :media_speech_http_post)
    })
  end

  defp elevenlabs_runtime(cwd, opts, generation) do
    config = Keyword.get_lazy(opts, :media_speech_config, fn -> Config.load(cwd) end)
    voice_cfg = get_in(config.gateway, [:voice]) || %{}

    key_source = %{
      api_key: Keyword.get(opts, :elevenlabs_tts_api_key),
      api_key_secret: provider_config_value(voice_cfg, :elevenlabs_api_key_secret),
      env_var: "ELEVENLABS_API_KEY",
      default_secret_names: ["ELEVENLABS_API_KEY", "elevenlabs_api_key"],
      config_api_key: provider_config_value(voice_cfg, :elevenlabs_api_key)
    }

    %{
      credential: fn ->
        MediaCommon.secret_api_key(key_source, :missing_elevenlabs_tts_api_key)
      end,
      base_url:
        Keyword.get(opts, :elevenlabs_tts_base_url) ||
          optional_string(provider_config_value(voice_cfg, :elevenlabs_base_url)) ||
          @default_elevenlabs_base_url,
      voice:
        generation.voice ||
          optional_string(provider_config_value(voice_cfg, :elevenlabs_voice_id)) ||
          @default_elevenlabs_voice_id,
      http_post: Keyword.get(opts, :media_speech_http_post)
    }
  end

  defp google_runtime(cwd, opts) do
    config = Keyword.get_lazy(opts, :media_speech_config, fn -> Config.load(cwd) end)
    provider_cfg = ProviderNames.provider_config(config.providers, :google_vertex) || %{}

    resolved =
      ProviderSettings.resolve(
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
      http_post: Keyword.get(opts, :media_speech_http_post),
      token_http_post: Keyword.get(opts, :google_token_http_post)
    }
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
end
