defmodule LemonChannels.Adapters.WhatsApp.InboundTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.WhatsApp.Inbound

  test "only native push-to-talk audio is inbound voice" do
    for {media_type, ptt, expected} <- [
          {"audio", true, true},
          {"audio", false, false},
          {"audio", nil, false},
          {"document", true, false},
          {nil, nil, false}
        ] do
      event = %{
        "type" => "message",
        "jid" => "123@s.whatsapp.net",
        "sender_jid" => "123@s.whatsapp.net",
        "message_id" => "message-1",
        "text" => "",
        "media_type" => media_type,
        "ptt" => ptt,
        "from_me" => false
      }

      assert {:ok, inbound} = Inbound.normalize(event)
      assert inbound.meta.inbound_voice == expected
    end
  end
end
