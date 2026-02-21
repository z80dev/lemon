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
end
