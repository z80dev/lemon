defmodule LemonGateway.Voice.TwilioWebSocketTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Voice.{StreamToken, TwilioWebSocket}

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

  describe "start event stream token" do
    setup do
      key = :gateway_test_config
      old = Application.get_env(:lemon_core, key)
      Application.put_env(:lemon_core, key, %{voice: %{twilio_auth_token: "ws-test-token"}})

      on_exit(fn ->
        if old,
          do: Application.put_env(:lemon_core, key, old),
          else: Application.delete_env(:lemon_core, key)
      end)
    end

    test "connection starts without any call resources" do
      assert {:ok, %{session_pid: nil, deepgram_pid: nil, call_sid: nil}} =
               TwilioWebSocket.init([])
    end

    test "start without a token closes the stream before creating resources" do
      {:ok, state} = TwilioWebSocket.init([])

      # CallSessionSupervisor is not running here: any resource creation would raise.
      assert {:stop, :normal, %{session_pid: nil}} =
               TwilioWebSocket.handle_in({start_frame("CAabc", %{}), [opcode: :text]}, state)
    end

    test "start with a token for another call closes the stream" do
      {:ok, state} = TwilioWebSocket.init([])
      token = StreamToken.sign("CAother", "+1", "+2")

      params = %{"callSid" => "CAabc", "from" => "+1", "to" => "+2", "token" => token}

      assert {:stop, :normal, %{session_pid: nil}} =
               TwilioWebSocket.handle_in({start_frame("CAabc", params), [opcode: :text]}, state)
    end

    test "start with tampered metadata closes the stream" do
      {:ok, state} = TwilioWebSocket.init([])
      token = StreamToken.sign("CAabc", "+1", "+2")

      params = %{"callSid" => "CAabc", "from" => "+9", "to" => "+2", "token" => token}

      assert {:stop, :normal, %{session_pid: nil}} =
               TwilioWebSocket.handle_in({start_frame("CAabc", params), [opcode: :text]}, state)
    end

    test "media before an authenticated start is dropped" do
      {:ok, state} = TwilioWebSocket.init([])

      frame =
        Jason.encode!(%{"event" => "media", "media" => %{"payload" => Base.encode64("x")}})

      assert {:ok, %{audio_buffer: <<>>}} =
               TwilioWebSocket.handle_in({frame, [opcode: :text]}, state)
    end

    test "StreamToken rejects expired tokens and fails closed without an auth token" do
      now = System.system_time(:second)
      token = StreamToken.sign("CA1", "+1", "+2", now - 1_000)
      assert {:error, :expired} = StreamToken.verify(token, "CA1", "+1", "+2", now)
      fresh = StreamToken.sign("CA1", "+1", "+2", now)
      assert :ok = StreamToken.verify(fresh, "CA1", "+1", "+2", now)

      Application.put_env(:lemon_core, :gateway_test_config, %{
        voice: %{twilio_auth_token: ""}
      })

      assert {:error, :no_auth_token} = StreamToken.verify(fresh, "CA1", "+1", "+2", now)
    end
  end

  test "call_ended from the session closes the stream" do
    state = %{call_sid: "CA1", session_pid: self(), deepgram_pid: nil, stream_sid: "MS1"}
    assert {:stop, :normal, %{session_pid: nil}} = TwilioWebSocket.handle_info(:call_ended, state)
  end

  defp start_frame(call_sid, custom) do
    Jason.encode!(%{
      "event" => "start",
      "start" => %{
        "streamSid" => "MS123",
        "callSid" => call_sid,
        "customParameters" => custom
      }
    })
  end
end
