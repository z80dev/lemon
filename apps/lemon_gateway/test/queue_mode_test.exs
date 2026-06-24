defmodule LemonGateway.QueueModeTest do
  use ExUnit.Case, async: true

  alias LemonGateway.ExecutionRequest
  alias LemonGateway.Types.Job

  test "legacy Job no longer carries queue semantics" do
    refute Map.has_key?(Map.from_struct(%Job{}), :queue_mode)
  end

  test "ExecutionRequest remains the queue-semantic-free gateway-private adapter" do
    job = %Job{
      run_id: "run_1",
      session_key: "agent:test:main",
      prompt: "hello",
      engine_id: "codex"
    }

    request = ExecutionRequest.from_job(job)

    assert request.run_id == "run_1"
    assert request.session_key == "agent:test:main"
    assert request.prompt == "hello"
    assert request.engine_id == "codex"
    refute Map.has_key?(Map.from_struct(request), :queue_mode)
  end

  test "Scheduler.submit_execution/1 requires router-owned conversation_key" do
    request = %ExecutionRequest{
      run_id: "run_missing_conversation",
      session_key: "agent:test:main",
      prompt: "hello",
      engine_id: "codex"
    }

    assert_raise ArgumentError,
                 ~r/missing router-owned conversation_key/,
                 fn -> LemonGateway.Scheduler.submit_execution(request) end
  end

  test "Runtime.submit_execution/1 accepts only core execution commands" do
    request = %ExecutionRequest{
      run_id: "run_private_request",
      session_key: "agent:test:main",
      prompt: "hello",
      engine_id: "codex",
      conversation_key: {:session, "agent:test:main"}
    }

    assert_raise FunctionClauseError, fn ->
      apply(LemonGateway.Runtime, :submit_execution, [request])
    end
  end
end
