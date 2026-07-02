unless System.get_env("LEMON_SECRETS_MASTER_KEY") do
  key_path = Path.expand("~/.lemon/secrets_master_key")

  if File.regular?(key_path) do
    System.put_env("LEMON_SECRETS_MASTER_KEY", key_path |> File.read!() |> String.trim())
  end
end

if Mix.env() == :test and
     ("--api-key-secret" in System.argv() or "vertex_veo" in System.argv()) do
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

defmodule LemonScripts.LiveMediaVideoSmoke do
  @provider "openai_video"
  @vertex_provider "vertex_veo"
  @proof_object "lemon.media_video_smoke"
  @check_name "media_provider_openai_video"
  @vertex_check_name "media_provider_vertex_veo"
  @default_model "sora-2"
  @default_vertex_model "veo-3.1-fast-generate-001"
  @default_prompt "Create a four second product-style clip of a lemon on a clean white table."

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          out: :string,
          proof_path: :string,
          model: :string,
          provider: :string,
          size: :string,
          seconds: :string,
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
        {:skip, "set LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 to run media video proof"}

      provider == @provider and provider_prefixed_model?(opts[:model]) ->
        {:skip,
         {:provider_prefixed_model_not_supported_for_media_type,
          "media video proof uses the OpenAI video endpoint; pass --base-url with an unprefixed model, or use media vision proof for provider-prefixed OpenAI-compatible routing"}}

      true ->
        config = LemonCore.Config.load(project_dir, cache: false)
        api_key = api_key_from_opts(opts)

        if credential_available?(api_key, config.providers, project_dir, provider) do
          {:ok,
           %{
             project_dir: project_dir,
             provider: provider,
             model: opts[:model] || default_model(provider),
             size: opts[:size] || "1280x720",
             seconds: opts[:seconds] || "4",
             api_key: api_key,
             base_url: opts[:base_url],
             keep_artifact: opts[:keep_artifact] == true
           }}
        else
          {:skip, "no configured #{provider} credential resolved for media video proof"}
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
        "media-video-local-smoke-jobs",
        to_string(run_id)
      ])

    artifacts_dir =
      Path.join([
        project_dir,
        ".lemon",
        "proofs",
        "media-video-local-smoke-artifacts",
        to_string(run_id)
      ])

    tool =
      CodingAgent.Tools.MediaGenerateVideo.tool(project_dir,
        media_jobs_dir: jobs_dir,
        media_artifacts_dir: artifacts_dir
      )

    params = %{
      "prompt" => @default_prompt,
      "provider" => "local_mp4",
      "model" => "local_mp4_preview",
      "filename" => "live-media-video-local-smoke"
    }

    case tool.execute.("live-media-video-local-smoke", params, nil, nil) do
      %AgentCore.Types.AgentToolResult{details: details} ->
        artifact = details["artifact"] || %{}
        artifact_path = artifact["path"]

        proof =
          local_proof(:completed, %{
            provider: details["provider"],
            model: details["model"],
            prompt_hash: details["prompt_hash"],
            prompt_chars: details["prompt_chars"],
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
          provider: "local_mp4",
          model: "local_mp4_preview",
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
        "media-video-smoke-jobs",
        to_string(run_id)
      ])

    artifacts_dir =
      Path.join([
        config.project_dir,
        ".lemon",
        "proofs",
        "media-video-smoke-artifacts",
        to_string(run_id)
      ])

    tool =
      CodingAgent.Tools.MediaGenerateVideo.tool(config.project_dir,
        media_jobs_dir: jobs_dir,
        media_artifacts_dir: artifacts_dir,
        openai_video_api_key: if(config.provider == @provider, do: config.api_key),
        openai_video_base_url: if(config.provider == @provider, do: config.base_url)
      )

    params = %{
      "prompt" => @default_prompt,
      "provider" => config.provider,
      "model" => config.model,
      "filename" => "live-media-video-smoke",
      "size" => config.size,
      "seconds" => config.seconds,
      "maxRetries" => 1,
      "maxPolls" => 90,
      "pollIntervalMs" => 2_000,
      "timeoutMs" => 240_000
    }

    case tool.execute.("live-media-video-smoke", params, nil, nil) do
      %AgentCore.Types.AgentToolResult{details: details} ->
        artifact = details["artifact"] || %{}
        artifact_path = artifact["path"]

        proof =
          proof(:completed, %{
            provider: details["provider"],
            model: details["model"],
            prompt_hash: details["prompt_hash"],
            prompt_chars: details["prompt_chars"],
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
      proof_object: "lemon.media_video_local_smoke",
      proof_scope: "media_local",
      completed_count: 1,
      skipped_count: 0,
      failed_count: 0,
      checks: [%{name: "media_local_video", status: "completed", proof_scope: "media_local"}],
      details: details,
      cleanup: cleanup()
    }
  end

  defp local_proof(:failed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "failed",
      proof_object: "lemon.media_video_local_smoke",
      proof_scope: "media_local",
      completed_count: 0,
      skipped_count: 0,
      failed_count: 1,
      checks: [%{name: "media_local_video", status: "failed", proof_scope: "media_local"}],
      details: details,
      cleanup: cleanup()
    }
  end

  defp cleanup do
    %{
      includes_raw_api_keys: false,
      includes_raw_prompt: false,
      includes_raw_video_bytes: false,
      includes_raw_provider_response: false,
      includes_raw_provider_job_id: false
    }
  end

  defp default_proof_path(project_dir, true) do
    Path.join([project_dir, ".lemon", "proofs", "media-video-local-smoke-latest.json"])
  end

  defp default_proof_path(project_dir, false) do
    Path.join([project_dir, ".lemon", "proofs", "media-video-smoke-latest.json"])
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
          AgentCore.ModelRuntime.Credentials.resolve_secret_api_key(value)

        _ ->
          nil
      end

    env_api_key || secret_api_key
  end

  defp credential_available?(api_key, _providers, _project_dir, @provider)
       when is_binary(api_key) and api_key != "",
       do: true

  defp credential_available?(_api_key, providers, project_dir, @provider) do
    AgentCore.ModelRuntime.Credentials.provider_has_credentials?(:openai, providers, cwd: project_dir)
  end

  defp credential_available?(_api_key, providers, project_dir, @vertex_provider) do
    AgentCore.ModelRuntime.Credentials.provider_has_credentials?(:google_vertex, providers, cwd: project_dir)
  end

  defp credential_available?(_api_key, _providers, _project_dir, _provider), do: false

  defp provider(opts) do
    case opts[:provider] do
      value when value in [@provider, @vertex_provider] -> value
      _ -> @provider
    end
  end

  defp default_model(@vertex_provider), do: @default_vertex_model
  defp default_model(_provider), do: @default_model

  defp check_name(@vertex_provider), do: @vertex_check_name
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

LemonScripts.LiveMediaVideoSmoke.main(System.argv())
