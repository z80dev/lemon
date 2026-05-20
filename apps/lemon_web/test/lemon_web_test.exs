defmodule LemonWebTest do
  @moduledoc """
  Basic tests for the LemonWeb application.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  defmodule ChannelWorker do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, %{}}
  end

  defmodule ChannelAdapter do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "web-ops-test-channel"

    @impl true
    def meta, do: %{label: "Web Ops Test Channel", capabilities: %{text: true}, docs: nil}

    @impl true
    def child_spec(_opts),
      do: %{id: __MODULE__, start: {LemonWebTest.ChannelWorker, :start_link, [[]]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_implemented}

    @impl true
    def deliver(_payload), do: {:error, :not_implemented}

    @impl true
    def gateway_methods, do: []
  end

  test "application starts successfully" do
    # The application should be running
    assert Application.started_applications()
           |> Enum.any?(fn {app, _, _} -> app == :lemon_web end)
  end

  test "endpoint configuration exists" do
    config = Application.get_env(:lemon_web, LemonWeb.Endpoint)
    assert is_list(config)
    assert config[:url] || config[:http]
    assert config[:adapter] == Bandit.PhoenixAdapter
  end

  test "router is configured" do
    # The router module should exist and be loadable
    assert Code.ensure_loaded?(LemonWeb.Router)
  end

  test "session live module exists" do
    # The SessionLive module should exist
    assert Code.ensure_loaded?(LemonWeb.SessionLive)
  end

  test "session live ignores coalesced output maps" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}
    message = %{type: :coalesced_output, text: "done", run_id: "run_test"}

    assert {:noreply, ^socket} = LemonWeb.SessionLive.handle_info(message, socket)
  end

  test "static LiveView entrypoint uses vendored Phoenix assets" do
    static_root = Path.expand("../priv/static/assets", __DIR__)
    app_js = File.read!(Path.join(static_root, "app.js"))

    assert app_js =~ ~s|from "/assets/vendor/phoenix.mjs"|
    assert app_js =~ ~s|from "/assets/vendor/phoenix_live_view.esm.js"|
    refute app_js =~ "cdn.jsdelivr.net"
    assert File.exists?(Path.join(static_root, "vendor/phoenix.mjs"))
    assert File.exists?(Path.join(static_root, "vendor/phoenix_live_view.esm.js"))
  end

  test "operations dashboard module exists" do
    assert Code.ensure_loaded?(LemonWeb.OpsDashboardLive)
    assert Code.ensure_loaded?(LemonWeb.OpsRunLive)
    assert Code.ensure_loaded?(LemonWeb.SupportBundleController)
  end

  test "support bundle controller returns a zip download" do
    conn = conn(:get, "/ops/support-bundle")
    conn = LemonWeb.SupportBundleController.download(conn, %{})

    assert conn.status == 200
    assert ["application/zip" <> _] = get_resp_header(conn, "content-type")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert conn.resp_body =~ "PK"
  end

  test "operations dashboard snapshot is available" do
    snapshot = LemonWeb.OpsDashboard.snapshot()

    assert is_map(snapshot.runtime)
    assert snapshot.build.lemon_version == "0.1.0"
    assert snapshot.build.runtime_mode in ["source-dev", "release-runtime"]
    assert is_map(snapshot.build.git)
    assert is_map(snapshot.router)
    assert is_map(snapshot.browser)
    assert is_map(snapshot.browser.local)
    assert is_boolean(snapshot.browser.available?)
    assert is_boolean(snapshot.browser.running?)
    assert is_integer(snapshot.browser.request_count)
    assert is_integer(snapshot.browser.pending_requests)
    assert is_integer(snapshot.browser.completed_count)
    assert is_integer(snapshot.browser.failed_count)
    assert is_map(snapshot.browser.session)
    assert is_boolean(snapshot.browser.session.available?)
    assert is_boolean(snapshot.browser.session.running?)
    assert is_map(snapshot.browser.driver_config)
    assert snapshot.browser.driver_config.mode in ["local_cdp", "remote_cdp"]
    assert is_boolean(snapshot.browser.driver_config.attach_only)
    assert is_boolean(snapshot.browser.driver_config.launches_browser)
    assert is_list(snapshot.browser.capabilities)
    assert Enum.any?(snapshot.browser.capabilities, &(&1.name == "screenshots"))
    assert is_list(snapshot.browser.operator_guidance)
    assert is_map(snapshot.browser.artifact_summary)
    assert is_integer(snapshot.browser.artifact_summary.count)
    assert is_integer(snapshot.browser.artifact_summary.total_bytes)
    assert is_map(snapshot.browser.artifact_summary.cleanup)
    assert is_list(snapshot.browser.recent_artifacts)
    assert is_map(snapshot.checkpoints)
    assert is_integer(snapshot.checkpoints.count)
    assert is_integer(snapshot.checkpoints.filesystem_count)
    assert is_integer(snapshot.checkpoints.invalid_count)
    assert is_map(snapshot.checkpoints.cleanup)
    assert snapshot.checkpoints.cleanup.includes_raw_paths == false
    assert snapshot.checkpoints.cleanup.includes_raw_session_ids == false
    assert is_list(snapshot.checkpoints.recent)
    assert is_map(snapshot.goals)
    assert is_integer(snapshot.goals.count)
    assert is_integer(snapshot.goals.active_count)
    assert is_integer(snapshot.goals.paused_count)
    assert is_integer(snapshot.goals.completed_count)
    assert is_map(snapshot.goals.cleanup)
    assert snapshot.goals.cleanup.includes_objectives == false
    assert snapshot.goals.cleanup.includes_raw_session_ids == false
    assert is_list(snapshot.goals.recent)
    assert is_map(snapshot.kanban)
    assert is_integer(snapshot.kanban.board_count)
    assert is_integer(snapshot.kanban.active_board_count)
    assert is_integer(snapshot.kanban.task_count)
    assert is_integer(snapshot.kanban.open_task_count)
    assert is_map(snapshot.kanban.cleanup)
    assert snapshot.kanban.cleanup.includes_titles == false
    assert snapshot.kanban.cleanup.includes_descriptions == false
    assert snapshot.kanban.cleanup.includes_comments == false
    assert snapshot.kanban.cleanup.includes_raw_session_ids == false
    assert is_list(snapshot.kanban.recent_boards)
    assert is_map(snapshot.media)
    assert snapshot.media.worker_status.supervised == true
    assert snapshot.media.worker_status.running == true
    assert is_integer(snapshot.media.worker_status.active_jobs)
    assert is_map(snapshot.media.summary)
    assert is_integer(snapshot.media.summary.count)
    assert is_integer(snapshot.media.summary.artifact_count)
    assert is_integer(snapshot.media.summary.artifact_total_bytes)
    assert is_map(snapshot.media.summary.status_counts)
    assert is_map(snapshot.media.summary.type_counts)
    assert snapshot.media.summary.cleanup.embeds_artifact_bytes_in_support_bundle == false
    assert snapshot.media.summary.cleanup.includes_raw_paths == false
    assert snapshot.media.summary.cleanup.includes_prompts == false
    assert snapshot.media.summary.cleanup.includes_provider_responses == false
    assert snapshot.media.summary.cleanup.includes_channel_message_bodies == false
    assert is_map(snapshot.media.provider_proofs)
    assert snapshot.media.provider_proofs.required_count == 5
    assert is_integer(snapshot.media.provider_proofs.completed_count)
    assert is_list(snapshot.media.provider_proofs.providers)
    assert length(snapshot.media.provider_proofs.providers) == 5
    assert Enum.any?(snapshot.media.provider_proofs.providers, &(&1.provider == "openai_vision"))

    image_proof = Enum.find(snapshot.media.provider_proofs.providers, &(&1.label == "image"))

    assert image_proof.command =~ "LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1"
    assert image_proof.command =~ "scripts/live_media_image_smoke.exs"
    assert image_proof.command =~ "--proof-path .lemon/proofs/media-image-smoke-latest.json"
    assert image_proof.secret_command =~ "scripts/live_media_image_smoke.exs"

    assert image_proof.secret_command =~
             "--proof-path .lemon/proofs/media-image-smoke-latest.json"

    assert image_proof.secret_command =~ "--api-key-secret SECRET_NAME"
    assert image_proof.proof_path == ".lemon/proofs/media-image-smoke-latest.json"
    assert image_proof.providers == ["openai_image", "vertex_imagen"]
    assert Enum.any?(image_proof.provider_commands, &(&1.provider == "vertex_imagen"))
    assert Enum.any?(image_proof.provider_commands, &(&1.command =~ "--provider vertex_imagen"))

    speech_proof = Enum.find(snapshot.media.provider_proofs.providers, &(&1.label == "TTS"))
    assert speech_proof.providers == ["openai_tts", "elevenlabs_tts", "google_tts"]
    assert Enum.any?(speech_proof.provider_commands, &(&1.command =~ "--provider google_tts"))

    video_proof = Enum.find(snapshot.media.provider_proofs.providers, &(&1.label == "video"))
    assert video_proof.providers == ["openai_video", "vertex_veo"]
    assert Enum.any?(video_proof.provider_commands, &(&1.command =~ "--provider vertex_veo"))

    assert is_list(snapshot.media.recent_jobs)
    assert is_map(snapshot.memory)
    assert snapshot.memory.provider_count >= 1
    assert snapshot.memory.enabled_provider_count >= 1
    assert Enum.any?(snapshot.memory.providers, &(&1.id == "local"))
    assert snapshot.memory.cleanup.includes_memory_contents == false
    assert snapshot.memory.cleanup.includes_raw_provider_config == false
    assert snapshot.memory.cleanup.includes_secret_values == false
    assert is_map(snapshot.proofs)
    assert is_integer(snapshot.proofs.proof_count)
    assert is_integer(snapshot.proofs.completed_count)
    assert is_integer(snapshot.proofs.failed_count)
    assert is_integer(snapshot.proofs.skipped_count)
    assert is_integer(snapshot.proofs.invalid_count)
    assert is_map(snapshot.proofs.reason_kind_counts)
    assert is_map(snapshot.proofs.proof_scope_counts)
    assert is_map(snapshot.proofs.check_name_counts)
    assert is_list(snapshot.proofs.latest_checks)
    assert is_list(snapshot.proofs.recent_proofs)
    assert snapshot.proofs.cleanup.includes_raw_paths == false
    assert snapshot.proofs.cleanup.includes_raw_filenames == false
    assert snapshot.proofs.cleanup.includes_raw_proof_details == false
    assert snapshot.proofs.cleanup.includes_raw_prompts == false
    assert snapshot.proofs.cleanup.includes_raw_provider_responses == false
    assert snapshot.proofs.cleanup.embeds_proof_file_contents == false
    assert is_list(snapshot.channels.failure_drilldown)
    assert is_map(snapshot.channels.readiness)
    assert snapshot.channels.readiness.promoted_platforms == ["telegram", "discord"]
    assert snapshot.channels.readiness.gate_count == 9
    assert is_integer(snapshot.channels.readiness.warning_count)
    assert snapshot.channels.readiness.cleanup.includes_raw_bot_tokens == false
    assert snapshot.channels.readiness.cleanup.includes_raw_proof_details == false

    assert Enum.any?(
             snapshot.channels.failure_drilldown,
             &(&1.id == "telegram_voice_transcription")
           )

    assert Enum.any?(snapshot.channels.failure_drilldown, &(&1.id == "discord_dm"))
    assert Enum.any?(snapshot.channels.failure_drilldown, &(&1.id == "discord_free_response"))
    assert Enum.any?(snapshot.channels.failure_drilldown, &(&1.id == "discord_reconnect"))

    telegram_voice_gate =
      Enum.find(snapshot.channels.failure_drilldown, &(&1.id == "telegram_voice_transcription"))

    assert telegram_voice_gate
    assert telegram_voice_gate.source == "proof_diagnostics"

    assert telegram_voice_gate.status in [
             "proven",
             "needs_proof",
             "configured",
             "blocked",
             "disabled"
           ]

    assert telegram_voice_gate.evidence =~ "provider"
    assert is_binary(telegram_voice_gate.next_action)

    discord_dm_gate = Enum.find(snapshot.channels.failure_drilldown, &(&1.id == "discord_dm"))

    assert discord_dm_gate
    assert discord_dm_gate.next_action =~ "--wait-dm-inbound"

    slash_gate =
      Enum.find(snapshot.channels.failure_drilldown, &(&1.id == "discord_slash_client"))

    assert slash_gate
    assert slash_gate.evidence =~ "deterministic local checks"

    assert is_map(snapshot.terminal_backends)
    assert snapshot.terminal_backends.count == 4
    assert snapshot.terminal_backends.default_backend == :local
    assert snapshot.terminal_backends.policy.backend_allowlist_configured == false
    assert :local in snapshot.terminal_backends.policy.allowed_backends
    assert snapshot.terminal_backends.policy.approval_required_backends == []
    terminal_backend = Enum.find(snapshot.terminal_backends.backends, &(&1.id == :local))
    terminal_pty_backend = Enum.find(snapshot.terminal_backends.backends, &(&1.id == :local_pty))
    terminal_docker_backend = Enum.find(snapshot.terminal_backends.backends, &(&1.id == :docker))
    terminal_ssh_backend = Enum.find(snapshot.terminal_backends.backends, &(&1.id == :ssh))
    assert terminal_backend.id == :local
    assert terminal_backend.transport == :erlang_port
    assert terminal_pty_backend.id == :local_pty
    assert terminal_pty_backend.pty == true
    assert terminal_docker_backend.id == :docker
    assert terminal_docker_backend.isolation == :container
    assert terminal_docker_backend.policy.requires_approval == false
    assert terminal_docker_backend.policy.docker.pull_policy == :never
    assert terminal_ssh_backend.id == :ssh
    assert terminal_ssh_backend.isolation == :remote_host
    assert terminal_ssh_backend.policy.ssh.allowed_targets_configured == false
    assert Map.has_key?(terminal_ssh_backend, :target_hash)
    assert snapshot.terminal_backends.cleanup.includes_commands == false
    assert snapshot.terminal_backends.cleanup.includes_environment == false
    assert snapshot.terminal_backends.cleanup.includes_process_output == false
    assert is_map(snapshot.lsp_diagnostics)
    assert snapshot.lsp_diagnostics.status == :preview
    assert snapshot.lsp_diagnostics.supported_language_count >= 6
    assert is_integer(snapshot.lsp_diagnostics.executable_summary.available_count)
    assert is_list(snapshot.lsp_diagnostics.supported_languages)
    assert snapshot.lsp_diagnostics.cleanup.includes_raw_paths == false
    assert snapshot.lsp_diagnostics.cleanup.includes_file_contents == false
    assert snapshot.lsp_diagnostics.cleanup.includes_diagnostics_output == false
    assert snapshot.lsp_diagnostics.cleanup.includes_workspace_roots == false
    assert snapshot.lsp_diagnostics.cleanup.includes_server_io == false
    assert snapshot.lsp_diagnostics.cleanup.includes_raw_session_ids == false
    assert snapshot.lsp_diagnostics.server_manager.running == true
    assert snapshot.lsp_diagnostics.server_manager.mode == :registry_and_sessions
    assert is_list(snapshot.lsp_diagnostics.server_manager.active_servers)
    assert is_list(snapshot.lsp_diagnostics.server_manager.recent_sessions)
    assert snapshot.lsp_diagnostics.server_manager.registry.count == 6
    assert is_map(snapshot.lsp_diagnostics.proofs)
    assert is_integer(snapshot.lsp_diagnostics.proofs.proof_count)
    assert is_integer(snapshot.lsp_diagnostics.proofs.check_count)
    assert is_list(snapshot.lsp_diagnostics.proofs.recent_proofs)
    assert is_list(snapshot.lsp_diagnostics.proofs.latest_checks)
    assert snapshot.lsp_diagnostics.proofs.cleanup.includes_raw_paths == false
    assert snapshot.lsp_diagnostics.proofs.cleanup.includes_raw_proof_details == false
    assert snapshot.lsp_diagnostics.proofs.error == nil

    assert snapshot.lsp_diagnostics.server_manager.registry.cleanup.includes_executable_paths ==
             false

    assert is_map(snapshot.provider)
    assert is_map(snapshot.config.defaults)
    assert is_list(snapshot.config.providers)
    assert is_list(snapshot.provider.checks)
    assert is_map(snapshot.provider.readiness)
    assert is_integer(snapshot.provider.readiness.count)
    assert is_integer(snapshot.provider.readiness.ready_count)
    assert is_list(snapshot.provider.readiness.providers)
    assert is_map(snapshot.provider.readiness.routing)
    assert is_list(snapshot.provider.readiness.routing.candidate_providers)
    assert is_map(snapshot.provider.readiness.routing.credential_pool)
    assert snapshot.provider.readiness.cleanup.includes_raw_api_keys == false
    assert snapshot.provider.readiness.cleanup.includes_secret_names == false
    assert snapshot.provider.readiness.cleanup.includes_raw_base_urls == false
    assert snapshot.provider.readiness.cleanup.includes_env_var_names == false
    assert is_map(snapshot.provider.live_proofs)
    assert is_map(snapshot.provider.live_proofs.fallback)

    assert snapshot.provider.live_proofs.fallback.status in [
             "missing",
             "proven",
             "skipped",
             "blocked",
             "unknown"
           ]

    assert snapshot.provider.live_proofs.cleanup.includes_raw_api_keys == false
    assert snapshot.provider.live_proofs.cleanup.includes_raw_prompts == false
    assert snapshot.provider.live_proofs.cleanup.includes_provider_answers == false
    assert is_map(snapshot.usage)
    assert snapshot.usage.status in ["unlimited", "within_limits", "over_limit", "unknown"]
    assert is_integer(snapshot.usage.total_requests)
    assert is_number(snapshot.usage.total_cost)
    assert is_map(snapshot.usage.total_tokens)
    assert is_integer(snapshot.usage.total_tokens.input)
    assert is_integer(snapshot.usage.total_tokens.output)
    assert is_integer(snapshot.usage.total_tokens.total)
    assert is_integer(snapshot.usage.provider_count)
    assert is_list(snapshot.usage.providers)
    assert is_map(snapshot.usage.today)
    assert is_map(snapshot.usage.quotas)
    assert snapshot.usage.cleanup.includes_prompts == false
    assert snapshot.usage.cleanup.includes_responses == false
    assert snapshot.usage.cleanup.includes_message_bodies == false
    assert snapshot.usage.cleanup.includes_credentials == false
    assert snapshot.usage.cleanup.includes_secret_values == false
    assert is_list(snapshot.active_sessions)
    assert is_list(snapshot.recent_runs)
    assert is_list(snapshot.pending_approvals)
    assert is_map(snapshot.readiness)
    assert snapshot.readiness.status in ["blocked", "warning", "ready", "failed", "unavailable"]
    assert snapshot.readiness.doctor.overall in ["pass", "warn", "fail", "unknown"]
    assert snapshot.readiness.channels.promoted_platforms == ["telegram", "discord"]
    assert is_integer(snapshot.readiness.channels.gate_count)
    assert is_integer(snapshot.readiness.proofs.proof_count)
    assert is_map(snapshot.readiness.proof_gates)
    assert is_map(snapshot.readiness.proof_gate_summary)
    assert Map.get(snapshot.readiness.proof_gate_summary, "gateCount") == 5
    assert Map.get(snapshot.readiness.proof_gate_summary, "statuses") |> is_map()
    assert is_list(snapshot.readiness.unresolved_gates)
    assert snapshot.readiness.cleanup.includes_raw_bot_tokens == false
    assert snapshot.readiness.cleanup.includes_secret_names == false
    assert snapshot.readiness.cleanup.includes_chat_ids == false
    assert snapshot.readiness.cleanup.includes_channel_ids == false
    assert snapshot.readiness.cleanup.includes_message_bodies == false
    assert snapshot.readiness.cleanup.includes_raw_proof_paths == false
    assert snapshot.readiness.cleanup.includes_raw_proof_details == false
    assert snapshot.readiness.cleanup.includes_raw_prompts == false
    assert snapshot.readiness.cleanup.includes_raw_provider_responses == false
    assert snapshot.readiness.cleanup.includes_secret_values == false
    assert is_integer(snapshot.activity.total_events)
    assert Enum.any?(snapshot.activity.categories, &(&1.category == "cron"))
    assert is_list(snapshot.cron.jobs)
    assert is_list(snapshot.cron.recent_runs)
    assert is_integer(snapshot.cron.active_run_count)
    assert is_integer(snapshot.cron.retry_run_count)
    assert is_integer(snapshot.cron.suppressed_run_count)
    assert is_integer(snapshot.cron.stale_recovery_count)
    assert is_integer(snapshot.cron.retry_scheduled_count)
    assert is_map(snapshot.extensions)
    assert snapshot.extensions.status in ["ok", "empty", "error"]
    assert is_integer(snapshot.extensions.directory_count)
    assert is_integer(snapshot.extensions.existing_directory_count)
    assert is_integer(snapshot.extensions.extension_file_count)
    assert is_integer(snapshot.extensions.manifest_count)
    assert is_integer(snapshot.extensions.valid_manifest_count)
    assert is_integer(snapshot.extensions.invalid_manifest_count)
    assert is_integer(snapshot.extensions.configured_extension_path_count)
    assert is_integer(snapshot.extensions.nested_lib_file_count)
    assert is_map(snapshot.extensions.capability_counts)
    assert is_map(snapshot.extensions.provider_type_counts)
    assert is_map(snapshot.extensions.host_type_counts)
    assert is_map(snapshot.extensions.distribution_source_counts)
    assert is_map(snapshot.extensions.audit_status_counts)
    assert is_list(snapshot.extensions.directories)
    assert is_map(snapshot.extensions.execution)
    assert snapshot.extensions.execution.enabled in [true, false]
    assert is_integer(snapshot.extensions.execution.configured_extension_path_count)
    assert is_integer(snapshot.extensions.execution.default_directory_count)
    assert snapshot.extensions.execution.auto_load_default_paths in [true, false]
    assert snapshot.extensions.execution.default_directories_diagnostics_only in [true, false]
    assert snapshot.extensions.execution.diagnostics_loads_extension_code == false
    assert is_map(snapshot.extensions.execution_telemetry)
    assert snapshot.extensions.execution_telemetry.proof_present in [true, false]
    assert snapshot.extensions.execution_telemetry.proof_status in ["completed", "missing", nil]
    assert is_integer(snapshot.extensions.execution_telemetry.completed_count)
    assert is_integer(snapshot.extensions.execution_telemetry.failed_count)

    assert snapshot.extensions.execution_telemetry.telemetry_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.execution_telemetry.disabled_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.execution_telemetry.env_disabled_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.execution_telemetry.emits_redacted_start_stop_exception in [
             true,
             false
           ]

    assert snapshot.extensions.execution_telemetry.blocks_disabled_explicit_paths in [
             true,
             false
           ]

    assert is_map(snapshot.extensions.execution_telemetry.redaction)
    assert snapshot.extensions.execution_telemetry.redaction.contains_raw_paths == false
    assert snapshot.extensions.execution_telemetry.redaction.contains_file_contents == false
    assert is_map(snapshot.extensions.wasm_telemetry)
    assert snapshot.extensions.wasm_telemetry.proof_present in [true, false]
    assert snapshot.extensions.wasm_telemetry.proof_status in ["completed", "missing", nil]
    assert is_integer(snapshot.extensions.wasm_telemetry.completed_count)
    assert is_integer(snapshot.extensions.wasm_telemetry.failed_count)

    assert snapshot.extensions.wasm_telemetry.success_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_telemetry.error_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_telemetry.exception_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_telemetry.redaction_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_telemetry.emits_redacted_start_stop_exception in [
             true,
             false
           ]

    assert is_map(snapshot.extensions.wasm_telemetry.host_boundary)
    assert is_integer(snapshot.extensions.wasm_telemetry.host_boundary.tool_count)
    assert is_map(snapshot.extensions.wasm_telemetry.redaction)
    assert snapshot.extensions.wasm_telemetry.redaction.contains_raw_paths == false
    assert snapshot.extensions.wasm_telemetry.redaction.contains_raw_params == false
    assert snapshot.extensions.wasm_telemetry.redaction.contains_raw_tool_call_ids == false
    assert snapshot.extensions.wasm_telemetry.redaction.contains_sidecar_error_text == false
    assert snapshot.extensions.wasm_telemetry.redaction.contains_tool_result_payload == false
    assert is_map(snapshot.extensions.wasm_policy)
    assert snapshot.extensions.wasm_policy.proof_present in [true, false]
    assert snapshot.extensions.wasm_policy.proof_status in ["completed", "missing", nil]
    assert is_integer(snapshot.extensions.wasm_policy.completed_count)
    assert is_integer(snapshot.extensions.wasm_policy.failed_count)

    assert snapshot.extensions.wasm_policy.http_check_status in ["completed", "missing", nil]

    assert snapshot.extensions.wasm_policy.tool_invoke_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_policy.exec_check_status in ["completed", "missing", nil]
    assert snapshot.extensions.wasm_policy.safe_check_status in ["completed", "missing", nil]
    assert snapshot.extensions.wasm_policy.override_check_status in ["completed", "missing", nil]

    assert snapshot.extensions.wasm_policy.capability_approval_defaults in [true, false]
    assert snapshot.extensions.wasm_policy.explicit_override_supported in [true, false]
    assert is_map(snapshot.extensions.wasm_policy.policy_boundary)

    assert snapshot.extensions.wasm_policy.policy_boundary.exec_requires_approval_by_default in [
             true,
             false
           ]

    assert is_map(snapshot.extensions.wasm_policy.redaction)
    assert snapshot.extensions.wasm_policy.redaction.contains_raw_paths == false
    assert snapshot.extensions.wasm_policy.redaction.contains_raw_params == false
    assert snapshot.extensions.wasm_policy.redaction.contains_raw_tool_call_ids == false
    assert is_map(snapshot.extensions.registry_audit)
    assert snapshot.extensions.registry_audit.proof_present in [true, false]
    assert snapshot.extensions.registry_audit.proof_status in ["completed", "missing", nil]
    assert is_integer(snapshot.extensions.registry_audit.completed_count)
    assert is_integer(snapshot.extensions.registry_audit.failed_count)

    assert snapshot.extensions.registry_audit.validate_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.registry_audit.block_check_status in ["completed", "missing", nil]
    assert snapshot.extensions.registry_audit.update_check_status in ["completed", "missing", nil]

    assert snapshot.extensions.registry_audit.no_code_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.registry_audit.redaction_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.registry_audit.registry_workflow_supported in [true, false]
    assert is_map(snapshot.extensions.registry_audit.registry_boundary)
    assert is_integer(snapshot.extensions.registry_audit.registry_boundary.installable_count)
    assert is_integer(snapshot.extensions.registry_audit.registry_boundary.blocked_count)
    assert is_integer(snapshot.extensions.registry_audit.registry_boundary.update_candidate_count)

    assert snapshot.extensions.registry_audit.registry_boundary.loads_extension_code in [
             true,
             false
           ]

    assert is_map(snapshot.extensions.registry_audit.redaction)
    assert snapshot.extensions.registry_audit.redaction.contains_raw_registry_paths == false
    assert snapshot.extensions.registry_audit.redaction.contains_distribution_urls == false
    assert snapshot.extensions.registry_audit.redaction.contains_package_names == false
    assert snapshot.extensions.registry_audit.redaction.contains_manifest_contents == false
    assert is_map(snapshot.extensions.wasm_lifecycle)
    assert snapshot.extensions.wasm_lifecycle.proof_present in [true, false]
    assert snapshot.extensions.wasm_lifecycle.proof_status in ["completed", "missing", nil]
    assert is_integer(snapshot.extensions.wasm_lifecycle.completed_count)
    assert is_integer(snapshot.extensions.wasm_lifecycle.failed_count)

    assert snapshot.extensions.wasm_lifecycle.discover_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_lifecycle.invoke_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_lifecycle.status_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_lifecycle.stop_check_status in ["completed", "missing", nil]

    assert snapshot.extensions.wasm_lifecycle.redaction_check_status in [
             "completed",
             "missing",
             nil
           ]

    assert snapshot.extensions.wasm_lifecycle.lifecycle_supported in [true, false]
    assert is_map(snapshot.extensions.wasm_lifecycle.lifecycle_boundary)
    assert is_integer(snapshot.extensions.wasm_lifecycle.lifecycle_boundary.tool_count)

    assert snapshot.extensions.wasm_lifecycle.lifecycle_boundary.stop_terminates_sidecar in [
             true,
             false
           ]

    assert is_map(snapshot.extensions.wasm_lifecycle.redaction)
    assert snapshot.extensions.wasm_lifecycle.redaction.contains_raw_cwd == false
    assert snapshot.extensions.wasm_lifecycle.redaction.contains_raw_session_ids == false
    assert snapshot.extensions.wasm_lifecycle.redaction.contains_raw_tool_names == false
    assert snapshot.extensions.wasm_lifecycle.redaction.contains_raw_params == false
    assert is_map(snapshot.extensions.host_runtime)
    assert is_map(snapshot.extensions.host_runtime.hosts)
    assert is_integer(snapshot.extensions.host_runtime.degraded_host_count)
    assert is_integer(snapshot.extensions.host_runtime.manifest_only_host_count)
    assert snapshot.extensions.host_runtime.runtime_health_loads_extension_code == false
    assert is_map(snapshot.extensions.cleanup)
    assert snapshot.extensions.cleanup.includes_raw_source_paths == false
    assert snapshot.extensions.cleanup.includes_file_contents == false
    assert snapshot.extensions.cleanup.includes_load_error_messages == false
    assert snapshot.extensions.cleanup.includes_manifest_contents == false
    assert snapshot.extensions.cleanup.includes_distribution_urls == false
    assert snapshot.extensions.cleanup.loads_extension_code == false
    assert is_list(snapshot.skills.checks)
    assert is_list(snapshot.channels.transports)
    assert snapshot.support.source_dev == "mix lemon.doctor --bundle"
  end

  test "operations dashboard exposes usage aggregates without prompt or secret fields" do
    today = Date.utc_today() |> Date.to_iso8601()
    previous_summary = LemonCore.UsageStore.get_summary(:current)
    previous_record = LemonCore.UsageStore.get_record(today)

    on_exit(fn ->
      restore_usage_summary(previous_summary)
      restore_usage_record(today, previous_record)
    end)

    LemonCore.UsageStore.put_summary(:current, %{
      total_cost: 0.1234,
      total_requests: 2,
      total_tokens: %{input: 100, output: 50},
      breakdown: %{"openai" => 0.1234},
      requests: %{"openai" => 2},
      tokens: %{"openai" => %{input: 100, output: 50}},
      prompt: "secret prompt",
      api_key: "secret-key"
    })

    LemonCore.UsageStore.put_record(today, %{
      date: today,
      total_cost: 0.1234,
      requests: %{"openai" => 2},
      breakdown: %{"openai" => 0.1234}
    })

    usage = LemonWeb.OpsDashboard.snapshot().usage

    assert usage.total_cost == 0.1234
    assert usage.total_requests == 2
    assert usage.total_tokens == %{input: 100, output: 50, total: 150}
    assert usage.provider_count == 1

    assert [%{provider: "openai", requests: 2, input_tokens: 100, output_tokens: 50}] =
             usage.providers

    assert usage.today.date == today
    assert usage.today.requests == 2
    assert usage.cleanup.includes_prompts == false
    assert usage.cleanup.includes_responses == false
    assert usage.cleanup.includes_credentials == false
    refute inspect(usage) =~ "secret prompt"
    refute inspect(usage) =~ "secret-key"
  end

  test "operations dashboard media provider proof next action reflects safe reason kind" do
    proof_dir = Path.join([File.cwd!(), ".lemon", "proofs"])
    File.mkdir_p!(proof_dir)
    path = Path.join(proof_dir, "web-media-provider-#{System.unique_integer()}-proof.json")

    File.write!(
      path,
      Jason.encode!(%{
        proof_object: "lemon.media_image_smoke",
        proof_scope: "media_provider",
        status: "failed",
        reason_kind: "vertex_imagen_http_error:permission_denied",
        details: %{
          provider: "vertex_imagen",
          raw_provider_response: "private provider response"
        },
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_provider_response: false
        }
      })
    )

    on_exit(fn -> File.rm(path) end)

    snapshot = LemonWeb.OpsDashboard.snapshot()
    image_proof = Enum.find(snapshot.media.provider_proofs.providers, &(&1.label == "image"))

    provider_media_gate =
      Enum.find(snapshot.readiness.unresolved_gates, &(&1.id == "provider_media"))

    assert image_proof.reason_kind == "vertex_imagen_http_error:permission_denied"
    assert "vertex_imagen_http_error:permission_denied" in provider_media_gate.reason_kinds
    assert image_proof.next_action =~ "image: enable provider API/IAM/billing permissions"
    assert image_proof.next_action =~ "scripts/live_media_image_smoke.exs"
    refute inspect(image_proof) =~ "private provider response"
  end

  test "operations dashboard channel drilldown reports Discord Message Content Intent drift" do
    proof_dir = Path.join([File.cwd!(), ".lemon", "proofs"])
    File.mkdir_p!(proof_dir)
    path = Path.join(proof_dir, "web-discord-free-response-#{System.unique_integer()}-proof.json")

    File.write!(
      path,
      Jason.encode!(%{
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        status: "failed",
        checks: [
          %{
            name: "discord_free_response_trigger_round_trip",
            status: "failed",
            reason_kind: "discord_message_content_intent_or_delivery",
            failure_hint: "message_content_intent_declared=false"
          }
        ],
        details: %{reason_kind: "discord_message_content_intent_or_delivery"},
        cleanup: %{
          includes_raw_paths: false,
          includes_raw_filenames: false,
          includes_raw_proof_details: false,
          includes_raw_prompts: false,
          includes_raw_provider_responses: false,
          embeds_proof_file_contents: false
        }
      })
    )

    on_exit(fn -> File.rm(path) end)

    snapshot = LemonWeb.OpsDashboard.snapshot()
    gate = Enum.find(snapshot.channels.failure_drilldown, &(&1.id == "discord_free_response"))

    assert gate.status == "blocked"
    assert gate.evidence =~ "Message Content Intent/delivery failures classified"
    assert gate.evidence =~ "runtime requests intent:"
    assert gate.next_action =~ "Message Content Intent"
  end

  test "operations dashboard channel drilldown reports missing Discord slash client-click proof" do
    proof_dir = Path.join([File.cwd!(), ".lemon", "proofs"])
    File.mkdir_p!(proof_dir)
    path = Path.join(proof_dir, "web-discord-slash-client-#{System.unique_integer()}-proof.json")

    File.write!(
      path,
      Jason.encode!(%{
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        status: "failed",
        checks: [
          %{
            name: "discord_slash_client_click_proof_artifact",
            status: "failed",
            reason_kind: "discord_slash_client_click_missing"
          }
        ],
        details: %{reason_kind: "discord_slash_client_click_missing"},
        cleanup: %{
          includes_raw_paths: false,
          includes_raw_filenames: false,
          includes_raw_proof_details: false,
          includes_raw_prompts: false,
          includes_raw_provider_responses: false,
          embeds_proof_file_contents: false
        }
      })
    )

    on_exit(fn -> File.rm(path) end)

    snapshot = LemonWeb.OpsDashboard.snapshot()
    gate = Enum.find(snapshot.channels.failure_drilldown, &(&1.id == "discord_slash_client"))

    assert gate.status == "needs_proof"
    assert gate.evidence =~ "missing client-click proof artifacts classified"

    assert gate.next_action =~
             "--wait-slash-client-click-proof"

    assert gate.next_action =~
             "--proof-path .lemon/proofs/discord-slash-client-click-check-latest.json"
  end

  test "operations dashboard proof list exposes MEDIA directive delivery diagnostics" do
    proof_dir = Path.join([File.cwd!(), ".lemon", "proofs"])
    File.mkdir_p!(proof_dir)
    path = Path.join(proof_dir, "web-media-directive-#{System.unique_integer()}-proof.json")

    File.write!(
      path,
      Jason.encode!(%{
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        status: "completed",
        completed_count: 1,
        failed_count: 0,
        skipped_count: 0,
        coverage: %{
          contains_media_directive: true,
          contains_file_delivery: true
        },
        checks: [
          %{
            name: "discord_media_directive_delivery",
            status: "completed",
            marker_seen: true,
            directive_leaked: false,
            attachment_count: 1
          }
        ],
        cleanup: %{
          includes_raw_paths: false,
          includes_raw_filenames: false,
          includes_raw_proof_details: false,
          includes_raw_prompts: false,
          includes_raw_provider_responses: false,
          embeds_proof_file_contents: false
        }
      })
    )

    on_exit(fn -> File.rm(path) end)

    snapshot = LemonWeb.OpsDashboard.snapshot()

    proof =
      Enum.find(
        snapshot.proofs.recent_proofs,
        &(&1.proof_object == "lemon.discord_live_matrix" and
            get_in(&1, [:media_proof, :media_directive_delivery]) == true)
      )

    assert proof.media_proof.discord_delivery == true
    assert proof.media_proof.discord_attachment_count == 1
    assert proof.media_proof.directive_leaked == false
    assert proof.coverage.contains_media_directive == true
  end

  test "operations dashboard proof list preserves redaction-only proof diagnostics" do
    proof_dir = Path.join([File.cwd!(), ".lemon", "proofs"])
    File.mkdir_p!(proof_dir)
    path = Path.join(proof_dir, "web-wasm-lifecycle-#{System.unique_integer()}-proof.json")

    File.write!(
      path,
      Jason.encode!(%{
        proof: "wasm_lifecycle_smoke",
        status: "completed",
        completed_count: 5,
        failed_count: 0,
        skipped_count: 0,
        details: %{
          raw_cwd: "/private/web/ops/project",
          raw_session_id: "private-session-id"
        },
        checks: [
          %{name: "wasm_lifecycle_stop_terminates_sidecar", status: "completed"}
        ],
        redaction: %{
          contains_raw_cwd: false,
          contains_raw_session_ids: false,
          contains_raw_tool_names: false,
          contains_raw_params: false
        }
      })
    )

    on_exit(fn -> File.rm(path) end)

    snapshot = LemonWeb.OpsDashboard.snapshot()

    proof =
      Enum.find(
        snapshot.proofs.recent_proofs,
        &(&1.proof_object == "wasm_lifecycle_smoke")
      )

    assert proof.status == "completed"
    assert proof.redaction["contains_raw_cwd"] == false
    assert proof.redaction["contains_raw_session_ids"] == false
    assert proof.redaction["contains_raw_tool_names"] == false
    assert proof.redaction["contains_raw_params"] == false
    assert proof.cleanup == %{}
    refute inspect(proof) =~ "/private/web/ops/project"
    refute inspect(proof) =~ "private-session-id"
  end

  test "operations dashboard redacts goal objective and session keys" do
    token = System.unique_integer([:positive, :monotonic])
    session_key = "web_ops_goal_session_#{token}"
    objective = "secret web ops goal #{token}"

    on_exit(fn -> LemonCore.GoalStore.clear(session_key) end)

    assert {:ok, _goal} = LemonCore.GoalStore.set(session_key, objective, agent_id: "web")

    snapshot = LemonWeb.OpsDashboard.snapshot()
    rendered = inspect(snapshot.goals)

    assert Enum.any?(
             snapshot.goals.recent,
             &(&1.agent_id == "web" and &1.objective_bytes == byte_size(objective))
           )

    refute rendered =~ objective
    refute rendered =~ session_key
  end

  test "operations dashboard exposes checkpoint rollback guidance without raw paths" do
    token = System.unique_integer([:positive, :monotonic])
    checkpoint_id = "web_ops_checkpoint_#{token}"
    checkpoint_dir = Path.join(System.tmp_dir!(), "lemon_checkpoints")
    checkpoint_path = Path.join(checkpoint_dir, "#{checkpoint_id}.json")
    secret_path = "/private/web/ops/#{token}.txt"
    secret_session = "web_ops_secret_session_#{token}"

    File.mkdir_p!(checkpoint_dir)

    File.write!(
      checkpoint_path,
      Jason.encode!(%{
        id: checkpoint_id,
        session_id: secret_session,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        metadata: %{
          kind: "filesystem",
          tool: "exec",
          action: "risky_shell",
          path_count: 1
        },
        state: %{
          filesystem: %{
            files: [
              %{path: secret_path, content_b64: Base.encode64("secret checkpoint content")}
            ]
          }
        }
      })
    )

    on_exit(fn -> File.rm(checkpoint_path) end)

    snapshot = LemonWeb.OpsDashboard.snapshot()
    rendered = inspect(snapshot.checkpoints)

    checkpoint = Enum.find(snapshot.checkpoints.recent, &(&1.checkpoint_id == checkpoint_id))

    assert checkpoint.rollback.tui_diff == "/checkpoint diff #{checkpoint_id}"
    assert checkpoint.rollback.tui_restore == "/checkpoint restore #{checkpoint_id}"
    assert checkpoint.rollback.control_plane_diff =~ ~s("method":"checkpoint.diff")
    assert checkpoint.rollback.control_plane_restore =~ ~s("method":"checkpoint.restore")
    refute rendered =~ secret_path
    refute rendered =~ secret_session
    refute rendered =~ "secret checkpoint content"
  end

  test "operations dashboard can preview and restore checkpoints through core" do
    token = System.unique_integer([:positive, :monotonic])
    session_id = "web_ops_restore_session_#{token}"
    tmp_dir = Path.join(System.tmp_dir!(), "lemon_web_restore_#{token}")
    path = Path.join(tmp_dir, "target.txt")

    File.mkdir_p!(tmp_dir)
    File.write!(path, "before\n")

    assert {:ok, checkpoint} =
             LemonCore.Checkpoint.create_filesystem(session_id, [path],
               cwd: tmp_dir,
               tool: "web-ops"
             )

    on_exit(fn ->
      LemonCore.Checkpoint.delete_all(session_id)
      File.rm_rf!(tmp_dir)
    end)

    File.write!(path, "after\n")

    assert {:ok, preview} = LemonWeb.OpsDashboard.checkpoint_diff(checkpoint.id)
    assert preview.checkpoint_id == checkpoint.id
    assert preview.changed_count == 1
    assert preview.output =~ "-before"
    assert preview.output =~ "+after"

    assert {:ok, restored} = LemonWeb.OpsDashboard.checkpoint_restore(checkpoint.id)
    assert restored.restored_count == 1
    assert File.read!(path) == "before\n"
  end

  test "operations dashboard exposes kanban state without task text or session keys" do
    token = System.unique_integer([:positive, :monotonic])
    task_description = "secret kanban description #{token}"
    comment = "secret kanban comment #{token}"
    session_key = "secret_kanban_session_#{token}"

    assert {:ok, board} =
             LemonCore.KanbanStore.create_board("Web ops board",
               workspace: "/tmp/lemon-web-kanban-#{token}",
               owner: "web"
             )

    assert {:ok, task} =
             LemonCore.KanbanStore.create_task(board.id, "Secret title #{token}",
               description: task_description,
               session_key: session_key,
               worker_profile: "senior"
             )

    assert {:ok, _task} = LemonCore.KanbanStore.add_comment(task.id, comment, author: "web")

    on_exit(fn -> LemonCore.KanbanStore.clear_board(board.id) end)

    snapshot = LemonWeb.OpsDashboard.snapshot()
    rendered = inspect(snapshot.kanban)

    assert Enum.any?(snapshot.kanban.recent_boards, &(&1.board_id == board.id))
    assert rendered =~ board.id
    refute rendered =~ task_description
    refute rendered =~ comment
    refute rendered =~ session_key
    refute rendered =~ "Secret title #{token}"
  end

  test "operations dashboard exposes cron, skill, and channel support panels" do
    token = System.unique_integer([:positive, :monotonic])
    job_id = "web_ops_cron_#{token}"
    run_id = "web_ops_cron_run_#{token}"
    active_run_id = "web_ops_cron_active_run_#{token}"
    audit_id = "web_ops_cron_audit_#{token}"
    suppressed_audit_id = "web_ops_cron_suppressed_audit_#{token}"
    stale_audit_id = "web_ops_cron_stale_audit_#{token}"
    retry_audit_id = "web_ops_cron_retry_audit_#{token}"
    now = System.system_time(:millisecond)

    :ok =
      LemonCore.Store.put(:cron_jobs, job_id, %{
        id: job_id,
        name: "Web ops cron",
        schedule: "*/15 * * * *",
        enabled: true,
        agent_id: "default",
        session_key: "agent:web:cron",
        timezone: "UTC",
        created_at_ms: now,
        updated_at_ms: now,
        next_run_at_ms: now + 60_000
      })

    :ok =
      LemonCore.Store.put(:cron_runs, active_run_id, %{
        id: active_run_id,
        job_id: job_id,
        run_id: "router_active_run_#{token}",
        status: :running,
        triggered_by: :schedule,
        started_at_ms: now - 1_000,
        meta: %{retry_attempt: 0}
      })

    :ok =
      LemonCore.Store.put(:cron_runs, run_id, %{
        id: run_id,
        job_id: job_id,
        run_id: "router_run_#{token}",
        status: :failed,
        triggered_by: :manual,
        started_at_ms: now,
        completed_at_ms: now + 100,
        meta: %{retry_attempt: 1},
        error: "test failure"
      })

    :ok =
      LemonCore.Store.put(:cron_audit_events, suppressed_audit_id, %{
        id: suppressed_audit_id,
        action: "scheduled_run_suppressed",
        ts_ms: now - 300,
        job_id: job_id,
        source: "cron_manager",
        triggered_by: "schedule",
        reason: "active_run_exists"
      })

    :ok =
      LemonCore.Store.put(:cron_audit_events, stale_audit_id, %{
        id: stale_audit_id,
        action: "stale_run_recovered",
        ts_ms: now - 200,
        job_id: job_id,
        run_id: active_run_id,
        source: "cron_manager",
        status: "timeout",
        triggered_by: "schedule"
      })

    :ok =
      LemonCore.Store.put(:cron_audit_events, retry_audit_id, %{
        id: retry_audit_id,
        action: "retry_scheduled",
        ts_ms: now - 100,
        job_id: job_id,
        run_id: run_id,
        source: "cron_manager",
        status: "failed",
        triggered_by: "schedule"
      })

    :ok =
      LemonCore.Store.put(:cron_audit_events, audit_id, %{
        id: audit_id,
        action: "run_aborted",
        ts_ms: now + 200,
        job_id: job_id,
        run_id: run_id,
        router_run_id: "router_run_#{token}",
        source: "cron_manager",
        status: "aborted",
        triggered_by: "manual",
        changed_fields: ["enabled"]
      })

    snapshot = LemonWeb.OpsDashboard.snapshot()
    cron_job = Enum.find(snapshot.cron.jobs, &(&1.id == job_id))

    assert cron_job.enabled?
    assert cron_job.latest_run_status == "failed"
    assert cron_job.latest_run_triggered_by == "manual"
    assert cron_job.latest_run_retry_attempt == 1
    assert [%{id: ^run_id, status: "failed", retry_attempt: 1} | _] = cron_job.recent_runs
    assert Enum.any?(snapshot.cron.recent_runs, &(&1.id == run_id and &1.status == "failed"))
    assert snapshot.cron.active_run_count >= 1
    assert snapshot.cron.retry_run_count >= 1
    assert snapshot.cron.suppressed_run_count >= 1
    assert snapshot.cron.stale_recovery_count >= 1
    assert snapshot.cron.retry_scheduled_count >= 1
    assert cron_job.next_run_at_ms == now + 60_000
    assert is_integer(snapshot.cron.next_run_at_ms)
    assert snapshot.cron.last_run_at_ms == now

    assert [%{id: ^audit_id, action: "run_aborted", status: "aborted"} | _] =
             snapshot.cron.recent_audit_events

    assert snapshot.cron.failed_run_count >= 1
    assert Enum.any?(snapshot.skills.checks, &(&1.name == "skills.directory"))
    assert Enum.any?(snapshot.channels.transports, &(&1.name == "telegram"))

    LemonCore.Store.delete(:cron_jobs, job_id)
    LemonCore.Store.delete(:cron_runs, run_id)
    LemonCore.Store.delete(:cron_runs, active_run_id)
    LemonCore.Store.delete(:cron_audit_events, audit_id)
    LemonCore.Store.delete(:cron_audit_events, suppressed_audit_id)
    LemonCore.Store.delete(:cron_audit_events, stale_audit_id)
    LemonCore.Store.delete(:cron_audit_events, retry_audit_id)
  end

  test "operations dashboard groups support-critical activity from introspection" do
    token = System.unique_integer([:positive, :monotonic])
    now = System.system_time(:millisecond)

    events = [
      {:cron_run_started, %{job_id: "cron_#{token}"}},
      {:skill_loaded, %{skill: "repo-map"}},
      {:channel_message_received, %{channel: "telegram"}},
      {:memory_search_completed, %{query: "setup"}},
      {:log_warning, %{message: "provider retry"}}
    ]

    Enum.with_index(events, fn {event_type, payload}, idx ->
      LemonCore.Introspection.record(event_type, payload,
        run_id: "web_ops_activity_#{token}_#{idx}",
        session_key: "agent:web:activity:#{token}",
        agent_id: "web",
        engine: "echo",
        ts_ms: now + idx
      )
    end)

    categories =
      LemonWeb.OpsDashboard.snapshot().activity.categories
      |> Map.new(&{&1.category, &1.count})

    assert categories["cron"] >= 1
    assert categories["skills"] >= 1
    assert categories["channels"] >= 1
    assert categories["memory"] >= 1
    assert categories["logs"] >= 1
  end

  test "operations run detail summarizes timeline, tools, failures, and children" do
    token = System.unique_integer([:positive, :monotonic])
    run_id = "web_ops_run_#{token}"
    child_run_id = "web_ops_child_#{token}"
    grandchild_run_id = "web_ops_grandchild_#{token}"
    session_key = "agent:web:#{token}"
    now = System.system_time(:millisecond)

    :ok =
      LemonCore.Introspection.record(:run_started, %{phase: :start},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now
      )

    :ok =
      LemonCore.Introspection.record(:tool_completed, %{tool_name: "bash", result_preview: "ok"},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 1
      )

    :ok =
      LemonCore.Introspection.record(:tool_completed, %{tool_name: "grep", error: "missing"},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 2
      )

    :ok =
      LemonCore.Introspection.record(
        :skill_load_observed,
        %{skill_key: "repo-map", status: "loaded"},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 3
      )

    :ok =
      LemonCore.Introspection.record(
        :memory_search_completed,
        %{scope: "current", result_count: 2},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 4
      )

    :ok =
      LemonCore.Introspection.record(
        :channel_message_received,
        %{channel: "telegram", peer_kind: "topic"},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 5
      )

    :ok =
      LemonCore.Introspection.record(
        :cron_run_completed,
        %{cron_run_id: "cron_run_#{token}", job_id: "cron_job_#{token}", status: :completed},
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 6
      )

    :ok =
      LemonCore.Introspection.record(
        :tool_completed,
        %{
          tool_name: "agent",
          result_preview: "delegated task queued",
          result_meta: %{task_id: "task_#{token}", run_id: child_run_id}
        },
        run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 7
      )

    :ok =
      LemonCore.Introspection.record(:run_started, %{phase: :child},
        run_id: child_run_id,
        parent_run_id: run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 8
      )

    :ok =
      LemonCore.Introspection.record(:run_started, %{phase: :grandchild},
        run_id: grandchild_run_id,
        parent_run_id: child_run_id,
        session_key: session_key,
        agent_id: "web",
        engine: "echo",
        ts_ms: now + 9
      )

    detail = LemonWeb.OpsDashboard.run_detail(run_id)

    assert detail.summary.run_id == run_id
    assert detail.summary.status == "active or incomplete"
    assert length(detail.events) == 8
    assert length(detail.tool_events) == 3

    assert Enum.map(detail.learning_events, & &1.event_type) == [
             "skill_load_observed",
             "memory_search_completed"
           ]

    assert [%{event_type: "channel_message_received", preview: channel_preview}] =
             detail.channel_events

    assert channel_preview.channel == "telegram"

    assert [%{event_type: "cron_run_completed", preview: cron_preview}] = detail.cron_events
    assert cron_preview.status == :completed

    assert [%{tool: "agent", preview: "delegated task queued"}] = detail.subagent_events

    assert [%{tool: "grep"}] = detail.failures
    assert [%{run_id: ^child_run_id, status: "started"}] = detail.children

    assert [%{run_id: ^child_run_id, children: [%{run_id: ^grandchild_run_id}]}] =
             detail.graph.children
  end

  test "operations run detail exposes structured approval metadata for one run" do
    token = System.unique_integer([:positive, :monotonic])
    run_id = "web_ops_run_approvals_#{token}"
    oauth_id = "web_ops_run_oauth_#{token}"
    sampling_id = "web_ops_run_sampling_#{token}"

    LemonCore.ExecApprovalStore.put_pending(oauth_id, %{
      id: oauth_id,
      run_id: run_id,
      session_key: "agent:web:run-approval",
      agent_id: "web",
      tool: "mcp_mcp_oauth",
      action: %{
        type: "mcp_oauth_authorization",
        authorization_url: "http://127.0.0.1:9090/oauth?state=state",
        resource: "http://127.0.0.1:9090/mcp",
        redirect_uri: "http://127.0.0.1:9191/callback",
        scope: "tools"
      },
      rationale: "MCP OAuth authorization required",
      requested_at_ms: LemonCore.Clock.now_ms(),
      expires_at_ms: nil
    })

    LemonCore.ExecApprovalStore.put_pending(sampling_id, %{
      id: sampling_id,
      run_id: run_id,
      session_key: "agent:web:run-approval",
      agent_id: "web",
      tool: "mcp_elixir_sampling",
      action: %{
        type: "mcp_sampling",
        request_hash: "abc123",
        message_count: 1,
        roles: ["user"],
        content_kinds: %{"text" => 1},
        text_char_count: 13,
        max_tokens: 16,
        requested_model: "lemon-test"
      },
      rationale: "MCP sampling request",
      requested_at_ms: LemonCore.Clock.now_ms(),
      expires_at_ms: nil
    })

    detail = LemonWeb.OpsDashboard.run_detail(run_id)

    assert Enum.find(detail.pending_approvals, &(&1.id == oauth_id)).action.authorization_url =~
             "/oauth"

    sampling = Enum.find(detail.pending_approvals, &(&1.id == sampling_id))
    assert sampling.action.type == "mcp_sampling"
    assert sampling.action.request_hash == "abc123"
    assert sampling.action.requested_model == "lemon-test"
    refute inspect(sampling) =~ "secret prompt"

    assert :ok = LemonCore.ExecApprovals.resolve(oauth_id, :deny)
    assert :ok = LemonCore.ExecApprovals.resolve(sampling_id, :deny)
  end

  test "operations run detail resolves pending approvals for one run" do
    run_id = "run_web_ops_detail_resolve_#{System.unique_integer([:positive, :monotonic])}"
    approval_id = "web_ops_detail_resolve_#{System.unique_integer([:positive, :monotonic])}"

    LemonCore.ExecApprovalStore.put_pending(approval_id, %{
      id: approval_id,
      run_id: run_id,
      session_key: "agent:web:detail-resolve",
      agent_id: "web",
      tool: "bash",
      action: %{cmd: "echo ok"},
      rationale: "run detail approval",
      requested_at_ms: LemonCore.Clock.now_ms(),
      expires_at_ms: nil
    })

    assert Enum.any?(
             LemonWeb.OpsDashboard.run_detail(run_id).pending_approvals,
             &(&1.id == approval_id)
           )

    socket = %Phoenix.LiveView.Socket{assigns: %{run_id: run_id, flash: %{}, __changed__: %{}}}

    assert {:noreply, socket} =
             LemonWeb.OpsRunLive.handle_event(
               "resolve-approval",
               %{"id" => approval_id, "decision" => "approve_once"},
               socket
             )

    refute Enum.any?(socket.assigns.detail.pending_approvals, &(&1.id == approval_id))

    assert [%{event_type: "approval_resolved", tool: "bash", preview: preview}] =
             socket.assigns.detail.approval_events

    assert preview.approval_id == approval_id
    assert preview.decision == "approve_once"

    refute Enum.any?(
             LemonWeb.OpsDashboard.run_detail(run_id).pending_approvals,
             &(&1.id == approval_id)
           )
  end

  test "operations dashboard exposes and resolves non-expiring approvals" do
    approval_id = "web_ops_approval_#{System.unique_integer([:positive, :monotonic])}"

    LemonCore.ExecApprovalStore.put_pending(approval_id, %{
      id: approval_id,
      run_id: "run_web_ops_approval",
      session_key: "agent:web:approval",
      agent_id: "web",
      tool: "bash",
      action: %{cmd: "echo ok"},
      rationale: "test approval",
      requested_at_ms: LemonCore.Clock.now_ms(),
      expires_at_ms: nil
    })

    snapshot = LemonWeb.OpsDashboard.snapshot()

    assert Enum.any?(snapshot.pending_approvals, &(&1.id == approval_id))
    assert :ok = LemonWeb.OpsDashboard.resolve_approval(approval_id, "approve_once")
    refute Enum.any?(LemonWeb.OpsDashboard.snapshot().pending_approvals, &(&1.id == approval_id))
  end

  test "operations dashboard exposes MCP OAuth authorization approval metadata" do
    approval_id = "web_ops_oauth_approval_#{System.unique_integer([:positive, :monotonic])}"
    authorization_url = "http://127.0.0.1:9090/oauth?state=state"

    LemonCore.ExecApprovalStore.put_pending(approval_id, %{
      id: approval_id,
      run_id: "run_web_ops_oauth_approval",
      session_key: "agent:web:oauth",
      agent_id: "web",
      tool: "mcp_mcp_oauth",
      action: %{
        type: "mcp_oauth_authorization",
        authorization_url: authorization_url,
        resource: "http://127.0.0.1:9090/mcp",
        redirect_uri: "http://127.0.0.1:9191/callback",
        scope: "tools"
      },
      rationale: "MCP OAuth authorization required",
      requested_at_ms: LemonCore.Clock.now_ms(),
      expires_at_ms: nil
    })

    approval =
      Enum.find(LemonWeb.OpsDashboard.snapshot().pending_approvals, &(&1.id == approval_id))

    assert approval.tool == "mcp_mcp_oauth"
    assert approval.action.authorization_url == authorization_url
    assert approval.action.type == "mcp_oauth_authorization"
    assert approval.action.redirect_uri == "http://127.0.0.1:9191/callback"

    assert :ok = LemonWeb.OpsDashboard.resolve_approval(approval_id, "deny")
  end

  test "operations dashboard exposes MCP sampling approval metadata" do
    approval_id = "web_ops_sampling_approval_#{System.unique_integer([:positive, :monotonic])}"

    LemonCore.ExecApprovalStore.put_pending(approval_id, %{
      id: approval_id,
      run_id: "run_web_ops_sampling_approval",
      session_key: "agent:web:sampling",
      agent_id: "web",
      tool: "mcp_elixir_sampling",
      action: %{
        type: "mcp_sampling",
        server: "elixir",
        request_hash: "abc123",
        message_count: 1,
        roles: ["user"],
        content_kinds: %{"text" => 1},
        text_char_count: 13,
        max_tokens: 16,
        requested_model: "lemon-test"
      },
      rationale: "MCP sampling request",
      requested_at_ms: LemonCore.Clock.now_ms(),
      expires_at_ms: nil
    })

    approval =
      Enum.find(LemonWeb.OpsDashboard.snapshot().pending_approvals, &(&1.id == approval_id))

    assert approval.tool == "mcp_elixir_sampling"
    assert approval.action.type == "mcp_sampling"
    assert approval.action.request_hash == "abc123"
    assert approval.action.message_count == 1
    assert approval.action.roles == ["user"]
    assert approval.action.content_kinds == %{"text" => 1}
    assert approval.action.text_char_count == 13
    assert approval.action.max_tokens == 16
    assert approval.action.requested_model == "lemon-test"
    refute inspect(approval) =~ "secret prompt"

    assert :ok = LemonWeb.OpsDashboard.resolve_approval(approval_id, "deny")
  end

  test "operations dashboard can toggle and run existing cron schedules" do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      LemonAutomation.CronManager.add(%{
        name: "web ops controllable cron #{token}",
        schedule: "0 0 1 1 *",
        enabled: false,
        agent_id: "web_ops_cron_#{token}",
        session_key: "agent:web_ops_cron_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    on_exit(fn -> _ = LemonAutomation.CronManager.remove(job.id) end)

    assert Enum.any?(LemonWeb.OpsDashboard.snapshot().cron.jobs, &(&1.id == job.id))

    assert :ok = LemonWeb.OpsDashboard.set_cron_enabled(job.id, true)

    assert Enum.any?(
             LemonWeb.OpsDashboard.snapshot().cron.jobs,
             &(&1.id == job.id and &1.enabled?)
           )

    assert :ok = LemonWeb.OpsDashboard.run_cron_now(job.id)
    assert Enum.any?(LemonWeb.OpsDashboard.snapshot().cron.recent_runs, &(&1.job_id == job.id))

    assert :ok = LemonWeb.OpsDashboard.set_cron_enabled(job.id, false)

    assert Enum.any?(
             LemonWeb.OpsDashboard.snapshot().cron.jobs,
             &(&1.id == job.id and not &1.enabled?)
           )
  end

  test "operations dashboard can abort active cron runs" do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      LemonAutomation.CronManager.add(%{
        name: "web ops abortable cron #{token}",
        schedule: "0 0 1 1 *",
        enabled: false,
        agent_id: "web_ops_cron_abort_#{token}",
        session_key: "agent:web_ops_cron_abort_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    run =
      job.id
      |> LemonAutomation.CronRun.new(:manual)
      |> Map.put(:id, "web_ops_cron_abort_run_#{token}")
      |> LemonAutomation.CronRun.start("web_ops_router_abort_#{token}")

    LemonAutomation.CronStore.put_run(run)

    on_exit(fn ->
      LemonAutomation.CronStore.delete_run(run.id)
      _ = LemonAutomation.CronManager.remove(job.id)
    end)

    snapshot = LemonWeb.OpsDashboard.snapshot()
    cron_job = Enum.find(snapshot.cron.jobs, &(&1.id == job.id))
    assert [%{id: run_id, status: "running"}] = cron_job.recent_runs
    assert run_id == run.id

    assert :ok = LemonWeb.OpsDashboard.abort_cron_run(run.id)
    assert LemonAutomation.CronStore.get_run(run.id).status == :aborted

    snapshot = LemonWeb.OpsDashboard.snapshot()
    cron_job = Enum.find(snapshot.cron.jobs, &(&1.id == job.id))
    assert [%{id: ^run_id, status: "aborted"}] = cron_job.recent_runs
  end

  test "operations dashboard can create, edit, and delete cron schedules" do
    token = System.unique_integer([:positive, :monotonic])
    name = "web ops created cron #{token}"

    assert :ok =
             LemonWeb.OpsDashboard.create_cron_job(%{
               "name" => name,
               "schedule" => "0 6 * * *",
               "agent_id" => "web_ops_created_#{token}",
               "session_key" => "agent:web_ops_created_#{token}:main",
               "prompt" => "first prompt",
               "timezone" => "UTC",
               "max_retries" => "1",
               "retry_backoff_ms" => "5000",
               "enabled" => "true"
             })

    job =
      LemonWeb.OpsDashboard.snapshot().cron.jobs
      |> Enum.find(&(&1.name == name))

    assert job.schedule == "0 6 * * *"
    assert job.enabled?
    assert job.max_retries == 1
    assert job.retry_backoff_ms == 5_000

    assert :ok =
             LemonWeb.OpsDashboard.update_cron_job(job.id, %{
               "name" => "#{name} updated",
               "schedule" => "30 7 * * 1",
               "prompt" => "updated prompt",
               "timezone" => "UTC",
               "max_retries" => "2",
               "retry_backoff_ms" => "10000"
             })

    job =
      LemonWeb.OpsDashboard.snapshot().cron.jobs
      |> Enum.find(&(&1.id == job.id))

    assert job.name == "#{name} updated"
    assert job.schedule == "30 7 * * 1"
    assert job.max_retries == 2
    assert job.retry_backoff_ms == 10_000

    assert :ok = LemonWeb.OpsDashboard.delete_cron_job(job.id)

    refute Enum.any?(LemonWeb.OpsDashboard.snapshot().cron.jobs, &(&1.id == job.id))
  end

  test "operations dashboard can install and update skills through installer" do
    token = System.unique_integer([:positive, :monotonic])
    old_agent_dir = System.get_env("LEMON_AGENT_DIR")
    old_approval = Application.fetch_env(:lemon_skills, :require_approval)
    tmp_dir = Path.join(System.tmp_dir!(), "lemon-web-skill-install-#{token}")
    agent_dir = Path.join(tmp_dir, "agent")
    skill_key = "web-install-skill-#{token}"
    source_dir = Path.join(tmp_dir, skill_key)

    System.put_env("LEMON_AGENT_DIR", agent_dir)
    Application.put_env(:lemon_skills, :require_approval, true)
    File.mkdir_p!(source_dir)

    File.write!(
      Path.join(source_dir, "SKILL.md"),
      """
      ---
      name: #{skill_key}
      description: Web install v1
      version: 1.0.0
      ---

      install v1
      """
    )

    on_exit(fn ->
      case old_agent_dir do
        nil -> System.delete_env("LEMON_AGENT_DIR")
        value -> System.put_env("LEMON_AGENT_DIR", value)
      end

      case old_approval do
        {:ok, value} -> Application.put_env(:lemon_skills, :require_approval, value)
        :error -> Application.delete_env(:lemon_skills, :require_approval)
      end

      File.rm_rf(tmp_dir)
      LemonSkills.Registry.refresh()
    end)

    LemonSkills.Registry.refresh()

    assert :ok = LemonWeb.OpsDashboard.install_skill(source_dir, global: true)

    skill =
      LemonWeb.OpsDashboard.snapshot().skills.entries
      |> Enum.find(&(&1.key == skill_key))

    assert skill.description == "Web install v1"
    assert skill.source_kind == "local"
    assert skill.source_id == source_dir

    File.write!(
      Path.join(source_dir, "SKILL.md"),
      """
      ---
      name: #{skill_key}
      description: Web install v2
      version: 1.1.0
      ---

      install v2
      """
    )

    assert :ok = LemonWeb.OpsDashboard.update_skill(skill_key)

    skill =
      LemonWeb.OpsDashboard.snapshot().skills.entries
      |> Enum.find(&(&1.key == skill_key))

    assert skill.description == "Web install v2"
    assert is_binary(skill.updated_at)
  end

  test "operations dashboard exposes skill provenance and can toggle existing skills" do
    token = System.unique_integer([:positive, :monotonic])
    old_agent_dir = System.get_env("LEMON_AGENT_DIR")
    tmp_dir = Path.join(System.tmp_dir!(), "lemon-web-skills-#{token}")
    agent_dir = Path.join(tmp_dir, "agent")
    skill_key = "web-ops-skill-#{token}"
    skill_dir = Path.join([agent_dir, "skill", skill_key])

    System.put_env("LEMON_AGENT_DIR", agent_dir)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: Web Ops Skill #{token}
      description: Web operations skill fixture
      requires:
        bins:
          - definitely-missing-lemon-web-skill-bin-#{token}
      ---

      body
      """
    )

    File.write!(
      Path.join(agent_dir, "skills.lock.json"),
      Jason.encode!(%{
        "version" => 1,
        "skills" => %{
          skill_key => %{
            "key" => skill_key,
            "source_kind" => "local",
            "source_id" => skill_dir,
            "trust_level" => "trusted",
            "audit_status" => "pass",
            "audit_findings" => []
          }
        }
      })
    )

    on_exit(fn ->
      case old_agent_dir do
        nil -> System.delete_env("LEMON_AGENT_DIR")
        value -> System.put_env("LEMON_AGENT_DIR", value)
      end

      File.rm_rf(tmp_dir)
      LemonSkills.Registry.refresh()
    end)

    LemonSkills.Registry.refresh()

    skill = Enum.find(LemonWeb.OpsDashboard.snapshot().skills.entries, &(&1.key == skill_key))
    assert skill.source_kind == "local"
    assert skill.trust_level == "trusted"
    assert skill.audit_status == "pass"
    assert skill.required_bins == ["definitely-missing-lemon-web-skill-bin-#{token}"]
    assert skill.missing == ["definitely-missing-lemon-web-skill-bin-#{token}"]

    assert :ok = LemonWeb.OpsDashboard.set_skill_enabled(skill_key, false)
    skill = Enum.find(LemonWeb.OpsDashboard.snapshot().skills.entries, &(&1.key == skill_key))
    refute skill.enabled?
    assert skill.activation_state == "hidden"

    assert :ok = LemonWeb.OpsDashboard.set_skill_enabled(skill_key, true)
    skill = Enum.find(LemonWeb.OpsDashboard.snapshot().skills.entries, &(&1.key == skill_key))
    assert skill.enabled?
  end

  test "operations dashboard exposes runtime channel status and reconnect controls" do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)

    old_adapters = Application.get_env(:lemon_channels, :adapters, [])
    Application.put_env(:lemon_channels, :adapters, old_adapters ++ [ChannelAdapter])

    _ = LemonWeb.OpsDashboard.disconnect_channel("web-ops-test-channel")

    assert :ok = LemonChannels.Application.register_and_start_adapter(ChannelAdapter)

    on_exit(fn ->
      _ = LemonWeb.OpsDashboard.disconnect_channel("web-ops-test-channel")
      Application.put_env(:lemon_channels, :adapters, old_adapters)
    end)

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "web-ops-test-channel"))

    assert channel.runtime_status == "running"
    assert channel.connected?
    assert channel.configured?

    assert :ok = LemonWeb.OpsDashboard.disconnect_channel("web-ops-test-channel")

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "web-ops-test-channel"))

    assert channel.runtime_status == "not_registered"
    assert channel.reconnectable?

    assert :ok = LemonWeb.OpsDashboard.reconnect_channel("web-ops-test-channel")

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "web-ops-test-channel"))

    assert channel.runtime_status == "running"
  end

  test "operations dashboard can edit gateway channel enablement config" do
    token = System.unique_integer([:positive, :monotonic])
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "lemon-web-channel-config-#{token}")
    config_path = Path.join([home, ".lemon", "config.toml"])

    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, "[gateway]\nenable_telegram = false\n")
    System.put_env("HOME", home)
    LemonCore.ConfigCache.invalidate(nil)
    LemonCore.ConfigCache.invalidate(File.cwd!())

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("HOME")
        value -> System.put_env("HOME", value)
      end

      LemonCore.ConfigCache.invalidate(nil)
      LemonCore.ConfigCache.invalidate(File.cwd!())
      File.rm_rf(home)
    end)

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "telegram"))

    refute channel.enabled?
    assert channel.configurable?
    assert channel.config_key == "enable_telegram"

    assert :ok = LemonWeb.OpsDashboard.set_channel_config_enabled("telegram", true)
    assert File.read!(config_path) =~ "enable_telegram = true"

    channel =
      LemonWeb.OpsDashboard.snapshot().channels.transports
      |> Enum.find(&(&1.name == "telegram"))

    assert channel.enabled?

    assert :ok = LemonWeb.OpsDashboard.set_channel_config_enabled("telegram", false)
    assert File.read!(config_path) =~ "enable_telegram = false"
  end

  test "operations dashboard can edit channel credentials and bindings config" do
    token = System.unique_integer([:positive, :monotonic])
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "lemon-web-channel-binding-config-#{token}")
    config_path = Path.join([home, ".lemon", "config.toml"])

    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      """
      [gateway]
      enable_telegram = true
      default_engine = "lemon"
      default_cwd = "~/"

      [gateway.telegram]
      bot_token_secret = "old_telegram_secret"
      allowed_chat_ids = [111]
      deny_unbound_chats = false

      [gateway.discord]
      bot_token_secret = "old_discord_secret"
      allowed_guild_ids = [333]
      allowed_channel_ids = [444]
      deny_unbound_channels = false
      message_content_intent_enabled = false

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 111
      agent_id = "default"
      """
    )

    System.put_env("HOME", home)
    LemonCore.ConfigCache.invalidate(nil)
    LemonCore.ConfigCache.invalidate(File.cwd!())

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("HOME")
        value -> System.put_env("HOME", value)
      end

      LemonCore.ConfigCache.invalidate(nil)
      LemonCore.ConfigCache.invalidate(File.cwd!())
      File.rm_rf(home)
    end)

    assert :ok =
             LemonWeb.OpsDashboard.update_channel_gateway_defaults(%{
               "default_engine" => "codex",
               "default_cwd" => "/tmp/lemon",
               "auto_resume" => "true"
             })

    assert :ok =
             LemonWeb.OpsDashboard.update_channel_telegram_config(%{
               "bot_token_secret" => "telegram_bot_token",
               "allowed_chat_ids" => "111, -100222",
               "deny_unbound_chats" => "true"
             })

    assert :ok =
             LemonWeb.OpsDashboard.update_channel_discord_config(%{
               "bot_token_secret" => "discord_bot_token",
               "allowed_guild_ids" => "333, 555",
               "allowed_channel_ids" => "444, 666",
               "deny_unbound_channels" => "true",
               "message_content_intent_enabled" => "true"
             })

    content = File.read!(config_path)
    assert content =~ ~s(default_engine = "codex")
    assert content =~ ~s(default_cwd = "/tmp/lemon")
    assert content =~ "auto_resume = true"
    assert content =~ ~s(bot_token_secret = "telegram_bot_token")
    assert content =~ "allowed_chat_ids = [111, -100222]"
    assert content =~ "deny_unbound_chats = true"
    assert content =~ ~s(bot_token_secret = "discord_bot_token")
    assert content =~ "allowed_guild_ids = [333, 555]"
    assert content =~ "allowed_channel_ids = [444, 666]"
    assert content =~ "deny_unbound_channels = true"
    assert content =~ "message_content_intent_enabled = true"

    snapshot = LemonWeb.OpsDashboard.snapshot()
    assert snapshot.channels.discord.allowed_guild_ids == [333, 555]
    assert snapshot.channels.discord.allowed_channel_ids == [444, 666]
    assert snapshot.channels.discord.deny_unbound_channels?
    assert snapshot.channels.discord.message_content_intent_enabled?

    assert :ok =
             LemonWeb.OpsDashboard.create_channel_binding(%{
               "transport" => "telegram",
               "chat_id" => "-100222",
               "topic_id" => "7",
               "agent_id" => "ops",
               "default_engine" => "codex",
               "project" => "lemon"
             })

    snapshot = LemonWeb.OpsDashboard.snapshot()
    assert snapshot.channels.gateway.default_engine == "codex"
    assert snapshot.channels.telegram.bot_token_secret == "telegram_bot_token"
    assert snapshot.channels.telegram.allowed_chat_ids == [111, -100_222]
    assert snapshot.channels.telegram.deny_unbound_chats?

    created =
      snapshot.channels.bindings
      |> Enum.find(&(&1.chat_id == -100_222))

    assert created.topic_id == 7
    assert created.agent_id == "ops"
    assert created.default_engine == "codex"
    assert created.project == "lemon"

    assert :ok =
             LemonWeb.OpsDashboard.update_channel_binding(created.index, %{
               "transport" => "telegram",
               "chat_id" => "-100333",
               "agent_id" => "updated",
               "default_engine" => "lemon"
             })

    snapshot = LemonWeb.OpsDashboard.snapshot()

    assert Enum.any?(
             snapshot.channels.bindings,
             &(&1.chat_id == -100_333 and &1.agent_id == "updated")
           )

    updated = Enum.find(snapshot.channels.bindings, &(&1.chat_id == -100_333))
    assert :ok = LemonWeb.OpsDashboard.delete_channel_binding(updated.index)

    refute Enum.any?(
             LemonWeb.OpsDashboard.snapshot().channels.bindings,
             &(&1.chat_id == -100_333)
           )
  end

  test "operations dashboard can edit defaults and provider reference config" do
    token = System.unique_integer([:positive, :monotonic])
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "lemon-web-general-config-#{token}")
    config_path = Path.join([home, ".lemon", "config.toml"])

    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      """
      [defaults]
      provider = "anthropic"
      model = "claude-sonnet-4-20250514"
      thinking_level = "medium"
      engine = "lemon"

      [providers.anthropic]
      api_key_secret = "old_anthropic_secret"
      """
    )

    System.put_env("HOME", home)
    LemonCore.ConfigCache.invalidate(nil)
    LemonCore.ConfigCache.invalidate(File.cwd!())

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("HOME")
        value -> System.put_env("HOME", value)
      end

      LemonCore.ConfigCache.invalidate(nil)
      LemonCore.ConfigCache.invalidate(File.cwd!())
      File.rm_rf(home)
    end)

    assert :ok =
             LemonWeb.OpsDashboard.update_default_config(%{
               "provider" => "openai",
               "model" => "gpt-5",
               "thinking_level" => "high",
               "engine" => "codex"
             })

    assert :ok =
             LemonWeb.OpsDashboard.update_provider_config("openai", %{
               "auth_source" => "api_key",
               "api_key_secret" => "llm_openai_api_key",
               "base_url" => "https://api.openai.com/v1"
             })

    content = File.read!(config_path)
    assert content =~ ~s(provider = "openai")
    assert content =~ ~s(model = "gpt-5")
    assert content =~ ~s(thinking_level = "high")
    assert content =~ ~s(engine = "codex")
    assert content =~ "[providers.openai]"
    assert content =~ ~s(auth_source = "api_key")
    assert content =~ ~s(api_key_secret = "llm_openai_api_key")
    assert content =~ ~s(base_url = "https://api.openai.com/v1")
    refute content =~ "sk-"

    {snapshot, provider} =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        snapshot = LemonWeb.OpsDashboard.snapshot()
        provider = Enum.find(snapshot.config.providers, &(&1.id == "openai"))

        if (snapshot.config.defaults.provider == "openai" and provider) && provider.configured? do
          {:halt, {snapshot, provider}}
        else
          Process.sleep(50)
          {:cont, nil}
        end
      end)

    assert snapshot.config.defaults.provider == "openai"
    assert snapshot.config.defaults.model == "gpt-5"
    assert snapshot.config.defaults.thinking_level == "high"
    assert snapshot.config.defaults.engine == "codex"

    assert provider.configured?
    assert provider.auth_source == "api_key"
    assert provider.api_key_secret == "llm_openai_api_key"
    assert provider.base_url == "https://api.openai.com/v1"

    openai_ready = Enum.find(snapshot.provider.readiness.providers, &(&1.provider == "openai"))

    assert openai_ready.configured?
    assert openai_ready.api_key_secret_configured?
    assert openai_ready.base_url_configured?
    assert snapshot.provider.readiness.routing.requested_provider == "openai"
    assert snapshot.provider.readiness.routing.cleanup.includes_raw_api_keys == false
    assert snapshot.provider.readiness.routing.cleanup.includes_secret_names == false
    assert snapshot.provider.readiness.routing.cleanup.includes_raw_base_urls == false
    assert snapshot.provider.readiness.routing.cleanup.includes_env_var_names == false
    refute inspect(snapshot.provider.readiness) =~ "llm_openai_api_key"
    refute inspect(snapshot.provider.readiness) =~ "https://api.openai.com/v1"
  end

  test "operations dashboard LSP proof panel scans past recent non-LSP proof artifacts" do
    proof_dir = Path.join([File.cwd!(), ".lemon", "proofs"])
    File.mkdir_p!(proof_dir)

    prefix = "web-panel-regression-#{System.unique_integer([:positive])}"
    lsp_path = Path.join(proof_dir, "#{prefix}-lsp-proof.json")

    non_lsp_paths =
      Enum.map(1..25, fn index ->
        Path.join(proof_dir, "#{prefix}-non-lsp-#{index}-proof.json")
      end)

    on_exit(fn ->
      Enum.each([lsp_path | non_lsp_paths], &File.rm/1)
    end)

    File.write!(
      lsp_path,
      Jason.encode!(%{
        status: "completed",
        proof_object: "#{prefix}_lsp",
        proof_scope: "lsp_web_panel_regression",
        completed_count: 1,
        failed_count: 0,
        skipped_count: 0,
        checks: [
          %{
            name: "#{prefix}_lsp_check",
            status: "completed",
            proof_scope: "lsp_web_panel_regression"
          }
        ],
        cleanup: %{includes_raw_paths: false, includes_raw_proof_details: false}
      })
    )

    Process.sleep(1100)

    Enum.each(non_lsp_paths, fn path ->
      File.write!(
        path,
        Jason.encode!(%{
          status: "completed",
          proof_object: "other_#{prefix}",
          proof_scope: "other_panel_regression",
          completed_count: 1,
          failed_count: 0,
          skipped_count: 0,
          checks: [%{name: "other_#{prefix}", status: "completed"}],
          cleanup: %{includes_raw_paths: false, includes_raw_proof_details: false}
        })
      )
    end)

    snapshot = LemonWeb.OpsDashboard.snapshot()

    assert snapshot.lsp_diagnostics.proofs.proof_count >= 1
    assert snapshot.lsp_diagnostics.proofs.check_count >= 1
    assert snapshot.lsp_diagnostics.proofs.error == nil

    assert Enum.any?(
             snapshot.lsp_diagnostics.proofs.recent_proofs,
             &(&1.proof_object == "#{prefix}_lsp")
           )

    assert Enum.any?(
             snapshot.lsp_diagnostics.proofs.latest_checks,
             &(&1.name == "#{prefix}_lsp_check")
           )
  end

  defp restore_usage_summary(nil), do: LemonCore.Store.delete(:usage_data, :current)
  defp restore_usage_summary(summary), do: LemonCore.UsageStore.put_summary(:current, summary)

  defp restore_usage_record(date, nil), do: LemonCore.Store.delete(:usage_records, date)
  defp restore_usage_record(date, record), do: LemonCore.UsageStore.put_record(date, record)
end
