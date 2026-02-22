defmodule LemonChannels.Adapters.Telegram.VoiceTranscriptionTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  defmodule LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.TestRouter do
    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end
  end

  defmodule LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.MockAPI do
    @updates_key {__MODULE__, :updates}
    @sent_key {__MODULE__, :sent}

    def set_updates(updates), do: :persistent_term.put(@updates_key, updates)
    def register_sent(pid), do: :persistent_term.put(@sent_key, pid)

    def get_updates(_token, _offset, _timeout_ms) do
      updates = :persistent_term.get(@updates_key, [])

      case updates do
        [first | rest] ->
          :persistent_term.put(@updates_key, rest)
          {:ok, %{"ok" => true, "result" => [first]}}

        [] ->
          {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def get_file(_token, _file_id) do
      {:ok, %{"ok" => true, "result" => %{"file_path" => "voice.ogg"}}}
    end

    def download_file(_token, _file_path) do
      {:ok, "AUDIO"}
    end

    def send_message(_token, _chat_id, text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      if pid = :persistent_term.get(@sent_key, nil) do
        send(pid, {:sent, text})
      end

      {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}
    end

    def edit_message_text(_token, _chat_id, _message_id, _text, _parse_mode_or_opts \\ nil) do
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}
    def answer_callback_query(_token, _cb_id, _opts \\ %{}), do: {:ok, %{"ok" => true}}
  end

  defmodule TestTranscriber do
    def transcribe(opts) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:transcribe, opts})
      end

      {:ok, "hello from voice"}
    end
  end

  setup do
    :persistent_term.put({Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.TestRouter, :pid}, self())
    :persistent_term.put({TestTranscriber, :pid}, self())
    Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.MockAPI.register_sent(self())
    LemonCore.RouterBridge.configure(router: Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.TestRouter)

    on_exit(fn ->
      if pid = Process.whereis(Elixir.LemonChannels.Adapters.Telegram.Transport) do
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        end
      end

      :persistent_term.erase({Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.TestRouter, :pid})
      :persistent_term.erase({TestTranscriber, :pid})
      :persistent_term.erase({Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.MockAPI, :sent})
      :persistent_term.erase({Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.MockAPI, :updates})
    end)

    :ok
  end

  defp voice_update do
    %{
      "update_id" => 1,
      "message" => %{
        "message_id" => 11,
        "date" => 1,
        "chat" => %{"id" => 123, "type" => "private"},
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "voice" => %{
          "file_id" => "voice-1",
          "mime_type" => "audio/ogg",
          "file_size" => 120,
          "duration" => 1
        }
      }
    }
  end

  test "transcribes voice and routes transcript" do
    Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.MockAPI.set_updates([voice_update()])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.MockAPI,
          poll_interval_ms: 10,
          debounce_ms: 10,
          voice_transcription: true,
          voice_transcription_api_key: "key",
          voice_transcriber: TestTranscriber,
          voice_max_bytes: 10_000
        }
      )

    assert_receive {:transcribe, opts}, 200
    assert opts[:audio_bytes] == "AUDIO"

    assert_receive {:inbound, msg}, 200
    assert msg.message.text == "hello from voice"
    assert msg.meta[:voice_transcribed] == true
  end

  test "voice disabled replies and skips routing" do
    Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.MockAPI.set_updates([voice_update()])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.VoiceTranscriptionTest.MockAPI,
          poll_interval_ms: 10,
          debounce_ms: 10,
          voice_transcription: false,
          voice_transcription_api_key: "key"
        }
      )

    assert_receive {:sent, text}, 200
    assert String.contains?(text, "Voice transcription is disabled")
    refute_receive {:inbound, _msg}, 100
  end
end
