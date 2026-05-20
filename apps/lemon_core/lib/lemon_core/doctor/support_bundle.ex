defmodule LemonCore.Doctor.SupportBundle do
  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.Report

  @sensitive_terms ~w(
    access_key
    api_key
    apikey
    authorization
    bearer
    bot_token
    credential
    master_key
    oauth
    password
    private
    private_key
    secret
    session
    token
    wallet_key
  )

  @env_allowlist ~w(
    LANG
    LEMON_CONTROL_PLANE_PORT
    LEMON_PATH
    LEMON_SIM_UI_PORT
    LEMON_STORE_PATH
    LEMON_WEB_HOST
    LEMON_WEB_PORT
    MIX_ENV
    PHX_HOST
    TERM
  )

  @media_provider_specs [
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

  @spec write(Report.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write(%Report{} = report, opts \\ []) do
    path = bundle_path(opts)
    File.mkdir_p!(Path.dirname(path))

    entries = [
      {~c"README.txt", readme()},
      {~c"manifest.json", json(manifest(opts))},
      {~c"doctor_report.json", Report.to_json(report)},
      {~c"environment.json", json(environment())},
      {~c"browser_diagnostics.json", json(browser_diagnostics(opts))},
      {~c"channel_diagnostics.json", json(channel_diagnostics(opts))},
      {~c"channel_readiness.json", json(channel_readiness(opts))},
      {~c"readiness_summary.json", json(readiness_summary(report, opts))},
      {~c"checkpoint_diagnostics.json", json(checkpoint_diagnostics(opts))},
      {~c"cron_diagnostics.json", json(cron_diagnostics(opts))},
      {~c"extension_diagnostics.json", json(extension_diagnostics(opts))},
      {~c"goal_diagnostics.json", json(goal_diagnostics(opts))},
      {~c"kanban_diagnostics.json", json(kanban_diagnostics(opts))},
      {~c"lsp_diagnostics.json", json(lsp_diagnostics())},
      {~c"media_diagnostics.json", json(media_diagnostics(opts))},
      {~c"memory_diagnostics.json", json(memory_diagnostics())},
      {~c"proof_diagnostics.json", json(proof_diagnostics(opts))},
      {~c"provider_diagnostics.json", json(provider_diagnostics(opts))},
      {~c"terminal_diagnostics.json", json(terminal_diagnostics())},
      {~c"usage_diagnostics.json", json(usage_diagnostics())}
      | config_entries(opts)
    ]

    case :zip.create(String.to_charlist(path), entries, []) do
      {:ok, _zip_path} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec redact_text(String.t()) :: String.t()
  def redact_text(text) when is_binary(text) do
    text
    |> redact_assignments()
    |> redact_inline_secrets()
  end

  defp bundle_path(opts) do
    case Keyword.get(opts, :bundle_path) do
      nil ->
        bundle_dir = Keyword.get(opts, :bundle_dir, "tmp/lemon-support-bundles")
        timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
        Path.expand(Path.join(bundle_dir, "lemon-doctor-bundle-#{timestamp}.zip"))

      path ->
        Path.expand(path)
    end
  end

  defp manifest(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    Map.merge(LemonCore.BuildInfo.current(cwd: project_dir), %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      bundle_version: 1,
      project_dir: project_dir |> Path.expand(),
      cwd: File.cwd!()
    })
  end

  defp environment do
    @env_allowlist
    |> Enum.sort()
    |> Map.new(fn name ->
      value = System.get_env(name)
      {name, env_value(name, value)}
    end)
  end

  defp env_value(_name, nil), do: %{present: false, value: nil}

  defp env_value(name, value) do
    if sensitive_name?(name) do
      %{present: true, value: "[redacted]"}
    else
      %{present: true, value: value}
    end
  end

  defp browser_diagnostics(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    %{
      local_server: LemonCore.Browser.LocalServer.status(),
      artifacts_dir: LemonCore.Browser.Artifacts.default_dir(project_dir),
      artifact_summary: LemonCore.Browser.Artifacts.summary(project_dir: project_dir),
      recent_artifacts: LemonCore.Browser.Artifacts.recent(project_dir: project_dir, limit: 20)
    }
  end

  defp channel_diagnostics(opts) do
    LemonCore.Doctor.ChannelDiagnostics.status(
      project_dir: Keyword.get(opts, :project_dir, File.cwd!())
    )
  end

  defp channel_readiness(opts) do
    LemonCore.Doctor.ChannelReadiness.status(
      project_dir: Keyword.get(opts, :project_dir, File.cwd!())
    )
  end

  defp readiness_summary(report, opts) do
    LemonCore.Doctor.ReadinessSummary.status(
      report: report,
      project_dir: Keyword.get(opts, :project_dir, File.cwd!()),
      limit: Keyword.get(opts, :readiness_limit, 20)
    )
  end

  defp checkpoint_diagnostics(opts) do
    LemonCore.Doctor.CheckpointDiagnostics.summary(
      checkpoint_dir: Keyword.get(opts, :checkpoint_dir),
      limit: Keyword.get(opts, :checkpoint_limit, 20)
    )
  end

  defp cron_diagnostics(opts) do
    LemonCore.Doctor.CronDiagnostics.status(limit: Keyword.get(opts, :cron_limit, 20))
  end

  defp extension_diagnostics(opts) do
    LemonCore.Doctor.ExtensionDiagnostics.status(
      project_dir: Keyword.get(opts, :project_dir, File.cwd!())
    )
  end

  defp goal_diagnostics(opts) do
    LemonCore.GoalStore.diagnostics(limit: Keyword.get(opts, :goal_limit, 20))
  end

  defp kanban_diagnostics(opts) do
    LemonCore.KanbanStore.diagnostics(limit: Keyword.get(opts, :kanban_limit, 20))
  end

  defp lsp_diagnostics do
    LemonCore.Doctor.LspDiagnostics.status()
  end

  defp media_diagnostics(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    %{
      jobs_dir: LemonCore.MediaJobs.default_dir(project_dir),
      artifacts_dir: LemonCore.MediaJobs.default_artifacts_dir(project_dir),
      worker_status: LemonCore.MediaJobSupervisor.status(),
      summary: LemonCore.MediaJobs.summary(project_dir: project_dir),
      provider_live: media_provider_live(project_dir),
      recent_jobs: LemonCore.MediaJobs.recent(project_dir: project_dir, limit: 20)
    }
  end

  defp media_provider_live(project_dir) do
    proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    providers =
      Enum.map(@media_provider_specs, fn spec ->
        media_provider_summary(spec, Map.get(proofs, :recent_proofs, []))
      end)

    completed_count = Enum.count(providers, &(&1.status == "completed"))

    %{
      status:
        if(completed_count == length(@media_provider_specs), do: "complete", else: "incomplete"),
      completed_count: completed_count,
      required_count: length(@media_provider_specs),
      providers: providers,
      cleanup: %{
        includes_raw_api_keys: false,
        includes_raw_prompts: false,
        includes_raw_provider_responses: false,
        includes_raw_media_bytes: false
      }
    }
  end

  defp media_provider_summary(spec, proofs) do
    matching = Enum.filter(proofs, &(get_in(&1, [:media_proof, :provider]) in spec.providers))
    status = best_media_provider_status(Enum.map(matching, &Map.get(&1, :status)))
    incomplete_proof = Enum.find(matching, &(Map.get(&1, :status) in ["failed", "skipped"]))
    target_provider = get_in(incomplete_proof || %{}, [:media_proof, :provider])
    reason_kind = Map.get(incomplete_proof || %{}, :reason_kind)

    %{
      label: spec.label,
      status: status,
      providers: spec.providers,
      target_provider: target_provider,
      reason_kind: reason_kind,
      proof_path: spec.proof_path,
      command: media_provider_command(spec, status, target_provider),
      secret_command:
        "#{media_provider_command(spec, status, target_provider)} --api-key-secret SECRET_NAME"
    }
  end

  defp best_media_provider_status(statuses) do
    cond do
      "completed" in statuses -> "completed"
      "failed" in statuses -> "failed"
      "skipped" in statuses -> "skipped"
      true -> "missing"
    end
  end

  defp media_provider_command(spec, status, target_provider) do
    command =
      "LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start #{spec.script} --proof-path #{spec.proof_path}"

    if status in ["failed", "skipped"] and target_provider in spec.providers and
         length(spec.providers) > 1 do
      "#{command} --provider #{target_provider}"
    else
      command
    end
  end

  defp memory_diagnostics do
    LemonCore.MemoryProviders.status()
  end

  defp proof_diagnostics(opts) do
    LemonCore.Doctor.ProofDiagnostics.status(
      project_dir: Keyword.get(opts, :project_dir, File.cwd!())
    )
  end

  defp terminal_diagnostics do
    LemonCore.TerminalBackends.diagnostics()
  end

  defp provider_diagnostics(opts) do
    LemonCore.Doctor.ProviderDiagnostics.status(
      project_dir: Keyword.get(opts, :project_dir, File.cwd!())
    )
  end

  defp usage_diagnostics, do: LemonCore.UsageDiagnostics.status()

  defp config_entries(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    [
      {~c"config/global_config.toml", Modular.global_path()},
      {~c"config/project_config.toml", Modular.project_path(project_dir)}
    ]
    |> Enum.map(fn {entry_name, path} ->
      expanded = Path.expand(path)

      content =
        if File.exists?(expanded) do
          File.read!(expanded) |> redact_text()
        else
          "missing: #{expanded}\n"
        end

      {entry_name, content}
    end)
  end

  defp json(data), do: Jason.encode!(data, pretty: true)

  defp readme do
    """
    Lemon doctor support bundle

    This archive is generated by `mix lemon.doctor --bundle` or the release
    support-bundle command.
    It includes the doctor report, runtime metadata, selected environment shape,
    redacted Lemon config files, and redacted diagnostics for browser, channels,
    channel readiness, compact launch readiness, checkpoints, cron, extensions,
    goals, kanban, LSP, media, memory, proofs, providers, terminals, and usage.

    Review before sharing. It should not contain provider keys, tokens, passwords,
    secret names, chat/channel/guild ids, private prompts, message bodies,
    memory contents, proof file contents, media bytes, or tool outputs.
    """
  end

  defp redact_assignments(text) do
    Regex.replace(
      ~r/^(\s*[^#\n=\[]*?(?:#{sensitive_pattern()})[^=\n]*=\s*).+$/imu,
      text,
      "\\1\"[redacted]\""
    )
  end

  defp redact_inline_secrets(text) do
    text
    |> then(&Regex.replace(~r/sk-[A-Za-z0-9_\-]{8,}/, &1, "[redacted]"))
    |> then(&Regex.replace(~r/(?i)bearer\s+[A-Za-z0-9._\-]+/, &1, "Bearer [redacted]"))
    |> then(&Regex.replace(~r/0x[a-fA-F0-9]{64}/, &1, "[redacted]"))
  end

  defp sensitive_name?(name) do
    downcased = String.downcase(to_string(name))
    Enum.any?(@sensitive_terms, &String.contains?(downcased, &1))
  end

  defp sensitive_pattern do
    Enum.map_join(@sensitive_terms, "|", &Regex.escape/1)
  end
end
