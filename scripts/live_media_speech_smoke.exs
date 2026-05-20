unless System.get_env("LEMON_SECRETS_MASTER_KEY") do
  key_path = Path.expand("~/.lemon/secrets_master_key")

  if File.regular?(key_path) do
    System.put_env("LEMON_SECRETS_MASTER_KEY", key_path |> File.read!() |> String.trim())
  end
end

if Mix.env() == :test and
     ("--api-key-secret" in System.argv() or "google_tts" in System.argv()) do
  Application.put_env(:lemon_core, LemonCore.Store,
    backend: LemonCore.Store.SqliteBackend,
    backend_opts: [
      path:
        System.get_env("LEMON_MEDIA_PROOF_SECRET_STORE_PATH") ||
          System.get_env("LEMON_STORE_PATH") ||
          Path.expand("~/.lemon/store"),
      ephemeral_tables: [:runs]
    ]
  )
end

Application.ensure_all_started(:coding_agent)

defmodule LemonScripts.LiveMediaSpeechSmoke do
  @provider "openai_tts"
  @elevenlabs_provider "elevenlabs_tts"
  @google_provider "google_tts"
  @proof_object "lemon.media_speech_smoke"
  @check_name "media_provider_openai_tts"
  @elevenlabs_check_name "media_provider_elevenlabs_tts"
  @google_check_name "media_provider_google_tts"
  @default_model "gpt-4o-mini-tts"
  @default_elevenlabs_model "eleven_turbo_v2_5"
  @default_google_model "cloud_tts_v1"
  @default_elevenlabs_voice_id "21m00Tcm4TlvDq8ikWAM"
  @default_google_voice "en-US-Neural2-C"
  @default_text "Lemon media speech proof completed."

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          out: :string,
          proof_path: :string,
          model: :string,
          provider: :string,
          voice: :string,
          format: :string,
          api_key_env: :string,
          api_key_secret: :string,
          base_url: :string,
          keep_artifact: :boolean,
          local: :boolean
        ]
      )

    project_dir = File.cwd!()

    proof_path =
      opts[:proof_path] ||
        opts[:out] ||
        default_proof_path(project_dir, opts[:local] == true)

    archive_path = archive_path(proof_path)

    proof =
      if opts[:local] == true do
        run_local_smoke(opts, project_dir)
      else
        case live_config(opts, project_dir) do
          {:skip, reason} -> proof(:skipped, skip_details(opts, reason))
          {:ok, config} -> run_smoke(config)
        end
      end

    write_json!(proof_path, proof)
    write_json!(archive_path, proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp live_config(opts, project_dir) do
    provider = provider(opts)

    cond do
      System.get_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS") not in [
        "1",
        "true",
        "TRUE",
        "yes",
        "YES"
      ] ->
        {:skip, "set LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 to run media speech proof"}

      provider == @provider and provider_prefixed_model?(opts[:model]) ->
        {:skip,
         {:provider_prefixed_model_not_supported_for_media_type,
          "media speech proof uses the OpenAI TTS endpoint; pass --base-url with an unprefixed model, or use media vision proof for provider-prefixed OpenAI-compatible routing"}}

      true ->
        config = LemonCore.Config.load(project_dir, cache: false)
        api_key = api_key_from_opts(opts)

        if credential_available?(api_key, config.providers, project_dir, provider) do
          {:ok,
           %{
             project_dir: project_dir,
             provider: provider,
             model: opts[:model] || default_model(provider),
             voice: opts[:voice] || default_voice(provider),
             format: opts[:format] || "mp3",
             api_key: api_key,
             base_url: opts[:base_url],
             keep_artifact: opts[:keep_artifact] == true
           }}
        else
          {:skip, "no configured #{provider} credential resolved for media speech proof"}
        end
    end
  end

  defp run_local_smoke(opts, project_dir) do
    run_id = System.unique_integer([:positive])

    jobs_dir =
      Path.join([
        project_dir,
        ".lemon",
        "proofs",
        "media-speech-local-smoke-jobs",
        to_string(run_id)
      ])

    artifacts_dir =
      Path.join([
        project_dir,
        ".lemon",
        "proofs",
        "media-speech-local-smoke-artifacts",
        to_string(run_id)
      ])

    tool =
      CodingAgent.Tools.MediaGenerateSpeech.tool(project_dir,
        media_jobs_dir: jobs_dir,
        media_artifacts_dir: artifacts_dir
      )

    params = %{
      "text" => @default_text,
      "provider" => "local_wav",
      "model" => "local_wav_preview",
      "filename" => "live-media-speech-local-smoke"
    }

    case tool.execute.("live-media-speech-local-smoke", params, nil, nil) do
      %AgentCore.Types.AgentToolResult{details: details} ->
        artifact = details["artifact"] || %{}
        artifact_path = artifact["path"]

        proof =
          local_proof(:completed, %{
            provider: details["provider"],
            model: details["model"],
            text_hash: details["prompt_hash"],
            text_chars: details["prompt_chars"],
            artifact_hash: hash_file(artifact_path),
            artifact_bytes: artifact["bytes"],
            artifact_mime_type: artifact["mime_type"],
            artifact_filename: artifact["filename"],
            job_id_hash: hash(details["job_id"]),
            cleanup: cleanup()
          })

        unless opts[:keep_artifact] == true do
          File.rm(artifact_path)
        end

        proof

      {:error, reason} ->
        local_proof(:failed, %{
          provider: "local_wav",
          model: "local_wav_preview",
          reason_hash: hash(reason),
          reason_kind: reason_kind(reason),
          cleanup: cleanup()
        })
    end
  end

  defp run_smoke(config) do
    run_id = System.unique_integer([:positive])

    jobs_dir =
      Path.join([
        config.project_dir,
        ".lemon",
        "proofs",
        "media-speech-smoke-jobs",
        to_string(run_id)
      ])

    artifacts_dir =
      Path.join([
        config.project_dir,
        ".lemon",
        "proofs",
        "media-speech-smoke-artifacts",
        to_string(run_id)
      ])

    tool =
      CodingAgent.Tools.MediaGenerateSpeech.tool(config.project_dir,
        media_jobs_dir: jobs_dir,
        media_artifacts_dir: artifacts_dir,
        openai_tts_api_key: if(config.provider == @provider, do: config.api_key),
        openai_tts_base_url: if(config.provider == @provider, do: config.base_url),
        elevenlabs_tts_api_key: if(config.provider == @elevenlabs_provider, do: config.api_key),
        elevenlabs_tts_base_url: if(config.provider == @elevenlabs_provider, do: config.base_url),
        google_tts_access_token: if(config.provider == @google_provider, do: config.api_key),
        google_tts_base_url: if(config.provider == @google_provider, do: config.base_url)
      )

    params = %{
      "text" => @default_text,
      "provider" => config.provider,
      "model" => config.model,
      "voice" => config.voice,
      "filename" => "live-media-speech-smoke",
      "responseFormat" => config.format,
      "maxRetries" => 1,
      "timeoutMs" => 120_000
    }

    case tool.execute.("live-media-speech-smoke", params, nil, nil) do
      %AgentCore.Types.AgentToolResult{details: details} ->
        artifact = details["artifact"] || %{}
        artifact_path = artifact["path"]

        proof =
          proof(:completed, %{
            provider: details["provider"],
            model: details["model"],
            voice_hash: hash(config.voice),
            text_hash: details["prompt_hash"],
            text_chars: details["prompt_chars"],
            artifact_hash: hash_file(artifact_path),
            artifact_bytes: artifact["bytes"],
            artifact_mime_type: artifact["mime_type"],
            artifact_filename: artifact["filename"],
            job_id_hash: hash(details["job_id"]),
            cleanup: cleanup()
          })

        unless config.keep_artifact do
          File.rm(artifact_path)
        end

        proof

      {:error, reason} ->
        proof(:failed, %{
          provider: config.provider,
          model: config.model,
          reason_hash: hash(reason),
          reason_kind: reason_kind(reason),
          cleanup: cleanup()
        })
    end
  end

  defp proof(:completed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "completed",
      proof_object: @proof_object,
      proof_scope: "media_provider",
      completed_count: 1,
      skipped_count: 0,
      failed_count: 0,
      checks: [
        %{name: check_name(details.provider), status: "completed", proof_scope: "media_provider"}
      ],
      details: details,
      cleanup: cleanup()
    }
  end

  defp proof(:failed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "failed",
      proof_object: @proof_object,
      proof_scope: "media_provider",
      completed_count: 0,
      skipped_count: 0,
      failed_count: 1,
      checks: [
        %{name: check_name(details.provider), status: "failed", proof_scope: "media_provider"}
      ],
      details: details,
      cleanup: cleanup()
    }
  end

  defp proof(:skipped, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "skipped",
      proof_object: @proof_object,
      proof_scope: "media_provider",
      completed_count: 0,
      skipped_count: 1,
      failed_count: 0,
      checks: [
        %{name: check_name(details.provider), status: "skipped", proof_scope: "media_provider"}
      ],
      details: details,
      cleanup: cleanup()
    }
  end

  defp local_proof(:completed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "completed",
      proof_object: "lemon.media_speech_local_smoke",
      proof_scope: "media_local",
      completed_count: 1,
      skipped_count: 0,
      failed_count: 0,
      checks: [%{name: "media_local_speech", status: "completed", proof_scope: "media_local"}],
      details: details,
      cleanup: cleanup()
    }
  end

  defp local_proof(:failed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "failed",
      proof_object: "lemon.media_speech_local_smoke",
      proof_scope: "media_local",
      completed_count: 0,
      skipped_count: 0,
      failed_count: 1,
      checks: [%{name: "media_local_speech", status: "failed", proof_scope: "media_local"}],
      details: details,
      cleanup: cleanup()
    }
  end

  defp cleanup do
    %{
      includes_raw_api_keys: false,
      includes_raw_text: false,
      includes_raw_audio_bytes: false,
      includes_raw_provider_response: false
    }
  end

  defp default_proof_path(project_dir, true) do
    Path.join([project_dir, ".lemon", "proofs", "media-speech-local-smoke-latest.json"])
  end

  defp default_proof_path(project_dir, false) do
    Path.join([project_dir, ".lemon", "proofs", "media-speech-smoke-latest.json"])
  end

  defp skip_details(opts, reason) do
    {reason_kind, reason_text} = skip_reason(reason)
    provider = provider(opts)

    %{
      provider: provider,
      model: opts[:model] || default_model(provider),
      reason_kind: reason_kind,
      reason_hash: hash(reason_text),
      cleanup: cleanup()
    }
  end

  defp skip_reason({kind, reason}) when is_atom(kind), do: {Atom.to_string(kind), reason}
  defp skip_reason(reason), do: {"credential_preflight_skipped", reason}

  defp api_key_from_opts(opts) do
    env_api_key =
      opts[:api_key_env]
      |> case do
        value when is_binary(value) and value != "" -> System.get_env(value)
        _ -> nil
      end

    secret_api_key =
      opts[:api_key_secret]
      |> case do
        value when is_binary(value) and value != "" ->
          LemonAiRuntime.resolve_secret_api_key(value)

        _ ->
          nil
      end

    env_api_key || secret_api_key
  end

  defp credential_available?(api_key, _providers, _project_dir, _provider)
       when is_binary(api_key) and api_key != "",
       do: true

  defp credential_available?(_api_key, providers, project_dir, @provider) do
    LemonAiRuntime.provider_has_credentials?(:openai, providers, cwd: project_dir)
  end

  defp credential_available?(_api_key, providers, project_dir, @google_provider) do
    LemonAiRuntime.provider_has_credentials?(:google_vertex, providers, cwd: project_dir)
  end

  defp credential_available?(_api_key, _providers, _project_dir, _provider), do: false

  defp provider(opts) do
    case opts[:provider] do
      value when value in [@provider, @elevenlabs_provider, @google_provider] -> value
      _ -> @provider
    end
  end

  defp default_model(@elevenlabs_provider), do: @default_elevenlabs_model
  defp default_model(@google_provider), do: @default_google_model
  defp default_model(_provider), do: @default_model

  defp default_voice(@elevenlabs_provider), do: @default_elevenlabs_voice_id
  defp default_voice(@google_provider), do: @default_google_voice
  defp default_voice(_provider), do: "alloy"

  defp check_name(@elevenlabs_provider), do: @elevenlabs_check_name
  defp check_name(@google_provider), do: @google_check_name
  defp check_name(_provider), do: @check_name

  defp provider_prefixed_model?(model) when is_binary(model) do
    String.contains?(model, ":")
  end

  defp provider_prefixed_model?(_model), do: false

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp archive_path(path) do
    ext = Path.extname(path)
    root = String.trim_trailing(path, ext)
    "#{root}-#{DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")}#{ext}"
  end

  defp hash_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> hash(bytes)
      {:error, _reason} -> nil
    end
  end

  defp hash_file(_path), do: nil

  defp hash(nil), do: nil

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
  end

  defp reason_kind(reason) when is_binary(reason) do
    case String.split(reason, ":", parts: 2) do
      ["media job failed", kind] -> String.trim(kind)
      [kind | _] -> String.slice(kind, 0, 80)
    end
  end

  defp reason_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_kind(_reason), do: "error"
end

LemonScripts.LiveMediaSpeechSmoke.main(System.argv())
