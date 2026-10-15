defmodule LemonChannels.Doctor.Checks.Channels do
  @moduledoc "Checks Telegram and Discord channel configuration from redacted diagnostics."

  alias LemonChannels.Doctor.Diagnostics
  alias LemonCore.Doctor.Check

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    channels = Diagnostics.status(project_dir: project_dir)
    telegram = transport_status(channels, "telegram")
    discord = transport_status(channels, "discord")

    [
      check_telegram(telegram),
      check_telegram_allowlist(telegram),
      check_telegram_voice_transcription(telegram),
      check_discord_config(discord),
      check_discord_free_response(discord)
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

  @doc "Returns opt-in bot identity jobs; offline checks never resolve live credentials."
  @spec live_checks(keyword()) :: [LemonCore.Doctor.LiveChecks.job()]
  def live_checks(opts), do: LemonChannels.Doctor.LiveChecks.jobs(opts)

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

  defp check_telegram_allowlist(%{enabled: true} = telegram) do
    cond do
      Map.get(telegram, :allowed_peer_count, 0) > 0 ->
        Check.pass(
          "channels.telegram.allowlist",
          "Telegram accepts #{telegram.allowed_peer_count} paired chat(s)."
        )

      Map.get(telegram, :allow_all_peers) == true ->
        Check.warn(
          "channels.telegram.allowlist",
          "Telegram accepts every chat (gateway.telegram.allow_all_chats = true); anyone who finds the bot can run the agent.",
          "Run `lemon gateway setup telegram` to pair your chat and remove allow_all_chats."
        )

      true ->
        Check.fail(
          "channels.telegram.allowlist",
          "Telegram allowlist is empty: the bot is unpaired and ignores every chat.",
          "Run `lemon gateway setup telegram` to pair your chat (writes gateway.telegram.allowed_chat_ids)."
        )
    end
  end

  defp check_telegram_allowlist(_telegram) do
    Check.skip("channels.telegram.allowlist", "Telegram is disabled.")
  end

  defp check_telegram_voice_transcription(%{enabled: true} = telegram) do
    voice = Map.get(telegram, :voice_transcription, %{})

    cond do
      Map.get(voice, :enabled) != true ->
        Check.skip(
          "channels.telegram.voice_transcription",
          "Telegram voice transcription is disabled."
        )

      Map.get(voice, :provider) == "local_transcript" ->
        Check.warn(
          "channels.telegram.voice_transcription",
          "Telegram local speech-to-text is unavailable; voice messages will not start runs.",
          "Use voice_transcription_provider = \"openai_transcribe\" and configure gateway.telegram.voice_transcription_api_key."
        )

      Map.get(voice, :api_key_required) == true and Map.get(voice, :api_key_configured) != true ->
        Check.warn(
          "channels.telegram.voice_transcription",
          "Telegram voice transcription is enabled but provider credentials are missing.",
          "Set gateway.telegram.voice_transcription_api_key with voice_transcription_provider = \"openai_transcribe\"."
        )

      true ->
        Check.pass(
          "channels.telegram.voice_transcription",
          "Telegram voice transcription is enabled with provider #{Map.get(voice, :provider)}."
        )
    end
  end

  defp check_telegram_voice_transcription(_telegram) do
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

  defp check_discord_free_response(%{enabled: true} = discord) do
    if get_in(discord, [:free_response, :message_content_intent_declared]) == true do
      Check.pass(
        "channels.discord.free_response",
        "Discord Message Content Intent is declared; free-response trigger mode can see unmentioned messages."
      )
    else
      Check.skip(
        "channels.discord.free_response",
        "Discord Message Content Intent is not declared, so free-response trigger mode only sees mentions. Enable the privileged intent in the Discord Developer Portal, then set gateway.discord.message_content_intent_enabled = true."
      )
    end
  end

  defp check_discord_free_response(_discord) do
    Check.skip("channels.discord.free_response", "Discord is disabled.")
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
end
