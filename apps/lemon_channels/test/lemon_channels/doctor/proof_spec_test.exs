defmodule LemonChannels.Doctor.ProofSpecTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Doctor.ProofSpec
  alias LemonCore.Doctor.Check

  describe "origin_cron_checks/0" do
    test "names the channel-origin cron delivery checks" do
      assert ProofSpec.origin_cron_checks() == [
               "telegram_channel_origin_cron_delivery",
               "discord_channel_origin_cron_delivery"
             ]
    end
  end

  describe "media_delivery_check_names/0" do
    test "names the generated media delivery checks" do
      assert ProofSpec.media_delivery_check_names() == [
               "telegram_forum_topic_generated_media_delivery",
               "telegram_forum_topic_generated_audio_delivery",
               "telegram_forum_topic_media_directive_delivery",
               "discord_generated_media_delivery",
               "discord_generated_audio_delivery",
               "discord_media_directive_delivery"
             ]
    end
  end

  describe "media_delivery_proof/1" do
    test "extracts Telegram forum-topic delivery evidence" do
      proof =
        ProofSpec.media_delivery_proof([
          %{
            "name" => "telegram_forum_topic_generated_audio_delivery",
            "status" => "completed",
            "document" => %{"has_document" => true},
            "marker_seen" => true
          }
        ])

      assert proof == %{
               channel_delivery: true,
               telegram_delivery: true,
               telegram_has_document: true,
               marker_seen: true
             }
    end

    test "marks Telegram MEDIA directive delivery without a leak" do
      proof =
        ProofSpec.media_delivery_proof([
          %{
            "name" => "telegram_forum_topic_media_directive_delivery",
            "status" => "completed",
            "telegram_has_document" => true,
            "marker_seen" => true,
            "directive_leaked" => false
          }
        ])

      assert proof == %{
               channel_delivery: true,
               telegram_delivery: true,
               telegram_has_document: true,
               marker_seen: true,
               media_directive_delivery: true,
               directive_leaked: false
             }
    end

    test "extracts Discord generated-media delivery evidence" do
      proof =
        ProofSpec.media_delivery_proof([
          %{
            "name" => "discord_generated_audio_delivery",
            "status" => "completed",
            "bot_reply" => %{"attachment_count" => 1}
          }
        ])

      assert proof == %{
               channel_delivery: true,
               discord_delivery: true,
               discord_attachment_count: 1
             }
    end

    test "marks Discord MEDIA directive delivery with a leak" do
      proof =
        ProofSpec.media_delivery_proof([
          %{
            "name" => "discord_media_directive_delivery",
            "status" => "completed",
            "attachment_count" => 1,
            "directive_leaked" => true
          }
        ])

      assert proof == %{
               channel_delivery: true,
               discord_delivery: true,
               discord_attachment_count: 1,
               media_directive_delivery: true,
               directive_leaked: true
             }
    end

    test "flags both channels when both deliveries are present" do
      proof =
        ProofSpec.media_delivery_proof([
          %{"name" => "telegram_forum_topic_generated_media_delivery", "status" => "completed"},
          %{"name" => "discord_generated_media_delivery", "status" => "completed"}
        ])

      assert proof.channel_delivery == true
      assert proof.telegram_delivery == true
      assert proof.discord_delivery == true
    end

    test "returns an empty map for unrelated checks" do
      assert ProofSpec.media_delivery_proof([%{"name" => "media_image_smoke", "status" => "failed"}]) ==
               %{}

      assert ProofSpec.media_delivery_proof("not a list") == %{}
    end
  end

  describe "media_delivery_check/1" do
    test "passes when Telegram and Discord deliveries are completed" do
      check =
        ProofSpec.media_delivery_check(
          proof_status([
            %{telegram_delivery: true, discord_delivery: true}
          ])
        )

      assert check ==
               Check.pass(
                 "media.channel_delivery",
                 "Media attachment delivery proof is completed for Telegram and Discord."
               )
    end

    test "warns when only Telegram delivery is completed" do
      check =
        ProofSpec.media_delivery_check(
          proof_status([%{telegram_delivery: true}])
        )

      assert check.status == :warn
      assert check.name == "media.channel_delivery"
      assert check.message =~ "only complete for Telegram"
      assert check.remediation =~ "live matrix for both Telegram and Discord"
    end

    test "warns when only Discord delivery is completed" do
      check =
        ProofSpec.media_delivery_check(
          proof_status([%{discord_delivery: true}])
        )

      assert check.status == :warn
      assert check.message =~ "only complete for Discord"
    end

    test "warns when neither channel delivery is completed" do
      check = ProofSpec.media_delivery_check(proof_status([]))

      assert check.status == :warn
      assert check.message =~ "missing for Telegram and Discord"
      assert check.remediation =~ "Telegram and Discord generated media/audio"
    end
  end

  describe "failure_hint/1" do
    test "classifies Discord DM setup refusals" do
      assert ProofSpec.failure_hint(
               "discord api post /users/@me/channels failed: 400 {\"message\":\"cannot send messages to this user\",\"code\":50007}"
             ) == "discord_dm_setup_refused"

      assert ProofSpec.failure_hint("cannot send messages to this user") ==
               "discord_dm_setup_refused"
    end

    test "classifies Message Content Intent drift" do
      assert ProofSpec.failure_hint("message_content_intent_declared=false") ==
               "discord_message_content_intent_or_delivery"

      assert ProofSpec.failure_hint("message content intent") ==
               "discord_message_content_intent_or_delivery"
    end

    test "classifies no-reply for unmentioned messages before the generic intent hint" do
      assert ProofSpec.failure_hint(
               "no lemon reply was observed for an unmentioned guild/thread message"
             ) == "discord_no_reply_for_unmentioned_message"
    end

    test "returns nil for unrecognized hints and nil input" do
      assert ProofSpec.failure_hint("some other failure") == nil
      assert ProofSpec.failure_hint(nil) == nil
    end
  end

  describe "setup_error_hint/1" do
    test "classifies Discord DM setup refusals" do
      assert ProofSpec.setup_error_hint(
               "discord api post /users/@me/channels failed: 400 {\"message\":\"cannot send messages to this user\",\"code\":50007}"
             ) == "discord_dm_setup_refused"

      assert ProofSpec.setup_error_hint("cannot send messages to this user") ==
               "discord_dm_setup_refused"
    end

    test "returns nil for unrecognized errors and nil input" do
      assert ProofSpec.setup_error_hint("some other error") == nil
      assert ProofSpec.setup_error_hint(nil) == nil
    end
  end

  describe "launch_gates/1" do
    test "passes the DM gate when the prompt round-trip proof is completed" do
      gates =
        ProofSpec.launch_gates(%{
          latest_checks: [%{name: "discord_dm_prompt_round_trip", status: "completed"}]
        })

      assert gates["discordDm"] == %{
               "status" => "passed",
               "evidence" => "Discord DM prompt round-trip proof is completed."
             }
    end

    test "blocks the DM gate on setup refusals" do
      gates =
        ProofSpec.launch_gates(%{
          reason_kind_counts: %{"discord_dm_setup_refused" => 1}
        })

      assert gates["discordDm"]["status"] == "blocked"
      assert gates["discordDm"]["reasonKind"] == "discord_dm_setup_refused"
      assert gates["discordDm"]["nextAction"] =~ "--wait-dm-inbound"
    end

    test "warns on the DM gate when no proof has been captured" do
      gates = ProofSpec.launch_gates(%{})

      assert gates["discordDm"]["status"] == "warning"
      assert gates["discordDm"]["reasonKind"] == "discord_dm_missing"
    end

    test "passes slash registration on all-command proof" do
      gates =
        ProofSpec.launch_gates(%{
          recent_proofs: [
            %{
              status: "completed",
              coverage: %{contains_all_slash_registration: true}
            }
          ]
        })

      assert gates["discordSlashRegistration"]["status"] == "passed"
      assert gates["discordSlashRegistration"]["evidence"] =~ "all expected Lemon commands"
    end

    test "warns on slash registration when only rollback registration is proven" do
      gates =
        ProofSpec.launch_gates(%{
          latest_checks: [%{name: "discord_rollback_slash_registration", status: "completed"}]
        })

      assert gates["discordSlashRegistration"]["status"] == "warning"
      assert gates["discordSlashRegistration"]["reasonKind"] == "discord_all_slash_registration_missing"
      assert gates["discordSlashRegistration"]["nextAction"] =~ "--check-all-slash-registration"
    end

    test "warns on slash registration when only media registration is proven" do
      gates =
        ProofSpec.launch_gates(%{
          recent_proofs: [
            %{
              status: "completed",
              coverage: %{contains_media_slash_registration: true}
            }
          ]
        })

      assert gates["discordSlashRegistration"]["status"] == "warning"
      assert gates["discordSlashRegistration"]["evidence"] =~ "/media slash registration"
    end

    test "warns on slash registration when nothing is proven" do
      gates = ProofSpec.launch_gates(%{})

      assert gates["discordSlashRegistration"]["status"] == "warning"
      assert gates["discordSlashRegistration"]["reasonKind"] == "discord_slash_registration_missing"
    end

    test "passes the client-click gate on a completed wait proof" do
      gates =
        ProofSpec.launch_gates(%{
          latest_checks: [%{name: "discord_slash_client_click_proof_wait", status: "completed"}]
        })

      assert gates["discordSlashClientClick"]["status"] == "passed"
      assert gates["discordSlashClientClick"]["evidence"] =~ "real Discord interaction"
    end

    test "passes the client-click gate on real client-click proof coverage" do
      gates =
        ProofSpec.launch_gates(%{
          recent_proofs: [
            %{
              status: "completed",
              proof_object: "lemon.discord_slash_client_click",
              coverage: %{real_client_click_proof: true}
            }
          ]
        })

      assert gates["discordSlashClientClick"]["status"] == "passed"
    end

    test "blocks the client-click gate on stale artifacts" do
      gates =
        ProofSpec.launch_gates(%{
          latest_checks: [
            %{
              name: "discord_slash_client_click_proof_artifact",
              status: "failed",
              reason_kind: "discord_slash_client_click_stale"
            }
          ]
        })

      assert gates["discordSlashClientClick"]["status"] == "blocked"
      assert gates["discordSlashClientClick"]["reasonKind"] == "discord_slash_client_click_stale"
      assert gates["discordSlashClientClick"]["nextAction"] =~ "--wait-slash-client-click-proof"
    end

    test "warns on the client-click gate with the captured reason" do
      gates =
        ProofSpec.launch_gates(%{
          latest_checks: [
            %{
              name: "discord_slash_client_click_proof_artifact",
              status: "failed",
              reason_kind: "discord_slash_client_click_missing"
            }
          ]
        })

      assert gates["discordSlashClientClick"]["status"] == "warning"
      assert gates["discordSlashClientClick"]["reasonKind"] == "discord_slash_client_click_missing"
      assert gates["discordSlashClientClick"]["evidence"] =~ "real Discord client"
    end

    test "returns exactly the three channel gates" do
      gates = ProofSpec.launch_gates(%{})

      assert Map.keys(gates) |> Enum.sort() == [
               "discordDm",
               "discordSlashClientClick",
               "discordSlashRegistration"
             ]
    end
  end

  defp proof_status(media_proofs) do
    %{
      recent_proofs:
        Enum.map(media_proofs, fn media_proof ->
          %{status: "completed", media_proof: media_proof}
        end)
    }
  end
end
