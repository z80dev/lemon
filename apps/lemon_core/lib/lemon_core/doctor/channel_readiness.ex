defmodule LemonCore.Doctor.ChannelReadiness do
  @moduledoc """
  Redacted launch-gate readiness for promoted Telegram and Discord channels.
  """

  alias LemonCore.Doctor.{ChannelDiagnostics, ProofDiagnostics}

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    channels =
      Keyword.get_lazy(opts, :channels, fn ->
        ChannelDiagnostics.status(project_dir: project_dir)
      end)

    proofs =
      Keyword.get_lazy(
        opts,
        :proofs,
        fn -> ProofDiagnostics.status(project_dir: project_dir, limit: 1_000) end
      )

    telegram = transport_status(channels, "telegram")
    discord = transport_status(channels, "discord")

    gates = [
      telegram_config_gate(telegram),
      telegram_voice_gate(telegram, proofs),
      discord_config_gate(discord),
      discord_dm_gate(discord, proofs),
      discord_free_response_gate(discord, proofs),
      discord_reconnect_gate(discord, proofs),
      discord_slash_registration_gate(discord, proofs),
      discord_slash_deterministic_gate(discord, proofs),
      discord_slash_client_click_gate(discord, proofs)
    ]

    %{
      status: aggregate_status(gates),
      promoted_platforms: ["telegram", "discord"],
      gates: gates,
      gate_count: length(gates),
      passed_count: gate_count(gates, "passed"),
      blocked_count: gate_count(gates, "blocked"),
      warning_count: gate_count(gates, "warning"),
      skipped_count: gate_count(gates, "skipped"),
      cleanup: %{
        includes_raw_bot_tokens: false,
        includes_secret_names: false,
        includes_chat_ids: false,
        includes_channel_ids: false,
        includes_guild_ids: false,
        includes_message_bodies: false,
        includes_raw_proof_paths: false,
        includes_raw_proof_details: false
      }
    }
  end

  defp telegram_config_gate(%{enabled: true} = telegram) do
    if token_ready?(telegram) do
      gate("telegram.config", "passed", "Telegram credentials are configured.", nil)
    else
      gate(
        "telegram.config",
        "blocked",
        "Telegram is enabled but credential shape is missing.",
        "Set gateway.telegram.bot_token_secret or gateway.telegram.bot_token."
      )
    end
  end

  defp telegram_config_gate(_telegram) do
    gate("telegram.config", "skipped", "Telegram is disabled.", nil)
  end

  defp telegram_voice_gate(%{enabled: true} = telegram, proofs) do
    voice = map_value(telegram, :voice_transcription, %{})

    cond do
      latest_check_completed?(proofs, "telegram_voice_local_transcript_provider") and
        latest_check_completed?(proofs, "telegram_voice_local_no_api_key") and
          latest_check_completed?(proofs, "telegram_voice_local_inbound_metadata") ->
        gate(
          "telegram.voice_transcription",
          "passed",
          "Telegram local voice transcription proof is completed.",
          nil
        )

      map_value(voice, :enabled) != true ->
        gate(
          "telegram.voice_transcription",
          "skipped",
          "Telegram voice transcription is disabled.",
          nil
        )

      map_value(voice, :api_key_required) == true and
          map_value(voice, :api_key_configured) != true ->
        gate(
          "telegram.voice_transcription",
          "blocked",
          "Telegram voice transcription is enabled but provider credentials are missing.",
          "Configure provider credentials or switch to local_transcript for deterministic proof."
        )

      true ->
        gate(
          "telegram.voice_transcription",
          "warning",
          "Telegram voice transcription still needs a proof artifact.",
          "Run MIX_ENV=test mix run scripts/live_telegram_voice_local_smoke.exs."
        )
    end
  end

  defp telegram_voice_gate(_telegram, _proofs) do
    gate("telegram.voice_transcription", "skipped", "Telegram is disabled.", nil)
  end

  defp discord_config_gate(%{enabled: true} = discord) do
    if token_ready?(discord) do
      gate("discord.config", "passed", "Discord credentials are configured.", nil)
    else
      gate(
        "discord.config",
        "blocked",
        "Discord is enabled but credential shape is missing.",
        "Set gateway.discord.bot_token_secret or gateway.discord.bot_token."
      )
    end
  end

  defp discord_config_gate(_discord) do
    gate("discord.config", "skipped", "Discord is disabled.", nil)
  end

  defp discord_dm_gate(%{enabled: true}, proofs) do
    cond do
      latest_check_completed?(proofs, "discord_dm_prompt_round_trip") ->
        gate("discord.dm", "passed", "Discord DM prompt round-trip proof is completed.", nil)

      reason_count(proofs, "discord_dm_setup_refused") > 0 ->
        gate(
          "discord.dm",
          "blocked",
          "Discord DM proof is blocked by unreachable DM setup.",
          "Use a reachable human/open-DM target, then run scripts/live_discord_matrix.py --wait-dm-inbound.",
          "discord_dm_setup_refused"
        )

      true ->
        gate(
          "discord.dm",
          "warning",
          "Discord DM prompt round-trip proof is missing.",
          "Run scripts/live_discord_matrix.py --wait-dm-inbound with --dm-channel-id or --dm-recipient-id.",
          "discord_dm_missing"
        )
    end
  end

  defp discord_dm_gate(_discord, _proofs) do
    gate("discord.dm", "skipped", "Discord is disabled.", nil)
  end

  defp discord_free_response_gate(%{enabled: true} = discord, proofs) do
    declared? = get_in_value(discord, [:free_response, :message_content_intent_declared]) == true

    cond do
      declared? and latest_check_completed?(proofs, "discord_free_response_trigger_round_trip") ->
        gate("discord.free_response", "passed", "Discord free-response proof is completed.", nil)

      not declared? ->
        gate(
          "discord.free_response",
          "blocked",
          "Discord Message Content Intent is not declared for free-response mode.",
          "Enable the privileged Discord Message Content Intent, then set gateway.discord.message_content_intent_enabled = true after verification."
        )

      proof_reason_present?(proofs, "discord_message_content_intent_or_delivery") or
          proof_reason_present?(proofs, "discord_no_reply_for_unmentioned_message") ->
        gate(
          "discord.free_response",
          "blocked",
          "Discord free-response proof is still blocked by live delivery or Message Content Intent drift.",
          "Verify the Developer Portal intent, restart the runtime, and rerun the free-response matrix."
        )

      true ->
        gate(
          "discord.free_response",
          "warning",
          "Discord free-response still needs completed live external-sender proof.",
          "Run the live Discord free-response matrix."
        )
    end
  end

  defp discord_free_response_gate(_discord, _proofs) do
    gate("discord.free_response", "skipped", "Discord is disabled.", nil)
  end

  defp discord_reconnect_gate(%{enabled: true}, proofs) do
    cond do
      latest_check_completed?(proofs, "discord_restart_replay_verify") ->
        gate(
          "discord.reconnect",
          "passed",
          "Discord restart/reconnect replay proof is completed.",
          nil
        )

      latest_check_completed?(proofs, "discord_restart_replay_seed") ->
        gate(
          "discord.reconnect",
          "warning",
          "Discord reconnect replay seed is present but verification is missing.",
          "Restart or hot reload the runtime intentionally, then run the restart verify matrix."
        )

      true ->
        gate(
          "discord.reconnect",
          "warning",
          "Discord reconnect replay proof is missing.",
          "Run the restart seed and verify phases of the live Discord matrix."
        )
    end
  end

  defp discord_reconnect_gate(_discord, _proofs) do
    gate("discord.reconnect", "skipped", "Discord is disabled.", nil)
  end

  defp discord_slash_registration_gate(%{enabled: true}, proofs) do
    cond do
      latest_check_completed?(proofs, "discord_all_slash_registration") or
          completed_registration_coverage?(proofs, :contains_all_slash_registration) ->
        gate(
          "discord.slash_registration",
          "passed",
          "Discord application-command registration proof covers all expected Lemon commands.",
          nil
        )

      latest_check_completed?(proofs, "discord_media_slash_registration") or
          completed_registration_coverage?(proofs, :contains_media_slash_registration) ->
        gate(
          "discord.slash_registration",
          "warning",
          "Discord /media slash registration proof is present but all-command proof is missing.",
          "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        )

      latest_check_completed?(proofs, "discord_rollback_slash_registration") or
          completed_registration_coverage?(proofs, :contains_rollback_slash_registration) ->
        gate(
          "discord.slash_registration",
          "warning",
          "Discord /rollback slash registration proof is present but all-command proof is missing.",
          "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        )

      true ->
        gate(
          "discord.slash_registration",
          "warning",
          "Discord live application-command registration proof is missing.",
          "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        )
    end
  end

  defp discord_slash_registration_gate(_discord, _proofs) do
    gate("discord.slash_registration", "skipped", "Discord is disabled.", nil)
  end

  defp discord_slash_deterministic_gate(%{enabled: true}, proofs) do
    if completed_proof_scope?(proofs, "discord_slash_interaction_deterministic") do
      gate(
        "discord.slash_deterministic",
        "passed",
        "Discord deterministic slash proof is completed.",
        nil
      )
    else
      gate(
        "discord.slash_deterministic",
        "warning",
        "Discord deterministic slash inventory/decoder proof is missing.",
        "Run mix run --no-start scripts/live_discord_slash_interaction_proof.exs."
      )
    end
  end

  defp discord_slash_deterministic_gate(_discord, _proofs) do
    gate("discord.slash_deterministic", "skipped", "Discord is disabled.", nil)
  end

  defp discord_slash_client_click_gate(%{enabled: true}, proofs) do
    reason =
      latest_check_reason(proofs, "discord_slash_client_click_proof_wait") ||
        latest_check_reason(proofs, "discord_slash_client_click_proof_artifact") ||
        "discord_slash_client_click_missing"

    cond do
      latest_check_completed?(proofs, "discord_slash_client_click_proof_wait") or
        latest_check_completed?(proofs, "discord_slash_client_click_proof_artifact") or
          real_client_click_proof?(proofs) ->
        gate(
          "discord.slash_client_click",
          "passed",
          "Discord slash client-click proof is completed.",
          nil
        )

      reason in [
        "discord_slash_client_click_invalid_artifact",
        "discord_slash_client_click_not_promotable",
        "discord_slash_client_click_stale"
      ] ->
        gate(
          "discord.slash_client_click",
          "blocked",
          "Discord slash client-click proof exists but cannot promote the launch gate.",
          "Rerun scripts/live_discord_matrix.py --wait-slash-client-click-proof while clicking a fresh real Discord slash command.",
          reason
        )

      true ->
        gate(
          "discord.slash_client_click",
          "warning",
          "Discord slash client-click proof has not been captured from a real Discord client.",
          "Deploy or hot reload the runtime, then run scripts/live_discord_matrix.py --wait-slash-client-click-proof --channel-id DISCORD_PROOF_CHANNEL_ID while clicking the requested real slash command.",
          reason
        )
    end
  end

  defp discord_slash_client_click_gate(_discord, _proofs) do
    gate("discord.slash_client_click", "skipped", "Discord is disabled.", nil)
  end

  defp gate(id, status, evidence, next_action, reason_kind \\ nil) do
    %{
      id: id,
      status: status,
      evidence: evidence,
      next_action: next_action,
      reason_kind: reason_kind
    }
  end

  defp aggregate_status(gates) do
    cond do
      Enum.any?(gates, &(Map.get(&1, :status) == "blocked")) -> "blocked"
      Enum.any?(gates, &(Map.get(&1, :status) == "warning")) -> "warning"
      Enum.any?(gates, &(Map.get(&1, :status) == "passed")) -> "passed"
      true -> "skipped"
    end
  end

  defp gate_count(gates, status), do: Enum.count(gates, &(Map.get(&1, :status) == status))

  defp transport_status(channels, name) do
    channels
    |> map_value(:transports, [])
    |> Enum.find(%{}, &(map_value(&1, :transport) == name))
  end

  defp token_ready?(status) do
    map_value(status, :token_configured) == true or
      map_value(status, :token_secret_configured) == true
  end

  defp latest_check_completed?(proofs, name), do: latest_check_status(proofs, name) == "completed"

  defp latest_check_status(proofs, name) do
    proofs
    |> map_value(:latest_checks, [])
    |> Enum.find_value(fn check ->
      if map_value(check, :name) == name, do: map_value(check, :status)
    end)
  end

  defp latest_check_reason(proofs, name) do
    proofs
    |> map_value(:latest_checks, [])
    |> Enum.find_value(fn check ->
      if map_value(check, :name) == name, do: map_value(check, :reason_kind)
    end)
  end

  defp reason_count(proofs, reason) do
    proofs
    |> map_value(:reason_kind_counts, %{})
    |> map_value(reason, 0)
  end

  defp proof_reason_present?(proofs, reason) do
    reason_count(proofs, reason) > 0 or
      Enum.any?(map_value(proofs, :latest_checks, []), &(map_value(&1, :reason_kind) == reason))
  end

  defp completed_proof_scope?(proofs, scope) do
    proofs
    |> map_value(:recent_proofs, [])
    |> Enum.any?(fn proof ->
      map_value(proof, :status) == "completed" and scope in map_value(proof, :proof_scopes, [])
    end)
  end

  defp completed_registration_coverage?(proofs, key) do
    proofs
    |> map_value(:recent_proofs, [])
    |> Enum.any?(fn proof ->
      map_value(proof, :status) == "completed" and
        map_value(proof, :proof_object) == "lemon.discord_live_matrix" and
        get_in_value(proof, [:coverage, key]) == true
    end)
  end

  defp real_client_click_proof?(proofs) do
    proofs
    |> map_value(:recent_proofs, [])
    |> Enum.any?(fn proof ->
      map_value(proof, :status) == "completed" and
        map_value(proof, :proof_object) == "lemon.discord_slash_client_click" and
        get_in_value(proof, [:coverage, :real_client_click_proof]) == true
    end)
  end

  defp get_in_value(data, keys) do
    Enum.reduce_while(keys, data, fn key, acc ->
      case map_value(acc, key, nil) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp map_value(_, _key, default), do: default
end
