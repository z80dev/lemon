unless System.get_env("LEMON_SECRETS_MASTER_KEY") do
  key_path = Path.expand("~/.lemon/secrets_master_key")

  if File.regular?(key_path) do
    System.put_env("LEMON_SECRETS_MASTER_KEY", key_path |> File.read!() |> String.trim())
  end
end

if "--api-key-secret" in System.argv() and Mix.env() == :test do
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

defmodule LemonScripts.LiveMediaVisionSmoke do
  @provider "openai_vision"
  @proof_object "lemon.media_vision_smoke"
  @check_name "media_provider_openai_vision"
  @default_model "gpt-4o-mini"

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          out: :string,
          proof_path: :string,
          model: :string,
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
    cond do
      System.get_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS") not in [
        "1",
        "true",
        "TRUE",
        "yes",
        "YES"
      ] ->
        {:skip, "set LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 to run media vision proof"}

      true ->
        config = LemonCore.Config.load(project_dir, cache: false)
        api_key = api_key_from_opts(opts)

        model = opts[:model] || @default_model

        if credential_available?(api_key, config.providers, project_dir, model) do
          {:ok,
           %{
             project_dir: project_dir,
             model: model,
             format: opts[:format] || "json",
             api_key: api_key,
             base_url: opts[:base_url],
             keep_artifact: opts[:keep_artifact] == true
           }}
        else
          {:skip, "no configured OpenAI credential resolved for media vision proof"}
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
        "media-vision-local-smoke-jobs",
        to_string(run_id)
      ])

    artifacts_dir =
      Path.join([
        project_dir,
        ".lemon",
        "proofs",
        "media-vision-local-smoke-artifacts",
        to_string(run_id)
      ])

    input_dir =
      Path.join([
        project_dir,
        ".lemon",
        "proofs",
        "media-vision-local-smoke-inputs",
        to_string(run_id)
      ])

    File.mkdir_p!(input_dir)
    image_path = Path.join(input_dir, "live-media-vision-local-smoke.png")
    File.write!(image_path, red_png())

    tool =
      CodingAgent.Tools.MediaAnalyzeImage.tool(project_dir,
        media_jobs_dir: jobs_dir,
        media_artifacts_dir: artifacts_dir
      )

    params = %{
      "imagePath" => Path.relative_to(image_path, project_dir),
      "provider" => "local_vision",
      "model" => "local_vision_preview",
      "prompt" => "Answer with the main color visible in this tiny image.",
      "filename" => "live-media-vision-local-smoke"
    }

    case tool.execute.("live-media-vision-local-smoke", params, nil, nil) do
      %AgentCore.Types.AgentToolResult{details: details} ->
        artifact = details["artifact"] || %{}
        artifact_path = artifact["path"]

        proof =
          local_proof(:completed, %{
            provider: details["provider"],
            model: details["model"],
            input_hash: details["input_hash"],
            input_chars: details["input_chars"],
            analysis_hash: hash(details["text"]),
            analysis_chars: String.length(to_string(details["text"] || "")),
            artifact_hash: hash_file(artifact_path),
            artifact_bytes: artifact["bytes"],
            artifact_mime_type: artifact["mime_type"],
            artifact_filename: artifact["filename"],
            job_id_hash: hash(details["job_id"]),
            cleanup: cleanup()
          })

        unless opts[:keep_artifact] == true do
          File.rm(artifact_path)
          File.rm(image_path)
        end

        proof

      {:error, reason} ->
        local_proof(:failed, %{
          provider: "local_vision",
          model: "local_vision_preview",
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
        "media-vision-smoke-jobs",
        to_string(run_id)
      ])

    artifacts_dir =
      Path.join([
        config.project_dir,
        ".lemon",
        "proofs",
        "media-vision-smoke-artifacts",
        to_string(run_id)
      ])

    input_dir =
      Path.join([
        config.project_dir,
        ".lemon",
        "proofs",
        "media-vision-smoke-inputs",
        to_string(run_id)
      ])

    File.mkdir_p!(input_dir)
    image_path = Path.join(input_dir, "live-media-vision-smoke.png")
    File.write!(image_path, red_png())

    tool =
      CodingAgent.Tools.MediaAnalyzeImage.tool(config.project_dir,
        media_jobs_dir: jobs_dir,
        media_artifacts_dir: artifacts_dir,
        openai_vision_api_key: config.api_key,
        openai_vision_base_url: config.base_url
      )

    params = %{
      "imagePath" => Path.relative_to(image_path, config.project_dir),
      "provider" => "openai_vision",
      "model" => config.model,
      "prompt" => "Answer with the main color visible in this tiny image.",
      "filename" => "live-media-vision-smoke",
      "responseFormat" => config.format,
      "maxRetries" => 1,
      "timeoutMs" => 120_000
    }

    case tool.execute.("live-media-vision-smoke", params, nil, nil) do
      %AgentCore.Types.AgentToolResult{details: details} ->
        artifact = details["artifact"] || %{}
        artifact_path = artifact["path"]

        proof =
          proof(:completed, %{
            provider: details["provider"],
            model: details["model"],
            input_hash: details["input_hash"],
            input_chars: details["input_chars"],
            analysis_hash: hash(details["text"]),
            analysis_chars: String.length(to_string(details["text"] || "")),
            artifact_hash: hash_file(artifact_path),
            artifact_bytes: artifact["bytes"],
            artifact_mime_type: artifact["mime_type"],
            artifact_filename: artifact["filename"],
            job_id_hash: hash(details["job_id"]),
            cleanup: cleanup()
          })

        unless config.keep_artifact do
          File.rm(artifact_path)
          File.rm(image_path)
        end

        proof

      {:error, reason} ->
        proof(:failed, %{
          provider: @provider,
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
      checks: [%{name: @check_name, status: "completed", proof_scope: "media_provider"}],
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
      checks: [%{name: @check_name, status: "failed", proof_scope: "media_provider"}],
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
      checks: [%{name: @check_name, status: "skipped", proof_scope: "media_provider"}],
      details: details,
      cleanup: cleanup()
    }
  end

  defp local_proof(:completed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "completed",
      proof_object: "lemon.media_vision_local_smoke",
      proof_scope: "media_local",
      completed_count: 1,
      skipped_count: 0,
      failed_count: 0,
      checks: [%{name: "media_local_vision", status: "completed", proof_scope: "media_local"}],
      details: details,
      cleanup: cleanup()
    }
  end

  defp local_proof(:failed, details) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "failed",
      proof_object: "lemon.media_vision_local_smoke",
      proof_scope: "media_local",
      completed_count: 0,
      skipped_count: 0,
      failed_count: 1,
      checks: [%{name: "media_local_vision", status: "failed", proof_scope: "media_local"}],
      details: details,
      cleanup: cleanup()
    }
  end

  defp cleanup do
    %{
      includes_raw_api_keys: false,
      includes_raw_image_bytes: false,
      includes_raw_analysis: false,
      includes_raw_provider_response: false
    }
  end

  defp default_proof_path(project_dir, true) do
    Path.join([project_dir, ".lemon", "proofs", "media-vision-local-smoke-latest.json"])
  end

  defp default_proof_path(project_dir, false) do
    Path.join([project_dir, ".lemon", "proofs", "media-vision-smoke-latest.json"])
  end

  defp skip_details(opts, reason) do
    %{
      provider: @provider,
      model: opts[:model] || @default_model,
      reason_kind: "credential_preflight_skipped",
      reason_hash: hash(reason),
      cleanup: cleanup()
    }
  end

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

  defp credential_available?(api_key, _providers, _project_dir, _model)
       when is_binary(api_key) and api_key != "",
       do: true

  defp credential_available?(_api_key, providers, project_dir, model) do
    LemonAiRuntime.provider_has_credentials?(provider_for_model(model), providers,
      cwd: project_dir
    )
  end

  defp provider_for_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _model] -> LemonAiRuntime.ProviderNames.canonical_name(provider) || :openai
      _ -> :openai
    end
  end

  defp provider_for_model(_model), do: :openai

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

  defp red_png do
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgAQMAAABJtOi3AAAAA1BMVEX/AAAZ4gk3AAAADElEQVQI12NgGNwAAACgAAFhJX1HAAAAAElFTkSuQmCC"
    |> Base.decode64!()
  end
end

LemonScripts.LiveMediaVisionSmoke.main(System.argv())
