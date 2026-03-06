defmodule CodingAgent.Session.StateTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentTool
  alias CodingAgent.Session.State

  test "normalize_extra_tools keeps only AgentTool structs" do
    tool = %AgentTool{
      name: "read",
      description: "read",
      parameters: %{},
      execute: fn _, _, _, _ -> :ok end
    }

    assert [^tool] = State.normalize_extra_tools([tool, %{}, "nope"])
    assert [] = State.normalize_extra_tools(:invalid)
  end

  test "build_context_guardrail_opts merges defaults with overrides" do
    opts = State.build_context_guardrail_opts("/tmp", "session-1", %{max_thinking_bytes: 1_024})

    assert opts.max_thinking_bytes == 1_024
    assert opts.max_tool_result_images == 0
    assert is_binary(opts.spill_dir)
  end

  test "build_prompt_message preserves plain text without images" do
    message = State.build_prompt_message("hello")

    assert %Ai.Types.UserMessage{content: "hello", role: :user} = message
    assert is_integer(message.timestamp)
  end

  test "build_prompt_message expands multipart content when images are present" do
    image = %{data: "b64", mime_type: "image/png"}
    message = State.build_prompt_message("look", images: [image])

    assert %Ai.Types.UserMessage{
             content: [
               %Ai.Types.TextContent{text: "look"},
               %Ai.Types.ImageContent{data: "b64", mime_type: "image/png"}
             ]
           } = message
  end

  test "begin_prompt resets overflow recovery bookkeeping" do
    timer_ref = make_ref()

    state = %{
      is_streaming: false,
      pending_prompt_timer_ref: nil,
      turn_index: 4,
      overflow_recovery_in_progress: true,
      overflow_recovery_attempted: true,
      overflow_recovery_signature: :sig,
      overflow_recovery_started_at_ms: 12,
      overflow_recovery_error_reason: :boom,
      overflow_recovery_partial_state: %{foo: :bar}
    }

    next_state = State.begin_prompt(state, timer_ref)

    assert next_state.is_streaming
    assert next_state.pending_prompt_timer_ref == timer_ref
    assert next_state.turn_index == 5
    refute next_state.overflow_recovery_in_progress
    refute next_state.overflow_recovery_attempted
    assert next_state.overflow_recovery_signature == nil
    assert next_state.overflow_recovery_started_at_ms == nil
    assert next_state.overflow_recovery_error_reason == nil
    assert next_state.overflow_recovery_partial_state == nil
  end
end
