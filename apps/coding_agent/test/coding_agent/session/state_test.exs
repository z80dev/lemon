defmodule CodingAgent.Session.StateTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.AgentTool
  alias LemonAi.Types.{TextContent, ToolResultMessage}
  alias CodingAgent.Session.{CompactionLifecycle, OverflowRecovery, State}

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

  test "pre-LLM transform bounds untrusted output while preserving one complete fence" do
    transform =
      State.build_transform_context(nil, %{
        enabled: true,
        mode: :trim,
        max_tool_result_bytes: 1_024,
        max_tool_result_images: 0,
        max_thinking_bytes: 0,
        max_tool_call_arg_string_bytes: 1_024,
        spill_dir: nil
      })

    message = %ToolResultMessage{
      tool_call_id: "oversize",
      tool_name: "read",
      trust: :untrusted,
      content: [%TextContent{text: String.duplicate("x", 10_000)}]
    }

    assert {:ok, [%ToolResultMessage{content: [%TextContent{text: text}]}]} =
             transform.([message], nil)

    assert byte_size(text) <= 1_024
    assert text =~ "...[content truncated]"
    assert marker_count(text, "<<<EXTERNAL_UNTRUSTED_CONTENT>>>") == 1
    assert marker_count(text, "<<<END_EXTERNAL_UNTRUSTED_CONTENT>>>") == 1
  end

  test "build_prompt_message preserves plain text without images" do
    message = State.build_prompt_message("hello")

    assert %LemonAi.Types.UserMessage{content: "hello", role: :user} = message
    assert is_integer(message.timestamp)
  end

  test "build_prompt_message expands multipart content when images are present" do
    image = %{data: "b64", mime_type: "image/png"}
    message = State.build_prompt_message("look", images: [image])

    assert %LemonAi.Types.UserMessage{
             content: [
               %LemonAi.Types.TextContent{text: "look"},
               %LemonAi.Types.ImageContent{data: "b64", mime_type: "image/png"}
             ]
           } = message
  end

  test "begin_prompt resets overflow recovery bookkeeping" do
    timer_ref = make_ref()

    state = %{
      is_streaming: false,
      pending_prompt_timer_ref: nil,
      turn_index: 4,
      overflow_recovery: %OverflowRecovery.State{
        in_progress: true,
        attempted: true,
        signature: :sig,
        started_at_ms: 12,
        error_reason: :boom,
        partial_state: %{foo: :bar}
      }
    }

    next_state = State.begin_prompt(state, timer_ref)

    assert next_state.is_streaming
    assert next_state.pending_prompt_timer_ref == timer_ref
    assert next_state.turn_index == 5
    assert next_state.overflow_recovery == %OverflowRecovery.State{}
  end

  test "reset_runtime invalidates all compaction task tracking" do
    state = %{
      session_manager: :old_manager,
      is_streaming: true,
      pending_prompt_timer_ref: make_ref(),
      turn_index: 4,
      started_at: 12,
      session_file: "/tmp/session.jsonl",
      steering_queue: :queue.from_list(["steer"]),
      follow_up_queue: :queue.from_list(["follow up"]),
      auto_compaction: %CompactionLifecycle.State{
        in_progress: true,
        signature: :auto_signature,
        task_pid: self(),
        task_monitor_ref: make_ref(),
        task_timeout_ref: make_ref()
      },
      overflow_recovery: %OverflowRecovery.State{
        in_progress: true,
        attempted: true,
        signature: :overflow_signature,
        task_pid: self(),
        task_monitor_ref: make_ref(),
        task_timeout_ref: make_ref(),
        started_at_ms: 13,
        error_reason: :boom,
        partial_state: %{private: :state}
      }
    }

    next_state = State.reset_runtime(state, :new_manager, 99)

    assert next_state.session_manager == :new_manager
    assert next_state.auto_compaction == %CompactionLifecycle.State{}
    assert next_state.overflow_recovery == %OverflowRecovery.State{}
  end

  defp marker_count(text, marker) do
    text |> String.split(marker) |> length() |> Kernel.-(1)
  end
end
