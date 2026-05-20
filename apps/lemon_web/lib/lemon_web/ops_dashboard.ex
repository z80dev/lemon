defmodule LemonWeb.OpsDashboard do
  @moduledoc false

  alias LemonCore.{
    Doctor.ChannelDiagnostics,
    Doctor.ChannelReadiness,
    Doctor.ReadinessSummary,
    ExecApprovalStore,
    Doctor.ExtensionDiagnostics,
    Doctor.ProofDiagnostics,
    GoalStore,
    Introspection,
    KanbanStore,
    MemoryProviders,
    MediaJobs,
    TerminalBackends,
    UsageDiagnostics
  }

  @recent_run_limit 10
  @run_detail_event_limit 500
  @child_lookup_limit 1_000
  @activity_event_limit 250
  @activity_recent_limit 5
  @lsp_proof_scan_limit 1_000
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

  def snapshot do
    %{
      generated_at: DateTime.utc_now(),
      runtime: runtime_status(),
      build: build_status(),
      router: router_status(),
      readiness: readiness_status(),
      browser: browser_status(),
      checkpoints: checkpoint_status(),
      goals: goal_status(),
      kanban: kanban_status(),
      media: media_status(),
      memory: memory_status(),
      proofs: proof_status(),
      terminal_backends: terminal_backend_status(),
      lsp_diagnostics: lsp_diagnostics_status(),
      provider: provider_status(),
      usage: usage_status(),
      config: config_status(),
      active_sessions: active_sessions(),
      recent_runs: recent_runs(),
      pending_approvals: pending_approvals(),
      activity: observed_activity(),
      cron: cron_status(),
      extensions: extensions_status(),
      skills: skills_status(),
      channels: channels_status(),
      support: support_commands(),
      planned_panels: planned_panels()
    }
  end

  def run_detail(run_id) when is_binary(run_id) and run_id != "" do
    events = run_events(run_id)

    %{
      run_id: run_id,
      summary: run_summary(run_id, events),
      events: events,
      event_counts: event_counts(events),
      tool_events: Enum.filter(events, &tool_event?/1),
      approval_events: Enum.filter(events, &approval_event?/1),
      learning_events: Enum.filter(events, &learning_event?/1),
      channel_events: Enum.filter(events, &channel_event?/1),
      cron_events: Enum.filter(events, &cron_event?/1),
      subagent_events: Enum.filter(events, &subagent_event?/1),
      failures: Enum.filter(events, &failure_event?/1),
      children: child_runs(run_id),
      graph: run_graph(run_id),
      pending_approvals: pending_approvals_for_run(run_id),
      support: support_commands()
    }
  end

  def run_detail(_run_id) do
    %{
      run_id: nil,
      summary: %{},
      events: [],
      event_counts: %{},
      tool_events: [],
      approval_events: [],
      learning_events: [],
      channel_events: [],
      cron_events: [],
      subagent_events: [],
      failures: [],
      children: [],
      graph: nil,
      pending_approvals: [],
      support: support_commands()
    }
  end

  def resolve_approval(approval_id, decision) when is_binary(approval_id) do
    with {:ok, decision} <- normalize_approval_decision(decision) do
      :ok = LemonCore.ExecApprovals.resolve(approval_id, decision)
      :ok
    end
  end

  def resolve_approval(_approval_id, _decision), do: {:error, :invalid_approval}

  def create_cron_job(params) when is_map(params) do
    case cron_manager_call(:add, [cron_create_params(params)]) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def create_cron_job(_params), do: {:error, :invalid_cron_job}

  def update_cron_job(job_id, params) when is_binary(job_id) and is_map(params) do
    case cron_manager_call(:update, [job_id, cron_update_params(params)]) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def update_cron_job(_job_id, _params), do: {:error, :invalid_cron_update}

  def delete_cron_job(job_id) when is_binary(job_id) do
    case cron_manager_call(:remove, [job_id]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def delete_cron_job(_job_id), do: {:error, :invalid_cron_job}

  def set_cron_enabled(job_id, enabled) when is_binary(job_id) and is_boolean(enabled) do
    case cron_manager_call(:update, [job_id, %{enabled: enabled}]) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def set_cron_enabled(_job_id, _enabled), do: {:error, :invalid_cron_update}

  def run_cron_now(job_id) when is_binary(job_id) do
    case cron_manager_call(:run_now, [job_id]) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def run_cron_now(_job_id), do: {:error, :invalid_cron_job}

  def abort_cron_run(run_id) when is_binary(run_id) do
    case cron_manager_call(:abort_run, [run_id]) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def abort_cron_run(_run_id), do: {:error, :invalid_cron_run}

  def set_skill_enabled(skill_key, enabled, opts \\ [])

  def set_skill_enabled(skill_key, enabled, opts)
      when is_binary(skill_key) and is_boolean(enabled) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    global = Keyword.get(opts, :global, true)
    function = if enabled, do: :enable, else: :disable

    case skills_module_call(["Config"], function, [skill_key, [cwd: cwd, global: global]]) do
      :ok ->
        _ = skills_module_call(["Registry"], :refresh, [[cwd: cwd]])
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  def set_skill_enabled(_skill_key, _enabled, _opts), do: {:error, :invalid_skill_update}

  def install_skill(source, opts \\ [])

  def install_skill(source, opts) when is_binary(source) do
    source = String.trim(source)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    global = Keyword.get(opts, :global, true)
    force = Keyword.get(opts, :force, false)

    if source == "" do
      {:error, :invalid_skill_source}
    else
      case skills_module_call(["Installer"], :install, [
             source,
             [cwd: cwd, global: global, force: force, approve: true]
           ]) do
        {:ok, _entry} ->
          _ = skills_module_call(["Registry"], :refresh, [[cwd: cwd]])
          :ok

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, other}
      end
    end
  end

  def install_skill(_source, _opts), do: {:error, :invalid_skill_source}

  def update_skill(skill_key, opts \\ [])

  def update_skill(skill_key, opts) when is_binary(skill_key) do
    skill_key = String.trim(skill_key)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    force = Keyword.get(opts, :force, false)

    if skill_key == "" do
      {:error, :invalid_skill_update}
    else
      case skills_module_call(["Installer"], :update, [
             skill_key,
             [cwd: cwd, force: force, approve: true]
           ]) do
        {:ok, _entry} ->
          _ = skills_module_call(["Registry"], :refresh, [[cwd: cwd]])
          :ok

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, other}
      end
    end
  end

  def update_skill(_skill_key, _opts), do: {:error, :invalid_skill_update}

  def disconnect_channel(channel_id) when is_binary(channel_id) and channel_id != "" do
    case channel_registry_call(:logout, [channel_id]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def disconnect_channel(_channel_id), do: {:error, :invalid_channel}

  def reconnect_channel(channel_id) when is_binary(channel_id) and channel_id != "" do
    with {:ok, adapter_module, opts} <- configured_channel_adapter(channel_id) do
      case channels_application_call(:register_and_start_adapter, [adapter_module, opts]) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  end

  def reconnect_channel(_channel_id), do: {:error, :invalid_channel}

  def checkpoint_diff(checkpoint_id) when is_binary(checkpoint_id) and checkpoint_id != "" do
    case LemonCore.Checkpoint.diff_filesystem(checkpoint_id) do
      {:ok, diff} ->
        {:ok,
         %{
           checkpoint_id: diff.checkpoint_id,
           changed_count: length(diff.changed),
           changed: diff.changed,
           output: diff.output
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def checkpoint_diff(_checkpoint_id), do: {:error, :invalid_checkpoint}

  def checkpoint_restore(checkpoint_id) when is_binary(checkpoint_id) and checkpoint_id != "" do
    case LemonCore.Checkpoint.restore_filesystem(checkpoint_id) do
      {:ok, restored} ->
        {:ok,
         %{
           checkpoint_id: restored.checkpoint_id,
           restored_count: length(restored.restored),
           restored: restored.restored
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def checkpoint_restore(_checkpoint_id), do: {:error, :invalid_checkpoint}

  def set_channel_config_enabled(channel_id, enabled)
      when is_binary(channel_id) and is_boolean(enabled) do
    case gateway_transport_config_key(channel_id) do
      nil ->
        {:error, :channel_not_configurable}

      key ->
        with :ok <- write_gateway_boolean(key, enabled),
             :ok <- reload_config() do
          :ok
        end
    end
  end

  def set_channel_config_enabled(_channel_id, _enabled), do: {:error, :invalid_channel}

  def update_default_config(params) when is_map(params) do
    fields = [
      {"provider", param_string(params, "provider"), :string},
      {"model", param_string(params, "model"), :string},
      {"thinking_level", param_string(params, "thinking_level"), :string},
      {"engine", param_string(params, "engine"), :string}
    ]

    with :ok <- write_table_fields("defaults", fields),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_default_config(_params), do: {:error, :invalid_default_config}

  def update_provider_config(provider_id, params)
      when is_binary(provider_id) and is_map(params) do
    provider_id = String.trim(provider_id)

    with :ok <- validate_provider_id(provider_id),
         :ok <- write_table_fields("providers.#{provider_id}", provider_config_fields(params)),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_provider_config(_provider_id, _params), do: {:error, :invalid_provider_config}

  def update_channel_gateway_defaults(params) when is_map(params) do
    with :ok <- write_gateway_defaults(params),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_channel_gateway_defaults(_params), do: {:error, :invalid_gateway_config}

  def update_channel_telegram_config(params) when is_map(params) do
    with {:ok, fields} <- telegram_config_fields(params),
         :ok <- write_table_fields("gateway.telegram", fields),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_channel_telegram_config(_params), do: {:error, :invalid_telegram_config}

  def update_channel_discord_config(params) when is_map(params) do
    with {:ok, fields} <- discord_config_fields(params),
         :ok <- write_table_fields("gateway.discord", fields),
         :ok <- reload_config() do
      :ok
    end
  end

  def update_channel_discord_config(_params), do: {:error, :invalid_discord_config}

  def create_channel_binding(params) when is_map(params) do
    with {:ok, binding} <- channel_binding_params(params),
         :ok <- write_gateway_bindings(current_channel_bindings() ++ [binding]),
         :ok <- reload_config() do
      :ok
    end
  end

  def create_channel_binding(_params), do: {:error, :invalid_channel_binding}

  def update_channel_binding(index, params) when is_map(params) do
    with {:ok, index} <- parse_binding_index(index),
         bindings <- current_channel_bindings(),
         true <- index < length(bindings),
         {:ok, binding} <- channel_binding_params(params),
         updated <- List.replace_at(bindings, index, binding),
         :ok <- write_gateway_bindings(updated),
         :ok <- reload_config() do
      :ok
    else
      false -> {:error, :invalid_channel_binding}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_channel_binding(_index, _params), do: {:error, :invalid_channel_binding}

  def delete_channel_binding(index) do
    with {:ok, index} <- parse_binding_index(index),
         bindings <- current_channel_bindings(),
         true <- index < length(bindings),
         updated <- List.delete_at(bindings, index),
         :ok <- write_gateway_bindings(updated),
         :ok <- reload_config() do
      :ok
    else
      false -> {:error, :invalid_channel_binding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_status do
    LemonCore.Runtime.Boot.status(:runtime_full)
  rescue
    error -> %{status: :unknown, apps: [], missing: [], error: Exception.message(error)}
  catch
    kind, reason -> %{status: :unknown, apps: [], missing: [], error: inspect({kind, reason})}
  end

  defp build_status do
    LemonCore.BuildInfo.current()
  rescue
    error -> %{runtime_mode: "unknown", error: Exception.message(error)}
  catch
    kind, reason -> %{runtime_mode: "unknown", error: inspect({kind, reason})}
  end

  defp router_status do
    LemonRouter.Health.status()
  rescue
    error -> %{ok: false, checks: [], error: Exception.message(error)}
  catch
    kind, reason -> %{ok: false, checks: [], error: inspect({kind, reason})}
  end

  defp browser_status do
    project_dir = File.cwd!()
    local = LemonCore.Browser.LocalServer.status()
    artifacts_dir = LemonCore.Browser.Artifacts.default_dir(project_dir)
    artifact_summary = LemonCore.Browser.Artifacts.summary(project_dir: project_dir)
    recent_artifacts = LemonCore.Browser.Artifacts.recent(project_dir: project_dir, limit: 5)

    %{
      local: local,
      available?: get_map(local, :available, false) == true,
      running?: get_map(local, :running, false) == true,
      session: browser_session(local),
      driver_config: browser_driver_config(local),
      capabilities: browser_capabilities(),
      operator_guidance: browser_operator_guidance(local, artifact_summary),
      pending_requests: get_map(local, :pending_requests, 0),
      completed_count: get_map(local, :completed_count, 0),
      failed_count: get_map(local, :failed_count, 0),
      request_count: get_map(local, :request_count, 0),
      last_error: get_map(local, :last_error),
      artifacts_dir: artifacts_dir,
      artifact_summary: artifact_summary,
      recent_artifacts: recent_artifacts
    }
  rescue
    error ->
      %{
        local: %{},
        available?: false,
        running?: false,
        session: browser_session(%{}),
        driver_config: browser_driver_config(%{}),
        capabilities: browser_capabilities(),
        operator_guidance: [
          %{status: "blocked", message: "browser status failed", action: "check web logs"}
        ],
        pending_requests: 0,
        completed_count: 0,
        failed_count: 0,
        request_count: 0,
        last_error: Exception.message(error),
        artifacts_dir: nil,
        artifact_summary: browser_artifact_summary_unavailable(),
        recent_artifacts: []
      }
  catch
    kind, reason ->
      %{
        local: %{},
        available?: false,
        running?: false,
        session: browser_session(%{}),
        driver_config: browser_driver_config(%{}),
        capabilities: browser_capabilities(),
        operator_guidance: [
          %{status: "blocked", message: "browser status failed", action: "check web logs"}
        ],
        pending_requests: 0,
        completed_count: 0,
        failed_count: 0,
        request_count: 0,
        last_error: inspect({kind, reason}),
        artifacts_dir: nil,
        artifact_summary: browser_artifact_summary_unavailable(),
        recent_artifacts: []
      }
  end

  defp browser_artifact_summary_unavailable do
    %{
      dir: nil,
      exists: false,
      count: 0,
      total_bytes: 0,
      oldest_modified_at: nil,
      newest_modified_at: nil,
      cleanup: %{
        managed: false,
        policy: "unknown",
        safe_to_delete: false,
        embeds_artifact_bytes_in_support_bundle: false
      }
    }
  end

  defp browser_session(local) when is_map(local) do
    port = get_map(local, :port, %{}) || %{}

    %{
      available?: get_map(local, :available, false) == true,
      running?: get_map(local, :running, false) == true,
      driver_pid_hash: local |> get_in_safe([:port, :os_pid]) |> browser_hash(),
      port_connected: get_map(port, :connected),
      pending_requests: get_map(local, :pending_requests, 0),
      buffer_bytes: get_map(local, :buffer_bytes, 0),
      request_count: get_map(local, :request_count, 0),
      completed_count: get_map(local, :completed_count, 0),
      failed_count: get_map(local, :failed_count, 0),
      started_at: get_map(local, :started_at),
      last_request_at: get_map(local, :last_request_at),
      last_error_at: get_map(local, :last_error_at),
      last_error_kind: browser_error_kind(get_map(local, :last_error))
    }
  end

  defp browser_session(_), do: browser_session(%{})

  defp browser_driver_config(local) when is_map(local) do
    config = get_map(local, :driver_config, %{}) || %{}

    %{
      mode: get_map(config, :mode, "local_cdp"),
      launches_browser: get_map(config, :launches_browser, true) == true,
      attach_only: get_map(config, :attach_only, false) == true,
      cdp_port: get_map(config, :cdp_port),
      cdp_endpoint_configured: get_map(config, :cdp_endpoint_configured, false) == true,
      cdp_endpoint_hash: get_map(config, :cdp_endpoint_hash)
    }
  end

  defp browser_driver_config(_), do: browser_driver_config(%{})

  defp browser_capabilities do
    [
      %{name: "navigation", status: "supported"},
      %{name: "snapshot", status: "supported"},
      %{name: "content extraction", status: "supported"},
      %{name: "click/type/press/scroll", status: "supported"},
      %{name: "screenshots", status: "supported"},
      %{name: "cookies", status: "supported"},
      %{name: "clear state", status: "supported"},
      %{name: "channel screenshot delivery", status: "preview"}
    ]
  end

  defp browser_operator_guidance(local, artifact_summary) do
    cond do
      get_map(local, :available, false) != true ->
        [
          %{
            status: "blocked",
            message: browser_error_kind(get_map(local, :error) || get_map(local, :last_error)),
            action: "build clients/lemon-browser-node and ensure node/chromium are available"
          }
        ]

      get_map(local, :running, false) == true and get_map(local, :pending_requests, 0) > 0 ->
        [
          %{
            status: "active",
            message: "#{get_map(local, :pending_requests, 0)} browser request(s) pending",
            action: "watch request completion or timeout"
          }
        ]

      get_map(local, :last_error) not in [nil, ""] ->
        [
          %{
            status: "check",
            message: browser_error_kind(get_map(local, :last_error)),
            action: "run the browser smoke proof or inspect the local driver"
          }
        ]

      get_map(artifact_summary, :count, 0) == 0 ->
        [
          %{
            status: "ready",
            message: "driver available; no retained browser artifacts",
            action: "run browser smoke proof when promoting browser support"
          }
        ]

      true ->
        [
          %{
            status: "ready",
            message: "#{get_map(artifact_summary, :count, 0)} browser artifact(s) retained",
            action: "review recent artifacts and cleanup policy before sharing"
          }
        ]
    end
  end

  defp browser_error_kind(nil), do: nil
  defp browser_error_kind(""), do: nil

  defp browser_error_kind(error) do
    normalized = error |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, "driver not built") -> "browser_driver_not_built"
      String.contains?(normalized, "node executable") -> "node_executable_missing"
      String.contains?(normalized, "timed out") -> "browser_request_timeout"
      String.contains?(normalized, "exited") -> "browser_driver_exited"
      true -> "browser_error"
    end
  end

  defp browser_hash(nil), do: nil
  defp browser_hash(value), do: hash_value(to_string(value))

  defp checkpoint_status do
    LemonCore.Doctor.CheckpointDiagnostics.summary(limit: 5)
  rescue
    error ->
      %{
        store_dir: nil,
        exists: false,
        count: 0,
        filesystem_count: 0,
        invalid_count: 0,
        total_bytes: 0,
        oldest: nil,
        newest: nil,
        recent: [],
        cleanup: %{
          managed: false,
          policy: "unknown",
          safe_to_delete: false,
          embeds_file_contents_in_support_bundle: false,
          includes_raw_paths: false,
          includes_raw_session_ids: false
        },
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        store_dir: nil,
        exists: false,
        count: 0,
        filesystem_count: 0,
        invalid_count: 0,
        total_bytes: 0,
        oldest: nil,
        newest: nil,
        recent: [],
        cleanup: %{
          managed: false,
          policy: "unknown",
          safe_to_delete: false,
          embeds_file_contents_in_support_bundle: false,
          includes_raw_paths: false,
          includes_raw_session_ids: false
        },
        error: inspect({kind, reason})
      }
  end

  defp goal_status do
    GoalStore.diagnostics(limit: 5)
  rescue
    error ->
      %{
        count: 0,
        active_count: 0,
        paused_count: 0,
        completed_count: 0,
        recent: [],
        cleanup: %{
          includes_objectives: false,
          includes_raw_session_ids: false
        },
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        count: 0,
        active_count: 0,
        paused_count: 0,
        completed_count: 0,
        recent: [],
        cleanup: %{
          includes_objectives: false,
          includes_raw_session_ids: false
        },
        error: inspect({kind, reason})
      }
  end

  defp kanban_status do
    diagnostics = KanbanStore.diagnostics(limit: 5)
    boards = KanbanStore.list_boards(limit: 5)

    Map.merge(diagnostics, %{
      recent_boards: Enum.map(boards, &kanban_board_summary/1)
    })
  rescue
    error ->
      %{
        board_count: 0,
        active_board_count: 0,
        archived_board_count: 0,
        task_count: 0,
        open_task_count: 0,
        recent_boards: [],
        cleanup: %{
          includes_titles: false,
          includes_descriptions: false,
          includes_comments: false,
          includes_raw_session_ids: false
        },
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        board_count: 0,
        active_board_count: 0,
        archived_board_count: 0,
        task_count: 0,
        open_task_count: 0,
        recent_boards: [],
        cleanup: %{
          includes_titles: false,
          includes_descriptions: false,
          includes_comments: false,
          includes_raw_session_ids: false
        },
        error: inspect({kind, reason})
      }
  end

  defp terminal_backend_status do
    TerminalBackends.diagnostics()
  rescue
    error ->
      %{
        backends: [],
        count: 0,
        default_backend: nil,
        policy: terminal_backend_policy(),
        cleanup: terminal_backend_cleanup(),
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        backends: [],
        count: 0,
        default_backend: nil,
        policy: terminal_backend_policy(),
        cleanup: terminal_backend_cleanup(),
        error: inspect({kind, reason})
      }
  end

  defp media_status do
    project_dir = File.cwd!()

    %{
      jobs_dir: MediaJobs.default_dir(project_dir),
      artifacts_dir: MediaJobs.default_artifacts_dir(project_dir),
      worker_status: LemonCore.MediaJobSupervisor.status(),
      summary: MediaJobs.summary(project_dir: project_dir),
      provider_proofs: media_provider_proofs(project_dir),
      recent_jobs: MediaJobs.recent(project_dir: project_dir, limit: 5)
    }
  rescue
    error ->
      %{
        jobs_dir: nil,
        artifacts_dir: nil,
        worker_status: media_worker_status_unavailable(),
        summary: media_summary_unavailable(),
        provider_proofs: media_provider_proofs_unavailable(),
        recent_jobs: [],
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        jobs_dir: nil,
        artifacts_dir: nil,
        worker_status: media_worker_status_unavailable(),
        summary: media_summary_unavailable(),
        provider_proofs: media_provider_proofs_unavailable(),
        recent_jobs: [],
        error: inspect({kind, reason})
      }
  end

  defp media_summary_unavailable do
    %{
      exists: false,
      count: 0,
      status_counts: %{},
      type_counts: %{},
      artifact_count: 0,
      artifact_total_bytes: 0,
      cleanup: %{
        managed: true,
        policy: "managed: 30d or 500 jobs / 250 artifacts",
        safe_to_delete: true,
        embeds_artifact_bytes_in_support_bundle: false,
        includes_raw_paths: false,
        includes_prompts: false,
        includes_provider_responses: false,
        includes_channel_message_bodies: false
      }
    }
  end

  defp media_worker_status_unavailable do
    %{
      supervised: true,
      running: false,
      active_jobs: 0,
      workers: 0,
      supervisors: 0
    }
  end

  defp media_provider_proofs(project_dir) do
    proofs =
      ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)
      |> get_map(:recent_proofs, [])

    providers =
      Enum.map(@media_provider_specs, fn spec ->
        media_provider_proof_summary(spec, proofs)
      end)

    completed_count = Enum.count(providers, &(&1.status == "proven"))

    %{
      status:
        if(completed_count == length(@media_provider_specs), do: "proven", else: "incomplete"),
      completed_count: completed_count,
      required_count: length(@media_provider_specs),
      providers: providers,
      next_action: media_provider_next_action(providers)
    }
  rescue
    _ -> media_provider_proofs_unavailable()
  catch
    _, _ -> media_provider_proofs_unavailable()
  end

  defp media_provider_proofs_unavailable do
    %{
      status: "unknown",
      completed_count: 0,
      required_count: length(@media_provider_specs),
      providers:
        Enum.map(@media_provider_specs, fn spec ->
          %{
            provider: media_provider_primary(spec),
            providers: spec.providers,
            label: spec.label,
            command: media_provider_command(spec.script, spec.proof_path),
            secret_command: media_provider_secret_command(spec.script, spec.proof_path),
            provider_commands: media_provider_commands(spec),
            proof_path: spec.proof_path,
            status: "unknown",
            proof_status: nil,
            reason_kind: nil,
            model: nil,
            modified_at: nil,
            proof_hash: nil,
            next_action: "run #{spec.script}"
          }
        end),
      next_action: "run provider-backed media smoke scripts"
    }
  end

  defp media_provider_proof_summary(spec, proofs) do
    proof =
      proofs
      |> Enum.filter(&(get_in(&1, [:media_proof, :provider]) in spec.providers))
      |> Enum.sort_by(
        fn proof ->
          {provider_proof_rank(get_map(proof, :status)), get_map(proof, :modified_at) || ""}
        end,
        fn {rank_a, modified_a}, {rank_b, modified_b} ->
          rank_a < rank_b or (rank_a == rank_b and modified_a >= modified_b)
        end
      )
      |> List.first()

    proof_status = get_map(proof, :status)

    %{
      provider: get_in(proof || %{}, [:media_proof, :provider]) || media_provider_primary(spec),
      providers: spec.providers,
      label: spec.label,
      command: media_provider_command(spec.script, spec.proof_path),
      secret_command: media_provider_secret_command(spec.script, spec.proof_path),
      provider_commands: media_provider_commands(spec),
      proof_path: spec.proof_path,
      status: provider_proof_status(proof_status),
      proof_status: proof_status,
      reason_kind: get_map(proof, :reason_kind),
      model: get_in(proof || %{}, [:media_proof, :model]),
      modified_at: get_map(proof, :modified_at),
      proof_hash: get_map(proof, :proof_hash),
      next_action:
        media_provider_next_action(
          proof_status,
          spec.script,
          get_map(proof, :reason_kind),
          spec.label
        )
    }
  end

  defp media_provider_primary(%{providers: [provider | _]}), do: provider

  defp media_provider_commands(%{providers: [_provider]}), do: []

  defp media_provider_commands(spec) do
    Enum.map(spec.providers, fn provider ->
      %{
        provider: provider,
        command: media_provider_command(spec.script, spec.proof_path, provider),
        secret_command: media_provider_secret_command(spec.script, spec.proof_path, provider)
      }
    end)
  end

  defp media_provider_command(script, proof_path) do
    "LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start #{script} --proof-path #{proof_path}"
  end

  defp media_provider_secret_command(script, proof_path) do
    "#{media_provider_command(script, proof_path)} --api-key-secret SECRET_NAME"
  end

  defp media_provider_command(script, proof_path, provider) do
    "#{media_provider_command(script, proof_path)} --provider #{provider}"
  end

  defp media_provider_secret_command(script, proof_path, provider) do
    "#{media_provider_command(script, proof_path, provider)} --api-key-secret SECRET_NAME"
  end

  defp media_provider_next_action(providers) do
    providers
    |> Enum.reject(&(&1.status == "proven"))
    |> List.first()
    |> case do
      nil -> "keep provider-backed media proofs current"
      provider -> provider.next_action
    end
  end

  defp media_provider_next_action("completed", _script, _reason, _label), do: "keep proof current"

  defp media_provider_next_action("failed", script, reason, label) do
    case media_provider_reason_action(reason, label) do
      nil -> "inspect provider diagnostics and rerun #{script}"
      action -> "#{action}; rerun #{script}"
    end
  end

  defp media_provider_next_action("skipped", script, _reason, _label),
    do: "enable live credentials and rerun #{script}"

  defp media_provider_next_action(_status, script, _reason, _label), do: "run #{script}"

  defp media_provider_reason_action(reason, label) when is_binary(reason) do
    cond do
      String.contains?(reason, "permission_denied") ->
        "#{label}: enable provider API/IAM/billing permissions for the configured account"

      String.contains?(reason, "billing_limit") ->
        "#{label}: use a funded provider account or raise quota"

      String.contains?(reason, "payment_required") ->
        "#{label}: fund or upgrade the provider account"

      String.contains?(reason, "invalid_request_error") ->
        "#{label}: verify model, voice, output format, and provider options"

      String.contains?(reason, "provider_http_error") ->
        "#{label}: inspect the sanitized provider HTTP reason"

      true ->
        nil
    end
  end

  defp media_provider_reason_action(_reason, _label), do: nil

  defp terminal_backend_cleanup do
    %{
      includes_commands: false,
      includes_environment: false,
      includes_process_output: false
    }
  end

  defp terminal_backend_policy do
    %{
      backend_allowlist_configured: false,
      allowed_backends: [],
      denied_backends: [],
      approval_required_backends: []
    }
  end

  defp memory_status do
    MemoryProviders.status()
  rescue
    error ->
      %{
        provider_count: 0,
        enabled_provider_count: 0,
        providers: [],
        cleanup: memory_cleanup(%{}),
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        provider_count: 0,
        enabled_provider_count: 0,
        providers: [],
        cleanup: memory_cleanup(%{}),
        error: inspect({kind, reason})
      }
  end

  defp memory_cleanup(cleanup) when is_map(cleanup) do
    %{
      includes_memory_contents: Map.get(cleanup, :includes_memory_contents, false),
      includes_raw_provider_config: Map.get(cleanup, :includes_raw_provider_config, false),
      includes_secret_values: Map.get(cleanup, :includes_secret_values, false)
    }
  end

  defp memory_cleanup(_), do: memory_cleanup(%{})

  defp proof_status do
    ProofDiagnostics.status(project_dir: File.cwd!(), limit: 5)
  rescue
    error ->
      %{
        directories: [],
        proof_count: 0,
        invalid_count: 0,
        completed_count: 0,
        failed_count: 0,
        skipped_count: 0,
        status_counts: %{},
        reason_kind_counts: %{},
        proof_scope_counts: %{},
        check_name_counts: %{},
        latest_checks: [],
        recent_proofs: [],
        cleanup: proof_cleanup(),
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        directories: [],
        proof_count: 0,
        invalid_count: 0,
        completed_count: 0,
        failed_count: 0,
        skipped_count: 0,
        status_counts: %{},
        reason_kind_counts: %{},
        proof_scope_counts: %{},
        check_name_counts: %{},
        latest_checks: [],
        recent_proofs: [],
        cleanup: proof_cleanup(),
        error: inspect({kind, reason})
      }
  end

  defp proof_cleanup do
    %{
      includes_raw_paths: false,
      includes_raw_filenames: false,
      includes_raw_proof_details: false,
      includes_raw_prompts: false,
      includes_raw_provider_responses: false,
      embeds_proof_file_contents: false
    }
  end

  defp lsp_diagnostics_status do
    LemonCore.Doctor.LspDiagnostics.status()
    |> Map.put(:proofs, lsp_proof_status())
  rescue
    error ->
      %{
        status: :unknown,
        default_timeout_ms: 0,
        supported_language_count: 0,
        supported_languages: [],
        executable_summary: %{available_count: 0, missing_count: 0, executables: []},
        server_manager: lsp_server_manager_status(),
        proofs: empty_lsp_proof_status(),
        cleanup: lsp_diagnostics_cleanup(),
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        status: :unknown,
        default_timeout_ms: 0,
        supported_language_count: 0,
        supported_languages: [],
        executable_summary: %{available_count: 0, missing_count: 0, executables: []},
        server_manager: lsp_server_manager_status(),
        proofs: empty_lsp_proof_status(),
        cleanup: lsp_diagnostics_cleanup(),
        error: inspect({kind, reason})
      }
  end

  defp lsp_proof_status do
    status = ProofDiagnostics.status(project_dir: File.cwd!(), limit: @lsp_proof_scan_limit)

    matching_proofs =
      status
      |> get_map(:recent_proofs, [])
      |> Enum.filter(&lsp_proof?/1)

    recent_proofs = Enum.take(matching_proofs, 4)

    matching_checks =
      status
      |> get_map(:latest_checks, [])
      |> Enum.filter(&lsp_check?/1)

    latest_checks = Enum.take(matching_checks, 8)

    %{
      recent_proofs: recent_proofs,
      latest_checks: latest_checks,
      proof_count: length(matching_proofs),
      check_count: length(matching_checks),
      cleanup: proof_cleanup(),
      error: nil
    }
  rescue
    error -> empty_lsp_proof_status(Exception.message(error))
  catch
    kind, reason -> empty_lsp_proof_status(inspect({kind, reason}))
  end

  defp empty_lsp_proof_status(error \\ nil) do
    %{
      recent_proofs: [],
      latest_checks: [],
      proof_count: 0,
      check_count: 0,
      cleanup: proof_cleanup(),
      error: error
    }
  end

  defp lsp_proof?(proof) when is_map(proof) do
    proof_text =
      [
        get_map(proof, :proof_object),
        get_map(proof, :reason_kind),
        safe_text_join(get_map(proof, :proof_scopes, []))
      ]
      |> safe_text_join()
      |> String.downcase()

    String.contains?(proof_text, "lsp")
  end

  defp lsp_proof?(_proof), do: false

  defp lsp_check?(check) when is_map(check) do
    check_text =
      [
        get_map(check, :name),
        get_map(check, :proof_object),
        get_map(check, :reason_kind)
      ]
      |> safe_text_join()
      |> String.downcase()

    String.contains?(check_text, "lsp") or
      String.contains?(check_text, "pyright") or
      String.contains?(check_text, "gopls") or
      String.contains?(check_text, "clangd") or
      String.contains?(check_text, "rust_analyzer") or
      String.contains?(check_text, "typescript_language_server") or
      String.contains?(check_text, "elixir_ls")
  end

  defp lsp_check?(_check), do: false

  defp safe_text_join(values) when is_list(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
  end

  defp safe_text_join(nil), do: ""
  defp safe_text_join(value), do: to_string(value)

  defp lsp_diagnostics_cleanup do
    %{
      includes_raw_paths: false,
      includes_file_contents: false,
      includes_diagnostics_output: false,
      includes_workspace_roots: false,
      includes_server_io: false,
      includes_raw_session_ids: false
    }
  end

  defp lsp_server_manager_status do
    %{
      running: false,
      mode: :unknown,
      registry: %{count: 0, servers: [], cleanup: %{includes_executable_paths: false}},
      active_count: 0,
      active_servers: [],
      recent_sessions: [],
      refreshed_at: nil
    }
  end

  defp kanban_board_summary(board) do
    tasks = KanbanStore.list_tasks(board.id, limit: 8)

    %{
      board_id: board.id,
      status: board.status,
      owner: board.owner,
      workspace_hash: hash_value(board.workspace),
      name_bytes: byte_size(board.name || ""),
      columns: board.columns,
      task_count: length(tasks),
      open_task_count: Enum.count(tasks, &(&1.status != "done")),
      leased_task_count: Enum.count(tasks, &kanban_leased?/1),
      updated_at_ms: board.updated_at_ms,
      tasks: Enum.map(tasks, &kanban_task_summary/1)
    }
  end

  defp kanban_task_summary(task) do
    %{
      task_id: task.id,
      status: task.status,
      priority: task.priority,
      assignee: task.assignee,
      worker_profile: task.worker_profile,
      title_bytes: byte_size(task.title || ""),
      depends_on_count: length(task.depends_on || []),
      comment_count: length(task.comments || []),
      leased?: kanban_leased?(task),
      run_id: task.run_id,
      updated_at_ms: task.updated_at_ms
    }
  end

  defp kanban_leased?(task) when is_map(task) do
    meta = get_map(task, :meta, %{}) || %{}
    is_map(get_map(meta, "kanbanLease") || get_map(meta, :kanbanLease))
  end

  defp kanban_leased?(_), do: false

  defp hash_value(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_value(_), do: nil

  defp provider_status do
    checks =
      LemonCore.Doctor.Checks.Providers.run()
      |> Enum.map(&format_check/1)

    secrets = LemonCore.Secrets.status()

    %{
      checks: checks,
      ok?: Enum.all?(checks, &(&1.status == "pass")),
      readiness: atomize_provider_status(LemonAiRuntime.ProviderStatus.snapshot(%{})),
      live_proofs: provider_live_proofs(),
      secrets: %{
        configured: secrets.configured,
        source: secrets.source,
        keychain_available: secrets.keychain_available,
        env_fallback: secrets.env_fallback,
        secret_count: secrets.count
      }
    }
  rescue
    error ->
      %{
        checks: [],
        ok?: false,
        error: Exception.message(error),
        readiness: atomize_provider_status(nil),
        live_proofs: provider_live_proofs_unavailable(),
        secrets: %{}
      }
  catch
    kind, reason ->
      %{
        checks: [],
        ok?: false,
        error: inspect({kind, reason}),
        readiness: atomize_provider_status(nil),
        live_proofs: provider_live_proofs_unavailable(),
        secrets: %{}
      }
  end

  defp provider_live_proofs do
    status = ProofDiagnostics.status(project_dir: File.cwd!(), limit: 1000)
    proofs = get_map(status, :recent_proofs, [])
    fallback = provider_fallback_proof(proofs)

    %{
      fallback: provider_fallback_summary(fallback),
      proof_scope_counts: get_map(status, :proof_scope_counts, %{}),
      cleanup: %{
        includes_raw_api_keys: false,
        includes_raw_prompts: false,
        includes_provider_answers: false
      }
    }
  rescue
    _ -> provider_live_proofs_unavailable()
  catch
    _, _ -> provider_live_proofs_unavailable()
  end

  defp provider_live_proofs_unavailable do
    %{
      fallback: %{
        status: "unknown",
        proof_status: nil,
        final_provider: nil,
        modified_at: nil,
        next_action: "run scripts/live_provider_fallback_smoke.exs"
      },
      proof_scope_counts: %{},
      cleanup: %{
        includes_raw_api_keys: false,
        includes_raw_prompts: false,
        includes_provider_answers: false
      }
    }
  end

  defp provider_fallback_proof?(proof) do
    "provider_fallback" in List.wrap(get_map(proof, :proof_scopes, [])) or
      present_string?(get_map(proof, :fallback_provider)) or
      present_string?(get_map(proof, :final_provider))
  end

  defp provider_fallback_proof(proofs) do
    proofs
    |> Enum.filter(&provider_fallback_proof?/1)
    |> Enum.sort_by(
      fn proof ->
        {provider_proof_rank(get_map(proof, :status)), get_map(proof, :modified_at) || ""}
      end,
      fn {rank_a, modified_a}, {rank_b, modified_b} ->
        rank_a < rank_b or (rank_a == rank_b and modified_a >= modified_b)
      end
    )
    |> List.first()
  end

  defp provider_fallback_summary(nil) do
    %{
      status: "missing",
      proof_status: nil,
      proof_object: nil,
      primary_provider: nil,
      fallback_provider: nil,
      final_provider: nil,
      modified_at: nil,
      proof_hash: nil,
      next_action: "run scripts/live_provider_fallback_smoke.exs"
    }
  end

  defp provider_fallback_summary(proof) do
    proof_status = get_map(proof, :status)

    %{
      status: provider_proof_status(proof_status),
      proof_status: proof_status,
      proof_object: get_map(proof, :proof_object),
      primary_provider: get_map(proof, :primary_provider),
      fallback_provider: get_map(proof, :fallback_provider),
      final_provider: get_map(proof, :final_provider),
      modified_at: get_map(proof, :modified_at),
      proof_hash: get_map(proof, :proof_hash),
      next_action: provider_proof_next_action(proof_status)
    }
  end

  defp provider_proof_status("completed"), do: "proven"
  defp provider_proof_status("skipped"), do: "skipped"
  defp provider_proof_status("failed"), do: "blocked"
  defp provider_proof_status(_), do: "unknown"

  defp provider_proof_rank("completed"), do: 0
  defp provider_proof_rank("failed"), do: 1
  defp provider_proof_rank("skipped"), do: 2
  defp provider_proof_rank(_), do: 3

  defp provider_proof_next_action("completed"), do: "keep live fallback proof current"

  defp provider_proof_next_action("skipped"),
    do: "enable live credentials and rerun fallback proof"

  defp provider_proof_next_action("failed"), do: "inspect provider diagnostics and rerun proof"
  defp provider_proof_next_action(_), do: "run scripts/live_provider_fallback_smoke.exs"

  defp usage_status, do: UsageDiagnostics.status()

  defp readiness_status do
    ReadinessSummary.status(project_dir: File.cwd!(), limit: 10)
  rescue
    error ->
      %{
        status: "unavailable",
        doctor: %{overall: "unknown", pass: 0, warn: 0, fail: 0, skip: 0},
        channels: %{
          status: "unknown",
          promoted_platforms: ["telegram", "discord"],
          gate_count: 0,
          passed_count: 0,
          blocked_count: 0,
          warning_count: 0,
          skipped_count: 0
        },
        media_provider: %{status: "unknown", message: nil, remediation: nil},
        proofs: %{
          proof_count: 0,
          completed_count: 0,
          failed_count: 0,
          skipped_count: 0,
          invalid_count: 0
        },
        proof_gates: %{},
        proof_gate_summary: %{
          "status" => "unknown",
          "gateCount" => 0,
          "passedCount" => 0,
          "blockedCount" => 0,
          "warningCount" => 0,
          "missingCount" => 0,
          "statuses" => %{}
        },
        unresolved_gates: [],
        cleanup: readiness_cleanup(),
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        status: "unavailable",
        doctor: %{overall: "unknown", pass: 0, warn: 0, fail: 0, skip: 0},
        channels: %{
          status: "unknown",
          promoted_platforms: ["telegram", "discord"],
          gate_count: 0,
          passed_count: 0,
          blocked_count: 0,
          warning_count: 0,
          skipped_count: 0
        },
        media_provider: %{status: "unknown", message: nil, remediation: nil},
        proofs: %{
          proof_count: 0,
          completed_count: 0,
          failed_count: 0,
          skipped_count: 0,
          invalid_count: 0
        },
        proof_gates: %{},
        proof_gate_summary: %{
          "status" => "unknown",
          "gateCount" => 0,
          "passedCount" => 0,
          "blockedCount" => 0,
          "warningCount" => 0,
          "missingCount" => 0,
          "statuses" => %{}
        },
        unresolved_gates: [],
        cleanup: readiness_cleanup(),
        error: inspect({kind, reason})
      }
  end

  defp readiness_cleanup do
    %{
      includes_raw_bot_tokens: false,
      includes_secret_names: false,
      includes_chat_ids: false,
      includes_channel_ids: false,
      includes_message_bodies: false,
      includes_raw_proof_paths: false,
      includes_raw_proof_details: false,
      includes_raw_prompts: false,
      includes_raw_provider_responses: false,
      includes_secret_values: false
    }
  end

  defp config_status do
    config = LemonCore.Config.load()

    %{
      defaults: format_default_config(config),
      providers: provider_config_entries(config.providers || [])
    }
  rescue
    error -> %{defaults: %{}, providers: [], error: Exception.message(error)}
  catch
    kind, reason -> %{defaults: %{}, providers: [], error: inspect({kind, reason})}
  end

  defp format_default_config(config) do
    default_profile = Map.get(config.agents || %{}, "default", %{})

    %{
      provider: get_map(config.agent, :default_provider),
      model: get_map(config.agent, :default_model),
      thinking_level: format_activity_value(get_map(config.agent, :default_thinking_level)),
      engine: get_map(default_profile, :default_engine)
    }
  end

  defp provider_config_entries(providers) when is_map(providers) do
    configured_ids = Map.keys(providers) |> Enum.map(&to_string/1)

    (known_provider_summaries() ++ Enum.map(configured_ids, &%{id: &1, display_name: &1}))
    |> Enum.reduce(%{}, fn provider, acc -> Map.put(acc, provider.id, provider) end)
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn provider ->
      config = Map.get(providers, provider.id, %{}) || %{}

      %{
        id: provider.id,
        display_name: provider.display_name || provider.id,
        configured?: map_size(config) > 0,
        auth_source: provider_field(config, :auth_source),
        api_key_secret: provider_field(config, :api_key_secret),
        oauth_secret: provider_field(config, :oauth_secret),
        base_url: provider_field(config, :base_url),
        has_direct_api_key?: provider_field(config, :api_key) not in [nil, ""]
      }
    end)
  end

  defp provider_config_entries(_providers), do: []

  defp atomize_provider_status(status) when is_map(status) do
    %{
      providers:
        status
        |> Map.get("providers", [])
        |> Enum.map(&atomize_provider_entry/1),
      count: Map.get(status, "count", 0),
      ready_count: Map.get(status, "readyCount", 0),
      default_provider: Map.get(status, "defaultProvider"),
      default_model: Map.get(status, "defaultModel"),
      routing: atomize_provider_routing(Map.get(status, "routing", %{})),
      cleanup: atomize_cleanup(Map.get(status, "cleanup", %{}))
    }
  end

  defp atomize_provider_status(_),
    do: %{
      providers: [],
      count: 0,
      ready_count: 0,
      routing: atomize_provider_routing(nil),
      cleanup: atomize_cleanup(nil)
    }

  defp atomize_provider_entry(entry) when is_map(entry) do
    config = Map.get(entry, "config", %{})
    ambient = Map.get(entry, "ambient", %{})

    %{
      provider: Map.get(entry, "provider"),
      config_name: Map.get(entry, "configName"),
      known?: Map.get(entry, "known") == true,
      configured?: Map.get(entry, "configured") == true,
      credential_ready?: Map.get(entry, "credentialReady") == true,
      api_key_configured?: Map.get(config, "apiKeyConfigured") == true,
      api_key_secret_configured?: Map.get(config, "apiKeySecretConfigured") == true,
      oauth_secret_configured?: Map.get(config, "oauthSecretConfigured") == true,
      base_url_configured?: Map.get(config, "baseUrlConfigured") == true,
      auth_source: Map.get(config, "authSource"),
      env_configured?: Map.get(ambient, "envConfigured") == true
    }
  end

  defp atomize_provider_entry(_), do: %{}

  defp atomize_provider_routing(routing) when is_map(routing) do
    %{
      enabled?: Map.get(routing, "enabled") == true,
      requested_provider: Map.get(routing, "requestedProvider"),
      requested_model: Map.get(routing, "requestedModel"),
      selected_provider: Map.get(routing, "selectedProvider"),
      selected_model: Map.get(routing, "selectedModel"),
      decision: Map.get(routing, "decision"),
      fallback_providers: Map.get(routing, "fallbackProviders", []),
      candidate_providers:
        routing
        |> Map.get("candidateProviders", [])
        |> Enum.map(&atomize_provider_routing_candidate/1),
      credential_pool:
        routing
        |> Map.get("credentialPool", %{})
        |> atomize_provider_credential_pool(),
      cleanup: atomize_cleanup(Map.get(routing, "cleanup", %{}))
    }
  end

  defp atomize_provider_routing(_),
    do: %{
      enabled?: false,
      requested_provider: nil,
      requested_model: nil,
      selected_provider: nil,
      selected_model: nil,
      decision: nil,
      fallback_providers: [],
      candidate_providers: [],
      credential_pool: %{providers: []},
      cleanup: atomize_cleanup(nil)
    }

  defp atomize_provider_routing_candidate(candidate) when is_map(candidate) do
    %{
      provider: Map.get(candidate, "provider"),
      role: Map.get(candidate, "role"),
      known?: Map.get(candidate, "known") == true,
      configured?: Map.get(candidate, "configured") == true,
      credential_ready?: Map.get(candidate, "credentialReady") == true,
      selected?: Map.get(candidate, "selected") == true
    }
  end

  defp atomize_provider_routing_candidate(_), do: %{}

  defp atomize_provider_credential_pool(pool) when is_map(pool) do
    %{
      providers:
        pool
        |> Map.get("providers", [])
        |> Enum.map(fn provider ->
          %{
            provider: Map.get(provider, "provider"),
            known?: Map.get(provider, "known") == true,
            credential_ready?: Map.get(provider, "credentialReady") == true,
            reference_count: Map.get(provider, "referenceCount", 0)
          }
        end)
    }
  end

  defp atomize_provider_credential_pool(_), do: %{providers: []}

  defp atomize_cleanup(cleanup) when is_map(cleanup) do
    %{
      includes_raw_api_keys: Map.get(cleanup, "includesRawApiKeys") == true,
      includes_secret_names: Map.get(cleanup, "includesSecretNames") == true,
      includes_raw_base_urls: Map.get(cleanup, "includesRawBaseUrls") == true,
      includes_env_var_names: Map.get(cleanup, "includesEnvVarNames") == true
    }
  end

  defp atomize_cleanup(_), do: %{}

  defp known_provider_summaries do
    LemonCore.Onboarding.Providers.list()
    |> Enum.map(fn provider ->
      %{id: provider.id, display_name: provider.display_name}
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp provider_field(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp active_sessions do
    LemonCore.RouterBridge.list_active_sessions()
    |> List.wrap()
    |> Enum.map(&format_active_session/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp recent_runs do
    Introspection.list(event_type: :run_completed, limit: @recent_run_limit)
    |> Enum.map(&format_run_event/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp run_events(run_id) do
    Introspection.list(run_id: run_id, limit: @run_detail_event_limit)
    |> Enum.map(&format_timeline_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&(&1.ts_ms || 0), :asc)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp child_runs(run_id) do
    Introspection.list(limit: @child_lookup_limit)
    |> Enum.filter(&(get_map(&1, :parent_run_id) == run_id))
    |> Enum.reduce(%{}, fn event, acc ->
      child_run_id = get_map(event, :run_id)

      if is_binary(child_run_id) and child_run_id != "" do
        Map.update(acc, child_run_id, child_run_summary(child_run_id, event), fn existing ->
          merge_child_run(existing, event)
        end)
      else
        acc
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&(&1.started_at_ms || 0), :asc)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp run_graph(root_run_id) do
    events =
      Introspection.list(limit: @child_lookup_limit)
      |> Enum.map(&format_timeline_event/1)
      |> Enum.reject(&is_nil/1)

    events_by_run =
      events
      |> Enum.filter(&(is_binary(&1.run_id) and &1.run_id != ""))
      |> Enum.group_by(& &1.run_id)

    summaries =
      Map.new(events_by_run, fn {run_id, run_events} ->
        sorted = Enum.sort_by(run_events, &(&1.ts_ms || 0), :asc)
        {run_id, run_summary(run_id, sorted)}
      end)

    children_by_parent =
      events
      |> Enum.reduce(%{}, fn event, acc ->
        child_run_id = event.run_id
        parent_run_id = event.parent_run_id

        if is_binary(child_run_id) and child_run_id != "" and is_binary(parent_run_id) and
             parent_run_id != "" do
          Map.update(
            acc,
            parent_run_id,
            MapSet.new([child_run_id]),
            &MapSet.put(&1, child_run_id)
          )
        else
          acc
        end
      end)
      |> Map.new(fn {parent_run_id, child_ids} ->
        {parent_run_id, child_ids |> MapSet.to_list() |> Enum.sort()}
      end)

    build_run_tree(root_run_id, summaries, children_by_parent, MapSet.new())
  rescue
    _ -> %{run_id: root_run_id, status: "unknown", children: []}
  catch
    _, _ -> %{run_id: root_run_id, status: "unknown", children: []}
  end

  defp pending_approvals do
    now_ms = LemonCore.Clock.now_ms()

    ExecApprovalStore.list_pending()
    |> Enum.map(fn {_id, pending} -> pending end)
    |> Enum.filter(&approval_active?(&1, now_ms))
    |> Enum.map(&format_pending_approval/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp format_active_session(%{session_key: session_key, run_id: run_id}) do
    %{session_key: session_key, run_id: run_id}
  end

  defp format_active_session(%{"sessionKey" => session_key, "runId" => run_id}) do
    %{session_key: session_key, run_id: run_id}
  end

  defp format_active_session({session_key, _pid, meta}) when is_map(meta) do
    %{session_key: session_key, run_id: meta[:run_id] || meta["run_id"]}
  end

  defp format_active_session(_), do: nil

  defp format_run_event(event) when is_map(event) do
    payload = event[:payload] || event["payload"] || %{}
    ok = payload[:ok] || payload["ok"]
    error = payload[:error] || payload["error"]

    %{
      run_id: event[:run_id] || event["run_id"],
      session_key: event[:session_key] || event["session_key"],
      agent_id: event[:agent_id] || event["agent_id"],
      engine: event[:engine] || event["engine"],
      completed_at_ms: event[:ts_ms] || event["ts_ms"],
      ok?: ok == true,
      error: error
    }
  end

  defp format_run_event(_), do: nil

  defp format_check(%{name: name, status: status, message: message, remediation: remediation}) do
    %{
      name: name,
      status: normalize_event_type(status),
      message: message,
      remediation: remediation
    }
  end

  defp format_check(other) do
    %{name: "unknown", status: "warn", message: inspect(other), remediation: nil}
  end

  defp format_timeline_event(event) when is_map(event) do
    payload = get_map(event, :payload, %{})
    event_type = normalize_event_type(get_map(event, :event_type))

    %{
      event_id: get_map(event, :event_id),
      event_type: event_type,
      ts_ms: get_map(event, :ts_ms),
      run_id: get_map(event, :run_id),
      session_key: get_map(event, :session_key),
      agent_id: get_map(event, :agent_id),
      parent_run_id: get_map(event, :parent_run_id),
      engine: get_map(event, :engine),
      provenance: normalize_event_type(get_map(event, :provenance)),
      tool: payload_tool(payload),
      ok?: payload_ok?(payload),
      error: payload_error(payload),
      preview: payload_preview(payload)
    }
  end

  defp format_timeline_event(_), do: nil

  defp format_pending_approval(pending) when is_map(pending) do
    %{
      id: pending[:id] || pending["id"],
      run_id: pending[:run_id] || pending["run_id"],
      session_key: pending[:session_key] || pending["session_key"],
      agent_id: pending[:agent_id] || pending["agent_id"],
      tool: pending[:tool] || pending["tool"],
      action: pending[:action] || pending["action"] || %{},
      rationale: pending[:rationale] || pending["rationale"],
      requested_at_ms: pending[:requested_at_ms] || pending["requested_at_ms"],
      expires_at_ms: approval_expires_at(pending)
    }
  end

  defp format_cron_job(id, job) when is_map(job) do
    %{
      id: get_map(job, :id, id),
      name: get_map(job, :name, "unnamed"),
      schedule: get_map(job, :schedule),
      enabled?: get_map(job, :enabled, true) == true,
      agent_id: get_map(job, :agent_id),
      session_key: get_map(job, :session_key),
      prompt: get_map(job, :prompt),
      timezone: get_map(job, :timezone, "UTC"),
      max_retries: get_map(job, :max_retries, 0),
      retry_backoff_ms: get_map(job, :retry_backoff_ms, 30_000),
      last_run_at_ms: get_map(job, :last_run_at_ms),
      next_run_at_ms: get_map(job, :next_run_at_ms),
      created_at_ms: get_map(job, :created_at_ms),
      updated_at_ms: get_map(job, :updated_at_ms),
      recent_runs: [],
      latest_run_status: nil,
      latest_run_triggered_by: nil,
      latest_run_started_at_ms: nil,
      latest_run_retry_attempt: 0
    }
  end

  defp format_cron_job(id, job) do
    %{
      id: id,
      name: inspect(job),
      schedule: nil,
      enabled?: false,
      agent_id: nil,
      session_key: nil,
      prompt: nil,
      timezone: nil,
      max_retries: 0,
      retry_backoff_ms: 30_000,
      last_run_at_ms: nil,
      next_run_at_ms: nil,
      created_at_ms: nil,
      updated_at_ms: nil,
      recent_runs: [],
      latest_run_status: nil,
      latest_run_triggered_by: nil,
      latest_run_started_at_ms: nil,
      latest_run_retry_attempt: 0
    }
  end

  defp format_cron_run(id, run) when is_map(run) do
    meta = get_map(run, :meta, %{}) || %{}

    %{
      id: get_map(run, :id, id),
      job_id: get_map(run, :job_id),
      run_id: get_map(run, :run_id),
      status: normalize_event_type(get_map(run, :status)) || "unknown",
      triggered_by: normalize_event_type(get_map(run, :triggered_by)),
      started_at_ms: get_map(run, :started_at_ms),
      completed_at_ms: get_map(run, :completed_at_ms),
      duration_ms: get_map(run, :duration_ms),
      retry_attempt: get_map(meta, :retry_attempt, 0) || 0,
      error: get_map(run, :error)
    }
  end

  defp format_cron_run(id, run) do
    %{
      id: id,
      job_id: nil,
      run_id: nil,
      status: inspect(run),
      triggered_by: nil,
      started_at_ms: nil,
      completed_at_ms: nil,
      duration_ms: nil,
      retry_attempt: 0,
      error: nil
    }
  end

  defp format_cron_audit_event(id, event) when is_map(event) do
    %{
      id: get_map(event, :id, id),
      action: normalize_event_type(get_map(event, :action)) || "unknown",
      ts_ms: get_map(event, :ts_ms),
      job_id: get_map(event, :job_id),
      run_id: get_map(event, :run_id),
      router_run_id: get_map(event, :router_run_id),
      source: normalize_event_type(get_map(event, :source)),
      status: normalize_event_type(get_map(event, :status)),
      triggered_by: normalize_event_type(get_map(event, :triggered_by)),
      reason: get_map(event, :reason),
      changed_fields: normalize_string_list(get_map(event, :changed_fields))
    }
  end

  defp format_cron_audit_event(id, event) do
    %{
      id: id,
      action: inspect(event),
      ts_ms: nil,
      job_id: nil,
      run_id: nil,
      router_run_id: nil,
      source: nil,
      status: nil,
      triggered_by: nil,
      reason: nil,
      changed_fields: []
    }
  end

  defp format_channel_binding(binding, index) when is_map(binding) do
    %{
      index: index,
      transport: get_map(binding, :transport),
      chat_id: get_map(binding, :chat_id),
      topic_id: get_map(binding, :topic_id),
      agent_id: get_map(binding, :agent_id),
      default_engine: get_map(binding, :default_engine),
      project: get_map(binding, :project)
    }
  end

  defp format_channel_binding(binding, index) do
    %{index: index, transport: "unknown", chat_id: inspect(binding), topic_id: nil, agent_id: nil}
  end

  defp approval_expires_at(pending) when is_map(pending) do
    cond do
      Map.has_key?(pending, :expires_at_ms) -> pending[:expires_at_ms]
      Map.has_key?(pending, "expires_at_ms") -> pending["expires_at_ms"]
      true -> 0
    end
  end

  defp approval_expires_at(_), do: 0

  defp approval_active?(pending, now_ms) do
    case approval_expires_at(pending) do
      nil -> true
      expires_at_ms when is_integer(expires_at_ms) -> expires_at_ms > now_ms
      _ -> false
    end
  end

  defp pending_approvals_for_run(run_id) do
    pending_approvals()
    |> Enum.filter(&(&1.run_id == run_id))
  end

  defp observed_activity do
    events =
      Introspection.list(limit: @activity_event_limit)
      |> Enum.map(&format_timeline_event/1)
      |> Enum.reject(&is_nil/1)

    [:cron, :skills, :channels, :memory, :logs]
    |> Enum.map(fn category ->
      category_events = Enum.filter(events, &(activity_category(&1) == category))

      %{
        category: Atom.to_string(category),
        count: length(category_events),
        recent:
          category_events
          |> Enum.sort_by(&(&1.ts_ms || 0), :desc)
          |> Enum.take(@activity_recent_limit)
      }
    end)
    |> then(&%{total_events: length(events), categories: &1})
  rescue
    _ -> %{total_events: 0, categories: []}
  catch
    _, _ -> %{total_events: 0, categories: []}
  end

  defp cron_status do
    jobs =
      :cron_jobs
      |> LemonCore.Store.list()
      |> Enum.map(fn {id, job} -> format_cron_job(id, job) end)
      |> Enum.sort_by(&(&1.updated_at_ms || &1.created_at_ms || 0), :desc)

    runs =
      :cron_runs
      |> LemonCore.Store.list()
      |> Enum.map(fn {id, run} -> format_cron_run(id, run) end)
      |> Enum.sort_by(&(&1.started_at_ms || &1.completed_at_ms || 0), :desc)

    audit_events =
      :cron_audit_events
      |> LemonCore.Store.list()
      |> Enum.map(fn {id, event} -> format_cron_audit_event(id, event) end)
      |> Enum.sort_by(&(&1.ts_ms || 0), :desc)

    jobs = attach_cron_run_summaries(jobs, runs)

    %{
      jobs: jobs,
      recent_runs: Enum.take(runs, 5),
      recent_audit_events: Enum.take(audit_events, 8),
      enabled_count: Enum.count(jobs, & &1.enabled?),
      active_run_count: Enum.count(runs, &cron_run_active?/1),
      failed_run_count: Enum.count(runs, &(&1.status in ["failed", "timeout"])),
      retry_run_count: Enum.count(runs, &(&1.triggered_by == "retry" or &1.retry_attempt > 0)),
      suppressed_run_count: Enum.count(audit_events, &(&1.action == "scheduled_run_suppressed")),
      stale_recovery_count: Enum.count(audit_events, &(&1.action == "stale_run_recovered")),
      retry_scheduled_count: Enum.count(audit_events, &(&1.action == "retry_scheduled")),
      next_run_at_ms: min_present(Enum.map(jobs, & &1.next_run_at_ms)),
      last_run_at_ms: max_present(Enum.map(runs, &(&1.started_at_ms || &1.completed_at_ms)))
    }
  rescue
    _ ->
      empty_cron_status()
  catch
    _, _ ->
      empty_cron_status()
  end

  defp empty_cron_status do
    %{
      jobs: [],
      recent_runs: [],
      recent_audit_events: [],
      enabled_count: 0,
      active_run_count: 0,
      failed_run_count: 0,
      retry_run_count: 0,
      suppressed_run_count: 0,
      stale_recovery_count: 0,
      retry_scheduled_count: 0,
      next_run_at_ms: nil,
      last_run_at_ms: nil
    }
  end

  defp cron_run_active?(%{status: status}) when status in ["pending", "running"], do: true
  defp cron_run_active?(_), do: false

  defp min_present(values) do
    values
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp max_present(values) do
    values
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp attach_cron_run_summaries(jobs, runs) do
    runs_by_job = Enum.group_by(runs, & &1.job_id)

    Enum.map(jobs, fn job ->
      recent_runs =
        runs_by_job
        |> Map.get(job.id, [])
        |> Enum.take(3)

      latest_run = List.first(recent_runs)

      job
      |> Map.put(:recent_runs, recent_runs)
      |> Map.put(:latest_run_status, get_map(latest_run, :status))
      |> Map.put(:latest_run_triggered_by, get_map(latest_run, :triggered_by))
      |> Map.put(:latest_run_started_at_ms, get_map(latest_run, :started_at_ms))
      |> Map.put(:latest_run_retry_attempt, get_map(latest_run, :retry_attempt, 0))
    end)
  end

  defp skills_status do
    checks =
      LemonCore.Doctor.Checks.Skills.run()
      |> Enum.map(&format_check/1)

    skills = skill_entries()

    %{
      checks: checks,
      ok?: Enum.all?(checks, &(&1.status in ["pass", "skip"])),
      entries: skills,
      installed_count: length(skills),
      enabled_count: Enum.count(skills, & &1.enabled?),
      blocked_count: Enum.count(skills, &(&1.audit_status == "block")),
      missing_count: Enum.count(skills, &(&1.missing != []))
    }
  rescue
    error ->
      %{checks: [], ok?: false, entries: [], error: Exception.message(error)}
  catch
    kind, reason -> %{checks: [], ok?: false, entries: [], error: inspect({kind, reason})}
  end

  defp extensions_status do
    diagnostics = ExtensionDiagnostics.status(project_dir: File.cwd!())
    directories = Map.get(diagnostics, :directories, [])

    %{
      status: extension_status(diagnostics),
      directories: directories,
      directory_count: Map.get(diagnostics, :directory_count, 0),
      existing_directory_count: Map.get(diagnostics, :existing_directory_count, 0),
      extension_file_count: Map.get(diagnostics, :extension_file_count, 0),
      manifest_count: Map.get(diagnostics, :manifest_count, 0),
      valid_manifest_count: Map.get(diagnostics, :valid_manifest_count, 0),
      invalid_manifest_count: Map.get(diagnostics, :invalid_manifest_count, 0),
      configured_extension_path_count: Map.get(diagnostics, :configured_extension_path_count, 0),
      nested_lib_file_count:
        Enum.reduce(directories, 0, &(Map.get(&1, :nested_lib_file_count, 0) + &2)),
      capability_counts: Map.get(diagnostics, :capability_counts, %{}),
      provider_type_counts: Map.get(diagnostics, :provider_type_counts, %{}),
      host_type_counts: Map.get(diagnostics, :host_type_counts, %{}),
      distribution_source_counts: Map.get(diagnostics, :distribution_source_counts, %{}),
      audit_status_counts: Map.get(diagnostics, :audit_status_counts, %{}),
      execution: extension_execution(Map.get(diagnostics, :execution, %{})),
      execution_telemetry:
        extension_execution_telemetry(Map.get(diagnostics, :execution_telemetry, %{})),
      wasm_telemetry: extension_wasm_telemetry(Map.get(diagnostics, :wasm_telemetry, %{})),
      wasm_policy: extension_wasm_policy(Map.get(diagnostics, :wasm_policy, %{})),
      registry_audit: extension_registry_audit(Map.get(diagnostics, :registry_audit, %{})),
      wasm_lifecycle: extension_wasm_lifecycle(Map.get(diagnostics, :wasm_lifecycle, %{})),
      host_runtime: extension_host_runtime(Map.get(diagnostics, :host_runtime, %{})),
      cleanup: extension_cleanup(Map.get(diagnostics, :cleanup, %{}))
    }
  rescue
    error ->
      %{
        status: "error",
        directories: [],
        directory_count: 0,
        existing_directory_count: 0,
        extension_file_count: 0,
        manifest_count: 0,
        valid_manifest_count: 0,
        invalid_manifest_count: 0,
        configured_extension_path_count: 0,
        nested_lib_file_count: 0,
        capability_counts: %{},
        provider_type_counts: %{},
        host_type_counts: %{},
        distribution_source_counts: %{},
        audit_status_counts: %{},
        execution: extension_execution(%{}),
        execution_telemetry: extension_execution_telemetry(%{}),
        wasm_telemetry: extension_wasm_telemetry(%{}),
        wasm_policy: extension_wasm_policy(%{}),
        registry_audit: extension_registry_audit(%{}),
        wasm_lifecycle: extension_wasm_lifecycle(%{}),
        host_runtime: extension_host_runtime(%{}),
        cleanup: extension_cleanup(%{}),
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        status: "error",
        directories: [],
        directory_count: 0,
        existing_directory_count: 0,
        extension_file_count: 0,
        manifest_count: 0,
        valid_manifest_count: 0,
        invalid_manifest_count: 0,
        configured_extension_path_count: 0,
        nested_lib_file_count: 0,
        capability_counts: %{},
        provider_type_counts: %{},
        host_type_counts: %{},
        distribution_source_counts: %{},
        audit_status_counts: %{},
        execution: extension_execution(%{}),
        execution_telemetry: extension_execution_telemetry(%{}),
        wasm_telemetry: extension_wasm_telemetry(%{}),
        wasm_policy: extension_wasm_policy(%{}),
        registry_audit: extension_registry_audit(%{}),
        wasm_lifecycle: extension_wasm_lifecycle(%{}),
        host_runtime: extension_host_runtime(%{}),
        cleanup: extension_cleanup(%{}),
        error: inspect({kind, reason})
      }
  end

  defp extension_status(%{extension_file_count: count}) when count > 0, do: "ok"
  defp extension_status(%{configured_extension_path_count: count}) when count > 0, do: "empty"
  defp extension_status(_), do: "empty"

  defp extension_cleanup(cleanup) when is_map(cleanup) do
    %{
      includes_raw_source_paths: Map.get(cleanup, :includes_raw_source_paths, false),
      includes_file_contents: Map.get(cleanup, :includes_file_contents, false),
      includes_load_error_messages: Map.get(cleanup, :includes_load_error_messages, false),
      includes_manifest_contents: Map.get(cleanup, :includes_manifest_contents, false),
      includes_distribution_urls: Map.get(cleanup, :includes_distribution_urls, false),
      loads_extension_code: Map.get(cleanup, :loads_extension_code, false)
    }
  end

  defp extension_cleanup(_), do: extension_cleanup(%{})

  defp extension_execution(execution) when is_map(execution) do
    %{
      enabled: Map.get(execution, :enabled, true),
      configured_extension_path_count: Map.get(execution, :configured_extension_path_count, 0),
      default_directory_count: Map.get(execution, :default_directory_count, 0),
      auto_load_default_paths: Map.get(execution, :auto_load_default_paths, false),
      default_directories_diagnostics_only:
        Map.get(execution, :default_directories_diagnostics_only, true),
      diagnostics_loads_extension_code:
        Map.get(execution, :diagnostics_loads_extension_code, false)
    }
  end

  defp extension_execution(_), do: extension_execution(%{})

  defp extension_execution_telemetry(telemetry) when is_map(telemetry) do
    %{
      proof_present: Map.get(telemetry, :proof_present, false),
      proof_hash: Map.get(telemetry, :proof_hash),
      proof_status: Map.get(telemetry, :proof_status, "missing"),
      generated_at: Map.get(telemetry, :generated_at),
      completed_count: Map.get(telemetry, :completed_count, 0),
      failed_count: Map.get(telemetry, :failed_count, 0),
      telemetry_check_status: Map.get(telemetry, :telemetry_check_status, "missing"),
      disabled_check_status: Map.get(telemetry, :disabled_check_status, "missing"),
      env_disabled_check_status: Map.get(telemetry, :env_disabled_check_status, "missing"),
      emits_redacted_start_stop_exception:
        Map.get(telemetry, :emits_redacted_start_stop_exception, false),
      blocks_disabled_explicit_paths: Map.get(telemetry, :blocks_disabled_explicit_paths, false),
      redaction: extension_execution_telemetry_redaction(Map.get(telemetry, :redaction, %{}))
    }
  end

  defp extension_execution_telemetry(_), do: extension_execution_telemetry(%{})

  defp extension_execution_telemetry_redaction(redaction) when is_map(redaction) do
    %{
      contains_raw_paths: Map.get(redaction, :contains_raw_paths, false),
      contains_file_contents: Map.get(redaction, :contains_file_contents, false),
      contains_load_error_messages: Map.get(redaction, :contains_load_error_messages, false),
      contains_tool_result_payload: Map.get(redaction, :contains_tool_result_payload, false)
    }
  end

  defp extension_execution_telemetry_redaction(_),
    do: extension_execution_telemetry_redaction(%{})

  defp extension_wasm_telemetry(telemetry) when is_map(telemetry) do
    %{
      proof_present: Map.get(telemetry, :proof_present, false),
      proof_hash: Map.get(telemetry, :proof_hash),
      proof_status: Map.get(telemetry, :proof_status, "missing"),
      generated_at: Map.get(telemetry, :generated_at),
      completed_count: Map.get(telemetry, :completed_count, 0),
      failed_count: Map.get(telemetry, :failed_count, 0),
      success_check_status: Map.get(telemetry, :success_check_status, "missing"),
      error_check_status: Map.get(telemetry, :error_check_status, "missing"),
      exception_check_status: Map.get(telemetry, :exception_check_status, "missing"),
      redaction_check_status: Map.get(telemetry, :redaction_check_status, "missing"),
      emits_redacted_start_stop_exception:
        Map.get(telemetry, :emits_redacted_start_stop_exception, false),
      host_boundary: extension_wasm_host_boundary(Map.get(telemetry, :host_boundary, %{})),
      redaction: extension_wasm_telemetry_redaction(Map.get(telemetry, :redaction, %{}))
    }
  end

  defp extension_wasm_telemetry(_), do: extension_wasm_telemetry(%{})

  defp extension_wasm_host_boundary(boundary) when is_map(boundary) do
    %{
      host: Map.get(boundary, :host),
      emits_start_stop_exception: Map.get(boundary, :emits_start_stop_exception, false),
      uses_hashed_wasm_paths: Map.get(boundary, :uses_hashed_wasm_paths, false),
      tool_count: Map.get(boundary, :tool_count, 0)
    }
  end

  defp extension_wasm_host_boundary(_), do: extension_wasm_host_boundary(%{})

  defp extension_wasm_telemetry_redaction(redaction) when is_map(redaction) do
    %{
      contains_raw_paths: Map.get(redaction, :contains_raw_paths, false),
      contains_raw_params: Map.get(redaction, :contains_raw_params, false),
      contains_raw_tool_call_ids: Map.get(redaction, :contains_raw_tool_call_ids, false),
      contains_sidecar_error_text: Map.get(redaction, :contains_sidecar_error_text, false),
      contains_tool_result_payload: Map.get(redaction, :contains_tool_result_payload, false)
    }
  end

  defp extension_wasm_telemetry_redaction(_), do: extension_wasm_telemetry_redaction(%{})

  defp extension_wasm_policy(policy) when is_map(policy) do
    %{
      proof_present: Map.get(policy, :proof_present, false),
      proof_hash: Map.get(policy, :proof_hash),
      proof_status: Map.get(policy, :proof_status, "missing"),
      generated_at: Map.get(policy, :generated_at),
      completed_count: Map.get(policy, :completed_count, 0),
      failed_count: Map.get(policy, :failed_count, 0),
      http_check_status: Map.get(policy, :http_check_status, "missing"),
      tool_invoke_check_status: Map.get(policy, :tool_invoke_check_status, "missing"),
      exec_check_status: Map.get(policy, :exec_check_status, "missing"),
      safe_check_status: Map.get(policy, :safe_check_status, "missing"),
      override_check_status: Map.get(policy, :override_check_status, "missing"),
      capability_approval_defaults: Map.get(policy, :capability_approval_defaults, false),
      explicit_override_supported: Map.get(policy, :explicit_override_supported, false),
      policy_boundary: extension_wasm_policy_boundary(Map.get(policy, :policy_boundary, %{})),
      redaction: extension_wasm_policy_redaction(Map.get(policy, :redaction, %{}))
    }
  end

  defp extension_wasm_policy(_), do: extension_wasm_policy(%{})

  defp extension_wasm_policy_boundary(boundary) when is_map(boundary) do
    %{
      http_requires_approval_by_default:
        Map.get(boundary, :http_requires_approval_by_default, false),
      tool_invoke_requires_approval_by_default:
        Map.get(boundary, :tool_invoke_requires_approval_by_default, false),
      exec_requires_approval_by_default:
        Map.get(boundary, :exec_requires_approval_by_default, false),
      safe_capabilities_execute_without_approval:
        Map.get(boundary, :safe_capabilities_execute_without_approval, false),
      explicit_never_can_override_default:
        Map.get(boundary, :explicit_never_can_override_default, false)
    }
  end

  defp extension_wasm_policy_boundary(_), do: extension_wasm_policy_boundary(%{})

  defp extension_wasm_policy_redaction(redaction) when is_map(redaction) do
    %{
      contains_raw_paths: Map.get(redaction, :contains_raw_paths, false),
      contains_raw_params: Map.get(redaction, :contains_raw_params, false),
      contains_raw_tool_call_ids: Map.get(redaction, :contains_raw_tool_call_ids, false)
    }
  end

  defp extension_wasm_policy_redaction(_), do: extension_wasm_policy_redaction(%{})

  defp extension_registry_audit(audit) when is_map(audit) do
    %{
      proof_present: Map.get(audit, :proof_present, false),
      proof_hash: Map.get(audit, :proof_hash),
      proof_status: Map.get(audit, :proof_status, "missing"),
      generated_at: Map.get(audit, :generated_at),
      completed_count: Map.get(audit, :completed_count, 0),
      failed_count: Map.get(audit, :failed_count, 0),
      validate_check_status: Map.get(audit, :validate_check_status, "missing"),
      block_check_status: Map.get(audit, :block_check_status, "missing"),
      update_check_status: Map.get(audit, :update_check_status, "missing"),
      no_code_check_status: Map.get(audit, :no_code_check_status, "missing"),
      redaction_check_status: Map.get(audit, :redaction_check_status, "missing"),
      registry_workflow_supported: Map.get(audit, :registry_workflow_supported, false),
      registry_boundary: extension_registry_boundary(Map.get(audit, :registry_boundary, %{})),
      redaction: extension_registry_redaction(Map.get(audit, :redaction, %{}))
    }
  end

  defp extension_registry_audit(_), do: extension_registry_audit(%{})

  defp extension_registry_boundary(boundary) when is_map(boundary) do
    %{
      validates_manifest_metadata: Map.get(boundary, :validates_manifest_metadata, false),
      blocks_unaudited_installs: Map.get(boundary, :blocks_unaudited_installs, false),
      detects_update_candidates: Map.get(boundary, :detects_update_candidates, false),
      loads_extension_code: Map.get(boundary, :loads_extension_code, false),
      installable_count: Map.get(boundary, :installable_count, 0),
      blocked_count: Map.get(boundary, :blocked_count, 0),
      update_candidate_count: Map.get(boundary, :update_candidate_count, 0),
      blocked_update_count: Map.get(boundary, :blocked_update_count, 0)
    }
  end

  defp extension_registry_boundary(_), do: extension_registry_boundary(%{})

  defp extension_registry_redaction(redaction) when is_map(redaction) do
    %{
      contains_raw_registry_paths: Map.get(redaction, :contains_raw_registry_paths, false),
      contains_distribution_urls: Map.get(redaction, :contains_distribution_urls, false),
      contains_package_names: Map.get(redaction, :contains_package_names, false),
      contains_manifest_contents: Map.get(redaction, :contains_manifest_contents, false)
    }
  end

  defp extension_registry_redaction(_), do: extension_registry_redaction(%{})

  defp extension_wasm_lifecycle(lifecycle) when is_map(lifecycle) do
    %{
      proof_present: Map.get(lifecycle, :proof_present, false),
      proof_hash: Map.get(lifecycle, :proof_hash),
      proof_status: Map.get(lifecycle, :proof_status, "missing"),
      generated_at: Map.get(lifecycle, :generated_at),
      completed_count: Map.get(lifecycle, :completed_count, 0),
      failed_count: Map.get(lifecycle, :failed_count, 0),
      discover_check_status: Map.get(lifecycle, :discover_check_status, "missing"),
      invoke_check_status: Map.get(lifecycle, :invoke_check_status, "missing"),
      status_check_status: Map.get(lifecycle, :status_check_status, "missing"),
      stop_check_status: Map.get(lifecycle, :stop_check_status, "missing"),
      redaction_check_status: Map.get(lifecycle, :redaction_check_status, "missing"),
      lifecycle_supported: Map.get(lifecycle, :lifecycle_supported, false),
      lifecycle_boundary:
        extension_wasm_lifecycle_boundary(Map.get(lifecycle, :lifecycle_boundary, %{})),
      redaction: extension_wasm_lifecycle_redaction(Map.get(lifecycle, :redaction, %{}))
    }
  end

  defp extension_wasm_lifecycle(_), do: extension_wasm_lifecycle(%{})

  defp extension_wasm_lifecycle_boundary(boundary) when is_map(boundary) do
    %{
      host: Map.get(boundary, :host),
      discover_emits_redacted_start_stop:
        Map.get(boundary, :discover_emits_redacted_start_stop, false),
      invoke_emits_redacted_start_stop:
        Map.get(boundary, :invoke_emits_redacted_start_stop, false),
      status_tracks_running_sidecar: Map.get(boundary, :status_tracks_running_sidecar, false),
      stop_terminates_sidecar: Map.get(boundary, :stop_terminates_sidecar, false),
      tool_count: Map.get(boundary, :tool_count, 0)
    }
  end

  defp extension_wasm_lifecycle_boundary(_), do: extension_wasm_lifecycle_boundary(%{})

  defp extension_wasm_lifecycle_redaction(redaction) when is_map(redaction) do
    %{
      contains_raw_cwd: Map.get(redaction, :contains_raw_cwd, false),
      contains_raw_session_ids: Map.get(redaction, :contains_raw_session_ids, false),
      contains_raw_tool_names: Map.get(redaction, :contains_raw_tool_names, false),
      contains_raw_params: Map.get(redaction, :contains_raw_params, false)
    }
  end

  defp extension_wasm_lifecycle_redaction(_), do: extension_wasm_lifecycle_redaction(%{})

  defp extension_host_runtime(runtime) when is_map(runtime) do
    hosts = Map.get(runtime, :hosts, %{})

    %{
      hosts:
        hosts
        |> Enum.map(fn {host, meta} -> {host, extension_host_runtime_meta(meta)} end)
        |> Map.new(),
      degraded_host_count: Map.get(runtime, :degraded_host_count, 0),
      manifest_only_host_count: Map.get(runtime, :manifest_only_host_count, 0),
      runtime_health_loads_extension_code:
        Map.get(runtime, :runtime_health_loads_extension_code, false)
    }
  end

  defp extension_host_runtime(_), do: extension_host_runtime(%{})

  defp extension_host_runtime_meta(meta) when is_map(meta) do
    %{
      configured_count: Map.get(meta, :configured_count, 0),
      status: Map.get(meta, :status, "not_configured"),
      diagnostics_loads_host_code: Map.get(meta, :diagnostics_loads_host_code, false)
    }
  end

  defp extension_host_runtime_meta(_), do: extension_host_runtime_meta(%{})

  defp channels_status do
    gateway = LemonCore.Config.load().gateway || %{}
    diagnostics = ChannelDiagnostics.status(project_dir: File.cwd!())
    proofs = proof_status()
    readiness = ChannelReadiness.status(channels: diagnostics, proofs: proofs)
    configured_transports = configured_channel_transports(gateway)
    runtime = channel_runtime_status()
    runtime_by_id = Map.new(runtime.adapters, &{&1.name, &1})
    configured_by_id = Map.new(configured_transports, &{&1.name, &1})

    transports =
      configured_by_id
      |> Map.keys()
      |> Kernel.++(Map.keys(runtime_by_id))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn name ->
        configured = Map.get(configured_by_id, name, %{name: name, enabled?: false})
        runtime_adapter = Map.get(runtime_by_id, name, %{})
        runtime_status = runtime_adapter[:runtime_status] || "not_registered"

        configured
        |> Map.merge(%{
          configured?:
            configured[:app_configured?] == true or MapSet.member?(runtime.configured, name),
          connected?: MapSet.member?(runtime.connected, name) or runtime_status == "running",
          runtime_status: runtime_status,
          reconnectable?: configured[:app_configured?] == true and runtime_status != "running",
          account_id: runtime_adapter[:account_id],
          capabilities: runtime_adapter[:capabilities] || %{}
        })
      end)

    bindings =
      gateway
      |> Map.get(:bindings, [])
      |> Enum.with_index()
      |> Enum.map(fn {binding, index} -> format_channel_binding(binding, index) end)

    %{
      transports: transports,
      enabled_count: Enum.count(transports, & &1.enabled?),
      running_count: Enum.count(transports, &(&1.runtime_status == "running")),
      bindings: bindings,
      gateway: format_gateway_channel_config(gateway),
      telegram: format_telegram_channel_config(gateway),
      discord: format_discord_channel_config(gateway),
      diagnostics: diagnostics,
      readiness: readiness,
      failure_drilldown: channel_failure_drilldown(diagnostics, proofs)
    }
  rescue
    error ->
      %{
        transports: [],
        enabled_count: 0,
        running_count: 0,
        bindings: [],
        gateway: %{},
        telegram: %{},
        diagnostics: %{},
        readiness: %{},
        failure_drilldown: [],
        error: Exception.message(error)
      }
  catch
    kind, reason ->
      %{
        transports: [],
        enabled_count: 0,
        running_count: 0,
        bindings: [],
        gateway: %{},
        telegram: %{},
        diagnostics: %{},
        readiness: %{},
        failure_drilldown: [],
        error: inspect({kind, reason})
      }
  end

  defp channel_failure_drilldown(diagnostics, proofs) do
    telegram = transport_diagnostics(diagnostics, "telegram")
    discord = transport_diagnostics(diagnostics, "discord")
    reason_counts = get_map(proofs, :reason_kind_counts, %{})
    check_counts = get_map(proofs, :check_name_counts, %{})

    [
      %{
        id: "telegram_voice_transcription",
        label: "Telegram voice transcription",
        status: telegram_voice_transcription_status(telegram, check_counts),
        evidence: telegram_voice_transcription_evidence(telegram, check_counts),
        next_action: telegram_voice_transcription_next_action(telegram, check_counts),
        source: "proof_diagnostics"
      },
      %{
        id: "discord_dm",
        label: "Discord DMs",
        status: discord_dm_status(reason_counts),
        evidence: discord_dm_evidence(reason_counts),
        next_action: discord_dm_next_action(reason_counts),
        source: get_in_safe(discord, [:direct_messages, :live_external_sender_proof_source])
      },
      %{
        id: "discord_free_response",
        label: "Discord free response",
        status: discord_free_response_status(discord, reason_counts),
        evidence: discord_free_response_evidence(discord, reason_counts),
        next_action: discord_free_response_next_action(discord, reason_counts),
        source: get_in_safe(discord, [:free_response, :live_external_sender_proof_source])
      },
      %{
        id: "discord_reconnect",
        label: "Discord reconnect replay",
        status: discord_reconnect_status(check_counts),
        evidence:
          "#{check_count(check_counts, "discord_restart_replay_seed")} seed checks; #{check_count(check_counts, "discord_restart_replay_verify")} verify checks",
        next_action: "Restart the runtime intentionally, then run restart verify",
        source: get_in_safe(discord, [:inbound_replay, :live_gateway_reconnect_proof_source])
      },
      %{
        id: "discord_slash_client",
        label: "Discord slash client-click",
        status: discord_slash_client_status(proofs),
        evidence: discord_slash_client_evidence(check_counts, reason_counts, proofs),
        next_action: discord_slash_client_next_action(proofs),
        source: get_in_safe(discord, [:slash_commands, :live_registration_proof_source])
      }
    ]
  end

  defp telegram_voice_transcription_status(telegram, check_counts) do
    voice = get_map(telegram, :voice_transcription, %{})

    cond do
      get_map(telegram, :enabled) != true ->
        "disabled"

      telegram_voice_transcription_proven?(check_counts) ->
        "proven"

      get_map(voice, :enabled) != true ->
        "disabled"

      get_map(voice, :api_key_required) == true and get_map(voice, :api_key_configured) != true ->
        "blocked"

      get_map(voice, :provider) == "local_transcript" ->
        "needs_proof"

      true ->
        "configured"
    end
  end

  defp telegram_voice_transcription_evidence(telegram, check_counts) do
    voice = get_map(telegram, :voice_transcription, %{})

    [
      "provider #{format_activity_value(get_map(voice, :provider))}",
      "#{check_count(check_counts, "telegram_voice_local_transcript_provider")} provider checks",
      "#{check_count(check_counts, "telegram_voice_local_no_api_key")} no-key checks",
      "#{check_count(check_counts, "telegram_voice_local_inbound_metadata")} metadata checks",
      "api key required: #{yes_no_value(get_map(voice, :api_key_required))}",
      "api key configured: #{yes_no_value(get_map(voice, :api_key_configured))}"
    ]
    |> Enum.join("; ")
  end

  defp telegram_voice_transcription_next_action(telegram, check_counts) do
    voice = get_map(telegram, :voice_transcription, %{})

    cond do
      get_map(telegram, :enabled) != true ->
        "Enable Telegram before proving voice transcription"

      telegram_voice_transcription_proven?(check_counts) ->
        "Keep the local voice proof artifact current; run provider-backed STT proof before claiming live speech-to-text parity"

      get_map(voice, :provider) == "local_transcript" ->
        "Run MIX_ENV=test mix run scripts/live_telegram_voice_local_smoke.exs"

      get_map(voice, :api_key_required) == true and get_map(voice, :api_key_configured) != true ->
        "Configure Telegram voice transcription credentials or switch to local_transcript for deterministic proof"

      true ->
        "Run a Telegram voice transcription proof"
    end
  end

  defp telegram_voice_transcription_proven?(check_counts) do
    check_count(check_counts, "telegram_voice_local_transcript_provider") > 0 and
      check_count(check_counts, "telegram_voice_local_no_api_key") > 0 and
      check_count(check_counts, "telegram_voice_local_inbound_metadata") > 0
  end

  defp discord_dm_status(reason_counts) do
    if reason_count(reason_counts, "discord_dm_setup_refused") > 0 do
      "blocked"
    else
      "needs_proof"
    end
  end

  defp discord_dm_evidence(reason_counts) do
    "#{reason_count(reason_counts, "discord_dm_setup_refused")} setup refusals classified"
  end

  defp discord_dm_next_action(reason_counts) do
    if reason_count(reason_counts, "discord_dm_setup_refused") > 0 do
      "Use a reachable human/open-DM target, then run scripts/live_discord_matrix.py --wait-dm-inbound --dm-recipient-id DISCORD_USER_ID --result-path tmp/discord-dm-proof.json --proof-path .lemon/proofs/discord-dm-latest.json"
    else
      "Run scripts/live_discord_matrix.py --wait-dm-inbound with --dm-channel-id for a known DM channel or --dm-recipient-id for a reachable human/open-DM target"
    end
  end

  defp discord_free_response_status(discord, reason_counts) do
    intent_declared =
      get_in_safe(discord, [:free_response, :message_content_intent_declared]) == true

    failures = discord_free_response_failure_count(reason_counts)

    cond do
      failures > 0 -> "blocked"
      intent_declared -> "needs_live_proof"
      true -> "blocked"
    end
  end

  defp discord_free_response_evidence(discord, reason_counts) do
    intent_or_delivery =
      reason_count(reason_counts, "discord_message_content_intent_or_delivery")

    no_reply = reason_count(reason_counts, "discord_no_reply_for_unmentioned_message")

    [
      "#{intent_or_delivery} Message Content Intent/delivery failures classified",
      "#{no_reply} no-reply failures classified",
      "runtime requests intent: #{yes_no_value(get_in_safe(discord, [:free_response, :runtime_requests_message_content_intent]))}",
      "intent declared: #{yes_no_value(get_in_safe(discord, [:free_response, :message_content_intent_declared]))}"
    ]
    |> Enum.join("; ")
  end

  defp discord_free_response_next_action(discord, reason_counts) do
    intent_declared =
      get_in_safe(discord, [:free_response, :message_content_intent_declared]) == true

    cond do
      reason_count(reason_counts, "discord_message_content_intent_or_delivery") > 0 and
          intent_declared ->
        "Verify Message Content Intent is enabled in the Discord Developer Portal, restart the runtime, and rerun the free-response proof"

      reason_count(reason_counts, "discord_message_content_intent_or_delivery") > 0 ->
        "Enable and declare Message Content Intent, restart the runtime, then rerun the free-response proof"

      reason_count(reason_counts, "discord_no_reply_for_unmentioned_message") > 0 ->
        "Rerun the free-response proof with an external unmentioned sender after confirming delivery and trigger-mode settings"

      true ->
        "Enable and declare Message Content Intent, then rerun the free-response proof"
    end
  end

  defp discord_free_response_failure_count(reason_counts) do
    reason_count(reason_counts, "discord_message_content_intent_or_delivery") +
      reason_count(reason_counts, "discord_no_reply_for_unmentioned_message")
  end

  defp discord_reconnect_status(check_counts) do
    seed_count = check_count(check_counts, "discord_restart_replay_seed")
    verify_count = check_count(check_counts, "discord_restart_replay_verify")

    cond do
      verify_count > 0 -> "proven"
      seed_count > 0 -> "seeded"
      true -> "needs_proof"
    end
  end

  defp discord_slash_client_status(proofs) do
    cond do
      get_in_safe(discord_slash_client_click_proof_coverage(proofs), [
        :real_client_click_proof
      ]) == true ->
        "proven"

      discord_slash_client_reason(proofs) in [
        "discord_slash_client_click_invalid_artifact",
        "discord_slash_client_click_not_promotable",
        "discord_slash_client_click_stale"
      ] ->
        "blocked"

      true ->
        "needs_proof"
    end
  end

  defp discord_slash_client_evidence(check_counts, reason_counts, proofs) do
    coverage = discord_slash_proof_coverage(proofs)
    registration_checks = check_count(check_counts, "discord_all_slash_registration")

    deterministic_checks =
      check_count(check_counts, "slash_command_inventory_16") +
        check_count(check_counts, "slash_command_inventory_15")

    client_click_checks = check_count(check_counts, "discord_slash_client_click_observed")
    completed = get_map(discord_slash_proof(proofs), :completed_count, 0)
    registered = get_map(coverage, :registered_command_count, nil)
    responses = get_map(coverage, :local_response_command_count, nil)
    decoders = get_map(coverage, :decode_command_count, nil)
    client_click_coverage = discord_slash_client_click_proof_coverage(proofs)
    client_click_commands = get_map(client_click_coverage, :client_click_command_count, nil)

    [
      "#{registration_checks} live registration inventory checks",
      "#{completed || deterministic_checks} deterministic local checks",
      if(registered, do: "#{registered} commands inventoried"),
      if(decoders, do: "#{decoders} decoder groups covered"),
      if(responses, do: "#{responses} safe response paths"),
      if(client_click_checks > 0, do: "#{client_click_checks} client-click observations"),
      if(client_click_commands, do: "#{client_click_commands} client-click commands observed"),
      discord_slash_client_reason_evidence(reason_counts, proofs),
      if(
        get_map(client_click_coverage, :real_client_click_proof, false),
        do: "client-click proof observed",
        else: "client-click breadth not proven"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp discord_slash_client_reason_evidence(reason_counts, proofs) do
    reason = discord_slash_client_reason(proofs)

    case reason do
      "discord_slash_client_click_missing" ->
        "#{reason_count(reason_counts, reason)} missing client-click proof artifacts classified"

      "discord_slash_client_click_invalid_artifact" ->
        "#{reason_count(reason_counts, reason)} invalid client-click proof artifacts classified"

      "discord_slash_client_click_not_promotable" ->
        "#{reason_count(reason_counts, reason)} non-promotable client-click proof artifacts classified"

      "discord_slash_client_click_stale" ->
        "#{reason_count(reason_counts, reason)} stale client-click proof artifacts classified"

      nil ->
        nil

      reason ->
        "latest client-click proof reason: #{reason}"
    end
  end

  defp discord_slash_client_next_action(proofs) do
    case discord_slash_client_reason(proofs) do
      "discord_slash_client_click_missing" ->
        "Deploy or hot reload the runtime, then run scripts/live_discord_matrix.py --wait-slash-client-click-proof --channel-id DISCORD_PROOF_CHANNEL_ID --proof-path .lemon/proofs/discord-slash-client-click-check-latest.json and click the requested real slash command"

      "discord_slash_client_click_invalid_artifact" ->
        "Fix or remove the invalid client-click proof artifact, then rerun scripts/live_discord_matrix.py --check-slash-client-click-proof with the redacted --proof-path output"

      "discord_slash_client_click_not_promotable" ->
        "Capture a real Discord client click with live client fields and a safe interaction response; deterministic synthetic slash proof does not promote this gate"

      "discord_slash_client_click_stale" ->
        "Rerun scripts/live_discord_matrix.py --wait-slash-client-click-proof while clicking a fresh real Discord slash command; stale artifacts do not promote this gate"

      _ ->
        "Run scripts/live_discord_matrix.py --wait-slash-client-click-proof for the registered command set"
    end
  end

  defp discord_slash_client_reason(proofs) do
    latest_check_reason(proofs, "discord_slash_client_click_proof_artifact")
  end

  defp latest_check_reason(proofs, check_name) do
    proofs
    |> get_map(:latest_checks, [])
    |> Enum.find(%{}, &(get_map(&1, :name) == check_name))
    |> get_map(:reason_kind)
  end

  defp discord_slash_proof_coverage(proofs) do
    proofs
    |> discord_slash_proof()
    |> get_map(:coverage, %{})
  end

  defp discord_slash_proof(proofs) do
    proofs
    |> get_map(:recent_proofs, [])
    |> Enum.find(%{}, fn proof ->
      get_map(proof, :proof_object) == "lemon.discord_slash_interaction" or
        "discord_slash_interaction_deterministic" in List.wrap(get_map(proof, :proof_scopes, []))
    end)
  end

  defp discord_slash_client_click_proof_coverage(proofs) do
    proofs
    |> discord_slash_client_click_proof()
    |> get_map(:coverage, %{})
  end

  defp discord_slash_client_click_proof(proofs) do
    proofs
    |> get_map(:recent_proofs, [])
    |> Enum.find(%{}, fn proof ->
      get_map(proof, :proof_object) == "lemon.discord_slash_client_click" or
        "discord_slash_client_click_observed" in List.wrap(get_map(proof, :proof_scopes, []))
    end)
  end

  defp transport_diagnostics(diagnostics, transport) do
    diagnostics
    |> get_map(:transports, [])
    |> Enum.find(%{}, &(get_map(&1, :transport) == transport))
  end

  defp reason_count(counts, reason), do: integer_count(counts, reason)
  defp check_count(counts, check), do: integer_count(counts, check)

  defp integer_count(counts, key) do
    case get_map(counts, key, 0) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp get_in_safe(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case get_map(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp yes_no_value(true), do: "yes"
  defp yes_no_value(false), do: "no"
  defp yes_no_value(_), do: "unknown"

  defp format_gateway_channel_config(gateway) do
    %{
      default_engine: Map.get(gateway, :default_engine),
      default_cwd: Map.get(gateway, :default_cwd),
      auto_resume?: Map.get(gateway, :auto_resume) == true
    }
  end

  defp format_telegram_channel_config(gateway) do
    telegram = Map.get(gateway, :telegram, %{}) || %{}

    %{
      bot_token_secret: get_map(telegram, :bot_token_secret),
      allowed_chat_ids: get_map(telegram, :allowed_chat_ids, []) |> List.wrap(),
      deny_unbound_chats?: get_map(telegram, :deny_unbound_chats, false) == true
    }
  end

  defp format_discord_channel_config(gateway) do
    discord = Map.get(gateway, :discord, %{}) || %{}

    %{
      bot_token_secret: get_map(discord, :bot_token_secret),
      allowed_guild_ids: get_map(discord, :allowed_guild_ids, []) |> List.wrap(),
      allowed_channel_ids: get_map(discord, :allowed_channel_ids, []) |> List.wrap(),
      deny_unbound_channels?: get_map(discord, :deny_unbound_channels, false) == true,
      message_content_intent_enabled?:
        get_map(discord, :message_content_intent_enabled, false) == true
    }
  end

  defp configured_channel_transports(gateway) do
    gateway_transports =
      [
        {"telegram", :enable_telegram},
        {"discord", :enable_discord},
        {"farcaster", :enable_farcaster},
        {"email", :enable_email},
        {"xmtp", :enable_xmtp},
        {"webhook", :enable_webhook}
      ]
      |> Enum.map(fn {name, field} ->
        %{
          name: name,
          enabled?: Map.get(gateway, field) == true,
          configurable?: true,
          config_key: Atom.to_string(field)
        }
      end)

    app_transports = configured_channel_adapter_summaries()

    (gateway_transports ++ app_transports)
    |> Enum.reduce(%{}, fn transport, acc ->
      Map.update(acc, transport.name, transport, fn existing ->
        existing
        |> Map.merge(transport)
        |> Map.update(:enabled?, existing.enabled?, &(&1 || existing.enabled?))
      end)
    end)
    |> Map.values()
  end

  defp configured_channel_adapter_summaries do
    :lemon_channels
    |> Application.get_env(:adapters, [])
    |> Enum.map(&normalize_configured_channel_adapter/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_configured_channel_adapter({adapter_module, _opts})
       when is_atom(adapter_module) do
    configured_channel_adapter_summary(adapter_module)
  end

  defp normalize_configured_channel_adapter(adapter_module) when is_atom(adapter_module) do
    configured_channel_adapter_summary(adapter_module)
  end

  defp normalize_configured_channel_adapter(_), do: nil

  defp configured_channel_adapter_summary(adapter_module) do
    case adapter_id(adapter_module) do
      id when is_binary(id) and id != "" ->
        %{name: id, enabled?: true, app_configured?: true, configurable?: false}

      _ ->
        nil
    end
  end

  defp configured_channel_adapter(channel_id) do
    :lemon_channels
    |> Application.get_env(:adapters, [])
    |> Enum.find_value(fn
      {adapter_module, opts} when is_atom(adapter_module) and is_list(opts) ->
        if adapter_id(adapter_module) == channel_id, do: {:ok, adapter_module, opts}

      adapter_module when is_atom(adapter_module) ->
        if adapter_id(adapter_module) == channel_id, do: {:ok, adapter_module, []}

      _ ->
        nil
    end)
    |> case do
      nil -> {:error, :channel_not_configured}
      result -> result
    end
  end

  defp adapter_id(adapter_module) when is_atom(adapter_module) do
    with {:module, ^adapter_module} <- Code.ensure_loaded(adapter_module),
         true <- function_exported?(adapter_module, :id, 0) do
      apply(adapter_module, :id, [])
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp channel_runtime_status do
    registry_status =
      case channel_registry_call(:status, []) do
        %{configured: configured, connected: connected} ->
          %{
            configured: configured |> List.wrap() |> MapSet.new(),
            connected: connected |> List.wrap() |> MapSet.new()
          }

        _ ->
          %{configured: MapSet.new(), connected: MapSet.new()}
      end

    adapters =
      case channel_registry_call(:list, []) do
        adapters when is_list(adapters) ->
          adapters
          |> Enum.map(&format_channel_runtime_adapter/1)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    %{
      adapters: adapters,
      configured: registry_status.configured,
      connected: registry_status.connected
    }
  end

  defp format_channel_runtime_adapter({channel_id, info}) when is_map(info) do
    %{
      name: channel_id,
      runtime_status: format_activity_value(info[:status] || info["status"] || "unknown"),
      account_id: info[:account_id] || info["account_id"],
      capabilities: info[:capabilities] || info["capabilities"] || %{}
    }
  end

  defp format_channel_runtime_adapter(info) when is_map(info) do
    %{
      name: info[:channel_id] || info["channelId"] || info[:id] || info["id"],
      runtime_status: format_activity_value(info[:status] || info["status"] || "unknown"),
      account_id: info[:account_id] || info["accountId"],
      capabilities: info[:capabilities] || info["capabilities"] || %{}
    }
  end

  defp format_channel_runtime_adapter(_), do: nil

  defp cron_manager_call(function, args) do
    module = Module.concat(["Lemon" <> "Automation", "CronManager"])

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :cron_manager_unavailable}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp skills_module_call(parts, function, args) do
    module = Module.concat(["Lemon" <> "Skills" | parts])

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :skills_unavailable}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp channel_registry_call(function, args) do
    module = Module.concat(["Lemon" <> "Channels", "Registry"])

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :channel_registry_unavailable}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp channels_application_call(function, args) do
    module = Module.concat(["Lemon" <> "Channels", "Application"])

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :channels_application_unavailable}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp gateway_transport_config_key("telegram"), do: "enable_telegram"
  defp gateway_transport_config_key("discord"), do: "enable_discord"
  defp gateway_transport_config_key("farcaster"), do: "enable_farcaster"
  defp gateway_transport_config_key("email"), do: "enable_email"
  defp gateway_transport_config_key("xmtp"), do: "enable_xmtp"
  defp gateway_transport_config_key("webhook"), do: "enable_webhook"
  defp gateway_transport_config_key(_), do: nil

  defp write_gateway_boolean(key, enabled) do
    path = LemonCore.Config.global_path()
    content = if File.exists?(path), do: File.read!(path), else: ""

    updated =
      LemonCore.Config.TomlPatch.upsert_raw_line(
        content,
        "gateway",
        key,
        "#{key} = #{enabled}"
      )

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, updated)
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp write_gateway_defaults(params) do
    fields = [
      {"default_engine", param_string(params, "default_engine"), :string},
      {"default_cwd", param_string(params, "default_cwd"), :string},
      {"auto_resume", boolean_param(params, "auto_resume"), :boolean}
    ]

    write_table_fields("gateway", fields)
  end

  defp telegram_config_fields(params) do
    with {:ok, allowed_chat_ids} <-
           parse_allowed_chat_ids(param_string(params, "allowed_chat_ids")) do
      {:ok,
       [
         {"bot_token_secret", param_string(params, "bot_token_secret"), :string},
         {"allowed_chat_ids", allowed_chat_ids, :integer_array},
         {"deny_unbound_chats", boolean_param(params, "deny_unbound_chats"), :boolean}
       ]}
    end
  end

  defp discord_config_fields(params) do
    with {:ok, allowed_guild_ids} <-
           parse_allowed_chat_ids(param_string(params, "allowed_guild_ids")),
         {:ok, allowed_channel_ids} <-
           parse_allowed_chat_ids(param_string(params, "allowed_channel_ids")) do
      {:ok,
       [
         {"bot_token_secret", param_string(params, "bot_token_secret"), :string},
         {"allowed_guild_ids", allowed_guild_ids, :integer_array},
         {"allowed_channel_ids", allowed_channel_ids, :integer_array},
         {"deny_unbound_channels", boolean_param(params, "deny_unbound_channels"), :boolean},
         {"message_content_intent_enabled",
          boolean_param(params, "message_content_intent_enabled"), :boolean}
       ]}
    end
  end

  defp provider_config_fields(params) do
    [
      {"auth_source", normalize_auth_source(param_string(params, "auth_source")), :string},
      {"api_key_secret", param_string(params, "api_key_secret"), :string},
      {"oauth_secret", param_string(params, "oauth_secret"), :string},
      {"base_url", param_string(params, "base_url"), :string}
    ]
  end

  defp normalize_auth_source(nil), do: nil
  defp normalize_auth_source(value) when value in ["api_key", "oauth"], do: value
  defp normalize_auth_source(_value), do: nil

  defp validate_provider_id(provider_id) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, provider_id) do
      :ok
    else
      {:error, :invalid_provider_id}
    end
  end

  defp write_table_fields(table, fields) do
    patch_config_file(fn content ->
      Enum.reduce(fields, content, fn
        {key, nil, _type}, acc ->
          LemonCore.Config.TomlPatch.delete_key(acc, table, key)

        {key, [], :integer_array}, acc ->
          LemonCore.Config.TomlPatch.delete_key(acc, table, key)

        {key, value, :string}, acc ->
          LemonCore.Config.TomlPatch.upsert_raw_line(acc, table, key, raw_string_line(key, value))

        {key, value, :boolean}, acc when is_boolean(value) ->
          LemonCore.Config.TomlPatch.upsert_raw_line(acc, table, key, "#{key} = #{value}")

        {key, value, :integer_array}, acc when is_list(value) ->
          LemonCore.Config.TomlPatch.upsert_raw_line(
            acc,
            table,
            key,
            raw_integer_array_line(key, value)
          )
      end)
    end)
  end

  defp write_gateway_bindings(bindings) when is_list(bindings) do
    patch_config_file(fn content ->
      content
      |> drop_gateway_bindings()
      |> append_gateway_bindings(bindings)
    end)
  end

  defp patch_config_file(fun) do
    path = LemonCore.Config.global_path()
    content = if File.exists?(path), do: File.read!(path), else: ""
    updated = fun.(content)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, updated)
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp raw_string_line(key, value), do: ~s(#{key} = #{toml_string(value)})

  defp raw_integer_array_line(key, values) do
    rendered = values |> Enum.map(&to_string/1) |> Enum.join(", ")
    "#{key} = [#{rendered}]"
  end

  defp toml_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp reload_config do
    cwd = File.cwd!()
    _ = LemonCore.ConfigCache.invalidate(cwd)
    _ = LemonCore.ConfigCache.invalidate(nil)
    _ = LemonCore.Config.reload(cwd, cache: false)

    if is_pid(Process.whereis(LemonCore.ConfigReloader)) do
      case LemonCore.ConfigReloader.reload(
             cwd: cwd,
             force: true,
             reason: :web_ops_channel_config
           ) do
        {:ok, _result} -> :ok
        {:error, :reload_in_progress} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp skill_entries do
    cwd = File.cwd!()

    case skills_module_call(["Registry"], :list, [[cwd: cwd, refresh: true]]) do
      entries when is_list(entries) ->
        entries
        |> Enum.map(&format_skill_entry(&1, cwd))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp format_skill_entry(entry, cwd) do
    status =
      case skills_module_call(["Status"], :check_entry, [entry, [cwd: cwd]]) do
        status when is_map(status) -> status
        _ -> %{}
      end

    %{
      key: entry_value(entry, :key),
      name: entry_value(entry, :name) || entry_value(entry, :key),
      description: entry_value(entry, :description),
      source: format_activity_value(entry_value(entry, :source)),
      path: entry_value(entry, :path),
      enabled?: not status_value(status, :disabled, false),
      activation_state: format_activity_value(status_value(status, :activation_state, "unknown")),
      source_kind: format_activity_value(entry_value(entry, :source_kind) || "unknown"),
      source_id: entry_value(entry, :source_id),
      trust_level: format_activity_value(entry_value(entry, :trust_level) || "unknown"),
      audit_status: format_activity_value(entry_value(entry, :audit_status) || "unknown"),
      content_hash: entry_value(entry, :content_hash),
      bundle_hash: entry_value(entry, :bundle_hash),
      upstream_hash: entry_value(entry, :upstream_hash),
      installed_at: format_time_value(entry_value(entry, :installed_at)),
      updated_at: format_time_value(entry_value(entry, :updated_at)),
      required_bins: required_bins(entry_value(entry, :manifest)),
      missing: missing_requirements(status)
    }
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp entry_value(entry, field) when is_map(entry) do
    Map.get(entry, field) || Map.get(entry, Atom.to_string(field))
  end

  defp entry_value(_, _), do: nil

  defp status_value(status, field, default) when is_map(status) do
    Map.get(status, field) || Map.get(status, Atom.to_string(field), default)
  end

  defp status_value(_, _, default), do: default

  defp required_bins(manifest) when is_map(manifest) do
    manifest
    |> manifest_get("requires", %{})
    |> manifest_get("bins", [])
    |> List.wrap()
    |> Enum.map(fn
      bin when is_binary(bin) -> bin
      bin when is_map(bin) -> manifest_get(bin, "name", nil)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp required_bins(_), do: []

  defp manifest_get(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key), default)
  end

  defp manifest_get(_, _, default), do: default

  defp missing_requirements(status) when is_map(status) do
    []
    |> Kernel.++(List.wrap(status_value(status, :missing_bins, [])))
    |> Kernel.++(List.wrap(status_value(status, :missing_config, [])))
    |> Kernel.++(List.wrap(status_value(status, :missing_env_vars, [])))
    |> Kernel.++(List.wrap(status_value(status, :missing_tools, [])))
    |> Enum.uniq()
  end

  defp missing_requirements(_), do: []

  defp cron_create_params(params) do
    %{}
    |> maybe_put(:name, param_string(params, "name"))
    |> maybe_put(:schedule, param_string(params, "schedule"))
    |> maybe_put(:agent_id, param_string(params, "agent_id"))
    |> maybe_put(:session_key, param_string(params, "session_key"))
    |> maybe_put(:prompt, param_string(params, "prompt"))
    |> maybe_put(:timezone, param_string(params, "timezone"))
    |> maybe_put(:max_retries, non_negative_integer_param(params, "max_retries"))
    |> maybe_put(:retry_backoff_ms, non_negative_integer_param(params, "retry_backoff_ms"))
    |> Map.put(:enabled, truthy_param?(Map.get(params, "enabled")))
  end

  defp cron_update_params(params) do
    %{}
    |> maybe_put(:name, param_string(params, "name"))
    |> maybe_put(:schedule, param_string(params, "schedule"))
    |> maybe_put(:prompt, param_string(params, "prompt"))
    |> maybe_put(:timezone, param_string(params, "timezone"))
    |> maybe_put(:max_retries, non_negative_integer_param(params, "max_retries"))
    |> maybe_put(:retry_backoff_ms, non_negative_integer_param(params, "retry_backoff_ms"))
  end

  defp param_string(params, key) do
    value = Map.get(params, key) || Map.get(params, String.to_atom(key))

    case value do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        Atom.to_string(value)

      nil ->
        nil

      value ->
        to_string(value)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_negative_integer_param(params, key) do
    value = Map.get(params, key) || Map.get(params, String.to_atom(key))

    case value do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        value = String.trim(value)

        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp boolean_param(params, key) do
    if Map.has_key?(params, key) or Map.has_key?(params, String.to_atom(key)) do
      truthy_param?(Map.get(params, key) || Map.get(params, String.to_atom(key)))
    end
  end

  defp truthy_param?(value), do: value in [true, "true", "on", "1", 1]

  defp current_channel_bindings do
    gateway = LemonCore.Config.load().gateway || %{}

    gateway
    |> Map.get(:bindings, [])
    |> List.wrap()
    |> Enum.map(&normalize_channel_binding/1)
    |> Enum.reject(&is_nil/1)
  end

  defp channel_binding_params(params) do
    binding =
      %{
        transport: param_string(params, "transport") || "telegram",
        chat_id: parse_required_binding_value(param_string(params, "chat_id")),
        topic_id: parse_optional_binding_value(param_string(params, "topic_id")),
        agent_id: param_string(params, "agent_id") || "default",
        default_engine: param_string(params, "default_engine"),
        project: param_string(params, "project")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if binding[:chat_id] do
      {:ok, binding}
    else
      {:error, :invalid_channel_binding}
    end
  end

  defp normalize_channel_binding(binding) when is_map(binding) do
    %{
      transport: get_map(binding, :transport),
      chat_id: get_map(binding, :chat_id),
      topic_id: get_map(binding, :topic_id),
      agent_id: get_map(binding, :agent_id),
      default_engine: get_map(binding, :default_engine),
      project: get_map(binding, :project)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_channel_binding(_binding), do: nil

  defp parse_binding_index(index) when is_integer(index) and index >= 0, do: {:ok, index}

  defp parse_binding_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_channel_binding}
    end
  end

  defp parse_binding_index(_index), do: {:error, :invalid_channel_binding}

  defp parse_required_binding_value(nil), do: nil
  defp parse_required_binding_value(value), do: parse_binding_value(value)

  defp parse_optional_binding_value(nil), do: nil
  defp parse_optional_binding_value(value), do: parse_binding_value(value)

  defp parse_binding_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp parse_binding_value(value), do: value

  defp parse_allowed_chat_ids(nil), do: {:ok, []}

  defp parse_allowed_chat_ids(value) when is_binary(value) do
    value
    |> String.split([",", "\n", " "], trim: true)
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case Integer.parse(raw) do
        {integer, ""} -> {:cont, {:ok, [integer | acc]}}
        _ -> {:halt, {:error, :invalid_allowed_chat_ids}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_gateway_bindings(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> Enum.reduce({[], false}, fn line, {kept, dropping?} ->
      cond do
        gateway_binding_header?(line) ->
          {kept, true}

        dropping? and table_header?(line) ->
          {[line | kept], false}

        dropping? ->
          {kept, true}

        true ->
          {[line | kept], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp append_gateway_bindings(content, []), do: ensure_final_newline(content)

  defp append_gateway_bindings(content, bindings) do
    rendered =
      bindings
      |> Enum.map(&render_gateway_binding/1)
      |> Enum.join("\n\n")

    content
    |> ensure_final_newline()
    |> Kernel.<>(if content == "", do: "", else: "\n")
    |> Kernel.<>(rendered)
    |> ensure_final_newline()
  end

  defp render_gateway_binding(binding) do
    [
      "[[gateway.bindings]]",
      binding_line("transport", binding[:transport], :string),
      binding_line("chat_id", binding[:chat_id], :scalar),
      binding_line("topic_id", binding[:topic_id], :scalar),
      binding_line("agent_id", binding[:agent_id], :string),
      binding_line("default_engine", binding[:default_engine], :string),
      binding_line("project", binding[:project], :string)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp binding_line(_key, nil, _type), do: nil
  defp binding_line(_key, "", _type), do: nil
  defp binding_line(key, value, :string), do: raw_string_line(key, value)
  defp binding_line(key, value, :scalar) when is_integer(value), do: "#{key} = #{value}"
  defp binding_line(key, value, :scalar), do: raw_string_line(key, value)

  defp gateway_binding_header?(line),
    do: Regex.match?(~r/^\s*\[\[gateway\.bindings\]\]\s*$/, line)

  defp table_header?(line), do: Regex.match?(~r/^\s*\[+[^]]+\]+\s*$/, line)

  defp ensure_final_newline(""), do: ""

  defp ensure_final_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end

  defp normalize_approval_decision(decision) when is_atom(decision) do
    if decision in [:approve_once, :approve_session, :approve_agent, :approve_global, :deny] do
      {:ok, decision}
    else
      {:error, :invalid_decision}
    end
  end

  defp normalize_approval_decision(decision) when is_binary(decision) do
    case decision do
      "approve_once" -> {:ok, :approve_once}
      "once" -> {:ok, :approve_once}
      "approve_session" -> {:ok, :approve_session}
      "session" -> {:ok, :approve_session}
      "approve_agent" -> {:ok, :approve_agent}
      "agent" -> {:ok, :approve_agent}
      "approve_global" -> {:ok, :approve_global}
      "global" -> {:ok, :approve_global}
      "deny" -> {:ok, :deny}
      _ -> {:error, :invalid_decision}
    end
  end

  defp normalize_approval_decision(_), do: {:error, :invalid_decision}

  defp run_summary(run_id, events) do
    started = Enum.find(events, &(&1.event_type == "run_started")) || List.first(events)
    completed = Enum.find(events, &(&1.event_type == "run_completed"))

    %{
      run_id: run_id,
      session_key: value_from_events(events, :session_key),
      agent_id: value_from_events(events, :agent_id),
      engine: value_from_events(events, :engine),
      parent_run_id: value_from_events(events, :parent_run_id),
      started_at_ms: if(started, do: started.ts_ms),
      completed_at_ms: if(completed, do: completed.ts_ms),
      status: run_status(events),
      error: completed && completed.error
    }
  end

  defp run_status(events) do
    completed = Enum.find(events, &(&1.event_type == "run_completed"))

    cond do
      completed && completed.ok? == true ->
        "completed"

      completed &&
          completed.error in [
            :user_requested,
            :interrupted,
            :aborted,
            "user_requested",
            "interrupted",
            "aborted"
          ] ->
        "aborted"

      completed ->
        "error"

      events == [] ->
        "unknown"

      true ->
        "active or incomplete"
    end
  end

  defp event_counts(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      Map.update(acc, event.event_type || "unknown", 1, &(&1 + 1))
    end)
  end

  defp value_from_events(events, field) do
    events
    |> Enum.map(&Map.get(&1, field))
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp tool_event?(event) do
    event_type = event.event_type || ""
    is_binary(event.tool) or String.contains?(event_type, "tool")
  end

  defp approval_event?(event) do
    event_type = event.event_type || ""
    String.starts_with?(event_type, "approval_")
  end

  defp learning_event?(event) do
    event_type = event.event_type || ""
    tool = event.tool || ""

    String.contains?(event_type, "skill") or
      String.contains?(event_type, "memory") or
      String.contains?(event_type, "learning") or
      tool in ["read_skill", "skill_manage", "search_memory", "memory_topic", "memory"]
  end

  defp channel_event?(event) do
    event_type = event.event_type || ""
    haystack = "#{event_type} #{format_activity_value(event.preview)}" |> String.downcase()

    String.contains?(haystack, "channel") or
      String.contains?(haystack, "telegram") or
      String.contains?(haystack, "discord")
  end

  defp cron_event?(event) do
    event_type = event.event_type || ""
    haystack = "#{event_type} #{format_activity_value(event.preview)}" |> String.downcase()

    String.contains?(haystack, "cron") or
      String.contains?(haystack, "heartbeat") or
      String.contains?(haystack, "scheduled")
  end

  defp subagent_event?(event) do
    event_type = event.event_type || ""
    tool = event.tool || ""

    haystack =
      "#{event_type} #{tool} #{format_activity_value(event.preview)}" |> String.downcase()

    tool in ["agent", "task"] or
      String.contains?(haystack, "subagent") or
      String.contains?(haystack, "delegat") or
      String.contains?(haystack, "task_id")
  end

  defp failure_event?(event) do
    event_type = event.event_type || ""

    event.ok? == false or
      not is_nil(event.error) or
      String.contains?(event_type, "error") or
      String.contains?(event_type, "failed") or
      String.contains?(event_type, "failure")
  end

  defp activity_category(event) do
    haystack =
      [event.event_type, event.tool, event.provenance, event.preview]
      |> Enum.map(&format_activity_value/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(haystack, "cron") or String.contains?(haystack, "heartbeat") ->
        :cron

      String.contains?(haystack, "skill") ->
        :skills

      String.contains?(haystack, "channel") or String.contains?(haystack, "telegram") or
        String.contains?(haystack, "discord") or String.contains?(haystack, "xmtp") or
          String.contains?(haystack, "whatsapp") ->
        :channels

      String.contains?(haystack, "memory") ->
        :memory

      String.contains?(haystack, "log") ->
        :logs

      true ->
        :other
    end
  end

  defp format_activity_value(value) when is_binary(value), do: value
  defp format_activity_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_activity_value(nil), do: ""
  defp format_activity_value(value), do: inspect(value)

  defp format_time_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time_value(value) when is_binary(value), do: value
  defp format_time_value(_), do: nil

  defp child_run_summary(child_run_id, event) do
    payload = get_map(event, :payload, %{})

    %{
      run_id: child_run_id,
      session_key: get_map(event, :session_key),
      agent_id: get_map(event, :agent_id),
      engine: get_map(event, :engine),
      started_at_ms: get_map(event, :ts_ms),
      last_event_at_ms: get_map(event, :ts_ms),
      status: child_status_from_event(event, payload)
    }
  end

  defp merge_child_run(existing, event) do
    payload = get_map(event, :payload, %{})
    ts_ms = get_map(event, :ts_ms)
    status = child_status_from_event(event, payload)

    existing
    |> Map.put(:last_event_at_ms, max_int(existing.last_event_at_ms, ts_ms))
    |> Map.put(:started_at_ms, min_int(existing.started_at_ms, ts_ms))
    |> maybe_put_child_status(status)
  end

  defp maybe_put_child_status(child, "unknown"), do: child
  defp maybe_put_child_status(child, status), do: Map.put(child, :status, status)

  defp build_run_tree(run_id, summaries, children_by_parent, visited) do
    summary = Map.get(summaries, run_id, %{run_id: run_id, status: "unknown"})
    visited = MapSet.put(visited, run_id)

    children =
      children_by_parent
      |> Map.get(run_id, [])
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.map(&build_run_tree(&1, summaries, children_by_parent, visited))

    %{
      run_id: run_id,
      status: summary.status || "unknown",
      engine: summary.engine,
      agent_id: summary.agent_id,
      session_key: summary.session_key,
      started_at_ms: summary.started_at_ms,
      completed_at_ms: summary.completed_at_ms,
      children: children
    }
  end

  defp child_status_from_event(event, payload) do
    event_type = normalize_event_type(get_map(event, :event_type))
    ok = payload_ok?(payload)
    error = payload_error(payload)

    cond do
      event_type == "run_completed" and ok == true ->
        "completed"

      event_type == "run_completed" and
          error in [
            :user_requested,
            :interrupted,
            :aborted,
            "user_requested",
            "interrupted",
            "aborted"
          ] ->
        "aborted"

      event_type == "run_completed" ->
        "error"

      event_type == "run_started" ->
        "started"

      true ->
        "unknown"
    end
  end

  defp min_int(nil, value), do: value
  defp min_int(value, nil), do: value
  defp min_int(a, b) when is_integer(a) and is_integer(b), do: min(a, b)
  defp min_int(a, _), do: a

  defp max_int(nil, value), do: value
  defp max_int(value, nil), do: value
  defp max_int(a, b) when is_integer(a) and is_integer(b), do: max(a, b)
  defp max_int(a, _), do: a

  defp payload_tool(payload) when is_map(payload) do
    get_map(payload, :tool_name) || get_map(payload, :tool) || get_map(payload, :name)
  end

  defp payload_tool(_), do: nil

  defp payload_ok?(payload) when is_map(payload), do: get_map(payload, :ok)
  defp payload_ok?(_), do: nil

  defp payload_error(payload) when is_map(payload) do
    get_map(payload, :error) || get_map(payload, :reason)
  end

  defp payload_error(_), do: nil

  defp payload_preview(payload) when is_map(payload) do
    get_map(payload, :result_preview) ||
      get_map(payload, :preview) ||
      get_map(payload, :message) ||
      get_map(payload, :phase) ||
      payload
  end

  defp payload_preview(payload), do: payload

  defp normalize_event_type(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_event_type(value) when is_binary(value), do: value
  defp normalize_event_type(nil), do: nil
  defp normalize_event_type(value), do: inspect(value)

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_event_type/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp normalize_string_list(_), do: []

  defp get_map(map, key, default \\ nil)
  defp get_map(nil, _key, default), do: default

  defp get_map(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      true ->
        default
    end
  rescue
    _ -> default
  end

  defp get_map(_map, _key, default), do: default

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp support_commands do
    %{
      source_dev: "mix lemon.doctor --bundle",
      release_runtime: "bin/lemon_runtime_full eval 'LemonCore.Doctor.CLI.bundle!()'"
    }
  end

  defp planned_panels do
    [
      %{name: "Run detail and failure timeline", status: "partial"},
      %{name: "Cron, skills, channel, memory, and log activity", status: "partial"},
      %{
        name: "Cron schedule, skill health, channel config, and checkpoint panels",
        status: "partial"
      },
      %{name: "Run graph and subagent tree", status: "partial"},
      %{name: "Cron mutation controls", status: "partial"},
      %{name: "Skills provenance and install/update controls", status: "next"},
      %{name: "Channel transport runtime controls", status: "next"},
      %{name: "Support bundle download", status: "next"}
    ]
  end
end
