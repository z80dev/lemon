defmodule LemonCore.Doctor.SupportBundle do
  @moduledoc """
  Builds sanitized support bundle archives from doctor reports, runtime diagnostics, and selected configuration files.
  """
  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.Report

  @env_allowlist ~w(
    LANG
    LEMON_CONTROL_PLANE_PORT
    LEMON_PATH
    LEMON_STORE_PATH
    LEMON_WEB_HOST
    LEMON_WEB_PORT
    MIX_ENV
    PHX_HOST
    TERM
  )

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
      {~c"checkpoint_diagnostics.json", json(checkpoint_diagnostics(opts))},
      {~c"cron_diagnostics.json", json(cron_diagnostics(opts))},
      {~c"extension_diagnostics.json", json(extension_diagnostics(opts))},
      {~c"goal_diagnostics.json", json(goal_diagnostics(opts))},
      {~c"kanban_diagnostics.json", json(kanban_diagnostics(opts))},
      {~c"lsp_diagnostics.json", json(lsp_diagnostics())},
      {~c"media_diagnostics.json", json(media_diagnostics(opts))},
      {~c"memory_diagnostics.json", json(memory_diagnostics())},
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
    if LemonCore.Redact.sensitive_key?(name) do
      %{present: true, value: "[redacted]"}
    else
      %{present: true, value: value}
    end
  end

  defp browser_diagnostics(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    %{
      local_server:
        probe(runtime_module(:browser_server), :status, [], %{
          available: false,
          running: false,
          error: "browser runtime not available",
          pending_requests: 0
        }),
      artifacts_dir: probe(runtime_module(:browser_artifacts), :default_dir, [project_dir], nil),
      artifact_summary:
        probe(runtime_module(:browser_artifacts), :summary, [[project_dir: project_dir]], %{
          available: false,
          error: "browser runtime not available"
        }),
      recent_artifacts:
        probe(
          runtime_module(:browser_artifacts),
          :recent,
          [[project_dir: project_dir, limit: 20]],
          []
        )
    }
  end

  defp channel_diagnostics(opts) do
    probe(
      runtime_module(:channel_diagnostics),
      :status,
      [[project_dir: Keyword.get(opts, :project_dir, File.cwd!())]],
      %{
        transports: [],
        registered_transports: [],
        binding_count: 0,
        unsupported_binding_count: 0,
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_secret_names: false,
          includes_chat_ids: false,
          includes_channel_ids: false,
          includes_guild_ids: false,
          includes_message_bodies: false
        }
      }
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
    workspace_diagnostics(:goal, limit: Keyword.get(opts, :goal_limit, 20))
    |> Map.put_new(:cleanup, %{includes_objectives: false, includes_raw_session_ids: false})
  end

  defp kanban_diagnostics(opts) do
    workspace_diagnostics(:kanban, limit: Keyword.get(opts, :kanban_limit, 20))
    |> Map.put_new(:cleanup, %{
      includes_titles: false,
      includes_descriptions: false,
      includes_comments: false,
      includes_raw_session_ids: false
    })
  end

  # The workspace stores live in the agent runtime, which core must not depend
  # on; the reference runtime injects them via config.
  defp workspace_diagnostics(kind, args) do
    mod = Application.get_env(:lemon_core, :workspace_diagnostics, [])[kind]

    probe(mod, :diagnostics, [args], %{
      available: false,
      error: "agent workspace runtime not available"
    })
  end

  defp lsp_diagnostics do
    LemonCore.Doctor.LspDiagnostics.status()
  end

  defp media_diagnostics(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    %{
      jobs_dir: probe(runtime_module(:media_jobs), :default_dir, [project_dir], nil),
      artifacts_dir:
        probe(runtime_module(:media_jobs), :default_artifacts_dir, [project_dir], nil),
      worker_status:
        probe(runtime_module(:media_supervisor), :status, [], %{
          supervised: false,
          running: false,
          active_jobs: 0,
          workers: 0,
          supervisors: 0,
          error: "media runtime not available"
        }),
      summary:
        probe(runtime_module(:media_jobs), :summary, [[project_dir: project_dir]], %{
          available: false,
          error: "media runtime not available"
        }),
      recent_jobs:
        probe(runtime_module(:media_jobs), :recent, [[project_dir: project_dir, limit: 20]], [])
    }
  end

  defp memory_diagnostics do
    probe(runtime_module(:memory_providers), :status, [], %{
      available: false,
      error: "memory runtime not available"
    })
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
          File.read!(expanded) |> LemonCore.Redact.text(strict: true)
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
    checkpoints, cron, extensions, goals, kanban, LSP, media, memory, providers,
    terminals, and usage.

    Review before sharing. It should not contain provider keys, tokens, passwords,
    secret names, chat/channel/guild ids, private prompts, message bodies,
    memory contents, media bytes, or tool outputs.
    """
  end

  # Media, browser and LSP diagnostics are owned by other apps; core looks their
  # modules up through config rather than naming them.
  defp runtime_module(key), do: LemonCore.Doctor.RuntimeModules.fetch(key)

  defp probe(nil, _fun, _args, fallback), do: fallback

  defp probe(mod, fun, args, fallback) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      fallback
    end
  end
end
