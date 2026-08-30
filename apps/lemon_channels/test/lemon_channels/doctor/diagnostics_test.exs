defmodule LemonChannels.Doctor.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Doctor.Diagnostics

  test "reports redacted Telegram and Discord transport diagnostics" do
    tmp_dir = tmp_dir()
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

    File.write!(
      Path.join([tmp_dir, ".lemon", "config.toml"]),
      """
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

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    status = Diagnostics.status(project_dir: tmp_dir)

    assert status.binding_count == 2
    assert status.unsupported_binding_count == 0
    assert is_list(status.registered_transports)

    telegram = Enum.find(status.transports, &(&1.transport == "telegram"))
    discord = Enum.find(status.transports, &(&1.transport == "discord"))

    assert telegram.enabled == true
    assert telegram.token_configured == true
    assert telegram.token_secret_configured == true
    assert telegram.allowed_peer_count == 2
    assert telegram.binding_count == 1
    assert telegram.topic_binding_count == 1
    assert telegram.files.enabled == true
    assert telegram.files.auto_send_generated_files == true
    assert telegram.files.deny_glob_count == 2
    assert telegram.voice_transcription.enabled == true
    assert telegram.voice_transcription.api_key_configured == true

    assert discord.enabled == true
    assert discord.token_configured == true
    assert discord.token_secret_configured == true
    assert discord.allowed_guild_count == 1
    assert discord.allowed_channel_count == 1
    assert discord.binding_count == 1
    assert discord.files.auto_send_generated_files == true
    assert discord.bot_message_policy.ignores_self_messages == true
    assert discord.bot_message_policy.ignores_webhooks == true
    assert discord.bot_message_policy.external_bot_messages_allowed == true
    assert discord.bot_message_policy.external_bot_messages_stable == false
    assert discord.bot_message_policy.external_bot_messages_live_proof_required == true
    assert discord.direct_messages.prompt_round_trip_supported == true
    assert discord.direct_messages.requires_reachable_dm_channel == true
    assert discord.direct_messages.bot_to_bot_dm_stable == false
    assert discord.direct_messages.setup_refusal_reason_kind == "discord_dm_setup_refused"
    assert discord.direct_messages.live_external_sender_proof_required == true
    assert discord.direct_messages.live_external_sender_proof_source == "proof_diagnostics"
    assert discord.free_response.trigger_command_supported == true
    assert discord.free_response.default_mode == "mentions"
    assert discord.free_response.all_messages_mode_supported == true
    assert discord.free_response.requires_message_content_intent == true
    assert discord.free_response.runtime_requests_message_content_intent == true
    assert discord.free_response.message_content_intent_declared == true
    assert discord.free_response.live_external_sender_proof_required == true
    assert discord.free_response.live_external_sender_proof_source == "proof_diagnostics"
    assert discord.inbound_replay.duplicate_message_suppression_supported == true
    assert discord.inbound_replay.persisted_idempotency_supported == true
    assert discord.inbound_replay.transport_restart_dedupe_proof_source == "discord_dedupe_proof"
    assert discord.inbound_replay.live_gateway_reconnect_proof_required == true
    assert discord.inbound_replay.live_gateway_reconnect_proof_source == "live_discord_matrix"
    assert discord.slash_commands.schema_export_supported == true
    assert discord.slash_commands.expected_command_count == 32
    assert "checkpoint" in discord.slash_commands.expected_commands
    assert "rollback" in discord.slash_commands.expected_commands
    assert "kanban" in discord.slash_commands.expected_commands
    assert "media" in discord.slash_commands.expected_commands
    assert discord.slash_commands.live_registration_proof_required == true
    assert discord.slash_commands.live_registration_proof_source == "live_discord_matrix"

    assert discord.slash_commands.deterministic_runtime_decoder_proof_source ==
             "discord_slash_interaction_proof"

    assert discord.slash_commands.real_client_click_proof_required_for_broad_parity == true

    assert status.cleanup.includes_raw_bot_tokens == false
    assert status.cleanup.includes_secret_names == false
    assert status.cleanup.includes_chat_ids == false
    assert status.cleanup.includes_channel_ids == false
    assert status.cleanup.includes_guild_ids == false
    assert status.cleanup.includes_message_bodies == false

    rendered = inspect(status)
    refute rendered =~ "123456789:SECRET_TOKEN"
    refute rendered =~ "telegram_bot_token_secret_name"
    refute rendered =~ "discord-token-secret"
    refute rendered =~ "discord_bot_token_secret_name"
    refute rendered =~ "111111111111111111"
    refute rendered =~ "222222222222222222"
    refute rendered =~ "sk-voice-secret"
  end

  test "counts unsupported bindings separately from reported transports" do
    tmp_dir = tmp_dir()
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

    File.write!(
      Path.join([tmp_dir, ".lemon", "config.toml"]),
      """
      [gateway]
      enable_telegram = true

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 123
      agent_id = "default"

      [[gateway.bindings]]
      transport = "demo"
      chat_id = 456
      agent_id = "default"
      """
    )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    status = Diagnostics.status(project_dir: tmp_dir)

    assert status.binding_count == 1
    assert status.unsupported_binding_count == 1
    assert Enum.find(status.transports, &(&1.transport == "telegram")).binding_count == 1
  end

  test "always reports both reported transports with redacted cleanup flags" do
    tmp_dir = tmp_dir()
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    status = Diagnostics.status(project_dir: tmp_dir)

    assert length(status.transports) == 2
    assert Enum.all?(status.transports, &(&1.transport in ["telegram", "discord"]))
    assert is_list(status.registered_transports)
    assert status.cleanup.includes_raw_bot_tokens == false
    assert status.cleanup.includes_secret_names == false
    assert status.cleanup.includes_message_bodies == false
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_channel_diagnostics_test_#{System.unique_integer([:positive])}"
    )
  end
end
