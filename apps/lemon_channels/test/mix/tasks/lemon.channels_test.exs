defmodule Mix.Tasks.Lemon.ChannelsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Channels

  setup do
    Mix.Task.run("loadpaths")

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_channels_task_test_#{System.unique_integer([:positive])}"
      )

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

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "prints redacted promoted channel readiness", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        Channels.run(["--project-dir", tmp_dir])
      end)

    assert output =~ "Lemon Channels"
    assert output =~ "Promoted platforms: telegram, discord"
    assert output =~ "Includes raw bot tokens: false"
    assert output =~ "Includes secret names: false"
    assert output =~ "Includes channel IDs: false"
    assert output =~ "telegram.config: passed"
    assert output =~ "discord.slash_client_click: warning"
    assert output =~ "discord_slash_client_click_missing"
    refute output =~ tmp_dir
    refute output =~ "private-telegram-token"
    refute output =~ "private-discord-secret-name"
    refute output =~ "111222333"
    refute output =~ "private operator prompt"
  end

  test "emits redacted JSON", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        Channels.run(["--project-dir", tmp_dir, "--json"])
      end)

    assert {:ok, decoded} = Jason.decode(output)
    assert decoded["promoted_platforms"] == ["telegram", "discord"]
    assert decoded["gate_count"] == 9
    assert decoded["cleanup"]["includes_raw_bot_tokens"] == false
    refute output =~ tmp_dir
    refute output =~ "private-telegram-token"
    refute output =~ "private-discord-secret-name"
    refute output =~ "111222333"
    refute output =~ "private operator prompt"
  end

  defp write_proof!(tmp_dir, filename, proof) do
    path = Path.join([tmp_dir, ".lemon", "proofs", filename])
    File.write!(path, Jason.encode!(proof))
  end
end
