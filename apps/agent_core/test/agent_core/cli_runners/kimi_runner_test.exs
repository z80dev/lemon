defmodule AgentCore.CliRunners.KimiRunnerTest do
  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.KimiRunner
  alias AgentCore.CliRunners.KimiRunner.RunnerState
  alias AgentCore.CliRunners.KimiSchema

  alias AgentCore.CliRunners.KimiSchema.{
    ErrorMessage,
    Message,
    StreamMessage,
    ToolCall,
    ToolFunction
  }

  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  setup do
    Application.delete_env(:agent_core, :kimi)
    :ok
  end

  describe "engine/0" do
    test "returns kimi" do
      assert KimiRunner.engine() == "kimi"
    end
  end

  describe "resume token formatting" do
    test "formats kimi resume command" do
      token = ResumeToken.new("kimi", "session_999")
      assert ResumeToken.format(token) == "`kimi --session session_999`"
    end
  end

  describe "build_command/3" do
    test "builds command for new session" do
      state = RunnerState.new(nil)
      {cmd, args} = KimiRunner.build_command("Hello", nil, state)

      assert cmd == "kimi"
      assert "--print" in args
      assert "--output-format" in args
      assert "stream-json" in args
      assert "-p" in args
      assert "Hello" in args
      refute "--session" in args
    end

    test "builds command for resumed session" do
      state = RunnerState.new(nil)
      token = ResumeToken.new("kimi", "session_123")
      {cmd, args} = KimiRunner.build_command("Continue", token, state)

      assert cmd == "kimi"
      assert "--session" in args
      assert "session_123" in args
    end

    test "adds extra args from config" do
      config = %LemonCore.Config{agent: %{cli: %{kimi: %{extra_args: ["--foo", "--bar"]}}}}
      state = RunnerState.new(nil, nil, config)
      {_cmd, args} = KimiRunner.build_command("Hello", nil, state)

      assert "--foo" in args
      assert "--bar" in args
    end

    test "adds config file flag when config exists and not provided" do
      config = Path.expand("~/.kimi/config.toml")

      if File.exists?(config) do
        state = RunnerState.new(nil)
        {_cmd, args} = KimiRunner.build_command("Hello", nil, state)

        assert "--config-file" in args
        assert config in args
      else
        assert true
      end
    end
  end

  describe "stdin_payload/3" do
    test "returns nil (Kimi uses CLI args for prompt)" do
      state = RunnerState.new(nil)
      assert KimiRunner.stdin_payload("Hello", nil, state) == nil
    end
  end

  describe "env/1" do
    test "ensures HOME is present" do
      env = KimiRunner.env(RunnerState.new(nil)) |> Map.new()
      assert is_binary(env["HOME"])
      assert env["HOME"] != ""
    end
  end

  describe "init_state/2" do
    test "creates state with resume token" do
      token = ResumeToken.new("kimi", "session_abc")
      state = KimiRunner.init_state("prompt", token)

      assert %RunnerState{} = state
      assert state.resume_token == token
      assert state.found_session == token
      assert state.pending_actions == %{}
    end
  end

  describe "decode_line/1" do
    test "decodes assistant message line" do
      json = ~s|{"role":"assistant","content":"Hello"}|

      assert {:ok, %StreamMessage{message: %Message{role: "assistant"}}} =
               KimiSchema.decode_event(json)
    end

    test "decodes tool message line" do
      json = ~s|{"role":"tool","tool_call_id":"call_1","content":"ok"}|

      assert {:ok, %StreamMessage{message: %Message{role: "tool", tool_call_id: "call_1"}}} =
               KimiSchema.decode_event(json)
    end

    test "decodes error line" do
      json = ~s|{"error":"failed"}|
      assert {:ok, %ErrorMessage{error: "failed"}} = KimiSchema.decode_event(json)
    end
  end

  describe "translate_event/2" do
    test "emits started event when resume token present" do
      token = ResumeToken.new("kimi", "session_123")
      state = RunnerState.new(token)

      msg = %StreamMessage{message: %Message{role: "assistant", content: "Hi"}}
      {[started], new_state, _opts} = KimiRunner.translate_event(msg, state)

      assert %StartedEvent{resume: ^token} = started
      assert new_state.started_emitted == true
    end

    test "accumulates assistant content" do
      state = RunnerState.new(nil)
      msg = %StreamMessage{message: %Message{role: "assistant", content: "Hello"}}
      {events, new_state, _opts} = KimiRunner.translate_event(msg, state)

      assert events == []
      assert new_state.last_assistant_text == "Hello"
    end

    test "starts tool action from tool_calls" do
      state = RunnerState.new(nil)

      tool_call = %ToolCall{
        id: "call_1",
        type: "function",
        function: %ToolFunction{name: "bash", arguments: ~s|{"command":"ls"}|}
      }

      msg = %StreamMessage{
        message: %Message{role: "assistant", tool_calls: [tool_call]}
      }

      {[action_event], new_state, _opts} = KimiRunner.translate_event(msg, state)

      assert %ActionEvent{phase: :started, action: %{id: "call_1", kind: :command}} = action_event
      assert Map.has_key?(new_state.pending_actions, "call_1")
    end

    test "completes tool action from tool result" do
      state = RunnerState.new(nil)

      tool_call = %ToolCall{
        id: "call_1",
        type: "function",
        function: %ToolFunction{name: "read", arguments: ~s|{"path":"README.md"}|}
      }

      msg = %StreamMessage{message: %Message{role: "assistant", tool_calls: [tool_call]}}
      {_events, state, _opts} = KimiRunner.translate_event(msg, state)

      tool_msg = %StreamMessage{
        message: %Message{role: "tool", tool_call_id: "call_1", content: "ok"}
      }

      {[action_event], new_state, _opts} = KimiRunner.translate_event(tool_msg, state)
      assert %ActionEvent{phase: :completed, action: %{id: "call_1"}} = action_event
      refute Map.has_key?(new_state.pending_actions, "call_1")
    end

    test "translates error event to completed error" do
      state = RunnerState.new(nil)

      {[completed], _state, _opts} =
        KimiRunner.translate_event(%ErrorMessage{error: "boom"}, state)

      assert %CompletedEvent{ok: false, error: "boom"} = completed
    end
  end

  describe "handle_exit_error/2" do
    test "emits note and completed error" do
      state = RunnerState.new(nil)
      {events, _state} = KimiRunner.handle_exit_error(1, state)

      assert length(events) == 2
      assert Enum.any?(events, &match?(%CompletedEvent{ok: false}, &1))
    end
  end

  describe "handle_stream_end/1" do
    test "emits completed ok when answer exists" do
      state = %RunnerState{RunnerState.new(nil) | last_assistant_text: "done"}
      {[completed], _state} = KimiRunner.handle_stream_end(state)

      assert %CompletedEvent{ok: true, answer: "done"} = completed
    end

    test "emits completed error when no output" do
      state = RunnerState.new(nil)
      {[completed], _state} = KimiRunner.handle_stream_end(state)

      assert %CompletedEvent{ok: false} = completed
    end
  end
end
