defmodule CodingAgent.SessionForkTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SessionFork
  alias CodingAgent.RateLimitRecovery

  describe "build_fork_system_prompt/2" do
    test "includes original prompt and fork context" do
      original_state = %{
        system_prompt: "You are a helpful assistant."
      }

      summary = "Discussion about API design"

      prompt = SessionFork.build_fork_system_prompt(original_state, summary)

      assert prompt =~ "You are a helpful assistant"
      assert prompt =~ "SESSION FORK CONTEXT"
      assert prompt =~ "Discussion about API design"
    end

    test "handles missing original prompt" do
      original_state = %{}
      summary = "Summary"

      prompt = SessionFork.build_fork_system_prompt(original_state, summary)

      assert prompt =~ "SESSION FORK CONTEXT"
    end
  end

  describe "build_fork_message/3" do
    test "includes reason and summary" do
      reason = :rate_limit_recovery
      summary = "Discussion about auth"
      context = %{todos: [], plans: []}

      message = SessionFork.build_fork_message(reason, summary, context)

      assert message =~ "Session forked"
      assert message =~ "rate limiting"
    end
  end

  describe "emit_fork_telemetry/3" do
    test "emits telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-fork-handler",
        [:coding_agent, :session_fork, :fork_completed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_received, metadata})
        end,
        nil
      )

      SessionFork.emit_fork_telemetry(:fork_completed, "session-123", %{
        new_session_id: "session-456"
      })

      assert_receive {:telemetry_received, metadata}
      assert metadata.original_session_id == "session-123"
      assert metadata.new_session_id == "session-456"

      :telemetry.detach("test-fork-handler")
    end
  end

  describe "generate_default_summary/1" do
    test "includes message count info" do
      context = %{
        messages: [%{role: "user"}, %{role: "assistant"}],
        todos: []
      }

      summary = SessionFork.generate_default_summary(context)

      assert summary =~ "2 messages"
    end

    test "includes todo count when present" do
      context = %{
        messages: [%{role: "user"}],
        todos: [%{id: 1}, %{id: 2}]
      }

      summary = SessionFork.generate_default_summary(context)

      assert summary =~ "2 outstanding todo"
    end

    test "handles empty context" do
      context = %{messages: [], todos: []}

      summary = SessionFork.generate_default_summary(context)

      assert summary =~ "No recent messages"
    end
  end

  describe "integration with RateLimitRecovery" do
    test "prepare_fork_context is used correctly" do
      state = %{
        session_id: "test-123",
        messages: [%{role: "user", content: "Hello"}],
        todos: [%{id: 1, content: "Task 1"}]
      }

      context = RateLimitRecovery.prepare_fork_context(state, preserve_message_count: 5)

      assert context.metadata.forked_from == "test-123"
      assert length(context.messages) == 1
      assert length(context.todos) == 1
    end
  end
end
