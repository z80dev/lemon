defmodule LemonChannels.Adapters.WhatsApp.VoiceOutboundTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.WhatsApp.{Bridge, Outbound, Transport}
  alias LemonChannels.OutboundPayload

  defmodule FakeTransport do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: Transport)
    def init(owner), do: {:ok, owner}

    def handle_call({:deliver, payload}, _from, owner) do
      send(owner, {:voice_transport, payload})
      {:reply, {:ok, %{"message_id" => "voice-id"}}, owner}
    end
  end

  test "voice delivery forwards inline audio with MIME, filename and reply" do
    start_supervised!({FakeTransport, self()})

    for {mime, filename} <- [{"audio/ogg", "reply.ogg"}, {"audio/mpeg", "reply.mp3"}] do
      bytes = <<0, 255, 2, 3>>

      payload = %OutboundPayload{
        channel_id: "whatsapp",
        account_id: "default",
        peer: %{kind: :dm, id: "123@s.whatsapp.net", thread_id: nil},
        kind: :voice,
        content: %{audio_bytes: bytes, mime_type: mime, filename: filename},
        reply_to: "original"
      }

      assert {:ok, %{"message_id" => "voice-id"}} = Outbound.deliver(payload)
      assert_receive {:voice_transport, command}
      assert command.kind == :send_voice
      assert command.jid == payload.peer.id
      assert Base.decode64!(command.audio_base64) == bytes
      assert command.mime_type == mime
      assert command.filename == filename
      assert command.reply_to_id == "original"
    end
  end

  test "bridge preserves inline voice fields in its JSON-safe port command" do
    assert :ok =
             Bridge.send_media(self(), %{
               id: "correlation",
               jid: "123@s.whatsapp.net",
               audio_base64: Base.encode64(<<0, 255>>),
               media_type: "audio",
               ptt: true,
               mime_type: "audio/mpeg",
               filename: "reply.mp3",
               reply_to: "original"
             })

    assert_receive {:"$gen_cast", {:command, command}}
    assert command["op"] == "send_media"
    assert command["ptt"] == true
    assert command["mime_type"] == "audio/mpeg"
    assert command["filename"] == "reply.mp3"
    assert command["reply_to"] == "original"
    assert Base.decode64!(command["audio_base64"]) == <<0, 255>>
    refute Map.has_key?(command, "file_path")
  end

  test "malformed voice payloads are rejected without transport delivery" do
    assert {:error, :invalid_voice_payload} =
             Outbound.deliver(%OutboundPayload{
               channel_id: "whatsapp",
               account_id: "default",
               peer: %{kind: :dm, id: "123@s.whatsapp.net", thread_id: nil},
               kind: :voice,
               content: %{audio_bytes: <<>>, mime_type: "audio/ogg", filename: "reply.ogg"}
             })
  end
end
