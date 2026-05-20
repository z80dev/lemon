defmodule LemonCore.Doctor.ChannelReadinessTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.ChannelReadiness

  test "reports redacted launch gates with Discord client-click wait remediation" do
    tmp_dir = tmp_dir()
    File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))

    File.write!(
      Path.join([tmp_dir, ".lemon", "config.toml"]),
      """
      [gateway]
      enable_telegram = true
      enable_discord = true

      [gateway.telegram]
      bot_token = "123456:private-telegram-token"
      voice_transcription = true
      voice_transcription_provider = "local_transcript"

      [gateway.discord]
      bot_token_secret = "private-discord-secret-name"
      message_content_intent_enabled = true
      allowed_channel_ids = ["111222333"]
      """
    )

    write_proof!(tmp_dir, "telegram-voice-local-latest.json", %{
      status: "completed",
      proof_object: "lemon.telegram_voice_local",
      checks: [
        %{name: "telegram_voice_local_transcript_provider", status: "completed"},
        %{name: "telegram_voice_local_no_api_key", status: "completed"},
        %{name: "telegram_voice_local_inbound_metadata", status: "completed"}
      ]
    })

    write_proof!(tmp_dir, "discord-client-click-check-latest.json", %{
      status: "failed",
      proof_object: "lemon.discord_slash_client_click",
      reason_kind: "discord_slash_client_click_missing",
      details: %{
        channel_id: "111222333",
        prompt: "private operator prompt"
      },
      checks: [
        %{
          name: "discord_slash_client_click_proof_artifact",
          status: "failed",
          proof_object: "lemon.discord_slash_client_click",
          reason_kind: "discord_slash_client_click_missing"
        }
      ]
    })

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    readiness = ChannelReadiness.status(project_dir: tmp_dir)

    assert readiness.status == "warning"
    assert readiness.promoted_platforms == ["telegram", "discord"]
    assert readiness.gate_count == 9
    assert readiness.warning_count > 0
    assert readiness.cleanup.includes_raw_bot_tokens == false
    assert readiness.cleanup.includes_channel_ids == false
    assert readiness.cleanup.includes_message_bodies == false

    assert gate(readiness, "telegram.config").status == "passed"
    assert gate(readiness, "telegram.voice_transcription").status == "passed"

    slash = gate(readiness, "discord.slash_client_click")
    assert slash.status == "warning"
    assert slash.reason_kind == "discord_slash_client_click_missing"
    assert slash.next_action =~ "--wait-slash-client-click-proof"
    assert slash.next_action =~ "DISCORD_PROOF_CHANNEL_ID"

    rendered = inspect(readiness)
    refute rendered =~ "private-telegram-token"
    refute rendered =~ "private-discord-secret-name"
    refute rendered =~ "111222333"
    refute rendered =~ "private operator prompt"
  end

  test "passes Discord client-click gate from a completed real-click proof" do
    readiness =
      ChannelReadiness.status(
        channels: %{
          transports: [
            %{transport: "telegram", enabled: false},
            %{transport: "discord", enabled: true, token_secret_configured: true}
          ]
        },
        proofs: %{
          latest_checks: [],
          recent_proofs: [
            %{
              status: "completed",
              proof_object: "lemon.discord_slash_client_click",
              coverage: %{real_client_click_proof: true}
            }
          ],
          reason_kind_counts: %{}
        }
      )

    assert gate(readiness, "discord.slash_client_click").status == "passed"
  end

  test "preserves Discord DM reason kinds on unresolved gates" do
    readiness =
      ChannelReadiness.status(
        channels: %{
          transports: [
            %{transport: "telegram", enabled: false},
            %{transport: "discord", enabled: true, token_secret_configured: true}
          ]
        },
        proofs: %{
          latest_checks: [],
          recent_proofs: [],
          reason_kind_counts: %{"discord_dm_setup_refused" => 1}
        }
      )

    discord_dm = gate(readiness, "discord.dm")
    assert discord_dm.status == "blocked"
    assert discord_dm.reason_kind == "discord_dm_setup_refused"
    assert discord_dm.next_action =~ "--wait-dm-inbound"
  end

  test "reports rollback-only slash registration as partial registration evidence" do
    readiness =
      ChannelReadiness.status(
        channels: %{
          transports: [
            %{transport: "telegram", enabled: false},
            %{transport: "discord", enabled: true, token_secret_configured: true}
          ]
        },
        proofs: %{
          latest_checks: [
            %{name: "discord_rollback_slash_registration", status: "completed"}
          ],
          recent_proofs: [
            %{
              status: "completed",
              proof_object: "lemon.discord_live_matrix",
              coverage: %{contains_rollback_slash_registration: true}
            }
          ],
          reason_kind_counts: %{}
        }
      )

    slash = gate(readiness, "discord.slash_registration")
    assert slash.status == "warning"
    assert slash.evidence =~ "/rollback"
    assert slash.next_action =~ "--check-all-slash-registration"
  end

  defp gate(readiness, id), do: Enum.find(readiness.gates, &(&1.id == id))

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_channel_readiness_test_#{System.unique_integer([:positive])}"
    )
  end

  defp write_proof!(tmp_dir, filename, proof) do
    path = Path.join([tmp_dir, ".lemon", "proofs", filename])
    File.write!(path, Jason.encode!(proof))
  end
end
