defmodule LemonGateway.Voice.CallSessionTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Voice.CallSession

  setup do
    previous_model = Application.get_env(:lemon_gateway, :voice_llm_model)
    Application.put_env(:lemon_gateway, :voice_llm_model, "unknown-model")

    on_exit(fn ->
      if is_nil(previous_model) do
        Application.delete_env(:lemon_gateway, :voice_llm_model)
      else
        Application.put_env(:lemon_gateway, :voice_llm_model, previous_model)
      end
    end)

    :ok
  end

  test "generate_response task sends speak cast back to owner process" do
    state = %CallSession{
      call_sid: "call-1",
      from_number: "+15550000000",
      to_number: "+15551111111",
      twilio_ws_pid: nil,
      deepgram_ws_pid: nil,
      started_at: DateTime.utc_now(),
      last_activity_at: DateTime.utc_now(),
      current_utterance: "",
      is_speaking: false,
      is_processing: false,
      response_queue: [],
      session_key: "voice:+15550000000",
      conversation_history: [%{role: "user", content: "hello"}],
      interruption_detected: false
    }

    assert {:noreply, new_state} = CallSession.handle_info(:generate_response, state)
    assert new_state.is_processing
    assert_receive {:"$gen_cast", {:speak, response}}, 1_000
    assert is_binary(response)
    assert response != ""
  end

  test "child spec uses temporary restart to avoid restart loops after normal call end" do
    spec = CallSession.child_spec(call_sid: "call-1")
    assert spec.restart == :temporary
  end

  test "audio_from_twilio forwards audio to deepgram client via cast and updates activity" do
    before_ts = DateTime.utc_now()

    state = %CallSession{
      call_sid: "call-1",
      from_number: "+15550000000",
      to_number: "+15551111111",
      twilio_ws_pid: nil,
      deepgram_ws_pid: self(),
      started_at: before_ts,
      last_activity_at: before_ts,
      current_utterance: "",
      is_speaking: false,
      is_processing: false,
      response_queue: [],
      session_key: "voice:+15550000000",
      conversation_history: [],
      interruption_detected: false
    }

    assert {:noreply, new_state} =
             CallSession.handle_cast({:audio_from_twilio, <<1, 2, 3, 4>>}, state)

    assert_receive {:"$websockex_cast", {:send_audio, <<1, 2, 3, 4>>}}, 500
    assert DateTime.compare(new_state.last_activity_at, before_ts) in [:eq, :gt]
  end

  test "audio_ready always advances speech state even when twilio websocket is missing" do
    state = %CallSession{
      call_sid: "call-1",
      from_number: "+15550000000",
      to_number: "+15551111111",
      twilio_ws_pid: nil,
      deepgram_ws_pid: nil,
      started_at: DateTime.utc_now(),
      last_activity_at: DateTime.utc_now(),
      current_utterance: "",
      is_speaking: true,
      is_processing: true,
      response_queue: [],
      session_key: "voice:+15550000000",
      conversation_history: [],
      interruption_detected: false
    }

    assert {:noreply, new_state} = CallSession.handle_info({:audio_ready, <<0, 0>>, "hi"}, state)
    assert new_state.is_processing == false
    assert_receive :speech_complete, 500
  end
end
