defmodule LemonGateway.Voice.TwilioWebSocketTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Voice.TwilioWebSocket

  test "speech_complete forwards notification to call session process" do
    state = %{call_sid: "call-1", session_pid: self(), stream_sid: "MS123"}

    assert {:ok, ^state} = TwilioWebSocket.handle_info(:speech_complete, state)
    assert_receive :speech_complete, 500
  end

  test "speech_complete is a no-op when session pid is missing" do
    state = %{call_sid: "call-1", session_pid: nil, stream_sid: "MS123"}
    assert {:ok, ^state} = TwilioWebSocket.handle_info(:speech_complete, state)
  end

  test "media frames are forwarded to call session and buffered" do
    payload = Base.encode64(<<1, 2, 3, 4>>)

    state = %{
      call_sid: "call-1",
      session_pid: self(),
      deepgram_pid: self(),
      stream_sid: "MS123",
      audio_buffer: <<>>
    }

    frame =
      Jason.encode!(%{
        "event" => "media",
        "media" => %{"track" => "inbound", "payload" => payload}
      })

    assert {:ok, new_state} = TwilioWebSocket.handle_in({frame, [opcode: :text]}, state)
    assert new_state.audio_buffer == <<1, 2, 3, 4>>

    assert_receive {:"$gen_cast", {:audio_from_twilio, <<1, 2, 3, 4>>}}, 500
  end

  test "start event binds provisional call sid to twilio call sid" do
    state = %{
      call_sid: "temp_deadbeef",
      session_pid: self(),
      deepgram_pid: self(),
      stream_sid: nil,
      audio_buffer: <<>>
    }

    frame =
      Jason.encode!(%{
        "event" => "start",
        "start" => %{"streamSid" => "MS123", "callSid" => "CAabc123"}
      })

    assert {:ok, new_state} = TwilioWebSocket.handle_in({frame, [opcode: :text]}, state)
    assert new_state.stream_sid == "MS123"
    assert new_state.call_sid == "CAabc123"
  end
end
