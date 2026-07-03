defmodule LemonCore.Doctor.SupportBundleTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.{Check, Report, SupportBundle}

  test "writes a zip containing diagnostics and metadata" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

    endpoint = "ws://user:secret@example.invalid:9222/devtools/browser/private"
    previous_endpoint = System.get_env("LEMON_BROWSER_CDP_ENDPOINT")
    System.put_env("LEMON_BROWSER_CDP_ENDPOINT", endpoint)

    on_exit(fn ->
      if previous_endpoint do
        System.put_env("LEMON_BROWSER_CDP_ENDPOINT", previous_endpoint)
      else
        System.delete_env("LEMON_BROWSER_CDP_ENDPOINT")
      end
    end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "config.toml"]),
      """
      [providers.openai]
      api_key = "sk-test-inline-secret"
      api_key_secret = "llm_openai_secret_name"
      base_url = "https://example.invalid/v1"

      [providers.anthropic]
      oauth_secret = "llm_anthropic_oauth_secret_name"
      auth_source = "oauth"

      [defaults]
      provider = "openai"
      model = "openai:test-model"

      [runtime]
      extension_paths = ["custom_extensions"]

      [runtime.provider_routing]
      fallback_providers = ["anthropic"]
      default_pool = "primary"

      [runtime.provider_routing.credential_pools.primary]
      providers = ["openai", "anthropic"]
      strategy = "priority"

      [gateway]
      enable_telegram = true
      enable_discord = true

      [gateway.telegram]
      bot_token = "123456789:SECRET_TOKEN"
      bot_token_secret = "telegram_bot_token_secret_name"
      allowed_chat_ids = [123456789, -1001234567890]
      deny_unbound_chats = true
      voice_transcription = true
      voice_transcription_api_key = "sk-voice-secret"

      [gateway.telegram.files]
      enabled = true
      auto_put = true
      auto_send_generated_files = true
      auto_send_generated_max_files = 2
      allowed_user_ids = [123456789]
      deny_globs = [".env", "**/*.pem"]

      [gateway.discord]
      bot_token = "discord-token-secret"
      bot_token_secret = "discord_bot_token_secret_name"
      allowed_guild_ids = ["111111111111111111"]
      allowed_channel_ids = ["222222222222222222"]
      deny_unbound_channels = true
      message_content_intent_enabled = true

      [gateway.discord.files]
      enabled = true
      auto_put = true
      auto_send_generated_files = true
      auto_send_generated_max_files = 3

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 123456789
      topic_id = 35
      agent_id = "default"

      [[gateway.bindings]]
      transport = "discord"
      channel_id = "222222222222222222"
      agent_id = "default"
      """
    )

    project_extension_dir = Path.join([tmp_dir, ".lemon", "extensions"])
    custom_extension_dir = Path.join(tmp_dir, "custom_extensions")
    File.mkdir_p!(project_extension_dir)
    File.mkdir_p!(custom_extension_dir)

    File.write!(
      Path.join(project_extension_dir, "project_extension.exs"),
      "defmodule ProjectExt do end\n"
    )

    File.write!(
      Path.join(custom_extension_dir, "custom_extension.ex"),
      "defmodule CustomExt do end\n"
    )

    File.write!(
      Path.join(custom_extension_dir, "lemon_extension.json"),
      Jason.encode!(%{
        schema_version: 1,
        name: "private-plugin-name",
        version: "0.1.0",
        capabilities: ["tools", "memory_provider"],
        providers: [
          %{
            type: "memory",
            name: "private-memory-provider",
            endpoint: "https://secret.example.invalid/memory"
          }
        ],
        hosts: [%{type: "beam"}, %{type: "wasm"}, %{type: "mcp"}],
        distribution: %{
          source: "git",
          url: "https://token@example.invalid/private/plugin.git"
        },
        audit: %{status: "pending"}
      })
    )

    File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "private-proof.json"]),
      Jason.encode!(%{
        status: "failed",
        completed_count: 0,
        failed_count: 1,
        skipped_count: 0,
        generated_at: "2026-05-16T12:01:00Z",
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_provider_responses: false
        },
        details: %{
          provider: "openai_vision",
          model: "openrouter:test-model",
          artifact_mime_type: "application/json",
          artifact_bytes: 59,
          analysis_chars: 43,
          artifact_hash: "private-artifact-hash",
          job_id_hash: "private-job-hash",
          reason_kind: "provider_http_error",
          proof_scope: "provider live media",
          raw_prompt: "private proof prompt"
        }
      })
    )

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "provider-fallback-proof.json"]),
      Jason.encode!(%{
        status: "completed",
        proof_object: "lemon.provider_fallback_smoke",
        completed_count: 1,
        failed_count: 0,
        skipped_count: 0,
        generated_at: "2026-05-16T12:03:00Z",
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_answer: false
        },
        details: %{
          model: "glm-5-turbo",
          primary_provider: "openai",
          fallback_provider: "zai",
          final_provider: "zai",
          answer_hash: "private-answer-hash"
        }
      })
    )

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "discord-slash-proof.json"]),
      Jason.encode!(%{
        status: "completed",
        proof_object: "lemon.discord_slash_interaction",
        proof_scope: "discord_slash_interaction_deterministic",
        completed_count: 34,
        failed_count: 0,
        generated_at: "2026-05-16T12:04:00Z",
        coverage: %{
          registered_command_count: 16,
          decode_command_count: 3,
          local_response_command_count: 13,
          real_client_click_proof: false,
          ignored_raw_field: "/private/path"
        },
        checks: [
          %{name: "slash_command_inventory_16", status: "completed"}
        ],
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_provider_responses: false
        }
      })
    )

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "discord-live-matrix-latest.json"]),
      Jason.encode!(%{
        status: "failed",
        proof: "discord_live_matrix",
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        completed_count: 1,
        failed_count: 1,
        skipped_count: 0,
        generated_at: "2026-05-16T12:05:00Z",
        coverage: %{
          check_count: 4,
          non_bot_user_sender: true,
          contains_dm: true,
          contains_generated_audio: true,
          contains_media_directive: true,
          contains_file_delivery: true,
          contains_slash_registration: true,
          contains_rollback_slash_registration: true,
          contains_media_slash_registration: true
        },
        checks: [
          %{
            name: "discord_file_delivery",
            status: "completed",
            proof_scope: "discord_file_delivery",
            nonce_hash: "safe-file-nonce-hash",
            channel_hash: "safe-channel-hash"
          },
          %{
            name: "discord_generated_audio_delivery",
            status: "completed",
            nonce_hash: "safe-audio-nonce-hash",
            attachment_count: 1
          },
          %{
            name: "discord_media_directive_delivery",
            status: "completed",
            nonce_hash: "safe-media-directive-nonce-hash",
            attachment_count: 1,
            directive_leaked: false
          },
          %{
            name: "discord_dm_prompt_round_trip",
            status: "failed",
            proof_scope: "discord_direct_message_channel",
            reason_kind: "discord_dm_setup_refused",
            failure_hint:
              "Discord refused DM channel setup with code 50007. Use a human/open-DM channel before promoting Discord DM support.",
            channel_hash: "safe-dm-channel-hash"
          }
        ],
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_raw_interaction_tokens: false,
          includes_raw_application_ids: false,
          includes_raw_channel_ids: false,
          includes_raw_user_ids: false,
          includes_raw_message_bodies: false,
          includes_secret_names: false
        }
      })
    )

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "telegram-voice-local-latest.json"]),
      Jason.encode!(%{
        status: "completed",
        proof_object: "lemon.telegram_voice_local_smoke",
        proof_scope: "telegram_voice_local_transcript",
        completed_count: 3,
        failed_count: 0,
        skipped_count: 0,
        generated_at: "2026-05-17T13:05:08.639510Z",
        coverage: %{
          check_count: 3
        },
        checks: [
          %{
            name: "telegram_voice_local_transcript_provider",
            status: "completed",
            proof_scope: "telegram_voice_local_transcript",
            prompt_hash: "safe-prompt-hash"
          },
          %{
            name: "telegram_voice_local_no_api_key",
            status: "completed",
            proof_scope: "telegram_voice_local_transcript",
            audio_bytes: 5,
            mime_type: "audio/ogg"
          },
          %{
            name: "telegram_voice_local_inbound_metadata",
            status: "completed",
            proof_scope: "telegram_voice_local_transcript",
            chat_id_hash: "safe-chat-hash",
            sender_id_hash: "safe-sender-hash",
            voice_transcribed: true,
            raw_transcript: "private transcript"
          }
        ],
        cleanup: %{
          includes_raw_bot_token: false,
          includes_raw_chat_ids: false,
          includes_raw_sender_ids: false,
          includes_raw_audio_bytes: false,
          includes_raw_transcript: false,
          includes_raw_message_body: false
        }
      })
    )

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "wasm-lifecycle-latest.json"]),
      Jason.encode!(%{
        status: "completed",
        proof: "wasm_lifecycle_smoke",
        completed_count: 5,
        failed_count: 0,
        generated_at: "2026-05-17T02:35:01.331778Z",
        checks: [
          %{name: "wasm_lifecycle_discover_emits_redacted_start_stop", status: "completed"},
          %{name: "wasm_lifecycle_invoke_emits_redacted_start_stop", status: "completed"},
          %{name: "wasm_lifecycle_status_tracks_running_sidecar", status: "completed"},
          %{name: "wasm_lifecycle_stop_terminates_sidecar", status: "completed"},
          %{name: "wasm_lifecycle_telemetry_omits_raw_sensitive_values", status: "completed"}
        ],
        lifecycle_boundary: %{
          host: "wasm",
          discover_emits_redacted_start_stop: true,
          invoke_emits_redacted_start_stop: true,
          status_tracks_running_sidecar: true,
          stop_terminates_sidecar: true,
          tool_count: 1
        },
        redaction: %{
          contains_raw_cwd: false,
          contains_raw_session_ids: false,
          contains_raw_tool_names: false,
          contains_raw_params: false
        }
      })
    )

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "terminal-backend-latest.json"]),
      Jason.encode!(%{
        status: "completed",
        completed_count: 4,
        failed_count: 0,
        skipped_count: 0,
        generated_at: "2026-05-17T06:26:25.028059Z",
        command_hash: "safe-command-hash",
        cwd_hash: "safe-cwd-hash",
        results: [
          %{backend: "local", status: "completed", output_hash: "safe-local-output"},
          %{backend: "local_pty", status: "completed", output_hash: "safe-pty-output"},
          %{
            backend: "docker",
            status: "completed",
            output_hash: "safe-docker-output",
            hardening: %{
              read_only_rootfs: true,
              tmpfs_noexec: true,
              drops_capabilities: true,
              no_new_privileges: true,
              cgroup_memory_limit: true,
              cgroup_cpu_quota: true,
              cgroup_pids_limit: true,
              pull_policy: "never",
              network: "none",
              memory: "1g",
              cpus: "2",
              pids_limit: "256",
              raw_command: "private command"
            }
          },
          %{backend: "ssh", status: "completed", output_hash: "safe-ssh-output"}
        ]
      })
    )

    File.mkdir_p!(Path.join(tmp_dir, "tmp"))

    File.write!(
      Path.join([tmp_dir, "tmp", "discord-free-response-proof.json"]),
      Jason.encode!(%{
        ok: false,
        checks: [
          %{
            name: "setup",
            ok: true
          },
          %{
            name: "discord_free_response_trigger_round_trip",
            ok: false,
            failure_hint:
              "No Lemon reply was observed for an unmentioned guild/thread message. Check Discord Message Content Intent."
          }
        ],
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_provider_responses: false
        }
      })
    )

    File.write!(
      Path.join([tmp_dir, "tmp", "discord-dm-proof.json"]),
      Jason.encode!(%{
        ok: false,
        checks: [
          %{
            name: "setup",
            ok: true
          },
          %{
            name: "discord_dm_prompt_round_trip",
            ok: false,
            proof_scope: "discord direct message channel setup",
            setup_error:
              "Discord API POST /users/@me/channels failed: 400 {\"message\": \"Cannot send messages to this user\", \"code\": 50007}",
            failure_hint:
              "Discord refused DM channel setup with code 50007 (Cannot send messages to this user). Use a human/open-DM channel before promoting Discord DM support.",
            local_channel_diagnostics: %{
              ok: true,
              transport: "discord",
              enabled: true
            }
          }
        ],
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_provider_responses: false
        }
      })
    )

    bundle_path = Path.join(tmp_dir, "support.zip")
    report = Report.from_checks([Check.pass("runtime.boot", "ok")])
    today_key = Date.to_iso8601(Date.utc_today())
    previous_usage_summary = LemonCore.UsageStore.get_summary(:current)
    previous_today_usage = LemonCore.UsageStore.get_record(today_key)
    cron_token = System.unique_integer([:positive, :monotonic])
    cron_job_id = "cron_support_job_#{cron_token}"
    cron_run_id = "cron_support_run_#{cron_token}"
    cron_prompt = "private scheduled support prompt #{cron_token}"
    cron_output = "private scheduled support output #{cron_token}"
    cron_error = "private scheduled support error #{cron_token}"
    cron_session_key = "agent:support-cron-#{cron_token}:main"
    cron_memory_file = "/private/support-cron-memory-#{cron_token}.md"

    on_exit(fn ->
      LemonCore.Store.delete(:cron_jobs, cron_job_id)
      LemonCore.Store.delete(:cron_runs, cron_run_id)

      if previous_usage_summary do
        LemonCore.UsageStore.put_summary(:current, previous_usage_summary)
      else
        LemonCore.Store.delete(:usage_data, :current)
      end

      if previous_today_usage do
        LemonCore.UsageStore.put_record(today_key, previous_today_usage)
      else
        LemonCore.Store.delete(:usage_records, today_key)
      end
    end)

    LemonCore.Store.put(:cron_jobs, cron_job_id, %{
      id: cron_job_id,
      name: "private support cron #{cron_token}",
      schedule: "*/10 * * * *",
      enabled: true,
      agent_id: "support-cron-agent-#{cron_token}",
      session_key: cron_session_key,
      prompt: cron_prompt,
      memory_file: cron_memory_file,
      timezone: "UTC",
      jitter_sec: 5,
      timeout_ms: 60_000,
      created_at_ms: 1_000,
      updated_at_ms: 2_000,
      last_run_at_ms: 3_000,
      next_run_at_ms: 4_000,
      meta: %{private_key: "private support meta"}
    })

    LemonCore.Store.put(:cron_runs, cron_run_id, %{
      id: cron_run_id,
      job_id: cron_job_id,
      run_id: "router_#{cron_run_id}",
      status: :failed,
      started_at_ms: 5_000,
      completed_at_ms: 6_000,
      duration_ms: 1_000,
      triggered_by: :manual,
      output: cron_output,
      error: cron_error,
      suppressed: false,
      meta: %{agent_id: "support-cron-agent-#{cron_token}", session_key: cron_session_key}
    })

    assert {:ok, _job} =
             LemonMedia.MediaJobs.record(
               %{
                 job_id: "support-media",
                 type: :image,
                 status: :completed,
                 channel: "telegram",
                 prompt: "private prompt",
                 artifact_name: "image.png",
                 bytes: 12,
                 created_at: "2026-05-16T12:00:00Z"
               },
               project_dir: tmp_dir
             )

    LemonCore.UsageStore.put_summary(:current, %{
      total_cost: 0.42,
      total_requests: 3,
      total_tokens: %{input: 1_000, output: 500},
      breakdown: %{"openai" => 0.42},
      requests: %{"openai" => 3},
      tokens: %{"openai" => %{input: 1_000, output: 500}},
      prompt: "private usage prompt",
      response: "private usage response",
      api_key: "usage-secret-key"
    })

    LemonCore.UsageStore.put_record(today_key, %{
      date: today_key,
      total_cost: 0.42,
      requests: %{"openai" => 3},
      message_body: "private usage message body"
    })

    assert {:ok, ^bundle_path} =
             SupportBundle.write(report, bundle_path: bundle_path, project_dir: tmp_dir)

    assert File.exists?(bundle_path)

    assert {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])
    names = Enum.map(entries, fn {name, _content} -> List.to_string(name) end)

    assert "README.txt" in names
    assert "manifest.json" in names
    assert "doctor_report.json" in names
    assert "environment.json" in names
    assert "browser_diagnostics.json" in names
    assert "channel_diagnostics.json" in names
    assert "channel_readiness.json" in names
    assert "readiness_summary.json" in names
    assert "checkpoint_diagnostics.json" in names
    assert "cron_diagnostics.json" in names
    assert "extension_diagnostics.json" in names
    assert "goal_diagnostics.json" in names
    assert "kanban_diagnostics.json" in names
    assert "lsp_diagnostics.json" in names
    assert "media_diagnostics.json" in names
    assert "memory_diagnostics.json" in names
    assert "proof_diagnostics.json" in names
    assert "provider_diagnostics.json" in names
    assert "terminal_diagnostics.json" in names
    assert "usage_diagnostics.json" in names
    assert "config/global_config.toml" in names
    assert "config/project_config.toml" in names

    {_, readme_text} = Enum.find(entries, fn {name, _content} -> name == ~c"README.txt" end)
    readme = IO.iodata_to_binary(readme_text)
    assert readme =~ "channel readiness"
    assert readme =~ "chat/channel/guild ids"
    assert readme =~ "proof file contents"

    {_, manifest_json} = Enum.find(entries, fn {name, _content} -> name == ~c"manifest.json" end)
    manifest = manifest_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert manifest["lemon_version"] == "0.1.0"
    assert manifest["runtime_mode"] in ["source-dev", "release-runtime"]
    assert is_map(manifest["git"])
    assert is_binary(manifest["elixir"])
    assert is_binary(manifest["otp"])

    {_, browser_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"browser_diagnostics.json" end)

    browser_text = IO.iodata_to_binary(browser_json)
    browser = Jason.decode!(browser_text)

    assert is_map(browser["local_server"])
    assert browser["local_server"]["driver_config"]["mode"] == "remote_cdp"
    assert browser["local_server"]["driver_config"]["attach_only"] == true
    assert browser["local_server"]["driver_config"]["launches_browser"] == false
    assert browser["local_server"]["driver_config"]["cdp_endpoint_configured"] == true
    assert is_binary(browser["local_server"]["driver_config"]["cdp_endpoint_hash"])
    refute String.contains?(browser_text, endpoint)
    refute String.contains?(browser_text, "secret")
    assert is_binary(browser["artifacts_dir"])
    assert is_map(browser["artifact_summary"])
    assert browser["artifact_summary"]["cleanup"]["managed"] == true
    assert browser["artifact_summary"]["cleanup"]["policy"] == "managed: 14d or 100 files"

    assert browser["artifact_summary"]["cleanup"]["embeds_artifact_bytes_in_support_bundle"] ==
             false

    assert is_list(browser["recent_artifacts"])

    {_, channel_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"channel_diagnostics.json" end)

    channels = channel_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert channels["binding_count"] == 2
    assert channels["unsupported_binding_count"] == 0
    assert channels["cleanup"]["includes_raw_bot_tokens"] == false
    assert channels["cleanup"]["includes_secret_names"] == false
    assert channels["cleanup"]["includes_chat_ids"] == false
    assert channels["cleanup"]["includes_channel_ids"] == false
    assert channels["cleanup"]["includes_guild_ids"] == false
    assert channels["cleanup"]["includes_message_bodies"] == false

    telegram = Enum.find(channels["transports"], &(&1["transport"] == "telegram"))
    discord = Enum.find(channels["transports"], &(&1["transport"] == "discord"))
    assert telegram["enabled"] == true
    assert telegram["token_configured"] == true
    assert telegram["token_secret_configured"] == true
    assert telegram["allowed_peer_count"] == 2
    assert telegram["topic_binding_count"] == 1
    assert telegram["files"]["enabled"] == true
    assert telegram["files"]["auto_send_generated_files"] == true
    assert telegram["files"]["deny_glob_count"] == 2
    assert telegram["voice_transcription"]["enabled"] == true
    assert telegram["voice_transcription"]["api_key_configured"] == true
    assert discord["enabled"] == true
    assert discord["token_configured"] == true
    assert discord["token_secret_configured"] == true
    assert discord["allowed_guild_count"] == 1
    assert discord["allowed_channel_count"] == 1
    assert discord["files"]["auto_send_generated_files"] == true
    assert discord["bot_message_policy"]["ignores_self_messages"] == true
    assert discord["bot_message_policy"]["ignores_webhooks"] == true
    assert discord["bot_message_policy"]["external_bot_messages_allowed"] == true
    assert discord["bot_message_policy"]["external_bot_messages_stable"] == false
    assert discord["bot_message_policy"]["external_bot_messages_live_proof_required"] == true
    assert discord["direct_messages"]["prompt_round_trip_supported"] == true
    assert discord["direct_messages"]["requires_reachable_dm_channel"] == true
    assert discord["direct_messages"]["bot_to_bot_dm_stable"] == false
    assert discord["direct_messages"]["setup_refusal_reason_kind"] == "discord_dm_setup_refused"
    assert discord["direct_messages"]["live_external_sender_proof_required"] == true
    assert discord["direct_messages"]["live_external_sender_proof_source"] == "proof_diagnostics"
    assert discord["free_response"]["trigger_command_supported"] == true
    assert discord["free_response"]["default_mode"] == "mentions"
    assert discord["free_response"]["all_messages_mode_supported"] == true
    assert discord["free_response"]["requires_message_content_intent"] == true
    assert discord["free_response"]["runtime_requests_message_content_intent"] == true
    assert discord["free_response"]["message_content_intent_declared"] == true
    assert discord["free_response"]["live_external_sender_proof_required"] == true
    assert discord["free_response"]["live_external_sender_proof_source"] == "proof_diagnostics"
    assert discord["inbound_replay"]["duplicate_message_suppression_supported"] == true
    assert discord["inbound_replay"]["persisted_idempotency_supported"] == true

    assert discord["inbound_replay"]["transport_restart_dedupe_proof_source"] ==
             "discord_dedupe_proof"

    assert discord["inbound_replay"]["live_gateway_reconnect_proof_required"] == true

    assert discord["inbound_replay"]["live_gateway_reconnect_proof_source"] ==
             "live_discord_matrix"

    assert discord["slash_commands"]["schema_export_supported"] == true
    assert discord["slash_commands"]["expected_command_count"] == 16
    assert "checkpoint" in discord["slash_commands"]["expected_commands"]
    assert "rollback" in discord["slash_commands"]["expected_commands"]
    assert "kanban" in discord["slash_commands"]["expected_commands"]
    assert "media" in discord["slash_commands"]["expected_commands"]
    assert discord["slash_commands"]["live_registration_proof_required"] == true
    assert discord["slash_commands"]["live_registration_proof_source"] == "live_discord_matrix"

    assert discord["slash_commands"]["deterministic_runtime_decoder_proof_source"] ==
             "discord_slash_interaction_proof"

    assert discord["slash_commands"]["real_client_click_proof_required_for_broad_parity"] ==
             true

    channel_text = inspect(channels)
    refute channel_text =~ "123456789:SECRET_TOKEN"
    refute channel_text =~ "telegram_bot_token_secret_name"
    refute channel_text =~ "discord-token-secret"
    refute channel_text =~ "discord_bot_token_secret_name"
    refute channel_text =~ "111111111111111111"
    refute channel_text =~ "222222222222222222"
    refute channel_text =~ "sk-voice-secret"

    {_, channel_readiness_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"channel_readiness.json" end)

    channel_readiness = channel_readiness_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert channel_readiness["promoted_platforms"] == ["telegram", "discord"]
    assert channel_readiness["gate_count"] == 9
    assert is_integer(channel_readiness["passed_count"])
    assert is_integer(channel_readiness["warning_count"])
    assert channel_readiness["cleanup"]["includes_raw_bot_tokens"] == false
    assert channel_readiness["cleanup"]["includes_raw_proof_details"] == false

    slash_gate =
      Enum.find(channel_readiness["gates"], &(&1["id"] == "discord.slash_client_click"))

    assert slash_gate["next_action"] =~ "--wait-slash-client-click-proof"
    readiness_text = inspect(channel_readiness)
    refute readiness_text =~ "123456789:SECRET_TOKEN"
    refute readiness_text =~ "telegram_bot_token_secret_name"
    refute readiness_text =~ "discord-token-secret"
    refute readiness_text =~ "discord_bot_token_secret_name"
    refute readiness_text =~ "111111111111111111"
    refute readiness_text =~ "222222222222222222"
    refute readiness_text =~ "sk-voice-secret"

    {_, readiness_summary_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"readiness_summary.json" end)

    readiness_summary = readiness_summary_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert readiness_summary["status"] in ["blocked", "warning", "ready", "failed"]
    assert readiness_summary["doctor"]["overall"] == "pass"
    assert readiness_summary["channels"]["promoted_platforms"] == ["telegram", "discord"]
    assert readiness_summary["proofs"]["proof_count"] >= 1
    assert readiness_summary["proof_gates"]["providerMedia"]["status"] in ["passed", "warning"]
    assert readiness_summary["proof_gate_summary"]["gateCount"] == 5
    assert is_map(readiness_summary["proof_gate_summary"]["statuses"])
    assert is_list(readiness_summary["unresolved_gates"])

    provider_media_gate =
      Enum.find(readiness_summary["unresolved_gates"], &(&1["id"] == "provider_media"))

    assert "provider_http_error" in provider_media_gate["reason_kinds"]
    assert readiness_summary["cleanup"]["includes_raw_bot_tokens"] == false
    assert readiness_summary["cleanup"]["includes_secret_names"] == false
    assert readiness_summary["cleanup"]["includes_chat_ids"] == false
    assert readiness_summary["cleanup"]["includes_channel_ids"] == false
    assert readiness_summary["cleanup"]["includes_message_bodies"] == false
    assert readiness_summary["cleanup"]["includes_raw_proof_paths"] == false
    assert readiness_summary["cleanup"]["includes_raw_proof_details"] == false
    assert readiness_summary["cleanup"]["includes_raw_prompts"] == false
    assert readiness_summary["cleanup"]["includes_raw_provider_responses"] == false
    assert readiness_summary["cleanup"]["includes_secret_values"] == false

    readiness_summary_text = inspect(readiness_summary)
    refute readiness_summary_text =~ "123456789:SECRET_TOKEN"
    refute readiness_summary_text =~ "telegram_bot_token_secret_name"
    refute readiness_summary_text =~ "discord-token-secret"
    refute readiness_summary_text =~ "discord_bot_token_secret_name"
    refute readiness_summary_text =~ "111111111111111111"
    refute readiness_summary_text =~ "222222222222222222"
    refute readiness_summary_text =~ "sk-voice-secret"
    refute readiness_summary_text =~ "private proof prompt"

    {_, checkpoint_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"checkpoint_diagnostics.json" end)

    checkpoint = checkpoint_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert checkpoint["cleanup"]["embeds_file_contents_in_support_bundle"] == false
    assert checkpoint["cleanup"]["includes_raw_paths"] == false
    assert checkpoint["cleanup"]["includes_raw_session_ids"] == false

    {_, cron_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"cron_diagnostics.json" end)

    cron = cron_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert cron["job_count"] >= 1
    assert cron["enabled_count"] >= 1
    assert cron["run_count"] >= 1
    assert cron["failed_run_count"] >= 1
    assert cron["status_counts"]["failed"] >= 1
    assert cron["trigger_counts"]["manual"] >= 1

    assert Enum.any?(
             cron["recent_jobs"],
             &(&1["prompt_hash"] == short_hash(cron_prompt) and
                 &1["session_key_hash"] == short_hash(cron_session_key) and
                 &1["memory_file_hash"] == short_hash(cron_memory_file))
           )

    assert Enum.any?(
             cron["recent_runs"],
             &(&1["output_hash"] == short_hash(cron_output) and
                 &1["error_hash"] == short_hash(cron_error))
           )

    assert cron["cleanup"]["includes_prompts"] == false
    assert cron["cleanup"]["includes_outputs"] == false
    assert cron["cleanup"]["includes_errors"] == false
    assert cron["cleanup"]["includes_raw_session_ids"] == false
    assert cron["cleanup"]["includes_raw_agent_ids"] == false
    assert cron["cleanup"]["includes_raw_memory_paths"] == false
    assert cron["cleanup"]["includes_meta_values"] == false
    refute inspect(cron) =~ cron_prompt
    refute inspect(cron) =~ cron_output
    refute inspect(cron) =~ cron_error
    refute inspect(cron) =~ cron_session_key
    refute inspect(cron) =~ cron_memory_file
    refute inspect(cron) =~ "private support meta"

    {_, extension_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"extension_diagnostics.json" end)

    extensions = extension_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert extensions["directory_count"] >= 2
    assert extensions["existing_directory_count"] >= 2
    assert extensions["extension_file_count"] >= 2
    assert extensions["manifest_count"] >= 1
    assert extensions["valid_manifest_count"] >= 1
    assert extensions["invalid_manifest_count"] == 0
    assert extensions["configured_extension_path_count"] == 1
    assert extensions["capability_counts"]["tools"] >= 1
    assert extensions["capability_counts"]["memory_provider"] >= 1
    assert extensions["provider_type_counts"]["memory"] >= 1
    assert extensions["host_type_counts"]["beam"] >= 1
    assert extensions["host_type_counts"]["wasm"] >= 1
    assert extensions["host_type_counts"]["mcp"] >= 1
    assert extensions["distribution_source_counts"]["git"] >= 1
    assert extensions["audit_status_counts"]["pending"] >= 1
    assert extensions["execution"]["configured_extension_path_count"] == 1
    assert extensions["execution"]["default_directory_count"] == 2
    assert extensions["execution"]["auto_load_default_paths"] == false
    assert extensions["execution"]["default_directories_diagnostics_only"] == true
    assert extensions["execution"]["diagnostics_loads_extension_code"] == false
    assert extensions["host_runtime"]["hosts"]["beam"]["status"] == "loadable"
    assert extensions["host_runtime"]["hosts"]["beam"]["configured_count"] >= 1
    assert extensions["host_runtime"]["hosts"]["wasm"]["status"] in ["disabled", "configured"]
    assert extensions["host_runtime"]["hosts"]["wasm"]["configured_count"] >= 1
    assert extensions["host_runtime"]["hosts"]["mcp"]["status"] == "manifest_only"
    assert extensions["host_runtime"]["hosts"]["mcp"]["configured_count"] >= 1
    assert extensions["host_runtime"]["degraded_host_count"] == 0
    assert extensions["host_runtime"]["manifest_only_host_count"] >= 1
    assert extensions["host_runtime"]["runtime_health_loads_extension_code"] == false
    assert extensions["wasm_lifecycle"]["proof_present"] == true
    assert extensions["wasm_lifecycle"]["proof_status"] == "completed"
    assert extensions["wasm_lifecycle"]["completed_count"] == 5
    assert extensions["wasm_lifecycle"]["failed_count"] == 0
    assert extensions["wasm_lifecycle"]["lifecycle_supported"] == true
    assert extensions["wasm_lifecycle"]["lifecycle_boundary"]["stop_terminates_sidecar"] == true
    assert extensions["wasm_lifecycle"]["redaction"]["contains_raw_cwd"] == false
    assert extensions["wasm_lifecycle"]["redaction"]["contains_raw_session_ids"] == false
    assert extensions["wasm_lifecycle"]["redaction"]["contains_raw_tool_names"] == false
    assert extensions["wasm_lifecycle"]["redaction"]["contains_raw_params"] == false
    assert extensions["cleanup"]["includes_raw_source_paths"] == false
    assert extensions["cleanup"]["includes_file_contents"] == false
    assert extensions["cleanup"]["includes_load_error_messages"] == false
    assert extensions["cleanup"]["includes_manifest_contents"] == false
    assert extensions["cleanup"]["includes_distribution_urls"] == false
    assert extensions["cleanup"]["loads_extension_code"] == false
    assert Enum.all?(extensions["directories"], &is_binary(&1["path_hash"]))
    refute inspect(extensions) =~ project_extension_dir
    refute inspect(extensions) =~ custom_extension_dir
    refute inspect(extensions) =~ "ProjectExt"
    refute inspect(extensions) =~ "CustomExt"
    refute inspect(extensions) =~ "private-plugin-name"
    refute inspect(extensions) =~ "private-memory-provider"
    refute inspect(extensions) =~ "secret.example"
    refute inspect(extensions) =~ "token@example"

    {_, goal_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"goal_diagnostics.json" end)

    goals = goal_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert goals["cleanup"]["includes_objectives"] == false
    assert goals["cleanup"]["includes_raw_session_ids"] == false

    {_, kanban_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"kanban_diagnostics.json" end)

    kanban = kanban_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert kanban["cleanup"]["includes_titles"] == false
    assert kanban["cleanup"]["includes_descriptions"] == false
    assert kanban["cleanup"]["includes_comments"] == false
    assert kanban["cleanup"]["includes_raw_session_ids"] == false

    {_, lsp_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"lsp_diagnostics.json" end)

    lsp = lsp_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert lsp["status"] == "preview"
    assert lsp["supported_language_count"] >= 6
    assert is_list(lsp["supported_languages"])
    assert is_integer(lsp["executable_summary"]["available_count"])
    assert lsp["cleanup"]["includes_raw_paths"] == false
    assert lsp["cleanup"]["includes_file_contents"] == false
    assert lsp["cleanup"]["includes_diagnostics_output"] == false
    assert lsp["cleanup"]["includes_workspace_roots"] == false
    assert lsp["cleanup"]["includes_server_io"] == false
    assert lsp["cleanup"]["includes_raw_session_ids"] == false
    assert lsp["server_manager"]["running"] == true
    assert lsp["server_manager"]["mode"] == "registry_and_sessions"
    assert is_list(lsp["server_manager"]["active_servers"])
    assert is_list(lsp["server_manager"]["recent_sessions"])
    assert lsp["server_manager"]["registry"]["count"] == 6
    assert lsp["server_manager"]["registry"]["cleanup"]["includes_executable_paths"] == false

    {_, media_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"media_diagnostics.json" end)

    media = media_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert is_binary(media["jobs_dir"])
    assert is_binary(media["artifacts_dir"])
    assert media["worker_status"]["supervised"] == true
    assert media["worker_status"]["running"] == true
    assert is_integer(media["worker_status"]["active_jobs"])
    assert media["summary"]["count"] == 1
    assert media["summary"]["status_counts"]["completed"] == 1
    assert media["summary"]["type_counts"]["image"] == 1
    assert media["summary"]["cleanup"]["embeds_artifact_bytes_in_support_bundle"] == false
    assert media["summary"]["cleanup"]["includes_raw_paths"] == false
    assert media["summary"]["cleanup"]["includes_prompts"] == false
    assert media["summary"]["cleanup"]["includes_provider_responses"] == false
    assert media["summary"]["cleanup"]["includes_channel_message_bodies"] == false
    assert media["provider_live"]["status"] == "incomplete"
    assert media["provider_live"]["required_count"] == 5
    assert is_integer(media["provider_live"]["completed_count"])
    assert length(media["provider_live"]["providers"]) == 5
    assert media["provider_live"]["cleanup"]["includes_raw_provider_responses"] == false

    vision_provider =
      Enum.find(media["provider_live"]["providers"], &(&1["label"] == "vision"))

    assert vision_provider["status"] in ["completed", "failed"]
    assert vision_provider["command"] =~ "scripts/live_media_vision_smoke.exs"
    assert vision_provider["secret_command"] =~ "--api-key-secret SECRET_NAME"

    assert [media_job] = media["recent_jobs"]
    assert media_job["job_id"] == "support-media"
    assert media_job["prompt_hash"]
    refute inspect(media) =~ "private prompt"

    {_, memory_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"memory_diagnostics.json" end)

    memory = memory_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert memory["provider_count"] >= 1
    assert memory["enabled_provider_count"] >= 1
    assert Enum.any?(memory["providers"], &(&1["id"] == "local"))
    assert memory["cleanup"]["includes_memory_contents"] == false
    assert memory["cleanup"]["includes_raw_provider_config"] == false
    assert memory["cleanup"]["includes_secret_values"] == false
    refute inspect(memory) =~ "external prompt"
    refute inspect(memory) =~ "private-memory-provider"

    {_, proof_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"proof_diagnostics.json" end)

    proofs = proof_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert proofs["proof_count"] == 9
    assert proofs["failed_count"] == 4
    assert proofs["completed_count"] == 5
    assert proofs["invalid_count"] == 0
    assert proofs["reason_kind_counts"]["provider_http_error"] == 1
    assert proofs["reason_kind_counts"]["discord_no_reply_for_unmentioned_message"] == 1
    assert proofs["reason_kind_counts"]["discord_dm_setup_refused"] == 2
    assert proofs["proof_scope_counts"]["provider_fallback"] == 1
    assert proofs["proof_scope_counts"]["provider_live_media"] == 1
    assert proofs["proof_scope_counts"]["media_provider"] == 1
    assert proofs["proof_scope_counts"]["discord_slash_interaction_deterministic"] == 1
    assert proofs["proof_scope_counts"]["discord_live_matrix"] == 1
    assert proofs["proof_scope_counts"]["channel_generated_media_delivery"] == 1
    assert proofs["proof_scope_counts"]["discord_file_delivery"] == 1
    assert proofs["proof_scope_counts"]["discord_direct_message_channel_setup"] == 1
    assert proofs["proof_scope_counts"]["discord_direct_message_channel"] == 1
    assert proofs["proof_scope_counts"]["telegram_voice_local_transcript"] == 1
    assert proofs["proof_scope_counts"]["wasm_lifecycle_smoke"] == 1
    assert proofs["proof_scope_counts"]["terminal_backend"] == 1
    assert proofs["check_name_counts"]["setup"] == 2
    assert proofs["check_name_counts"]["discord_free_response_trigger_round_trip"] == 1
    assert proofs["check_name_counts"]["discord_dm_prompt_round_trip"] == 2
    assert proofs["check_name_counts"]["discord_file_delivery"] == 1
    assert proofs["check_name_counts"]["discord_generated_audio_delivery"] == 1
    assert proofs["check_name_counts"]["discord_media_directive_delivery"] == 1
    assert proofs["check_name_counts"]["telegram_voice_local_transcript_provider"] == 1
    assert proofs["check_name_counts"]["telegram_voice_local_no_api_key"] == 1
    assert proofs["check_name_counts"]["telegram_voice_local_inbound_metadata"] == 1
    assert proofs["check_name_counts"]["wasm_lifecycle_stop_terminates_sidecar"] == 1
    assert proofs["check_name_counts"]["terminal_backend_docker"] == 1

    assert Enum.any?(
             proofs["latest_checks"],
             &(&1["name"] == "discord_file_delivery" and
                 &1["status"] == "completed" and
                 &1["proof_object"] == "lemon.discord_live_matrix")
           )

    assert Enum.any?(
             proofs["latest_checks"],
             &(&1["name"] == "discord_free_response_trigger_round_trip" and
                 &1["status"] == "failed" and
                 &1["reason_kind"] == "discord_no_reply_for_unmentioned_message")
           )

    assert Enum.any?(
             proofs["latest_checks"],
             &(&1["name"] == "discord_dm_prompt_round_trip" and
                 &1["status"] == "failed" and
                 &1["reason_kind"] == "discord_dm_setup_refused")
           )

    assert Enum.any?(
             proofs["latest_checks"],
             &(&1["name"] == "telegram_voice_local_inbound_metadata" and
                 &1["status"] == "completed" and
                 &1["proof_object"] == "lemon.telegram_voice_local_smoke")
           )

    assert Enum.all?(proofs["latest_checks"], &is_binary(&1["file_hash"]))
    assert Enum.all?(proofs["latest_checks"], &is_binary(&1["proof_hash"]))
    assert proofs["cleanup"]["includes_raw_paths"] == false
    assert proofs["cleanup"]["includes_raw_filenames"] == false
    assert proofs["cleanup"]["includes_raw_proof_details"] == false
    assert proofs["cleanup"]["includes_raw_prompts"] == false
    assert proofs["cleanup"]["includes_raw_provider_responses"] == false
    assert proofs["cleanup"]["embeds_proof_file_contents"] == false
    assert Enum.any?(proofs["directories"], &(&1["label"] == ".lemon/proofs"))
    assert Enum.any?(proofs["recent_proofs"], &(&1["status"] == "completed"))
    assert Enum.any?(proofs["recent_proofs"], &(&1["status"] == "failed"))
    assert Enum.any?(proofs["recent_proofs"], &(&1["model"] == "openrouter:test-model"))
    assert Enum.any?(proofs["recent_proofs"], &(&1["reason_kind"] == "provider_http_error"))

    assert Enum.any?(
             proofs["recent_proofs"],
             &(&1["proof_object"] == "lemon.provider_fallback_smoke")
           )

    assert Enum.any?(
             proofs["recent_proofs"],
             &(&1["proof_object"] == "wasm_lifecycle_smoke")
           )

    wasm_lifecycle_proof =
      Enum.find(
        proofs["recent_proofs"],
        &(&1["proof_object"] == "wasm_lifecycle_smoke")
      )

    assert wasm_lifecycle_proof["redaction"]["contains_raw_cwd"] == false
    assert wasm_lifecycle_proof["redaction"]["contains_raw_session_ids"] == false
    assert wasm_lifecycle_proof["redaction"]["contains_raw_tool_names"] == false
    assert wasm_lifecycle_proof["redaction"]["contains_raw_params"] == false
    assert wasm_lifecycle_proof["cleanup"] == %{}

    telegram_voice_proof =
      Enum.find(
        proofs["recent_proofs"],
        &(&1["proof_object"] == "lemon.telegram_voice_local_smoke")
      )

    assert telegram_voice_proof["status"] == "completed"
    assert telegram_voice_proof["completed_count"] == 3
    assert telegram_voice_proof["failed_count"] == 0
    assert "telegram_voice_local_transcript" in telegram_voice_proof["proof_scopes"]
    assert telegram_voice_proof["coverage"]["check_count"] == 3
    assert telegram_voice_proof["cleanup"]["includes_raw_bot_token"] == false
    assert telegram_voice_proof["cleanup"]["includes_raw_chat_ids"] == false
    assert telegram_voice_proof["cleanup"]["includes_raw_sender_ids"] == false
    assert telegram_voice_proof["cleanup"]["includes_raw_audio_bytes"] == false
    assert telegram_voice_proof["cleanup"]["includes_raw_transcript"] == false
    assert telegram_voice_proof["cleanup"]["includes_raw_message_body"] == false
    refute inspect(proofs) =~ "private transcript"

    slash_proof =
      Enum.find(
        proofs["recent_proofs"],
        &(&1["proof_object"] == "lemon.discord_slash_interaction")
      )

    assert slash_proof["coverage"]["registered_command_count"] == 16
    assert slash_proof["coverage"]["decode_command_count"] == 3
    assert slash_proof["coverage"]["local_response_command_count"] == 13
    assert slash_proof["coverage"]["real_client_click_proof"] == false
    refute Map.has_key?(slash_proof["coverage"], "ignored_raw_field")

    live_matrix_proof =
      Enum.find(
        proofs["recent_proofs"],
        &(&1["proof_object"] == "lemon.discord_live_matrix")
      )

    assert live_matrix_proof["coverage"]["check_count"] == 4
    assert live_matrix_proof["coverage"]["contains_dm"] == true
    assert live_matrix_proof["coverage"]["contains_generated_audio"] == true
    assert live_matrix_proof["coverage"]["contains_media_directive"] == true
    assert live_matrix_proof["coverage"]["contains_file_delivery"] == true
    assert live_matrix_proof["coverage"]["contains_slash_registration"] == true
    assert live_matrix_proof["coverage"]["contains_rollback_slash_registration"] == true
    assert live_matrix_proof["coverage"]["contains_media_slash_registration"] == true
    assert live_matrix_proof["cleanup"]["includes_raw_bot_tokens"] == false
    assert live_matrix_proof["cleanup"]["includes_raw_channel_ids"] == false
    assert live_matrix_proof["cleanup"]["includes_raw_message_bodies"] == false
    assert live_matrix_proof["cleanup"]["includes_secret_names"] == false
    assert live_matrix_proof["media_proof"]["discord_delivery"] == true
    assert live_matrix_proof["media_proof"]["discord_attachment_count"] == 1
    assert live_matrix_proof["media_proof"]["media_directive_delivery"] == true
    assert live_matrix_proof["media_proof"]["directive_leaked"] == false

    media_provider_proof =
      Enum.find(
        proofs["recent_proofs"],
        &(&1["provider"] == "openai_vision")
      )

    assert media_provider_proof["media_proof"]["provider"] == "openai_vision"
    assert media_provider_proof["media_proof"]["model"] == "openrouter:test-model"
    assert media_provider_proof["media_proof"]["artifact_mime_type"] == "application/json"
    assert media_provider_proof["media_proof"]["artifact_bytes"] == 59
    assert media_provider_proof["media_proof"]["analysis_chars"] == 43
    assert media_provider_proof["media_proof"]["has_artifact_hash"] == true
    assert media_provider_proof["media_proof"]["has_job_id_hash"] == true

    terminal_proof =
      Enum.find(
        proofs["recent_proofs"],
        &("terminal_backend" in &1["proof_scopes"])
      )

    assert terminal_proof["terminal_hardening"]["docker"]["read_only_rootfs"] == true
    assert terminal_proof["terminal_hardening"]["docker"]["tmpfs_noexec"] == true
    assert terminal_proof["terminal_hardening"]["docker"]["drops_capabilities"] == true
    assert terminal_proof["terminal_hardening"]["docker"]["no_new_privileges"] == true
    assert terminal_proof["terminal_hardening"]["docker"]["cgroup_memory_limit"] == true
    assert terminal_proof["terminal_hardening"]["docker"]["cgroup_cpu_quota"] == true
    assert terminal_proof["terminal_hardening"]["docker"]["cgroup_pids_limit"] == true
    assert terminal_proof["terminal_hardening"]["docker"]["pull_policy"] == "never"
    assert terminal_proof["terminal_hardening"]["docker"]["network"] == "none"
    assert terminal_proof["terminal_hardening"]["docker"]["memory"] == "1g"
    assert terminal_proof["terminal_hardening"]["docker"]["cpus"] == "2"
    assert terminal_proof["terminal_hardening"]["docker"]["pids_limit"] == "256"
    refute inspect(terminal_proof) =~ "private command"

    assert Enum.any?(proofs["recent_proofs"], &(&1["primary_provider"] == "openai"))
    assert Enum.any?(proofs["recent_proofs"], &(&1["fallback_provider"] == "zai"))
    assert Enum.any?(proofs["recent_proofs"], &(&1["final_provider"] == "zai"))

    assert Enum.any?(
             proofs["recent_proofs"],
             &(&1["reason_kind"] == "discord_no_reply_for_unmentioned_message")
           )

    assert Enum.any?(
             proofs["recent_proofs"],
             &(&1["reason_kind"] == "discord_dm_setup_refused")
           )

    assert Enum.all?(proofs["recent_proofs"], &is_binary(&1["file_hash"]))
    assert Enum.all?(proofs["recent_proofs"], &is_binary(&1["proof_hash"]))
    refute inspect(proofs) =~ "private-proof.json"
    refute inspect(proofs) =~ "provider-fallback-proof.json"
    refute inspect(proofs) =~ "discord-dm-proof.json"
    refute inspect(proofs) =~ "discord-live-matrix-latest.json"
    refute inspect(proofs) =~ Path.join([tmp_dir, ".lemon", "proofs"])
    refute inspect(proofs) =~ Path.join([tmp_dir, "tmp"])
    refute inspect(proofs) =~ "private proof prompt"
    refute inspect(proofs) =~ "private-answer-hash"
    refute inspect(proofs) =~ "No Lemon reply"
    refute inspect(proofs) =~ "Cannot send messages"

    {_, provider_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"provider_diagnostics.json" end)

    provider = provider_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert provider["default_provider"] == "openai"
    assert provider["default_model_configured"] == true
    assert provider["cleanup"]["includes_raw_api_keys"] == false
    assert provider["cleanup"]["includes_secret_names"] == false
    assert provider["cleanup"]["includes_raw_base_urls"] == false
    assert provider["cleanup"]["includes_env_var_names"] == false
    assert provider["cleanup"]["includes_provider_responses"] == false
    assert provider["routing"]["enabled"] == true
    assert provider["routing"]["credential_pool_count"] >= 1

    openai = Enum.find(provider["providers"], &(&1["provider"] == "openai"))
    anthropic = Enum.find(provider["providers"], &(&1["provider"] == "anthropic"))
    assert openai["configured"] == true
    assert openai["credential_ready"] == true
    assert Enum.any?(openai["inline_credentials"], &(&1["field"] == "api_key"))
    assert Enum.any?(openai["endpoint_shape"], &(&1["field"] == "base_url"))

    assert Enum.any?(
             openai["secret_references"],
             &(&1["field"] == "api_key_secret" and &1["configured"] == true)
           )

    assert anthropic["auth_source"] == "oauth"

    assert Enum.any?(
             anthropic["secret_references"],
             &(&1["field"] == "oauth_secret" and &1["configured"] == true)
           )

    provider_text = inspect(provider)
    refute provider_text =~ "sk-test-inline-secret"
    refute provider_text =~ "llm_openai_secret_name"
    refute provider_text =~ "llm_anthropic_oauth_secret_name"
    refute provider_text =~ "https://example.invalid"
    refute provider_text =~ "OPENAI_API_KEY"

    {_, terminal_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"terminal_diagnostics.json" end)

    terminal = terminal_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert terminal["count"] == 4
    assert terminal["default_backend"] == "local"
    assert terminal["policy"]["backend_allowlist_configured"] == false
    assert "local" in terminal["policy"]["allowed_backends"]
    assert terminal["policy"]["approval_required_backends"] == []
    local = Enum.find(terminal["backends"], &(&1["id"] == "local"))
    local_pty = Enum.find(terminal["backends"], &(&1["id"] == "local_pty"))
    docker = Enum.find(terminal["backends"], &(&1["id"] == "docker"))
    ssh = Enum.find(terminal["backends"], &(&1["id"] == "ssh"))
    assert local["id"] == "local"
    assert local["transport"] == "erlang_port"
    assert local_pty["id"] == "local_pty"
    assert local_pty["pty"] == true
    assert docker["id"] == "docker"
    assert docker["transport"] == "docker_cli"
    assert docker["isolation"] == "container"
    assert docker["network"] == "none"
    assert docker["pull_policy"] == "never"
    assert docker["drops_capabilities"] == true
    assert docker["no_new_privileges"] == true
    assert docker["policy"]["allowed"] == true
    assert docker["policy"]["requires_approval"] == false
    assert docker["policy"]["docker"]["pull_policy"] == "never"
    assert ssh["id"] == "ssh"
    assert ssh["transport"] == "openssh_cli"
    assert ssh["configured"] == System.get_env("LEMON_SSH_TERMINAL_TARGET") not in [nil, ""]
    assert ssh["policy"]["ssh"]["allowed_targets_configured"] == false
    refute Map.has_key?(ssh, "target")
    refute inspect(ssh["policy"]) =~ System.get_env("LEMON_SSH_TERMINAL_TARGET", "__unset__")
    assert is_nil(ssh["target_hash"]) or is_binary(ssh["target_hash"])
    assert terminal["cleanup"]["includes_commands"] == false
    assert terminal["cleanup"]["includes_environment"] == false
    assert terminal["cleanup"]["includes_process_output"] == false

    {_, usage_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"usage_diagnostics.json" end)

    usage_text = IO.iodata_to_binary(usage_json)
    usage = Jason.decode!(usage_text)

    assert usage["status"] in ["within_limits", "unlimited"]
    assert usage["period"] == "current"
    assert usage["total_cost"] == 0.42
    assert usage["total_requests"] == 3
    assert usage["total_tokens"]["input"] == 1_000
    assert usage["total_tokens"]["output"] == 500
    assert usage["total_tokens"]["total"] == 1_500
    assert usage["provider_count"] == 1
    assert usage["today"]["date"] == today_key
    assert usage["today"]["cost"] == 0.42
    assert usage["today"]["requests"] == 3

    assert [openai_usage] = usage["providers"]
    assert openai_usage["provider"] == "openai"
    assert openai_usage["cost"] == 0.42
    assert openai_usage["requests"] == 3
    assert openai_usage["input_tokens"] == 1_000
    assert openai_usage["output_tokens"] == 500
    assert usage["cleanup"]["includes_prompts"] == false
    assert usage["cleanup"]["includes_responses"] == false
    assert usage["cleanup"]["includes_message_bodies"] == false
    assert usage["cleanup"]["includes_credentials"] == false
    assert usage["cleanup"]["includes_secret_values"] == false
    refute usage_text =~ "private usage prompt"
    refute usage_text =~ "private usage response"
    refute usage_text =~ "private usage message body"
    refute usage_text =~ "usage-secret-key"
  end

  test "media diagnostics include target-provider proof rerun commands" do
    tmp_dir = tmp_dir()
    bundle_path = Path.join(tmp_dir, "support.zip")

    File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "media-image-smoke-latest.json"]),
      Jason.encode!(%{
        status: "failed",
        proof_object: "lemon.media_image_smoke",
        proof_scope: "media_provider",
        completed_count: 0,
        failed_count: 1,
        skipped_count: 0,
        reason_kind: "vertex_imagen_http_error:permission_denied",
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_provider_response: false
        },
        details: %{
          provider: "vertex_imagen",
          raw_provider_response: "private provider response"
        }
      })
    )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    report = Report.from_checks([Check.warn("media.provider_live", "blocked", "rerun")])

    assert {:ok, ^bundle_path} =
             SupportBundle.write(report, bundle_path: bundle_path, project_dir: tmp_dir)

    assert {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])

    {_, media_json} =
      Enum.find(entries, fn {name, _content} -> name == ~c"media_diagnostics.json" end)

    media = media_json |> IO.iodata_to_binary() |> Jason.decode!()
    image = Enum.find(media["provider_live"]["providers"], &(&1["label"] == "image"))

    assert image["status"] == "failed"
    assert image["target_provider"] == "vertex_imagen"
    assert image["reason_kind"] == "vertex_imagen_http_error:permission_denied"
    assert image["command"] =~ "--provider vertex_imagen"
    assert image["secret_command"] =~ "--provider vertex_imagen --api-key-secret SECRET_NAME"
    refute inspect(media) =~ "private provider response"
  end

  test "redacts sensitive config assignments and inline tokens" do
    text = """
    model = "claude"
    api_key = "sk-ant-real-secret"
    bot_token = "123:abc"
    wallet_key = "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    note = "Bearer abc.def"
    """

    redacted = SupportBundle.redact_text(text)

    assert redacted =~ ~s(model = "claude")
    assert redacted =~ ~s(api_key = "[redacted]")
    assert redacted =~ ~s(bot_token = "[redacted]")
    assert redacted =~ ~s(wallet_key = "[redacted]")
    assert redacted =~ "Bearer [redacted]"
    refute redacted =~ "sk-ant-real-secret"
    refute redacted =~ "123:abc"
    refute redacted =~ "0123456789abcdef"
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_support_bundle_test_#{System.unique_integer([:positive])}"
    )
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
