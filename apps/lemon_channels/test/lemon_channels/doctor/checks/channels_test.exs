defmodule LemonChannels.Doctor.Checks.ChannelsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.Check

  alias LemonChannels.Doctor.Checks.Channels

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

    test "classifies Discord DM setup refusals and no-reply hints from redacted artifacts" do
      tmp_dir = tmp_dir("channels_discord_reason_kinds")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "discord-free-response-proof.json", %{
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
        ]
      })

      write_proof!(tmp_dir, "discord-dm-proof.json", %{
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
              "Discord API POST /users/@me/channels failed: 400 {\"message\": \"Cannot send messages to this user\", \"code\": 50007}"
          }
        ]
      })

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: tmp_dir, limit: 10)

      assert proofs.reason_kind_counts["discord_no_reply_for_unmentioned_message"] == 1
      assert proofs.reason_kind_counts["discord_dm_setup_refused"] == 1
      assert proofs.check_name_counts["setup"] == 2
      assert proofs.proof_scope_counts["discord_direct_message_channel_setup"] == 1

      assert Enum.any?(
               proofs.latest_checks,
               &(&1.name == "discord_free_response_trigger_round_trip" and
                   &1.reason_kind == "discord_no_reply_for_unmentioned_message")
             )

      assert Enum.any?(
               proofs.latest_checks,
               &(&1.name == "discord_dm_prompt_round_trip" and
                   &1.reason_kind == "discord_dm_setup_refused")
             )
    end

    test "extracts Discord live-matrix and slash-interaction evidence from redacted artifacts" do
      tmp_dir = tmp_dir("channels_discord_matrix_evidence")

      File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

      write_proof!(tmp_dir, "discord-slash-proof.json", %{
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

      write_proof!(tmp_dir, "discord-live-matrix-latest.json", %{
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: tmp_dir, limit: 10)

      assert proofs.reason_kind_counts["discord_dm_setup_refused"] == 1
      assert proofs.proof_scope_counts["discord_slash_interaction_deterministic"] == 1
      assert proofs.proof_scope_counts["discord_live_matrix"] == 1
      assert proofs.proof_scope_counts["discord_file_delivery"] == 1
      assert proofs.proof_scope_counts["discord_direct_message_channel"] == 1
      assert proofs.proof_scope_counts["channel_generated_media_delivery"] == 1
      assert proofs.check_name_counts["discord_file_delivery"] == 1
      assert proofs.check_name_counts["discord_generated_audio_delivery"] == 1
      assert proofs.check_name_counts["discord_media_directive_delivery"] == 1
      assert proofs.check_name_counts["discord_dm_prompt_round_trip"] == 1

      assert Enum.any?(
               proofs.latest_checks,
               &(&1.name == "discord_file_delivery" and
                   &1.status == "completed" and
                   &1.proof_object == "lemon.discord_live_matrix")
             )

      assert Enum.any?(
               proofs.latest_checks,
               &(&1.name == "discord_dm_prompt_round_trip" and
                   &1.status == "failed" and
                   &1.reason_kind == "discord_dm_setup_refused")
             )

      assert Enum.all?(proofs.latest_checks, &is_binary(&1.file_hash))
      assert Enum.all?(proofs.latest_checks, &is_binary(&1.proof_hash))

      live_matrix_proof =
        Enum.find(proofs.recent_proofs, &(&1.proof_object == "lemon.discord_live_matrix"))

      assert live_matrix_proof.coverage.check_count == 4
      assert live_matrix_proof.coverage.contains_dm == true
      assert live_matrix_proof.coverage.contains_generated_audio == true
      assert live_matrix_proof.coverage.contains_media_directive == true
      assert live_matrix_proof.coverage.contains_file_delivery == true
      assert live_matrix_proof.coverage.contains_slash_registration == true
      assert live_matrix_proof.coverage.contains_rollback_slash_registration == true
      assert live_matrix_proof.coverage.contains_media_slash_registration == true
      assert live_matrix_proof.media_proof.discord_delivery == true
      assert live_matrix_proof.media_proof.discord_attachment_count == 1
      assert live_matrix_proof.media_proof.media_directive_delivery == true
      assert live_matrix_proof.media_proof.directive_leaked == false
      assert live_matrix_proof.cleanup["includes_raw_bot_tokens"] == false
      assert live_matrix_proof.cleanup["includes_raw_channel_ids"] == false
      assert live_matrix_proof.cleanup["includes_raw_message_bodies"] == false
      assert live_matrix_proof.cleanup["includes_secret_names"] == false

      slash_proof =
        Enum.find(proofs.recent_proofs, &(&1.proof_object == "lemon.discord_slash_interaction"))

      assert slash_proof.coverage.registered_command_count == 16
      assert slash_proof.coverage.decode_command_count == 3
      assert slash_proof.coverage.local_response_command_count == 13
      assert slash_proof.coverage.real_client_click_proof == false
      refute Map.has_key?(slash_proof.coverage, :ignored_raw_field)

      refute inspect(proofs) =~ "/private/path"
      refute inspect(proofs) =~ "Cannot send messages"
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

  defp tmp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp write_proof!(tmp_dir, filename, proof) do
    path = Path.join([tmp_dir, ".lemon", "proofs", filename])
    File.write!(path, Jason.encode!(proof))
  end

  defp check_status(checks, name) do
    checks
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:status)
  end
end
