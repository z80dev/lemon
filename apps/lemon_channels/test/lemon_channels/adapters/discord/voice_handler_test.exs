defmodule LemonChannels.Adapters.Discord.VoiceHandlerTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Discord.{Inbound, VoiceHandler}

  defmodule Provider do
    def transcribe(%{
          audio_bytes: "AUDIO",
          mime_type: "audio/ogg",
          provider: "openai_transcribe"
        }),
        do: {:ok, "  hello from voice  "}
  end

  defmodule FailingProvider do
    def transcribe(_), do: {:error, :provider_failed}
  end

  defmodule EmptyProvider do
    def transcribe(_), do: {:ok, "   "}
  end

  defp config do
    %{
      enabled: true,
      provider: "openai_transcribe",
      model: "test",
      base_url: "unused",
      api_key: "stub",
      max_bytes: 10
    }
  end

  defp inbound(overrides \\ %{}, content \\ "", flags \\ 8192) do
    attachment =
      Map.merge(
        %{
          id: 4,
          filename: "voice.ogg",
          content_type: "audio/ogg",
          size: 5,
          url: "https://cdn.discordapp.com/attachments/1/voice.ogg",
          duration_secs: 2,
          waveform: "AAAA"
        },
        overrides
      )

    {:ok, inbound} =
      Inbound.normalize(%{
        account_id: "default",
        message: %{
          id: 1,
          channel_id: 2,
          flags: flags,
          content: content,
          author: %{id: 3},
          attachments: [attachment]
        }
      })

    inbound
  end

  test "voice attachment becomes real transcript combined with typed content" do
    download = fn url, 10 ->
      assert url =~ "cdn.discordapp.com"
      {:ok, "AUDIO"}
    end

    {result, []} = VoiceHandler.transcribe(inbound(%{}, "typed"), config(), download, Provider)
    assert result.message.text == "typed\n\nhello from voice"
    assert result.meta.voice_transcribed
  end

  test "ordinary audio attachments also transcribe without voice flags" do
    original = inbound(%{}, "", 0)

    {result, []} =
      VoiceHandler.transcribe(original, config(), fn _, _ -> {:ok, "AUDIO"} end, Provider)

    assert result.message.text == "hello from voice"
  end

  test "disabled transcription keeps URL and reports existing disabled copy without downloading" do
    original = inbound()
    assert original.meta.voice_message

    assert {^original, ["Voice transcription is disabled."]} =
             VoiceHandler.transcribe(
               original,
               %{config() | enabled: false},
               fn _, _ -> flunk("downloaded") end,
               Provider
             )
  end

  test "disabled transcription silently preserves ordinary audio attachment URLs" do
    original = inbound(%{}, "", 0)
    refute original.meta.voice_message

    assert {^original, []} =
             VoiceHandler.transcribe(
               original,
               %{config() | enabled: false},
               fn _, _ -> flunk("downloaded") end,
               Provider
             )
  end

  test "oversized metadata fails before download" do
    original = inbound(%{size: 11})

    assert {^original, [error]} =
             VoiceHandler.transcribe(
               original,
               config(),
               fn _, _ -> flunk("downloaded") end,
               Provider
             )

    assert error =~ "too large"
  end

  test "actual downloaded size is bounded independently of metadata" do
    original = inbound()

    assert {^original, [error]} =
             VoiceHandler.transcribe(
               original,
               config(),
               fn _, _ -> {:ok, String.duplicate("a", 11)} end,
               Provider
             )

    assert error =~ "too large"
  end

  test "non-CDN hosts are rejected without network calls" do
    original = inbound(%{url: "https://example.com/voice.ogg"})

    assert {^original, [error]} =
             VoiceHandler.transcribe(
               original,
               config(),
               fn _, _ -> flunk("downloaded") end,
               Provider
             )

    assert error =~ "Voice transcription failed"
  end

  test "provider errors preserve the URL instead of submitting a synthetic transcript" do
    original = inbound()

    assert {^original, [error]} =
             VoiceHandler.transcribe(
               original,
               config(),
               fn _, _ -> {:ok, "AUDIO"} end,
               FailingProvider
             )

    assert error =~ "send the message as text"
  end

  test "blank provider text is not a successful transcript" do
    original = inbound()

    assert {^original, [_error]} =
             VoiceHandler.transcribe(
               original,
               config(),
               fn _, _ -> {:ok, "AUDIO"} end,
               EmptyProvider
             )
  end

  test "non-audio attachment URLs survive successful transcription" do
    original = inbound()

    other = %{
      url: "https://cdn.discordapp.com/attachments/1/file.pdf",
      content_type: "application/pdf"
    }

    original = %{original | meta: Map.update!(original.meta, :attachments, &(&1 ++ [other]))}

    {result, []} =
      VoiceHandler.transcribe(original, config(), fn _, _ -> {:ok, "AUDIO"} end, Provider)

    assert result.message.text ==
             "hello from voice\n\nAttachments:\n- https://cdn.discordapp.com/attachments/1/file.pdf"
  end

  test "local transcript fails closed" do
    original = inbound()

    assert {^original, [_error]} =
             VoiceHandler.transcribe(original, %{config() | provider: "local_transcript"}, fn _,
                                                                                              _ ->
               {:ok, "AUDIO"}
             end)
  end
end
