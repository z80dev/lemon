defmodule LemonCore.Doctor.Checks.Channels do
  @moduledoc "Checks Telegram and Discord channel readiness from redacted diagnostics."

  alias LemonCore.Doctor.{ChannelDiagnostics, ChannelReadiness, Check, ProofDiagnostics}

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    channels = ChannelDiagnostics.status(project_dir: project_dir)
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 500)
    readiness = ChannelReadiness.status(channels: channels, proofs: proofs)
    telegram = transport_status(channels, "telegram")
    discord = transport_status(channels, "discord")

    [
      check_channel_readiness(readiness),
      check_telegram(telegram),
      check_telegram_voice_transcription(telegram, proofs),
      check_discord_config(discord),
      check_discord_dm(discord, proofs),
      check_discord_free_response(discord, proofs),
      check_discord_reconnect(discord, proofs),
      check_discord_slash_registration(discord, proofs),
      check_discord_slash_deterministic(discord, proofs),
      check_discord_slash_client_click(discord, proofs)
    ]
  rescue
    error ->
      [
        Check.warn(
          "channels.diagnostics",
          "Channel diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_channel_readiness(readiness) do
    status = Map.get(readiness, :status)
    gate_count = Map.get(readiness, :gate_count, 0)
    passed_count = Map.get(readiness, :passed_count, 0)
    warning_count = Map.get(readiness, :warning_count, 0)
    blocked_count = Map.get(readiness, :blocked_count, 0)
    skipped_count = Map.get(readiness, :skipped_count, 0)

    message =
      "Telegram/Discord launch gates: #{passed_count} passed, #{warning_count} warning, #{blocked_count} blocked, #{skipped_count} skipped across #{gate_count} gate(s)."

    case status do
      "passed" ->
        Check.pass("channels.readiness", message)

      "skipped" ->
        Check.skip("channels.readiness", message)

      _ ->
        Check.warn("channels.readiness", message, unresolved_gate_next_action(readiness))
    end
  end

  defp unresolved_gate_next_action(readiness) do
    readiness
    |> Map.get(:gates, [])
    |> Enum.find_value(fn gate ->
      if Map.get(gate, :status) in ["blocked", "warning"] do
        Map.get(gate, :next_action)
      end
    end)
  end

  defp check_telegram(%{enabled: true} = telegram) do
    if token_ready?(telegram) do
      Check.pass("channels.telegram.config", "Telegram is enabled with credential shape present.")
    else
      Check.warn(
        "channels.telegram.config",
        "Telegram is enabled but no bot token or bot token secret is configured.",
        "Set gateway.telegram.bot_token_secret or gateway.telegram.bot_token."
      )
    end
  end

  defp check_telegram(_telegram) do
    Check.skip("channels.telegram.config", "Telegram is disabled.")
  end

  defp check_telegram_voice_transcription(%{enabled: true} = telegram, proofs) do
    voice = Map.get(telegram, :voice_transcription, %{})

    cond do
      latest_check_completed?(proofs, "telegram_voice_local_transcript_provider") and
        latest_check_completed?(proofs, "telegram_voice_local_no_api_key") and
          latest_check_completed?(proofs, "telegram_voice_local_inbound_metadata") ->
        Check.pass(
          "channels.telegram.voice_transcription",
          "Telegram local voice transcription proof is completed without provider credentials."
        )

      completed_proof_scope?(proofs, "telegram_voice_local_transcript") ->
        Check.pass(
          "channels.telegram.voice_transcription",
          "Telegram local voice transcription proof artifact is completed."
        )

      Map.get(voice, :enabled) != true ->
        Check.skip(
          "channels.telegram.voice_transcription",
          "Telegram voice transcription is disabled."
        )

      Map.get(voice, :api_key_required) == true and Map.get(voice, :api_key_configured) != true ->
        Check.warn(
          "channels.telegram.voice_transcription",
          "Telegram voice transcription is enabled but provider credentials are missing.",
          "Set gateway.telegram.voice_transcription_api_key or use voice_transcription_provider = \"local_transcript\" for deterministic local proof."
        )

      Map.get(voice, :provider) == "local_transcript" ->
        Check.warn(
          "channels.telegram.voice_transcription",
          "Telegram local voice transcription still needs a completed proof artifact.",
          "Run `MIX_ENV=test mix run scripts/live_telegram_voice_local_smoke.exs`."
        )

      true ->
        Check.pass(
          "channels.telegram.voice_transcription",
          "Telegram voice transcription is enabled with provider credential shape present."
        )
    end
  end

  defp check_telegram_voice_transcription(_telegram, _proofs) do
    Check.skip("channels.telegram.voice_transcription", "Telegram is disabled.")
  end

  defp check_discord_config(%{enabled: true} = discord) do
    if token_ready?(discord) do
      Check.pass("channels.discord.config", "Discord is enabled with credential shape present.")
    else
      Check.warn(
        "channels.discord.config",
        "Discord is enabled but no bot token or bot token secret is configured.",
        "Set gateway.discord.bot_token_secret or gateway.discord.bot_token."
      )
    end
  end

  defp check_discord_config(_discord) do
    Check.skip("channels.discord.config", "Discord is disabled.")
  end

  defp check_discord_dm(%{enabled: true}, proofs) do
    cond do
      latest_check_completed?(proofs, "discord_dm_prompt_round_trip") ->
        Check.pass("channels.discord.dm", "Discord DM prompt round-trip proof is completed.")

      reason_count(proofs, "discord_dm_setup_refused") > 0 ->
        Check.warn(
          "channels.discord.dm",
          "Discord DM proof is blocked by Discord DM channel setup refusal.",
          "Use a reachable human/open-DM target before promoting Discord DM support."
        )

      true ->
        Check.warn(
          "channels.discord.dm",
          "Discord DM support still needs a completed live prompt round-trip proof.",
          "Run the live Discord DM matrix with a reachable target."
        )
    end
  end

  defp check_discord_dm(_discord, _proofs) do
    Check.skip("channels.discord.dm", "Discord is disabled.")
  end

  defp check_discord_free_response(%{enabled: true} = discord, proofs) do
    declared? = get_in(discord, [:free_response, :message_content_intent_declared]) == true

    cond do
      declared? and latest_check_completed?(proofs, "discord_free_response_trigger_round_trip") ->
        Check.pass(
          "channels.discord.free_response",
          "Discord free-response trigger proof is completed with Message Content Intent declared."
        )

      not declared? ->
        Check.warn(
          "channels.discord.free_response",
          "Discord free-response is blocked until Message Content Intent is declared and live proof passes.",
          "Lemon requests the Discord message_content gateway intent at runtime; enable the privileged Discord Message Content Intent in the Developer Portal, then set gateway.discord.message_content_intent_enabled = true after verifying it."
        )

      proof_reason_present?(proofs, "discord_message_content_intent_or_delivery") ->
        Check.warn(
          "channels.discord.free_response",
          "Discord free-response proof is still blocked at Message Content Intent or unmentioned-message delivery despite the local declaration.",
          "Lemon requests the Discord message_content gateway intent at runtime; verify the privileged intent is enabled in the Discord Developer Portal, restart the runtime, and rerun the live free-response matrix."
        )

      proof_reason_present?(proofs, "discord_no_reply_for_unmentioned_message") ->
        Check.warn(
          "channels.discord.free_response",
          "Discord free-response proof observed no Lemon reply for an unmentioned message.",
          "Verify Message Content Intent, live gateway delivery, and trigger-mode storage before promotion."
        )

      true ->
        Check.warn(
          "channels.discord.free_response",
          "Discord free-response still needs a completed live external-sender proof.",
          "Run the live Discord free-response matrix."
        )
    end
  end

  defp check_discord_free_response(_discord, _proofs) do
    Check.skip("channels.discord.free_response", "Discord is disabled.")
  end

  defp check_discord_reconnect(%{enabled: true}, proofs) do
    cond do
      latest_check_completed?(proofs, "discord_restart_replay_verify") ->
        Check.pass(
          "channels.discord.reconnect",
          "Discord live gateway restart/reconnect replay proof is completed."
        )

      latest_check_completed?(proofs, "discord_restart_replay_seed") ->
        Check.warn(
          "channels.discord.reconnect",
          "Discord restart replay seed is present, but post-restart verification is still missing.",
          "Restart or hot reload the runtime intentionally, then run the restart verify matrix."
        )

      true ->
        Check.warn(
          "channels.discord.reconnect",
          "Discord live gateway restart/reconnect replay still needs seed and verify proof.",
          "Run the restart seed and verify phases of the live Discord matrix."
        )
    end
  end

  defp check_discord_reconnect(_discord, _proofs) do
    Check.skip("channels.discord.reconnect", "Discord is disabled.")
  end

  defp check_discord_slash_registration(%{enabled: true}, proofs) do
    cond do
      latest_check_completed?(proofs, "discord_all_slash_registration") or
          completed_registration_coverage?(proofs, :contains_all_slash_registration) ->
        Check.pass(
          "channels.discord.slash_registration",
          "Discord live application-command registration proof is completed for all expected Lemon command names."
        )

      latest_check_completed?(proofs, "discord_media_slash_registration") or
          completed_registration_coverage?(proofs, :contains_media_slash_registration) ->
        Check.warn(
          "channels.discord.slash_registration",
          "Discord /media slash registration proof is completed, but all-command registration proof is still missing.",
          "Run `scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json`."
        )

      true ->
        Check.warn(
          "channels.discord.slash_registration",
          "Discord live application-command registration proof is missing.",
          "Run `scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json`."
        )
    end
  end

  defp check_discord_slash_registration(_discord, _proofs) do
    Check.skip("channels.discord.slash_registration", "Discord is disabled.")
  end

  defp check_discord_slash_deterministic(%{enabled: true}, proofs) do
    if completed_proof_scope?(proofs, "discord_slash_interaction_deterministic") do
      coverage = slash_coverage(proofs)
      registered = Map.get(coverage, :registered_command_count, 0)
      local = Map.get(coverage, :local_response_command_count, 0)

      Check.pass(
        "channels.discord.slash_deterministic",
        "Discord deterministic slash proof is completed for #{registered} registered command(s) and #{local} local response path(s)."
      )
    else
      Check.warn(
        "channels.discord.slash_deterministic",
        "Discord deterministic slash inventory/decoder proof is missing.",
        "Run `mix run --no-start scripts/live_discord_slash_interaction_proof.exs`."
      )
    end
  end

  defp check_discord_slash_deterministic(_discord, _proofs) do
    Check.skip("channels.discord.slash_deterministic", "Discord is disabled.")
  end

  defp check_discord_slash_client_click(%{enabled: true}, proofs) do
    cond do
      real_client_click_proof?(proofs) or completed_client_click_artifact_check?(proofs) ->
        Check.pass(
          "channels.discord.slash_client_click",
          "Discord slash client-click proof is completed from a real Discord interaction."
        )

      latest_check_status(proofs, "discord_slash_client_click_proof_artifact") == "failed" ->
        check_discord_slash_client_click_failure(proofs)

      true ->
        Check.warn(
          "channels.discord.slash_client_click",
          "Discord slash support still needs real client-click evidence.",
          "Deploy or hot reload the runtime, then run `scripts/live_discord_matrix.py --wait-slash-client-click-proof --channel-id DISCORD_PROOF_CHANNEL_ID --proof-path .lemon/proofs/discord-slash-client-click-check-latest.json` while clicking a real Discord slash command."
        )
    end
  end

  defp check_discord_slash_client_click(_discord, _proofs) do
    Check.skip("channels.discord.slash_client_click", "Discord is disabled.")
  end

  defp check_discord_slash_client_click_failure(proofs) do
    case latest_check_reason(proofs, "discord_slash_client_click_proof_artifact") do
      "discord_slash_client_click_missing" ->
        Check.warn(
          "channels.discord.slash_client_click",
          "Discord slash client-click proof artifact has not been captured yet.",
          "Deploy or hot reload the runtime, then run `scripts/live_discord_matrix.py --wait-slash-client-click-proof --channel-id DISCORD_PROOF_CHANNEL_ID --proof-path .lemon/proofs/discord-slash-client-click-check-latest.json` while clicking a real Discord slash command."
        )

      "discord_slash_client_click_not_promotable" ->
        Check.warn(
          "channels.discord.slash_client_click",
          "Discord slash client-click proof artifact exists but is not promotable.",
          "Capture a completed real Discord client interaction with safe mentions and rerun `scripts/live_discord_matrix.py --wait-slash-client-click-proof`."
        )

      "discord_slash_client_click_stale" ->
        Check.warn(
          "channels.discord.slash_client_click",
          "Discord slash client-click proof artifact is stale for the latest wait attempt.",
          "Rerun `scripts/live_discord_matrix.py --wait-slash-client-click-proof` while clicking a fresh real Discord slash command."
        )

      "discord_slash_client_click_invalid_artifact" ->
        Check.warn(
          "channels.discord.slash_client_click",
          "Discord slash client-click proof artifact is invalid JSON.",
          "Delete or replace the invalid artifact, then rerun `scripts/live_discord_matrix.py --wait-slash-client-click-proof` while clicking a real Discord slash command."
        )

      _ ->
        Check.warn(
          "channels.discord.slash_client_click",
          "Discord slash client-click proof artifact is missing or failed validation.",
          "Deploy or hot reload the runtime, then run `scripts/live_discord_matrix.py --wait-slash-client-click-proof` while clicking a real Discord slash command."
        )
    end
  end

  defp transport_status(channels, name) do
    channels
    |> Map.get(:transports, [])
    |> Enum.find(%{}, &(Map.get(&1, :transport) == name))
  end

  defp token_ready?(status) do
    Map.get(status, :token_configured) == true or
      Map.get(status, :token_secret_configured) == true
  end

  defp latest_check_completed?(proofs, name), do: latest_check_status(proofs, name) == "completed"

  defp latest_check_status(proofs, name) do
    proofs
    |> Map.get(:latest_checks, [])
    |> Enum.find_value(fn check ->
      if Map.get(check, :name) == name, do: Map.get(check, :status)
    end)
  end

  defp latest_check_reason(proofs, name) do
    proofs
    |> Map.get(:latest_checks, [])
    |> Enum.find_value(fn check ->
      if Map.get(check, :name) == name, do: Map.get(check, :reason_kind)
    end)
  end

  defp reason_count(proofs, reason) do
    proofs
    |> Map.get(:reason_kind_counts, %{})
    |> Map.get(reason, 0)
  end

  defp proof_reason_present?(proofs, reason) do
    reason_count(proofs, reason) > 0 or
      Enum.any?(Map.get(proofs, :latest_checks, []), &(Map.get(&1, :reason_kind) == reason))
  end

  defp completed_proof_scope?(proofs, scope) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.any?(fn proof ->
      Map.get(proof, :status) == "completed" and scope in Map.get(proof, :proof_scopes, [])
    end)
  end

  defp real_client_click_proof?(proofs) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.any?(fn proof ->
      Map.get(proof, :status) == "completed" and
        Map.get(proof, :proof_object) == "lemon.discord_slash_client_click" and
        get_in(proof, [:coverage, :real_client_click_proof]) == true
    end)
  end

  defp completed_client_click_artifact_check?(proofs) do
    proofs
    |> Map.get(:latest_checks, [])
    |> Enum.any?(fn check ->
      Map.get(check, :name) == "discord_slash_client_click_proof_artifact" and
        Map.get(check, :status) == "completed" and
        Map.get(check, :proof_object) == "lemon.discord_slash_client_click"
    end)
  end

  defp completed_registration_coverage?(proofs, key) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.any?(fn proof ->
      Map.get(proof, :status) == "completed" and
        Map.get(proof, :proof_object) == "lemon.discord_live_matrix" and
        get_in(proof, [:coverage, key]) == true
    end)
  end

  defp slash_coverage(proofs) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.find_value(%{}, fn proof ->
      if Map.get(proof, :status) == "completed" and
           "discord_slash_interaction_deterministic" in Map.get(proof, :proof_scopes, []) do
        Map.get(proof, :coverage, %{})
      end
    end)
  end
end
