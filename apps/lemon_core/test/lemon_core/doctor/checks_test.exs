defmodule LemonCore.Doctor.ChecksTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.Check

  alias LemonCore.Doctor.Checks.{
    ACP,
    Browser,
    Channels,
    Config,
    Cron,
    Extensions,
    LSP,
    MCP,
    Media,
    NodeTools,
    OpenAICompat,
    Providers,
    Runtime,
    Skills,
    TerminalBackends,
    Usage
  }

  describe "Config.run/1" do
    test "returns a list of Check structs" do
      checks = Config.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "check names are unique" do
      names = Config.run() |> Enum.map(& &1.name)
      assert length(names) == length(Enum.uniq(names))
    end
  end

  describe "Runtime.run/1" do
    test "returns a list of Check structs" do
      checks = Runtime.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end
  end

  describe "Providers.run/1" do
    test "returns a list of Check structs" do
      checks = Providers.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "provider routing check reports a ready fallback without leaking credentials" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "provider_routing_check_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [providers.zai]
        api_key = "private-zai-key"

        [defaults]
        provider = "openai"
        model = "glm-5-turbo"

        [runtime.provider_routing]
        fallback_providers = ["zai"]
        """
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Providers.run(project_dir: tmp_dir)
      routing_check = Enum.find(checks, &(&1.name == "providers.routing"))

      assert routing_check.status == :pass
      assert routing_check.message =~ "Default provider is not credential-ready"
      assert routing_check.message =~ "zai"
      refute inspect(routing_check) =~ "private-zai-key"
    end
  end

  describe "Usage.run/1" do
    test "returns a list of Check structs" do
      checks = Usage.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "reports safe aggregate usage without leaking stored prompt or credential fields" do
      checks =
        Usage.run(
          summary: %{
            total_cost: 0.42,
            total_requests: 3,
            total_tokens: %{input: 1_000, output: 500},
            breakdown: %{"openai" => 0.42},
            requests: %{"openai" => 3},
            tokens: %{"openai" => %{input: 1_000, output: 500}},
            prompt: "private usage prompt",
            api_key: "usage-secret-key"
          },
          today: %{date: Date.to_iso8601(Date.utc_today()), total_cost: 0.42},
          quotas: %{runs_limit: 10, tokens_limit: 2_000, cost_limit: 1.0}
        )

      usage = Enum.find(checks, &(&1.name == "usage.status"))

      assert usage.status == :pass
      assert usage.message =~ "3 request(s)"
      assert usage.message =~ "1500 token(s)"
      assert usage.message =~ "1 provider(s)"
      refute inspect(usage) =~ "private usage prompt"
      refute inspect(usage) =~ "usage-secret-key"
    end

    test "warns when configured usage quotas are exceeded" do
      checks =
        Usage.run(
          summary: %{
            total_cost: 1.5,
            total_requests: 3,
            total_tokens: %{input: 1_000, output: 500}
          },
          quotas: %{runs_limit: 2, tokens_limit: 1_000, cost_limit: 1.0}
        )

      usage = Enum.find(checks, &(&1.name == "usage.status"))

      assert usage.status == :warn
      assert usage.message =~ "over a configured quota"
      assert usage.remediation =~ "Web `/ops`"
    end
  end

  describe "Channels.run/1" do
    test "returns a list of Check structs" do
      checks = Channels.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "reports Discord live parity gates from redacted proofs" do
      tmp_dir = tmp_dir("channels_checks")

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [gateway]
        enable_discord = true

        [gateway.discord]
        bot_token_secret = "discord_bot_token_secret_name"
        message_content_intent_enabled = false
        """
      )

      write_proof!(tmp_dir, "discord-dm-proof.json", %{
        ok: false,
        checks: [
          %{
            name: "discord_dm_prompt_round_trip",
            ok: false,
            proof_scope: "discord direct message channel setup",
            setup_error:
              "Discord API POST /users/@me/channels failed: 400 {\"message\":\"Cannot send messages to this user\",\"code\":50007}"
          }
        ]
      })

      write_proof!(tmp_dir, "discord-slash-proof.json", %{
        status: "completed",
        proof_object: "lemon.discord_slash_interaction",
        proof_scope: "discord_slash_interaction_deterministic",
        coverage: %{
          registered_command_count: 16,
          local_response_command_count: 13,
          real_client_click_proof: false
        },
        checks: [
          %{name: "discord_slash_interaction_inventory", status: "completed"}
        ]
      })

      write_proof!(tmp_dir, "discord-slash-client-click-proof.json", %{
        ok: true,
        checks: [
          %{
            name: "discord_slash_client_click_proof_artifact",
            status: "completed",
            proof_object: "lemon.discord_slash_client_click"
          }
        ]
      })

      write_proof!(tmp_dir, "discord-all-slash-registration-latest.json", %{
        status: "completed",
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        coverage: %{
          contains_slash_registration: true,
          contains_all_slash_registration: true
        },
        checks: [
          %{name: "discord_all_slash_registration", status: "completed"}
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Channels.run(project_dir: tmp_dir)

      readiness = Enum.find(checks, &(&1.name == "channels.readiness"))
      assert readiness.status == :warn
      assert readiness.message =~ "Telegram/Discord launch gates:"
      assert readiness.message =~ "gate(s)"
      assert is_binary(readiness.remediation)
      refute inspect(readiness) =~ "discord_bot_token_secret_name"

      assert check_status(checks, "channels.discord.config") == :pass
      assert check_status(checks, "channels.discord.dm") == :warn
      assert check_status(checks, "channels.discord.free_response") == :warn
      assert check_status(checks, "channels.discord.slash_deterministic") == :pass
      assert check_status(checks, "channels.discord.slash_registration") == :pass
      assert check_status(checks, "channels.discord.slash_client_click") == :pass

      assert Enum.find(checks, &(&1.name == "channels.discord.dm")).message =~
               "setup refusal"

      free_response = Enum.find(checks, &(&1.name == "channels.discord.free_response"))
      assert free_response.remediation =~ "message_content gateway intent"
      refute inspect(free_response) =~ "discord_bot_token_secret_name"
    end

    test "reports Discord free-response Message Content Intent proof drift" do
      tmp_dir = tmp_dir("channels_message_content_intent")

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [gateway]
        enable_discord = true

        [gateway.discord]
        bot_token_secret = "discord_bot_token_secret_name"
        message_content_intent_enabled = true
        """
      )

      write_proof!(tmp_dir, "discord-free-response-latest.json", %{
        status: "failed",
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        reason_kind: "discord_no_reply_for_unmentioned_message",
        checks: [
          %{
            name: "discord_free_response_trigger_round_trip",
            status: "failed",
            reason_kind: "discord_message_content_intent_or_delivery"
          }
        ],
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_raw_channel_ids: false,
          includes_raw_user_ids: false,
          includes_raw_message_bodies: false,
          includes_secret_names: false
        }
      })

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Channels.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "channels.discord.free_response"))

      assert check.status == :warn
      assert check.message =~ "Message Content Intent"
      assert check.message =~ "despite the local declaration"
      assert check.remediation =~ "message_content gateway intent"
      assert check.remediation =~ "Discord Developer Portal"
      refute inspect(checks) =~ "discord_bot_token_secret_name"
    end

    test "reports Discord slash client-click missing artifact reason" do
      tmp_dir = tmp_dir("channels_slash_client_click_missing")

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [gateway]
        enable_discord = true

        [gateway.discord]
        bot_token_secret = "discord_bot_token_secret_name"
        """
      )

      write_proof!(tmp_dir, "discord-slash-client-click-check-latest.json", %{
        status: "failed",
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        checks: [
          %{
            name: "discord_slash_client_click_proof_artifact",
            status: "failed",
            proof_object: "lemon.discord_slash_client_click",
            reason_kind: "discord_slash_client_click_missing"
          }
        ],
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_raw_channel_ids: false,
          includes_raw_user_ids: false,
          includes_raw_message_bodies: false,
          includes_secret_names: false
        }
      })

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Channels.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "channels.discord.slash_client_click"))

      assert check.status == :warn
      assert check.message =~ "has not been captured yet"
      assert check.remediation =~ "--wait-slash-client-click-proof"
      assert check.remediation =~ "--proof-path"
      refute inspect(checks) =~ "discord_bot_token_secret_name"
    end

    test "classifies explicit Message Content Intent proof hints before generic no-reply hints" do
      tmp_dir = tmp_dir("channels_message_content_reason")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "discord-free-response-latest.json", %{
        ok: false,
        checks: [
          %{
            name: "discord_free_response_trigger_round_trip",
            ok: false,
            failure_hint:
              "No Lemon reply was observed for an unmentioned guild/thread message. Local channel diagnostics currently report message_content_intent_declared=false."
          }
        ]
      })

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: tmp_dir, limit: 10)

      assert proofs.reason_kind_counts["discord_message_content_intent_or_delivery"] == 1
      refute Map.has_key?(proofs.reason_kind_counts, "discord_no_reply_for_unmentioned_message")

      assert Enum.any?(
               proofs.latest_checks,
               &(&1.name == "discord_free_response_trigger_round_trip" and
                   &1.reason_kind == "discord_message_content_intent_or_delivery")
             )
    end

    test "reports Telegram local voice transcription proof from redacted artifact" do
      tmp_dir = tmp_dir("channels_telegram_voice")

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [gateway]
        enable_telegram = true

        [gateway.telegram]
        bot_token_secret = "telegram_bot_token_secret_name"
        voice_transcription = true
        voice_transcription_provider = "local_transcript"
        """
      )

      write_proof!(tmp_dir, "telegram-voice-local-latest.json", %{
        status: "completed",
        proof_object: "lemon.telegram_voice_local_smoke",
        proof_scope: "telegram_voice_local_transcript",
        completed_count: 3,
        failed_count: 0,
        skipped_count: 0,
        coverage: %{check_count: 3},
        checks: [
          %{name: "telegram_voice_local_transcript_provider", status: "completed"},
          %{name: "telegram_voice_local_no_api_key", status: "completed"},
          %{name: "telegram_voice_local_inbound_metadata", status: "completed"}
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Channels.run(project_dir: tmp_dir)

      assert check_status(checks, "channels.telegram.config") == :pass
      assert check_status(checks, "channels.telegram.voice_transcription") == :pass

      assert Enum.find(checks, &(&1.name == "channels.telegram.voice_transcription")).message =~
               "without provider credentials"

      refute inspect(checks) =~ "telegram_bot_token_secret_name"
    end

    test "warns when only Discord media slash registration proof is present" do
      tmp_dir = tmp_dir("channels_media_registration_only")

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [gateway]
        enable_discord = true

        [gateway.discord]
        bot_token_secret = "discord_bot_token_secret_name"
        """
      )

      write_proof!(tmp_dir, "discord-media-slash-registration-latest.json", %{
        status: "completed",
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        coverage: %{
          contains_slash_registration: true,
          contains_media_slash_registration: true,
          contains_all_slash_registration: false
        },
        checks: [
          %{name: "discord_media_slash_registration", status: "completed"}
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Channels.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "channels.discord.slash_registration"))

      assert check.status == :warn
      assert check.message =~ "/media slash registration proof is completed"
    end
  end

  describe "Media.run/1" do
    test "returns a list of Check structs" do
      checks = Media.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "reports channel delivery separately from incomplete provider proofs" do
      tmp_dir = tmp_dir("media_checks")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "telegram-generated-audio-latest.json", %{
        status: "completed",
        proof_object: "lemon.telegram_live_matrix",
        proof_scope: "telegram_live_matrix",
        checks: [
          %{
            name: "telegram_forum_topic_generated_audio_delivery",
            status: "completed",
            document: %{has_document: true},
            marker_seen: true
          }
        ]
      })

      write_proof!(tmp_dir, "discord-generated-audio-latest.json", %{
        status: "completed",
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        checks: [
          %{
            name: "discord_generated_audio_delivery",
            status: "completed",
            bot_reply: %{attachment_count: 1}
          }
        ]
      })

      write_proof!(tmp_dir, "media-vision-smoke-latest.json", %{
        status: "completed",
        proof_object: "lemon.media_vision_smoke",
        proof_scope: "media_provider",
        completed_count: 1,
        failed_count: 0,
        skipped_count: 0,
        details: %{
          provider: "openai_vision",
          model: "openrouter:test-model",
          artifact_mime_type: "application/json",
          artifact_bytes: 59,
          analysis_chars: 43,
          artifact_hash: "private-artifact-hash",
          job_id_hash: "private-job-hash"
        },
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_image_bytes: false,
          includes_raw_analysis: false,
          includes_raw_provider_response: false
        }
      })

      write_proof!(tmp_dir, "media-image-smoke-latest.json", %{
        status: "failed",
        proof_object: "lemon.media_image_smoke",
        proof_scope: "media_provider",
        completed_count: 0,
        failed_count: 1,
        skipped_count: 0,
        reason_kind: "provider_http_error",
        details: %{
          provider: "openai_image",
          model: "gpt-image-1",
          reason_hash: "private-reason-hash",
          raw_provider_response: "private provider response"
        },
        cleanup: %{
          includes_raw_api_keys: false,
          includes_raw_prompts: false,
          includes_raw_provider_response: false
        }
      })

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Media.run(project_dir: tmp_dir)
      channel = Enum.find(checks, &(&1.name == "media.channel_delivery"))
      provider = Enum.find(checks, &(&1.name == "media.provider_live"))

      assert channel.status == :pass
      assert channel.message =~ "Telegram and Discord"
      assert provider.status == :warn
      assert provider.message =~ "completed vision"
      assert provider.message =~ "failed image"
      assert provider.message =~ "missing TTS, STT, video"
      assert provider.message =~ "reasons image=provider_http_error"
      assert provider.remediation =~ "scripts/live_media_image_smoke.exs"
      assert provider.remediation =~ "LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test"

      assert provider.remediation =~
               "--proof-path .lemon/proofs/media-image-smoke-latest.json --provider openai_image"

      assert provider.remediation =~ "--proof-path .lemon/proofs/media-video-smoke-latest.json"
      assert provider.remediation =~ "--api-key-secret SECRET_NAME"
      assert provider.remediation =~ "Provider hints"
      assert provider.remediation =~ "image reached the provider but returned an HTTP error"
      refute inspect(checks) =~ "private-artifact-hash"
      refute inspect(checks) =~ "private provider response"
    end

    test "provider live remediation distinguishes permission and billing blockers" do
      tmp_dir = tmp_dir("media_provider_reason_remediation")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "media-image-smoke-latest.json", %{
        status: "failed",
        proof_object: "lemon.media_image_smoke",
        proof_scope: "media_provider",
        reason_kind: "vertex_imagen_http_error:permission_denied",
        details: %{provider: "vertex_imagen"}
      })

      write_proof!(tmp_dir, "media-speech-smoke-latest.json", %{
        status: "failed",
        proof_object: "lemon.media_speech_smoke",
        proof_scope: "media_provider",
        reason_kind: "elevenlabs_tts_http_error:payment_required",
        details: %{provider: "elevenlabs_tts"}
      })

      write_proof!(tmp_dir, "media-video-smoke-latest.json", %{
        status: "failed",
        proof_object: "lemon.media_video_smoke",
        proof_scope: "media_provider",
        reason_kind: "openai_video_http_error:billing_limit_user_error",
        details: %{provider: "openai_video"}
      })

      for {path, provider} <- [
            {"media-transcription-smoke-latest.json", "openai_transcribe"},
            {"media-vision-smoke-latest.json", "openai_vision"}
          ] do
        write_proof!(tmp_dir, path, %{
          status: "completed",
          proof_object: "lemon.media_provider_smoke",
          proof_scope: "media_provider",
          details: %{provider: provider}
        })
      end

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Media.run(project_dir: tmp_dir)
      provider = Enum.find(checks, &(&1.name == "media.provider_live"))

      assert provider.status == :warn
      assert provider.remediation =~ "Inspect provider permissions, quota, or billing"

      assert provider.remediation =~
               "--proof-path .lemon/proofs/media-image-smoke-latest.json --provider vertex_imagen"

      assert provider.remediation =~
               "--proof-path .lemon/proofs/media-speech-smoke-latest.json --provider elevenlabs_tts"

      assert provider.remediation =~
               "--proof-path .lemon/proofs/media-video-smoke-latest.json --provider openai_video"

      assert provider.remediation =~ "image reached the provider but permissions were denied"
      assert provider.remediation =~ "TTS reached the provider but payment is required"
      assert provider.remediation =~ "video reached the provider but hit a billing or quota limit"
    end

    test "accepts MEDIA directive channel delivery proofs" do
      tmp_dir = tmp_dir("media_directive_checks")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "telegram-media-directive-latest.json", %{
        status: "completed",
        proof_object: "lemon.telegram_live_matrix",
        proof_scope: "telegram_live_matrix",
        coverage: %{contains_media_directive: true},
        checks: [
          %{
            name: "telegram_forum_topic_media_directive_delivery",
            status: "completed",
            telegram_has_document: true,
            marker_seen: true,
            directive_leaked: false
          }
        ]
      })

      write_proof!(tmp_dir, "discord-media-directive-latest.json", %{
        status: "completed",
        proof_object: "lemon.discord_live_matrix",
        proof_scope: "discord_live_matrix",
        coverage: %{contains_media_directive: true},
        checks: [
          %{
            name: "discord_media_directive_delivery",
            status: "completed",
            attachment_count: 1,
            directive_leaked: false
          }
        ]
      })

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Media.run(project_dir: tmp_dir)
      channel = Enum.find(checks, &(&1.name == "media.channel_delivery"))

      assert channel.status == :pass
      assert channel.message =~ "Media attachment delivery proof"
    end

    test "passes provider live check when all provider proof artifacts are completed" do
      tmp_dir = tmp_dir("media_provider_complete")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      for provider <- [
            "vertex_imagen",
            "google_tts",
            "openai_transcribe",
            "openai_vision",
            "vertex_veo"
          ] do
        write_proof!(tmp_dir, "#{provider}-latest.json", %{
          status: "completed",
          proof_object: "lemon.media_provider_smoke",
          proof_scope: "media_provider",
          completed_count: 1,
          failed_count: 0,
          skipped_count: 0,
          details: %{
            provider: provider,
            model: "test-model",
            artifact_mime_type: "application/json",
            artifact_bytes: 12,
            artifact_hash: "private-artifact-hash",
            job_id_hash: "private-job-hash"
          }
        })
      end

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Media.run(project_dir: tmp_dir)
      provider = Enum.find(checks, &(&1.name == "media.provider_live"))

      assert provider.status == :pass
      assert provider.message =~ "image, TTS, STT, vision, video"
    end
  end

  describe "TerminalBackends.run/1" do
    test "returns a list of Check structs" do
      checks = TerminalBackends.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skips when the terminal backend proof has not been generated" do
      tmp_dir = tmp_dir("terminal_backends_missing")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = TerminalBackends.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "terminal.backends_live"))

      assert check.status == :skip
      assert check.message =~ "has not been generated"
    end

    test "passes when all terminal backend result rows are completed" do
      tmp_dir = tmp_dir("terminal_backends_completed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_terminal_backend_proof!(tmp_dir, [
        %{backend: "local", status: "completed"},
        %{backend: "local_pty", status: "completed"},
        %{backend: "docker", status: "completed"},
        %{backend: "ssh", status: "completed"}
      ])

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = TerminalBackends.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "terminal.backends_live"))

      assert check.status == :pass
      assert check.message =~ "local, local PTY, Docker, SSH"
      refute inspect(checks) =~ tmp_dir
    end

    test "warns when a terminal backend failed or is missing from the latest proof" do
      tmp_dir = tmp_dir("terminal_backends_failed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_terminal_backend_proof!(tmp_dir, [
        %{backend: "local", status: "completed"},
        %{backend: "local_pty", status: "completed"},
        %{backend: "docker", status: "failed"}
      ])

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = TerminalBackends.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "terminal.backends_live"))

      assert check.status == :warn
      assert check.message =~ "failed Docker"
      assert check.message =~ "missing SSH"
      assert check.remediation =~ "scripts/live_terminal_backend_smoke.exs"
      assert check.remediation =~ ".lemon/proofs/terminal-backend-latest.json"
      refute inspect(checks) =~ tmp_dir
    end
  end

  describe "OpenAICompat.run/1" do
    test "returns a list of Check structs" do
      checks = OpenAICompat.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skips when the OpenAI-compatible proof has not been generated" do
      tmp_dir = tmp_dir("openai_compat_missing")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = OpenAICompat.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "openai_compat.api_preview"))

      assert check.status == :skip
      assert check.message =~ "has not been generated"
    end

    test "passes when OpenAI-compatible smoke result rows are completed" do
      tmp_dir = tmp_dir("openai_compat_completed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      write_openai_compat_proof!(tmp_dir, openai_compat_results("completed"))

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = OpenAICompat.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "openai_compat.api_preview"))
      proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: tmp_dir, limit: 100)

      assert check.status == :pass
      assert check.message =~ "external fetch"
      assert proofs.proof_scope_counts["openai_compat_api"] == 1
      assert proofs.status_counts["completed"] == 1
      assert proofs.check_name_counts["openai_compat_external_openai_sdk_client"] == 1
      refute inspect(checks) =~ tmp_dir
    end

    test "warns when OpenAI-compatible smoke rows are failed or missing" do
      tmp_dir = tmp_dir("openai_compat_failed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      results =
        "completed"
        |> openai_compat_results()
        |> Enum.reject(&(&1.name == "run_cancel"))
        |> Enum.map(fn
          %{name: "external_python_sdk_client"} = row -> %{row | status: "failed"}
          row -> row
        end)

      write_openai_compat_proof!(tmp_dir, results)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = OpenAICompat.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "openai_compat.api_preview"))

      assert check.status == :warn
      assert check.message =~ "failed OpenAI Python SDK client"
      assert check.message =~ "missing run cancel"
      assert check.remediation =~ "scripts/live_openai_compat_smoke.exs"
      refute inspect(checks) =~ tmp_dir
    end
  end

  describe "ACP.run/1" do
    test "returns a list of Check structs" do
      checks = ACP.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skips when ACP proof artifacts have not been generated" do
      tmp_dir = tmp_dir("acp_missing")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = ACP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "acp.preview"))

      assert check.status == :skip
      assert check.message =~ "has not been generated"
    end

    test "passes when ACP stdio, external client, and official SDK proofs are completed" do
      tmp_dir = tmp_dir("acp_completed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      write_acp_proofs!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = ACP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "acp.preview"))
      proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: tmp_dir, limit: 100)

      assert check.status == :pass
      assert check.message =~ "official ACP SDK"
      assert proofs.proof_scope_counts["acp_stdio"] == 1
      assert proofs.proof_scope_counts["acp_stdio_external_client"] == 1
      assert proofs.proof_scope_counts["acp_official_sdk_client"] == 1
      assert proofs.check_name_counts["acp_official_sdk_approval_bus_permission_bridge"] == 1
      refute inspect(checks) =~ tmp_dir
    end

    test "warns when ACP proof artifacts are failed or missing" do
      tmp_dir = tmp_dir("acp_failed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_acp_proof!(
        tmp_dir,
        "acp-stdio-smoke-latest.json",
        "lemon.acp_stdio_smoke",
        acp_stdio_results()
      )

      write_acp_proof!(
        tmp_dir,
        "acp-stdio-external-client-latest.json",
        "lemon.acp_stdio_external_client_smoke",
        Enum.map(acp_external_results(), fn
          %{name: "approval_bus_permission_bridge"} = row -> %{row | status: "failed"}
          row -> row
        end),
        update_count: 2,
        client_request_count: 6
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = ACP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "acp.preview"))

      assert check.status == :warn
      assert check.message =~ "failed external Node client"
      assert check.message =~ "missing official ACP SDK client"
      assert check.remediation =~ "scripts/live_acp_stdio_smoke.exs"
      assert check.remediation =~ "scripts/live_acp_official_sdk_client.mjs"
      refute inspect(checks) =~ tmp_dir
    end
  end

  describe "MCP.run/1" do
    test "returns a list of Check structs" do
      checks = MCP.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skips when MCP proof artifacts have not been generated" do
      tmp_dir = tmp_dir("mcp_missing")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = MCP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "mcp.preview"))

      assert check.status == :skip
      assert check.message =~ "has not been generated"
    end

    test "passes when MCP stdio, HTTP, and SSE proofs are completed" do
      tmp_dir = tmp_dir("mcp_completed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      write_mcp_proofs!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = MCP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "mcp.preview"))
      proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: tmp_dir, limit: 100)

      assert check.status == :pass
      assert check.message =~ "Streamable HTTP"
      assert proofs.proof_scope_counts["mcp_stdio"] == 1
      assert proofs.proof_scope_counts["mcp_http"] == 1
      assert proofs.proof_scope_counts["mcp_sse"] == 1
      assert proofs.check_name_counts["mcp_http_oauth_pkce_authorization_code"] == 1
      refute inspect(checks) =~ tmp_dir
    end

    test "warns when MCP proof artifacts are failed or missing" do
      tmp_dir = tmp_dir("mcp_failed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_mcp_proof!(
        tmp_dir,
        "mcp-stdio-latest.json",
        "mcp_stdio_smoke",
        mcp_stdio_results()
      )

      write_mcp_proof!(
        tmp_dir,
        "mcp-http-latest.json",
        "mcp_http_smoke",
        Enum.map(mcp_http_results(), fn
          %{name: "mcp_http_oauth_pkce_authorization_code"} = row ->
            %{row | status: "failed"}

          row ->
            row
        end)
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = MCP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "mcp.preview"))

      assert check.status == :warn
      assert check.message =~ "failed Streamable HTTP"
      assert check.message =~ "missing SSE"
      assert check.remediation =~ "scripts/live_mcp_stdio_smoke.exs"
      assert check.remediation =~ "scripts/live_mcp_sse_smoke.exs"
      refute inspect(checks) =~ tmp_dir
    end
  end

  describe "Browser.run/1" do
    test "returns a list of Check structs" do
      checks = Browser.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skips when browser proof artifact has not been generated" do
      tmp_dir = tmp_dir("browser_missing")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Browser.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "browser.preview"))

      assert check.status == :skip
      assert check.message =~ "has not been generated"
    end

    test "passes when browser smoke proof is completed and redacted" do
      tmp_dir = tmp_dir("browser_completed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      write_browser_proof!(tmp_dir, "browser-smoke-latest.json", browser_proof())

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Browser.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "browser.preview"))
      proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: tmp_dir, limit: 100)

      assert check.status == :pass
      assert check.message =~ "supervised local driver"
      assert proofs.proof_scope_counts["browser_smoke"] == 1
      refute inspect(checks) =~ tmp_dir
    end

    test "warns when browser smoke proof is incomplete" do
      tmp_dir = tmp_dir("browser_incomplete")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      proof =
        browser_proof(%{
          "browser_download_completed" => false,
          "failed_count" => 1,
          "progress_cleanup" => %{
            "contains_raw_sensitive_values" => false,
            "includes_raw_urls" => false,
            "includes_selectors" => true,
            "includes_typed_text" => false,
            "includes_cookie_values" => false,
            "includes_page_text" => false,
            "includes_artifact_paths" => false,
            "includes_raw_paths" => false,
            "includes_screenshot_bytes" => false
          }
        })

      write_browser_proof!(tmp_dir, "browser-smoke-latest.json", proof)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Browser.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "browser.preview"))

      assert check.status == :warn
      assert check.message =~ "failed or incomplete"
      assert check.remediation =~ "scripts/live_browser_smoke.exs"
      refute inspect(checks) =~ tmp_dir
    end
  end

  describe "Cron.run/1" do
    test "returns a list of Check structs" do
      checks = Cron.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skips when cron proof artifacts have not been generated" do
      tmp_dir = tmp_dir("cron_missing")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Cron.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "cron.preview"))

      assert check.status == :skip
      assert check.message =~ "has not been generated"
    end

    test "passes when cron diagnostics, restart, and channel-origin proofs are completed" do
      tmp_dir = tmp_dir("cron_completed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      write_cron_proofs!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Cron.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "cron.preview"))

      assert check.status == :pass
      assert check.message =~ "runtime restart"
      refute inspect(checks) =~ tmp_dir
    end

    test "warns when cron proof artifacts are failed or missing" do
      tmp_dir = tmp_dir("cron_failed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_cron_diagnostics_proof!(
        tmp_dir,
        Enum.map(cron_diagnostics_checks(), fn
          %{name: "cron_diagnostics_redaction"} = row -> %{row | status: "failed"}
          row -> row
        end)
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Cron.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "cron.preview"))

      assert check.status == :warn
      assert check.message =~ "failed diagnostics"
      assert check.message =~ "missing runtime restart"
      assert check.message =~ "channel origin"
      assert check.remediation =~ "scripts/live_cron_diagnostics_smoke.exs"
      refute inspect(checks) =~ tmp_dir
    end
  end

  describe "LSP.run/1" do
    test "returns a list of Check structs" do
      checks = LSP.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skips when LSP proof artifacts have not been generated" do
      tmp_dir = tmp_dir("lsp_missing")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = LSP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "lsp.preview"))

      assert check.status == :skip
      assert check.message =~ "has not been generated"
    end

    test "passes when LSP project and real repo fixture proofs are completed" do
      tmp_dir = tmp_dir("lsp_completed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
      write_lsp_proofs!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = LSP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "lsp.preview"))

      assert check.status == :pass
      assert check.message =~ "real repo fixtures"
      refute inspect(checks) =~ tmp_dir
    end

    test "warns when LSP proof artifacts are failed or missing" do
      tmp_dir = tmp_dir("lsp_failed")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_lsp_proof!(
        tmp_dir,
        "lsp-project-fixtures-latest.json",
        "lsp_project_fixtures_smoke",
        Enum.map(lsp_results("lsp_project_fixtures_smoke"), fn
          %{name: "lsp_project_fixtures_smoke_pyright_editor_flow"} = row ->
            %{row | status: "failed"}

          row ->
            row
        end)
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = LSP.run(project_dir: tmp_dir)
      check = Enum.find(checks, &(&1.name == "lsp.preview"))

      assert check.status == :warn
      assert check.message =~ "failed project fixtures"
      assert check.message =~ "missing real repo fixtures"
      assert check.remediation =~ "scripts/live_lsp_server_smoke.exs"
      refute inspect(checks) =~ tmp_dir
    end
  end

  describe "Extensions.run/1" do
    test "returns a list of Check structs" do
      checks = Extensions.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "reports completed redacted extension tool telemetry proof" do
      tmp_dir = tmp_dir("extensions_checks")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "extension-host-smoke-latest.json", %{
        status: "completed",
        generated_at: "2026-05-17T00:44:58.671764Z",
        completed_count: 7,
        failed_count: 0,
        checks: [
          %{name: "extension_tool_execution_emits_redacted_telemetry", status: "completed"},
          %{name: "extensions_disabled_blocks_explicit_path_execution", status: "completed"},
          %{
            name: "extensions_env_disabled_blocks_explicit_path_execution",
            status: "completed"
          }
        ],
        redaction: %{
          contains_raw_paths: false,
          contains_file_contents: false,
          contains_load_error_messages: false,
          contains_tool_result_payload: false
        }
      })

      checks = Extensions.run(project_dir: tmp_dir)

      assert check_status(checks, "extensions.telemetry") == :pass
      refute inspect(checks) =~ tmp_dir
    end

    test "reports completed redacted wasm tool telemetry proof" do
      tmp_dir = tmp_dir("extensions_wasm_checks")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "wasm-tool-telemetry-latest.json", %{
        status: "completed",
        generated_at: "2026-05-17T01:18:56.838802Z",
        completed_count: 4,
        failed_count: 0,
        checks: [
          %{name: "wasm_tool_success_emits_redacted_start_stop_telemetry", status: "completed"},
          %{name: "wasm_tool_error_emits_redacted_error_status", status: "completed"},
          %{name: "wasm_tool_exit_emits_redacted_exception_telemetry", status: "completed"},
          %{name: "wasm_tool_telemetry_omits_raw_sensitive_values", status: "completed"}
        ],
        host_boundary: %{
          host: "wasm",
          emits_start_stop_exception: true,
          uses_hashed_wasm_paths: true,
          tool_count: 3
        },
        redaction: %{
          contains_raw_paths: false,
          contains_raw_params: false,
          contains_raw_tool_call_ids: false,
          contains_sidecar_error_text: false,
          contains_tool_result_payload: false
        }
      })

      checks = Extensions.run(project_dir: tmp_dir)

      assert check_status(checks, "extensions.wasm_telemetry") == :pass
      refute inspect(checks) =~ tmp_dir
    end

    test "reports completed wasm policy proof" do
      tmp_dir = tmp_dir("extensions_wasm_policy_checks")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "wasm-policy-latest.json", %{
        status: "completed",
        generated_at: "2026-05-17T01:26:08.374597Z",
        completed_count: 5,
        failed_count: 0,
        checks: [
          %{name: "wasm_policy_http_requires_approval", status: "completed"},
          %{name: "wasm_policy_tool_invoke_requires_approval", status: "completed"},
          %{name: "wasm_policy_exec_requires_approval", status: "completed"},
          %{name: "wasm_policy_safe_capabilities_execute_without_approval", status: "completed"},
          %{name: "wasm_policy_explicit_never_overrides_default_approval", status: "completed"}
        ],
        policy_boundary: %{
          http_requires_approval_by_default: true,
          tool_invoke_requires_approval_by_default: true,
          exec_requires_approval_by_default: true,
          safe_capabilities_execute_without_approval: true,
          explicit_never_can_override_default: true
        },
        redaction: %{
          contains_raw_paths: false,
          contains_raw_params: false,
          contains_raw_tool_call_ids: false
        }
      })

      checks = Extensions.run(project_dir: tmp_dir)

      assert check_status(checks, "extensions.wasm_policy") == :pass
      refute inspect(checks) =~ tmp_dir
    end

    test "reports completed extension registry audit proof" do
      tmp_dir = tmp_dir("extensions_registry_audit_checks")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "extension-registry-audit-latest.json", %{
        status: "completed",
        generated_at: "2026-05-17T02:02:00Z",
        completed_count: 5,
        failed_count: 0,
        checks: [
          %{name: "extension_registry_validates_code_free_index", status: "completed"},
          %{name: "extension_registry_blocks_unaudited_install", status: "completed"},
          %{name: "extension_registry_detects_audited_update", status: "completed"},
          %{name: "extension_registry_audit_does_not_load_code", status: "completed"},
          %{name: "extension_registry_audit_redacts_sensitive_values", status: "completed"}
        ],
        registry_boundary: %{
          validates_manifest_metadata: true,
          blocks_unaudited_installs: true,
          detects_update_candidates: true,
          loads_extension_code: false,
          installable_count: 2,
          blocked_count: 2,
          update_candidate_count: 1,
          blocked_update_count: 1
        },
        redaction: %{
          contains_raw_registry_paths: false,
          contains_distribution_urls: false,
          contains_package_names: false,
          contains_manifest_contents: false
        }
      })

      checks = Extensions.run(project_dir: tmp_dir)

      assert check_status(checks, "extensions.registry_audit") == :pass
      refute inspect(checks) =~ tmp_dir
    end

    test "reports completed wasm lifecycle proof" do
      tmp_dir = tmp_dir("extensions_wasm_lifecycle_checks")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "wasm-lifecycle-latest.json", %{
        status: "completed",
        generated_at: "2026-05-17T02:29:28.355Z",
        completed_count: 5,
        failed_count: 0,
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

      checks = Extensions.run(project_dir: tmp_dir)

      assert check_status(checks, "extensions.wasm_lifecycle") == :pass
      refute inspect(checks) =~ tmp_dir
    end
  end

  describe "NodeTools.run/1" do
    test "returns a check per binary" do
      checks = NodeTools.run()
      assert is_list(checks)
      assert length(checks) >= 1
    end

    test "git check is present" do
      checks = NodeTools.run()
      assert Enum.any?(checks, &String.contains?(&1.name, "git"))
    end

    test "git check passes when git is on PATH" do
      # In CI/dev environments git is always available
      if System.find_executable("git") do
        checks = NodeTools.run()
        git_check = Enum.find(checks, &String.contains?(&1.name, "git"))
        assert git_check.status == :pass
      end
    end
  end

  describe "Skills.run/1" do
    test "returns a list of Check structs" do
      checks = Skills.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skills directory check has expected name" do
      checks = Skills.run()
      assert Enum.any?(checks, &(&1.name == "skills.directory"))
    end
  end

  defp tmp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp write_proof!(tmp_dir, filename, proof) do
    path = Path.join([tmp_dir, ".lemon", "proofs", filename])
    File.write!(path, Jason.encode!(proof))
  end

  defp write_terminal_backend_proof!(tmp_dir, results) do
    write_proof!(tmp_dir, "terminal-backend-latest.json", %{
      status:
        if(Enum.any?(results, &(Map.get(&1, :status) == "failed")),
          do: "failed",
          else: "completed"
        ),
      proof_object: "lemon.terminal_backend_smoke",
      completed_count: Enum.count(results, &(Map.get(&1, :status) == "completed")),
      failed_count: Enum.count(results, &(Map.get(&1, :status) == "failed")),
      skipped_count: Enum.count(results, &(Map.get(&1, :status) == "skipped")),
      results: results,
      cleanup: %{
        includes_commands: false,
        includes_environment: false,
        includes_process_output: false
      }
    })
  end

  defp write_openai_compat_proof!(tmp_dir, results) do
    write_proof!(tmp_dir, "openai-compat-smoke-latest.json", %{
      completed_count: Enum.count(results, &(Map.get(&1, :status) == "completed")),
      failed_count: Enum.count(results, &(Map.get(&1, :status) == "failed")),
      endpoint_count: length(results),
      base_url_hash: "private-base-url-hash",
      results: results,
      request_summaries: [
        %{
          endpoint: "chat.completions",
          run_id: "run_private",
          model: "test:model",
          streaming: false,
          session_key_hash: "private-session-hash",
          image_input_count: 0,
          runtime_image_count: 0
        }
      ],
      cleanup: %{
        includes_raw_prompts: false,
        includes_raw_api_keys: false,
        includes_raw_answers: false,
        includes_raw_events: false
      }
    })
  end

  defp openai_compat_results(status) do
    [
      "health_and_capabilities",
      "chat_wait",
      "image_input_metadata",
      "data_url_image_pass_through",
      "non_vision_image_rejection",
      "remote_image_url_fetch_policy",
      "external_fetch_client",
      "external_openai_sdk_client",
      "external_python_sdk_client",
      "response_continuation",
      "stored_response",
      "chat_stream",
      "run_status_redaction",
      "run_cancel"
    ]
    |> Enum.map(&%{name: &1, status: status})
  end

  defp write_acp_proofs!(tmp_dir) do
    write_acp_proof!(
      tmp_dir,
      "acp-stdio-smoke-latest.json",
      "lemon.acp_stdio_smoke",
      acp_stdio_results()
    )

    write_acp_proof!(
      tmp_dir,
      "acp-stdio-external-client-latest.json",
      "lemon.acp_stdio_external_client_smoke",
      acp_external_results(),
      update_count: 2,
      client_request_count: 6
    )

    write_acp_proof!(
      tmp_dir,
      "acp-official-sdk-client-latest.json",
      "lemon.acp_official_sdk_client_smoke",
      acp_official_sdk_results(),
      update_count: 2,
      client_request_count: 4
    )
  end

  defp write_acp_proof!(tmp_dir, filename, object, results, attrs \\ []) do
    proof =
      %{
        object: object,
        completed_count: Enum.count(results, &(Map.get(&1, :status) == "completed")),
        failed_count: Enum.count(results, &(Map.get(&1, :status) == "failed")),
        results: results,
        cleanup: %{
          includes_raw_prompts: false,
          includes_raw_api_keys: false,
          includes_raw_answers: false,
          includes_raw_events: false,
          includes_raw_session_ids: false,
          includes_child_stderr: false,
          includes_raw_file_contents: false,
          includes_raw_file_paths: false
        }
      }
      |> Map.merge(Map.new(attrs))

    write_proof!(tmp_dir, filename, proof)
  end

  defp acp_stdio_results do
    [
      "initialize",
      "session_new",
      "queued_prompt",
      "wait_prompt_updates",
      "session_list_resume_close",
      "parse_error"
    ]
    |> acp_results()
  end

  defp acp_external_results do
    [
      "initialize",
      "session_new",
      "queued_prompt",
      "wait_prompt_updates",
      "client_file_and_permission_requests",
      "approval_bus_permission_bridge",
      "list_resume_close",
      "unsupported_image_block",
      "parse_error"
    ]
    |> acp_results()
  end

  defp acp_official_sdk_results do
    [
      "initialize",
      "session_new",
      "queued_prompt",
      "wait_prompt_updates",
      "client_file_and_permission_requests",
      "approval_bus_permission_bridge",
      "load_cancel",
      "unsupported_image_block"
    ]
    |> acp_results()
  end

  defp acp_results(names), do: Enum.map(names, &%{name: &1, status: "completed"})

  defp write_mcp_proofs!(tmp_dir) do
    write_mcp_proof!(tmp_dir, "mcp-stdio-latest.json", "mcp_stdio_smoke", mcp_stdio_results())
    write_mcp_proof!(tmp_dir, "mcp-http-latest.json", "mcp_http_smoke", mcp_http_results())
    write_mcp_proof!(tmp_dir, "mcp-sse-latest.json", "mcp_sse_smoke", mcp_sse_results())
  end

  defp write_mcp_proof!(tmp_dir, filename, proof, checks) do
    write_proof!(tmp_dir, filename, %{
      status:
        if(Enum.any?(checks, &(Map.get(&1, :status) == "failed")),
          do: "failed",
          else: "completed"
        ),
      proof: proof,
      proof_scope: proof,
      completed_count: Enum.count(checks, &(Map.get(&1, :status) == "completed")),
      failed_count: Enum.count(checks, &(Map.get(&1, :status) == "failed")),
      skipped_count: 0,
      checks: checks,
      cleanup: %{
        includes_raw_paths: false,
        includes_raw_filenames: false,
        includes_raw_prompts: false,
        includes_raw_provider_responses: false,
        includes_raw_tool_arguments: false,
        includes_raw_tool_results: false,
        includes_server_io: false
      }
    })
  end

  defp mcp_stdio_results do
    [
      "mcp_stdio_degraded_startup_missing_command",
      "mcp_stdio_client_initializes",
      "mcp_stdio_lists_tools",
      "mcp_stdio_lists_resources",
      "mcp_stdio_reads_resource",
      "mcp_stdio_lists_prompts",
      "mcp_stdio_gets_prompt",
      "mcp_stdio_calls_tool_success",
      "mcp_stdio_calls_tool_error",
      "mcp_source_discovers_prefixed_stdio_tools",
      "mcp_source_invokes_resource_and_prompt_utilities",
      "mcp_registry_exposes_prefixed_stdio_tools",
      "mcp_source_applies_stdio_filters",
      "mcp_server_accepts_spec_initialized_notification",
      "mcp_stdio_sampling_callback_wrapper",
      "mcp_stdio_sampling_reviewed_model_policy",
      "mcp_stdio_sampling_ops_approval_bridge"
    ]
    |> mcp_results()
  end

  defp mcp_http_results do
    [
      "mcp_http_client_initializes",
      "mcp_http_lists_tools",
      "mcp_http_calls_tool_success",
      "mcp_http_calls_tool_error",
      "mcp_http_lists_resources",
      "mcp_http_reads_resource",
      "mcp_http_lists_prompts",
      "mcp_http_gets_prompt",
      "mcp_http_streamable_sse_response_and_session_headers",
      "mcp_http_oauth_protected_resource_metadata",
      "mcp_http_oauth_authorization_server_metadata",
      "mcp_http_oauth_client_credentials_token_acquisition",
      "mcp_http_oauth_client_credentials_token_refresh",
      "mcp_http_oauth_refresh_token_grant",
      "mcp_http_oauth_client_secret_basic_token_auth",
      "mcp_http_oauth_pkce_authorization_code",
      "mcp_http_oauth_token_cache_resume",
      "mcp_source_discovers_prefixed_http_tools",
      "mcp_source_invokes_http_tool",
      "mcp_source_invokes_http_resource_and_prompt_utilities",
      "mcp_registry_exposes_prefixed_http_tools",
      "mcp_source_status_reports_http_capabilities",
      "mcp_source_applies_http_filters",
      "mcp_source_http_oauth_loopback_callback"
    ]
    |> mcp_results()
  end

  defp mcp_sse_results do
    [
      "mcp_sse_client_initializes",
      "mcp_sse_lists_tools",
      "mcp_sse_calls_tool_success",
      "mcp_sse_calls_tool_error",
      "mcp_sse_lists_resources",
      "mcp_sse_reads_resource",
      "mcp_sse_lists_prompts",
      "mcp_sse_gets_prompt",
      "mcp_source_discovers_prefixed_sse_tools",
      "mcp_source_invokes_sse_tool",
      "mcp_source_invokes_sse_resource_and_prompt_utilities",
      "mcp_registry_exposes_prefixed_sse_tools",
      "mcp_source_status_reports_sse_capabilities",
      "mcp_source_applies_sse_filters"
    ]
    |> mcp_results()
  end

  defp mcp_results(names), do: Enum.map(names, &%{name: &1, status: "completed"})

  defp write_lsp_proofs!(tmp_dir) do
    write_lsp_proof!(
      tmp_dir,
      "lsp-project-fixtures-latest.json",
      "lsp_project_fixtures_smoke",
      lsp_results("lsp_project_fixtures_smoke")
    )

    write_lsp_proof!(
      tmp_dir,
      "lsp-real-repo-fixtures-latest.json",
      "lsp_real_repo_fixtures_smoke",
      lsp_results("lsp_real_repo_fixtures_smoke")
    )
  end

  defp write_lsp_proof!(tmp_dir, filename, proof, checks) do
    write_proof!(tmp_dir, filename, %{
      status:
        if(Enum.any?(checks, &(Map.get(&1, :status) == "failed")),
          do: "failed",
          else: "completed"
        ),
      proof: proof,
      proof_scope: proof,
      completed_count: Enum.count(checks, &(Map.get(&1, :status) == "completed")),
      failed_count: Enum.count(checks, &(Map.get(&1, :status) == "failed")),
      skipped_count: 0,
      checks: checks,
      cleanup: %{
        includes_raw_paths: false,
        includes_file_contents: false,
        includes_diagnostics_output: false,
        includes_raw_session_ids: false,
        includes_server_io: false
      }
    })
  end

  defp lsp_results(prefix) do
    [
      "pyright",
      "gopls",
      "clangd",
      "rust_analyzer",
      "typescript_language_server",
      "elixir_ls"
    ]
    |> Enum.map(&%{name: "#{prefix}_#{&1}_editor_flow", status: "completed"})
  end

  defp write_browser_proof!(tmp_dir, filename, proof) do
    write_proof!(tmp_dir, filename, proof)
  end

  defp browser_proof(overrides \\ %{}) do
    Map.merge(
      %{
        "generated_at" => "2026-05-17T12:44:13.291364Z",
        "result" => "passed",
        "completed_count" => 20,
        "failed_count" => 0,
        "model_visible_image_included" => true,
        "browser_to_media_vision_completed" => true,
        "browser_wait_for_selector_completed" => true,
        "browser_evaluate_completed" => true,
        "browser_hover_completed" => true,
        "browser_select_option_completed" => true,
        "browser_upload_file_completed" => true,
        "browser_download_completed" => true,
        "browser_analyze_completed" => true,
        "browser_analyze_model_visible_image_included" => true,
        "browser_cdp_attach_completed" => true,
        "browser_navigation_metadata_blocked" => true,
        "browser_navigation_public_route_guarded" => true,
        "progress_update_count" => 40,
        "progress_browser_child_action_count" => 40,
        "progress_cleanup" => %{
          "contains_raw_sensitive_values" => false,
          "includes_raw_urls" => false,
          "includes_selectors" => false,
          "includes_typed_text" => false,
          "includes_cookie_values" => false,
          "includes_page_text" => false,
          "includes_artifact_paths" => false,
          "includes_raw_paths" => false,
          "includes_screenshot_bytes" => false
        },
        "exercised_tools" => [
          "browser_navigate",
          "browser_wait_for_selector",
          "browser_evaluate",
          "browser_hover",
          "browser_select_option",
          "browser_upload_file",
          "browser_download",
          "browser_snapshot",
          "browser_type",
          "browser_click",
          "browser_screenshot",
          "browser_screenshot_include_image",
          "media_analyze_image_local_vision",
          "browser_analyze_local_vision",
          "browser_get_content",
          "browser_events",
          "browser_set_cookies",
          "browser_get_cookies",
          "browser_clear_state",
          "browser_cdp_attach_mode"
        ]
      },
      overrides
    )
  end

  defp write_cron_proofs!(tmp_dir) do
    write_cron_diagnostics_proof!(tmp_dir, cron_diagnostics_checks())
    write_cron_runtime_restart_proof!(tmp_dir, cron_runtime_restart_checks())
    write_cron_channel_origin_proof!(tmp_dir, cron_channel_origin_checks())
  end

  defp write_cron_diagnostics_proof!(tmp_dir, checks) do
    write_proof!(tmp_dir, "cron-diagnostics-latest.json", %{
      status: proof_status(checks),
      proof_object: "lemon.cron_diagnostics_smoke",
      proof_scope: "cron_diagnostics",
      completed_count: completed_count(checks),
      failed_count: failed_count(checks),
      skipped_count: 0,
      checks: checks,
      cleanup: %{
        includes_raw_session_ids: false,
        includes_prompts: false,
        includes_outputs: false,
        includes_errors: false,
        includes_raw_agent_ids: false,
        includes_raw_memory_paths: false,
        includes_meta_values: false
      }
    })
  end

  defp write_cron_runtime_restart_proof!(tmp_dir, checks) do
    write_proof!(tmp_dir, "cron-runtime-restart-latest.json", %{
      status: proof_status(checks),
      object: "lemon.cron_runtime_restart_smoke",
      completed_count: completed_count(checks),
      failed_count: failed_count(checks),
      skipped_count: 0,
      checks: checks,
      cleanup: %{
        includes_raw_prompts: false,
        includes_raw_session_ids: false,
        includes_raw_outputs: false,
        includes_raw_store_path: false
      }
    })
  end

  defp write_cron_channel_origin_proof!(tmp_dir, checks) do
    write_proof!(tmp_dir, "cron-channel-origin-latest.json", %{
      status: proof_status(checks),
      proof_object: "lemon.cron_channel_origin_smoke",
      proof_scope: "cron_channel_origin_delivery",
      completed_count: completed_count(checks),
      failed_count: failed_count(checks),
      skipped_count: 0,
      checks: checks,
      cleanup: %{
        includes_raw_session_ids: false,
        includes_prompts: false,
        includes_outputs: false,
        includes_raw_channel_ids: false,
        includes_raw_peer_ids: false,
        includes_raw_cron_ids: false
      }
    })
  end

  defp cron_diagnostics_checks do
    [
      "cron_diagnostics_counts",
      "cron_diagnostics_retry_policy",
      "cron_diagnostics_redaction",
      "cron_support_bundle_entry"
    ]
    |> completed_checks()
  end

  defp cron_runtime_restart_checks do
    [
      "runtime_booted",
      "cron_api_ready",
      "pre_restart_scheduled_run_observed",
      "runtime_restarted",
      "persisted_cron_state_loaded",
      "post_restart_scheduled_run_observed",
      "cleanup_complete"
    ]
    |> completed_checks()
  end

  defp cron_channel_origin_checks do
    [
      "telegram_channel_origin_cron_delivery",
      "discord_channel_origin_cron_delivery"
    ]
    |> completed_checks()
  end

  defp completed_checks(names), do: Enum.map(names, &%{name: &1, status: "completed"})

  defp proof_status(checks) do
    if Enum.any?(checks, &(Map.get(&1, :status) == "failed")),
      do: "failed",
      else: "completed"
  end

  defp completed_count(checks), do: Enum.count(checks, &(Map.get(&1, :status) == "completed"))
  defp failed_count(checks), do: Enum.count(checks, &(Map.get(&1, :status) == "failed"))

  defp check_status(checks, name) do
    checks
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:status)
  end
end
