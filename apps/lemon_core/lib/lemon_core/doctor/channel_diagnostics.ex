defmodule LemonCore.Doctor.ChannelDiagnostics do
  @moduledoc """
  Redacted Telegram and Discord configuration diagnostics for support bundles.
  """

  alias LemonCore.Config

  @supported_transports [:telegram, :discord]

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    gateway = Config.load(project_dir, cache: false).gateway || %{}
    bindings = Map.get(gateway, :bindings, [])

    %{
      transports: [
        telegram_status(gateway, bindings),
        discord_status(gateway, bindings)
      ],
      binding_count: Enum.count(bindings, &(transport(&1) in @supported_transports)),
      unsupported_binding_count:
        Enum.count(bindings, &(transport(&1) not in @supported_transports)),
      cleanup: %{
        includes_raw_bot_tokens: false,
        includes_secret_names: false,
        includes_chat_ids: false,
        includes_channel_ids: false,
        includes_guild_ids: false,
        includes_message_bodies: false
      }
    }
  end

  defp telegram_status(gateway, bindings) do
    telegram = Map.get(gateway, :telegram, %{}) || %{}
    files = map_value(telegram, :files, %{}) || %{}

    %{
      transport: "telegram",
      enabled: Map.get(gateway, :enable_telegram) == true,
      token_configured:
        configured_string?(map_value(telegram, :token)) or
          configured_string?(map_value(telegram, :bot_token)),
      token_secret_configured: configured_string?(map_value(telegram, :bot_token_secret)),
      allowed_peer_count: length(List.wrap(map_value(telegram, :allowed_chat_ids, []))),
      deny_unbound_peers: map_value(telegram, :deny_unbound_chats, false) == true,
      binding_count: Enum.count(bindings, &(transport(&1) == :telegram)),
      topic_binding_count:
        Enum.count(bindings, &(transport(&1) == :telegram and present?(&1[:topic_id]))),
      files: file_status(files),
      compaction: compaction_status(map_value(telegram, :compaction, %{})),
      voice_transcription: %{
        enabled: map_value(telegram, :voice_transcription, false) == true,
        provider: telegram_voice_provider(telegram),
        model_configured: configured_string?(map_value(telegram, :voice_transcription_model)),
        base_url_configured:
          configured_string?(map_value(telegram, :voice_transcription_base_url)),
        api_key_required: telegram_voice_provider(telegram) != "local_transcript",
        api_key_configured: configured_string?(map_value(telegram, :voice_transcription_api_key))
      }
    }
  end

  defp telegram_voice_provider(telegram) do
    case map_value(telegram, :voice_transcription_provider, "openai_transcribe") do
      provider when is_binary(provider) and provider != "" -> provider
      _ -> "openai_transcribe"
    end
  end

  defp discord_status(gateway, bindings) do
    discord = Map.get(gateway, :discord, %{}) || %{}
    files = map_value(discord, :files, %{}) || %{}

    %{
      transport: "discord",
      enabled: Map.get(gateway, :enable_discord) == true,
      token_configured: configured_string?(map_value(discord, :bot_token)),
      token_secret_configured: configured_string?(map_value(discord, :bot_token_secret)),
      allowed_guild_count: length(List.wrap(map_value(discord, :allowed_guild_ids, []))),
      allowed_channel_count: length(List.wrap(map_value(discord, :allowed_channel_ids, []))),
      deny_unbound_channels: map_value(discord, :deny_unbound_channels, false) == true,
      binding_count: Enum.count(bindings, &(transport(&1) == :discord)),
      files: file_status(files),
      bot_message_policy: discord_bot_message_policy(),
      direct_messages: discord_direct_message_status(),
      free_response: discord_free_response_status(discord),
      inbound_replay: discord_inbound_replay_status(),
      slash_commands: discord_slash_command_status()
    }
  end

  defp discord_bot_message_policy do
    %{
      ignores_self_messages: true,
      ignores_webhooks: true,
      external_bot_messages_allowed: true,
      external_bot_messages_stable: false,
      external_bot_messages_live_proof_required: true
    }
  end

  defp discord_direct_message_status do
    %{
      prompt_round_trip_supported: true,
      requires_reachable_dm_channel: true,
      bot_to_bot_dm_stable: false,
      setup_refusal_reason_kind: "discord_dm_setup_refused",
      live_external_sender_proof_required: true,
      live_external_sender_proof_source: "proof_diagnostics"
    }
  end

  defp discord_free_response_status(discord) do
    %{
      trigger_command_supported: true,
      default_mode: "mentions",
      all_messages_mode_supported: true,
      requires_message_content_intent: true,
      runtime_requests_message_content_intent: true,
      message_content_intent_declared:
        truthy?(map_value(discord, :message_content_intent_enabled, false)) or
          truthy?(map_value(discord, :message_content_intent, false)),
      live_external_sender_proof_required: true,
      live_external_sender_proof_source: "proof_diagnostics"
    }
  end

  defp discord_inbound_replay_status do
    %{
      duplicate_message_suppression_supported: true,
      persisted_idempotency_supported: true,
      transport_restart_dedupe_proof_source: "discord_dedupe_proof",
      live_gateway_reconnect_proof_required: true,
      live_gateway_reconnect_proof_source: "live_discord_matrix"
    }
  end

  defp discord_slash_command_status do
    commands = [
      "lemon",
      "session",
      "model",
      "thinking",
      "resume",
      "cancel",
      "checkpoint",
      "rollback",
      "goal",
      "kanban",
      "media",
      "trigger",
      "cwd",
      "reload",
      "topic",
      "file"
    ]

    %{
      schema_export_supported: true,
      expected_command_count: length(commands),
      expected_commands: commands,
      live_registration_proof_required: true,
      live_registration_proof_source: "live_discord_matrix",
      deterministic_runtime_decoder_proof_source: "discord_slash_interaction_proof",
      real_client_click_proof_required_for_broad_parity: true
    }
  end

  defp file_status(files) when is_map(files) do
    %{
      enabled: truthy?(map_value(files, :enabled, false)),
      auto_put: truthy?(map_value(files, :auto_put, false)),
      auto_send_generated_files: auto_send_generated_files?(files),
      auto_send_generated_max_files:
        positive_integer(map_value(files, :auto_send_generated_max_files)),
      max_upload_bytes_configured: present?(map_value(files, :max_upload_bytes)),
      max_download_bytes_configured: present?(map_value(files, :max_download_bytes)),
      deny_glob_count: length(List.wrap(map_value(files, :deny_globs, []))),
      allowed_user_count: length(List.wrap(map_value(files, :allowed_user_ids, [])))
    }
  end

  defp file_status(_), do: file_status(%{})

  defp compaction_status(compaction) when is_map(compaction) do
    %{
      enabled: map_value(compaction, :enabled, false) == true,
      context_window_configured: present?(map_value(compaction, :context_window_tokens)),
      reserve_configured: present?(map_value(compaction, :reserve_tokens)),
      trigger_ratio_configured: present?(map_value(compaction, :trigger_ratio))
    }
  end

  defp compaction_status(_), do: compaction_status(%{})

  defp transport(%{transport: transport}) when transport in @supported_transports, do: transport
  defp transport(%{transport: transport}) when is_binary(transport), do: safe_transport(transport)
  defp transport(_), do: nil

  defp safe_transport("telegram"), do: :telegram
  defp safe_transport("discord"), do: :discord
  defp safe_transport(_), do: nil

  defp auto_send_generated_files?(files) do
    truthy?(map_value(files, :auto_send_generated_files, false)) or
      truthy?(map_value(files, :auto_send_generated_images, false))
  end

  defp truthy?(value), do: value in [true, "true", 1]
  defp configured_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp map_value(_, _, default), do: default
end
