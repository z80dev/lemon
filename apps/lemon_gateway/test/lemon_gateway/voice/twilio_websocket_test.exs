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
      audio_buffer: <<>>,
      unauthorized_count: 0
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
      audio_buffer: <<>>,
      unauthorized_count: 0
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

  # ---------------------------------------------------------------------------
  # Flood guard tests
  # ---------------------------------------------------------------------------

  defp flood_state(count \\ 0) do
    %{
      call_sid: "CA-flood-test",
      session_pid: self(),
      deepgram_pid: self(),
      stream_sid: "MS-flood",
      audio_buffer: <<>>,
      unauthorized_count: count
    }
  end

  test "unrecognized event type increments unauthorized_count but keeps connection open" do
    frame = Jason.encode!(%{"event" => "unknown_evil_event"})
    assert {:ok, new_state} = TwilioWebSocket.handle_in({frame, [opcode: :text]}, flood_state())
    assert new_state.unauthorized_count == 1
  end

  test "malformed JSON increments unauthorized_count but keeps connection open" do
    assert {:ok, new_state} =
             TwilioWebSocket.handle_in({"not json!!!", [opcode: :text]}, flood_state())

    assert new_state.unauthorized_count == 1
  end

  test "binary frame increments unauthorized_count but keeps connection open" do
    assert {:ok, new_state} =
             TwilioWebSocket.handle_in({<<0, 1, 2, 3>>, [opcode: :binary]}, flood_state())

    assert new_state.unauthorized_count == 1
  end

  test "flood guard closes connection when threshold is reached" do
    # Arrive one step below the threshold and send one more unauthorized frame
    state = flood_state(9)
    frame = Jason.encode!(%{"event" => "bad_event"})
    assert {:stop, :normal, new_state} = TwilioWebSocket.handle_in({frame, [opcode: :text]}, state)
    assert new_state.unauthorized_count == 10
  end

  test "flood guard closes connection when threshold is already exceeded" do
    state = flood_state(10)
    frame = Jason.encode!(%{"event" => "bad_event"})
    assert {:stop, :normal, new_state} = TwilioWebSocket.handle_in({frame, [opcode: :text]}, state)
    assert new_state.unauthorized_count == 11
  end

  test "legitimate authorized traffic does not increment unauthorized_count" do
    payload = Base.encode64(<<1, 2, 3, 4>>)

    state = flood_state()

    frame =
      Jason.encode!(%{
        "event" => "media",
        "media" => %{"track" => "inbound", "payload" => payload}
      })

    assert {:ok, new_state} = TwilioWebSocket.handle_in({frame, [opcode: :text]}, state)
    assert new_state.unauthorized_count == 0
  end

  test "flood guard does not trigger before threshold" do
    state = flood_state(8)
    frame = Jason.encode!(%{"event" => "bad_event"})
    assert {:ok, new_state} = TwilioWebSocket.handle_in({frame, [opcode: :text]}, state)
    assert new_state.unauthorized_count == 9
  end
end
