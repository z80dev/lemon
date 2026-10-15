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

    test "a configured Discord bot reports healthy from config alone, ignoring stale proof files" do
      tmp_dir =
        project_with_config("channels_discord", """
        [gateway]
        enable_discord = true

        [gateway.discord]
        bot_token_secret = "discord_bot_token_secret_name"
        message_content_intent_enabled = false
        """)

      # Legacy live-proof artifacts must not influence the doctor.
      proofs_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proofs_dir)

      File.write!(
        Path.join(proofs_dir, "discord-dm-proof.json"),
        Jason.encode!(%{
          status: "failed",
          reason_kind: "discord_dm_setup_refused",
          checks: [%{name: "discord_dm_prompt_round_trip", status: "failed"}]
        })
      )

      checks = Channels.run(project_dir: tmp_dir)
      discord_checks = Enum.filter(checks, &String.starts_with?(&1.name, "channels.discord."))

      assert Enum.map(discord_checks, & &1.name) == [
               "channels.discord.config",
               "channels.discord.free_response"
             ]

      assert check_status(checks, "channels.discord.config") == :pass
      assert check_status(checks, "channels.discord.free_response") == :skip
      refute Enum.any?(discord_checks, &(&1.status in [:warn, :fail]))

      free_response = find_check(checks, "channels.discord.free_response")
      assert free_response.message =~ "gateway.discord.message_content_intent_enabled"
      refute inspect(checks) =~ "discord_bot_token_secret_name"
    end

    test "declared Discord Message Content Intent passes the free-response check" do
      tmp_dir =
        project_with_config("channels_discord_intent", """
        [gateway]
        enable_discord = true

        [gateway.discord]
        bot_token_secret = "discord_private_secret_name"
        message_content_intent_enabled = true
        """)

      checks = Channels.run(project_dir: tmp_dir)

      assert check_status(checks, "channels.discord.config") == :pass
      assert check_status(checks, "channels.discord.free_response") == :pass
      refute inspect(checks) =~ "discord_private_secret_name"
    end

    test "an enabled Discord bot without credentials warns with remediation" do
      tmp_dir =
        project_with_config("channels_discord_missing_token", """
        [gateway]
        enable_discord = true
        """)

      check = find_check(Channels.run(project_dir: tmp_dir), "channels.discord.config")

      assert check.status == :warn
      assert check.remediation =~ "gateway.discord.bot_token_secret"
    end

    test "Telegram local voice transcription warns that no STT backend exists" do
      tmp_dir =
        project_with_config("channels_telegram_voice_local", """
        [gateway]
        enable_telegram = true

        [gateway.telegram]
        bot_token_secret = "telegram_bot_token_secret_name"
        voice_transcription = true
        voice_transcription_provider = "local_transcript"
        """)

      checks = Channels.run(project_dir: tmp_dir)

      assert check_status(checks, "channels.telegram.config") == :pass
      assert check_status(checks, "channels.telegram.voice_transcription") == :warn
      refute inspect(checks) =~ "telegram_bot_token_secret_name"
    end

    test "Telegram provider voice transcription without an API key warns" do
      tmp_dir =
        project_with_config("channels_telegram_voice_provider", """
        [gateway]
        enable_telegram = true

        [gateway.telegram]
        bot_token_secret = "telegram_bot_token_secret_name"
        voice_transcription = true
        voice_transcription_provider = "openai_transcribe"
        """)

      check =
        find_check(Channels.run(project_dir: tmp_dir), "channels.telegram.voice_transcription")

      assert check.status == :warn
      assert check.remediation =~ "voice_transcription_api_key"
    end
  end

  defp project_with_config(prefix, toml) do
    tmp_dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    File.write!(Path.join([tmp_dir, ".lemon", "config.toml"]), toml)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  defp find_check(checks, name), do: Enum.find(checks, &(&1.name == name))

  defp check_status(checks, name) do
    checks
    |> find_check(name)
    |> Map.fetch!(:status)
  end
end
