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
end
