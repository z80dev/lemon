defmodule LemonGateway.QueueModeTest do
  use ExUnit.Case, async: true

  alias LemonGateway.ExecutionRequest
  alias LemonGateway.Types.Job

  test "legacy Job no longer carries queue semantics" do
    refute Map.has_key?(Map.from_struct(%Job{}), :queue_mode)
  end

  test "ExecutionRequest remains the queue-semantic-free public gateway contract" do
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
end
