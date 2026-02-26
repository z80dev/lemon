defmodule AgentCore.CliRunners.PiRunnerTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.PiRunner
  alias AgentCore.CliRunners.PiRunner.RunnerState

  alias AgentCore.CliRunners.PiSchema.{
    AgentEnd,
    MessageEnd,
    SessionHeader,
    ToolExecutionEnd,
    ToolExecutionStart
  }

  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  describe "engine/0" do
    test "returns pi" do
      assert PiRunner.engine() == "pi"
    end
  end

  describe "build_command/3" do
    test "builds command and always includes --session" do
      token = ResumeToken.new("pi", "s1")
      state = RunnerState.new(token)
      {cmd, args} = PiRunner.build_command("Hello", token, state)

      assert cmd == "pi"
      assert "--print" in args
      assert "--mode" in args
      assert "json" in args
      assert "--session" in args
      assert "s1" in args
      assert List.last(args) == "Hello"
    end

    test "adds provider/model/extra_args from config when present" do
      cfg = %LemonCore.Config{
        agent: %{cli: %{pi: %{extra_args: ["--foo"], provider: "openai", model: "gpt-4.1"}}}
      }

      token = ResumeToken.new("pi", "s1")
      state = RunnerState.new(token, "/tmp", cfg)

      {_cmd, args} = PiRunner.build_command("Hello", token, state)
      assert "--foo" in args
      assert "--provider" in args
      assert "openai" in args
      assert "--model" in args
      assert "gpt-4.1" in args
    end
  end

  describe "translate_event/2" do
    test "emits started event (and may promote id on session header)" do
      token = ResumeToken.new("pi", "/tmp/sessions/s1.jsonl")
      state = RunnerState.new(token)

      {[started], _state, _opts} =
        PiRunner.translate_event(%SessionHeader{id: "abcd-1234"}, state)

      assert %StartedEvent{resume: %{engine: "pi"}} = started
    end

    test "translates tool execution lifecycle" do
      token = ResumeToken.new("pi", "s1")
      state = RunnerState.new(token)
      {_, state, _} = PiRunner.translate_event(%SessionHeader{id: nil}, state)

      start = %ToolExecutionStart{toolCallId: "t1", toolName: "bash", args: %{"command" => "ls"}}
      {[ev1], state, _} = PiRunner.translate_event(start, state)
      assert %ActionEvent{phase: :started, action: %{id: "t1"}} = ev1

      done = %ToolExecutionEnd{toolCallId: "t1", toolName: "bash", result: "ok", isError: false}
      {[ev2], state, _} = PiRunner.translate_event(done, state)
      assert %ActionEvent{phase: :completed, ok: true, action: %{id: "t1"}} = ev2
      refute Map.has_key?(state.pending_actions, "t1")
    end

    test "captures assistant message and completes on agent_end" do
      token = ResumeToken.new("pi", "s1")
      state = RunnerState.new(token)
      {_, state, _} = PiRunner.translate_event(%SessionHeader{id: nil}, state)

      msg = %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      }

      {_, state, _} = PiRunner.translate_event(%MessageEnd{message: msg}, state)

      agent_end = %AgentEnd{messages: [msg]}
      {events, _state, _opts} = PiRunner.translate_event(agent_end, state)

      assert Enum.any?(events, fn
               %CompletedEvent{ok: true, answer: "Hello", usage: usage} when is_map(usage) -> true
               _ -> false
             end)
    end

    test "completes with error when assistant stopReason is error" do
      token = ResumeToken.new("pi", "s1")
      state = RunnerState.new(token)
      {_, state, _} = PiRunner.translate_event(%SessionHeader{id: nil}, state)

      msg = %{
        "role" => "assistant",
        "stopReason" => "error",
        "errorMessage" => "boom",
        "content" => [%{"type" => "text", "text" => "partial"}]
      }

      {_, state, _} = PiRunner.translate_event(%MessageEnd{message: msg}, state)
      agent_end = %AgentEnd{messages: [msg]}
      {events, _state, _opts} = PiRunner.translate_event(agent_end, state)

      assert Enum.any?(
               events,
               &match?(%CompletedEvent{ok: false, error: "boom", answer: "partial"}, &1)
             )
    end
  end
end
