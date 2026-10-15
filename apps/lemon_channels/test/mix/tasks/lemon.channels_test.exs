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

    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

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
      allowed_channel_ids = [111222333]
      """
    )

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "prints redacted per-transport configuration status", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        Channels.run(["--project-dir", tmp_dir])
      end)

    assert output =~ "Lemon Channels"
    assert output =~ ~r/telegram: enabled=true credentials=configured .*voice_transcription=true/

    assert output =~
             ~r/discord: enabled=true credentials=configured .*allowed_channels=1 .*message_content_intent=true/

    refute output =~ tmp_dir
    refute output =~ "private-telegram-token"
    refute output =~ "private-discord-secret-name"
    refute output =~ "111222333"
  end

  test "emits redacted JSON", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        Channels.run(["--project-dir", tmp_dir, "--json"])
      end)

    assert {:ok, decoded} = Jason.decode(output)

    assert Enum.map(decoded["transports"], & &1["transport"]) == ["telegram", "discord"]
    assert Enum.all?(decoded["transports"], & &1["enabled"])
    assert decoded["cleanup"]["includes_raw_bot_tokens"] == false
    refute output =~ tmp_dir
    refute output =~ "private-telegram-token"
    refute output =~ "private-discord-secret-name"
    refute output =~ "111222333"
  end
end
