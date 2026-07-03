defmodule Mix.Tasks.Lemon.Media do
  @moduledoc """
  Show redacted generated-media and provider-proof readiness.

  ## Usage

      mix lemon.media
      mix lemon.media --project-dir /path/to/project --limit 5
      mix lemon.media --json

  ## Options

    * `--project-dir` - Project root to scan. Defaults to the current directory.
    * `--limit` - Number of recent media jobs to show. Defaults to 20.
    * `--json` - Emit the raw redacted media diagnostics JSON.
  """

  use Mix.Task

  alias LemonMedia.{MediaJobs, MediaJobSupervisor}
  alias LemonCore.Doctor.ProofDiagnostics

  @default_limit 20

  @provider_specs [
    %{
      providers: ["openai_image", "vertex_imagen"],
      label: "image",
      script: "scripts/live_media_image_smoke.exs",
      proof_path: ".lemon/proofs/media-image-smoke-latest.json"
    },
    %{
      providers: ["openai_tts", "elevenlabs_tts", "google_tts"],
      label: "TTS",
      script: "scripts/live_media_speech_smoke.exs",
      proof_path: ".lemon/proofs/media-speech-smoke-latest.json"
    },
    %{
      providers: ["openai_transcribe", "deepgram_transcribe"],
      label: "STT",
      script: "scripts/live_media_transcription_smoke.exs",
      proof_path: ".lemon/proofs/media-transcription-smoke-latest.json"
    },
    %{
      providers: ["openai_vision"],
      label: "vision",
      script: "scripts/live_media_vision_smoke.exs",
      proof_path: ".lemon/proofs/media-vision-smoke-latest.json"
    },
    %{
      providers: ["openai_video", "vertex_veo"],
      label: "video",
      script: "scripts/live_media_video_smoke.exs",
      proof_path: ".lemon/proofs/media-video-smoke-latest.json"
    }
  ]

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project_dir: :string,
          limit: :integer,
          json: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    project_dir = opts[:project_dir] || File.cwd!()
    limit = normalize_limit(opts[:limit])
    status = media_status(project_dir, limit)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(status, pretty: true))
    else
      print_text(status)
    end
  end

  defp media_status(project_dir, limit) do
    jobs_dir = MediaJobs.default_dir(project_dir)
    artifacts_dir = MediaJobs.default_artifacts_dir(project_dir)

    summary =
      MediaJobs.summary(project_dir: project_dir, dir: jobs_dir, artifacts_dir: artifacts_dir)

    providers = provider_proofs(project_dir)

    %{
      jobs_dir_hash: hash(jobs_dir),
      artifacts_dir_hash: hash(artifacts_dir),
      worker_status: safe_worker_status(MediaJobSupervisor.status()),
      summary: safe_summary(summary),
      provider_proofs: providers,
      recent_jobs:
        MediaJobs.recent(project_dir: project_dir, dir: jobs_dir, limit: limit)
        |> Enum.map(&safe_job/1),
      cleanup: cleanup(summary, providers)
    }
  end

  defp provider_proofs(project_dir) do
    proofs =
      ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)
      |> Map.get(:recent_proofs, [])

    providers = Enum.map(@provider_specs, &provider_summary(&1, proofs))
    completed_count = Enum.count(providers, &(&1.status == "proven"))

    %{
      status: if(completed_count == length(@provider_specs), do: "proven", else: "incomplete"),
      completed_count: completed_count,
      required_count: length(@provider_specs),
      providers: providers,
      next_action: provider_next_action(providers),
      cleanup: provider_cleanup()
    }
  end

  defp provider_summary(spec, proofs) do
    proof =
      proofs
      |> Enum.filter(&(get_in(&1, [:media_proof, :provider]) in spec.providers))
      |> Enum.sort_by(
        fn proof ->
          {proof_rank(Map.get(proof, :status)), Map.get(proof, :modified_at) || ""}
        end,
        fn {rank_a, modified_a}, {rank_b, modified_b} ->
          rank_a < rank_b or (rank_a == rank_b and modified_a >= modified_b)
        end
      )
      |> List.first()

    proof_status = Map.get(proof || %{}, :status)
    provider = get_in(proof || %{}, [:media_proof, :provider]) || hd(spec.providers)

    %{
      label: spec.label,
      provider: provider,
      providers: spec.providers,
      status: provider_status(proof_status),
      proof_status: proof_status,
      reason_kind: Map.get(proof || %{}, :reason_kind),
      model: get_in(proof || %{}, [:media_proof, :model]),
      proof_hash: Map.get(proof || %{}, :proof_hash),
      modified_at: Map.get(proof || %{}, :modified_at),
      command: provider_command(spec.script, spec.proof_path, provider),
      secret_command:
        "#{provider_command(spec.script, spec.proof_path, provider)} --api-key-secret SECRET_NAME",
      next_action:
        provider_next_action(
          proof_status,
          spec.script,
          Map.get(proof || %{}, :reason_kind),
          spec.label
        )
    }
  end

  defp provider_command(script, proof_path, provider) do
    command =
      "LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start #{script} --proof-path #{proof_path}"

    if provider, do: "#{command} --provider #{provider}", else: command
  end

  defp proof_rank("completed"), do: 0
  defp proof_rank("failed"), do: 1
  defp proof_rank("skipped"), do: 2
  defp proof_rank(_), do: 3

  defp provider_status("completed"), do: "proven"
  defp provider_status("failed"), do: "blocked"
  defp provider_status("skipped"), do: "missing"
  defp provider_status(_), do: "missing"

  defp provider_next_action(providers) when is_list(providers) do
    providers
    |> Enum.reject(&(&1.status == "proven"))
    |> List.first()
    |> case do
      nil -> "keep provider-backed media proofs current"
      provider -> provider.next_action
    end
  end

  defp provider_next_action("completed", _script, _reason, _label), do: "keep proof current"

  defp provider_next_action("failed", script, reason, label) do
    case provider_reason_action(reason, label) do
      nil -> "inspect provider diagnostics and rerun #{script}"
      action -> "#{action}; rerun #{script}"
    end
  end

  defp provider_next_action("skipped", script, _reason, _label),
    do: "enable live credentials and rerun #{script}"

  defp provider_next_action(_status, script, _reason, _label), do: "run #{script}"

  defp provider_reason_action(reason, label) when is_binary(reason) do
    cond do
      String.contains?(reason, "permission_denied") ->
        "#{label}: enable provider API/IAM/billing permissions for the configured account"

      String.contains?(reason, "billing_limit") ->
        "#{label}: use a funded account or raise the provider quota"

      String.contains?(reason, "payment_required") ->
        "#{label}: fund or upgrade the provider account"

      true ->
        nil
    end
  end

  defp provider_reason_action(_reason, _label), do: nil

  defp safe_summary(summary) do
    %{
      exists: Map.get(summary, :exists) == true,
      count: Map.get(summary, :count, 0),
      status_counts: Map.get(summary, :status_counts, %{}),
      type_counts: Map.get(summary, :type_counts, %{}),
      artifact_count: Map.get(summary, :artifact_count, 0),
      artifact_total_bytes: Map.get(summary, :artifact_total_bytes, 0),
      oldest_created_at: Map.get(summary, :oldest_created_at),
      newest_created_at: Map.get(summary, :newest_created_at),
      cleanup: Map.get(summary, :cleanup, %{})
    }
  end

  defp safe_worker_status(status) when is_map(status) do
    %{
      running: Map.get(status, :running, 0),
      queued: Map.get(status, :queued, 0),
      max_concurrency: Map.get(status, :max_concurrency)
    }
  end

  defp safe_worker_status(_status), do: %{}

  defp safe_job(job) do
    artifact = Map.get(job, :artifact, %{}) || %{}

    %{
      job_id: Map.get(job, :job_id),
      type: Map.get(job, :type),
      status: Map.get(job, :status),
      provider: Map.get(job, :provider),
      model: Map.get(job, :model),
      channel: Map.get(job, :channel),
      prompt_chars: Map.get(job, :prompt_chars),
      error_kind: Map.get(job, :error_kind),
      created_at: Map.get(job, :created_at),
      updated_at: Map.get(job, :updated_at),
      artifact:
        %{
          path_hash: Map.get(artifact, :path_hash),
          mime_type: Map.get(artifact, :mime_type),
          bytes: Map.get(artifact, :bytes),
          exists: Map.get(artifact, :exists)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  defp cleanup(summary, provider_proofs) do
    summary_cleanup = Map.get(summary, :cleanup, %{})
    provider_cleanup = get_in(provider_proofs, [:cleanup]) || %{}

    Map.merge(summary_cleanup, provider_cleanup)
  end

  defp provider_cleanup do
    %{
      includes_prompts: false,
      includes_raw_artifact_paths: false,
      includes_generated_bytes: false,
      includes_provider_responses: false,
      includes_channel_message_bodies: false,
      includes_raw_proof_paths: false,
      includes_secret_values: false
    }
  end

  defp print_text(status) do
    summary = status.summary
    providers = status.provider_proofs
    cleanup = status.cleanup

    Mix.shell().info("Lemon Media")
    Mix.shell().info("Jobs: #{summary.count}")
    Mix.shell().info("Artifacts: #{summary.artifact_count}")
    Mix.shell().info("Artifact bytes: #{summary.artifact_total_bytes}")

    Mix.shell().info(
      "Provider proofs: #{providers.completed_count}/#{providers.required_count} #{providers.status}"
    )

    Mix.shell().info("Includes prompts: #{truthy?(cleanup[:includes_prompts])}")

    Mix.shell().info(
      "Includes raw artifact paths: #{truthy?(cleanup[:includes_raw_artifact_paths] || cleanup[:includes_raw_paths])}"
    )

    Mix.shell().info("Includes generated bytes: #{truthy?(cleanup[:includes_generated_bytes])}")

    Mix.shell().info(
      "Includes provider responses: #{truthy?(cleanup[:includes_provider_responses])}"
    )

    Mix.shell().info(
      "Includes channel message bodies: #{truthy?(cleanup[:includes_channel_message_bodies])}"
    )

    Mix.shell().info("Includes raw proof paths: #{truthy?(cleanup[:includes_raw_proof_paths])}")
    Mix.shell().info("Includes secret values: #{truthy?(cleanup[:includes_secret_values])}")
    print_counts("Job Statuses", summary.status_counts)
    print_counts("Job Types", summary.type_counts)
    print_provider_proofs(providers.providers)
    print_recent_jobs(status.recent_jobs)
  end

  defp print_counts(label, counts) when counts == %{} do
    Mix.shell().info("#{label}: none")
  end

  defp print_counts(label, counts) do
    Mix.shell().info("#{label}:")

    counts
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.each(fn {key, value} -> Mix.shell().info("  #{key}: #{value}") end)
  end

  defp print_provider_proofs(providers) do
    Mix.shell().info("Provider Proofs:")

    Enum.each(providers, fn provider ->
      reason = if provider.reason_kind, do: " reason=#{provider.reason_kind}", else: ""

      Mix.shell().info(
        "  #{provider.label}: #{provider.status} provider=#{provider.provider}#{reason}"
      )
    end)
  end

  defp print_recent_jobs([]), do: Mix.shell().info("Recent Jobs: none")

  defp print_recent_jobs(jobs) do
    Mix.shell().info("Recent Jobs:")

    Enum.each(jobs, fn job ->
      Mix.shell().info(
        "  #{job.job_id}: #{job.status} type=#{job.type} provider=#{job.provider || "none"}"
      )
    end)
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 100)
  defp normalize_limit(_), do: Mix.raise("--limit must be a positive integer")

  defp hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp truthy?(value), do: if(value, do: "true", else: "false")
end
