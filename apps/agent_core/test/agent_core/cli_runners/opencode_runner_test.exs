defmodule AgentCore.CliRunners.OpencodeRunnerTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.OpencodeRunner
  alias AgentCore.CliRunners.OpencodeRunner.RunnerState

  alias AgentCore.CliRunners.OpencodeSchema.{StepFinish, StepStart, Text, ToolUse}

  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  describe "engine/0" do
    test "returns opencode" do
      assert OpencodeRunner.engine() == "opencode"
    end
  end

  describe "build_command/3" do
    test "builds command for new session" do
      state = RunnerState.new(nil)
      {cmd, args} = OpencodeRunner.build_command("Hello", nil, state)

      assert cmd == "opencode"
      assert args == ["run", "--format", "json", "--", "Hello"]
    end

    test "builds command for resumed session" do
      token = ResumeToken.new("opencode", "ses_123")
      state = RunnerState.new(token)
      {cmd, args} = OpencodeRunner.build_command("Continue", token, state)

      assert cmd == "opencode"
      assert "--session" in args
      assert "ses_123" in args
    end

    test "adds model from config when present" do
      cfg = %LemonCore.Config{agent: %{cli: %{opencode: %{model: "gpt-4.1"}}}}
      state = RunnerState.new(nil, nil, cfg)
      {_cmd, args} = OpencodeRunner.build_command("Hello", nil, state)

      assert "--model" in args
      assert "gpt-4.1" in args
    end
  end

  describe "translate_event/2" do
    test "emits started event on step_start when sessionID is present" do
      state = RunnerState.new(nil)

      {[started], state, _opts} =
        OpencodeRunner.translate_event(%StepStart{sessionID: "ses_abc"}, state)

      assert %StartedEvent{resume: %ResumeToken{engine: "opencode", value: "ses_abc"}} = started
      assert state.started_emitted == true
    end

    test "starts and completes a tool_use action" do
      state = RunnerState.new(nil)

      # Establish session (so StartedEvent is emitted and resume is set).
      {_, state, _} = OpencodeRunner.translate_event(%StepStart{sessionID: "ses_abc"}, state)

      tool_started =
        %ToolUse{
          sessionID: "ses_abc",
          part: %{
            "callID" => "call_1",
            "tool" => "bash",
            "state" => %{"input" => %{"command" => "ls -la"}}
          }
        }

      {[action1], state, _opts} = OpencodeRunner.translate_event(tool_started, state)
      assert %ActionEvent{phase: :started, action: %{id: "call_1", kind: :command}} = action1
      assert Map.has_key?(state.pending_actions, "call_1")

      tool_completed =
        %ToolUse{
          sessionID: "ses_abc",
          part: %{
            "callID" => "call_1",
            "tool" => "bash",
            "state" => %{
              "status" => "completed",
              "input" => %{"command" => "ls -la"},
              "output" => "ok",
              "metadata" => %{"exit" => 0}
            }
          }
        }

      {[action2], state, _opts} = OpencodeRunner.translate_event(tool_completed, state)
      assert %ActionEvent{phase: :completed, ok: true, action: %{id: "call_1"}} = action2
      refute Map.has_key?(state.pending_actions, "call_1")
    end

    test "accumulates text and completes on step_finish reason stop" do
      state = RunnerState.new(nil)
      {_, state, _} = OpencodeRunner.translate_event(%StepStart{sessionID: "ses_abc"}, state)

      {_, state, _} =
        OpencodeRunner.translate_event(
          %Text{sessionID: "ses_abc", part: %{"text" => "Hello"}},
          state
        )

      {_, state, _} =
        OpencodeRunner.translate_event(
          %Text{sessionID: "ses_abc", part: %{"text" => " world"}},
          state
        )

      finish = %StepFinish{sessionID: "ses_abc", part: %{"reason" => "stop"}}
      {events, _state, _opts} = OpencodeRunner.translate_event(finish, state)

      assert Enum.any?(events, &match?(%CompletedEvent{ok: true, answer: "Hello world"}, &1))
    end
  end
end
