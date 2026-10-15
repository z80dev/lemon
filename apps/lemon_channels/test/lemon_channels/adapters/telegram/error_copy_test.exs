defmodule LemonChannels.Adapters.Telegram.ErrorCopyTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.{VoiceHandler, FileOperations, TopicCommand}

  defmodule FailingAPI do
    def get_file(_, _), do: {:ok, %{"ok" => true, "result" => %{"file_path" => "voice.ogg"}}}
    def download_file(_, _), do: {:ok, "audio"}
    def send_document(_, _, _, _), do: {:error, {:forbidden, %{private: :detail}}}
    def create_forum_topic(_, _, _), do: {:error, {:forbidden, %{private: :detail}}}
  end

  defmodule FailingTranscriber do
    def transcribe(_), do: {:error, {:provider_failed, %{private: :detail}}}
  end

  defmodule FailingDownloadAPI do
    def get_file(_, _), do: {:error, {:unavailable, %{private: :detail}}}
  end

  test "voice tuple failures and missing credentials have actionable plain copy" do
    state = %{
      voice_transcription: true,
      voice_transcription_api_key: "key",
      voice_transcription_model: "model",
      voice_transcription_base_url: "unused",
      voice_transcriber: FailingTranscriber,
      voice_max_bytes: 100,
      api_mod: FailingAPI,
      token: "unused"
    }

    inbound = %{meta: %{voice: %{file_id: "voice"}}, message: %{text: ""}}
    callback = fn _, _, _, _, text -> send(self(), {:reply, text}) end
    ids = fn _ -> {1, nil, 2} end

    assert {:skip, ^state} = VoiceHandler.maybe_transcribe_voice(state, inbound, callback, ids)
    assert_receive {:reply, text}
    assert text =~ "send the message as text"
    assert_plain(text)

    state = %{state | voice_transcription_api_key: nil}
    assert {:skip, ^state} = VoiceHandler.maybe_transcribe_voice(state, inbound, callback, ids)
    assert_receive {:reply, text}
    assert text =~ "OPENAI_API_KEY"
    assert text =~ "lemon secrets set"
    assert_plain(text)
  end

  test "file API tuple failures have next steps without raw terms" do
    assert {:error, text} =
             FileOperations.send_document_reply(
               %{api_mod: FailingAPI, token: "unused"},
               1,
               nil,
               nil,
               "unused",
               "file"
             )

    assert text =~ "file size"
    assert_plain(text)

    assert {:error, text} =
             FileOperations.download_media_bytes(
               %{api_mod: FailingDownloadAPI, token: "unused"},
               %{meta: %{document: %{file_id: "file"}}}
             )

    assert text =~ "again"
    assert_plain(text)
  end

  test "topic API tuple failures explain required bot permissions" do
    state = %{api_mod: FailingAPI, token: "unused"}
    inbound = %{message: %{text: "/topic Test"}, meta: %{}}

    callbacks = %{
      extract_message_ids: fn _ -> {1, nil, 2} end,
      send_system_message: fn _, _, _, _, text -> send(self(), {:reply, text}) end
    }

    assert ^state = TopicCommand.handle_topic_command(state, inbound, callbacks)
    assert_receive {:reply, text}
    assert text =~ "permission to manage topics"
    assert_plain(text)
  end

  defp assert_plain(text) do
    refute text =~ "{"
    refute text =~ "%{"
    refute text =~ ":detail"
  end
end
