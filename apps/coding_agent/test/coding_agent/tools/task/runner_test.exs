defmodule CodingAgent.Tools.Task.RunnerTest do
  use ExUnit.Case, async: false

  alias AgentCore.Test.Mocks
  alias CodingAgent.Tools.Task.Runner

  test "times out hung child sessions instead of waiting forever" do
    tmp_dir = Path.join(System.tmp_dir!(), "task-runner-timeout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    stream_fn = fn _model, _context, _options ->
      {:ok, ai_stream} = Ai.EventStream.start_link(timeout: :infinity)
      {:ok, ai_stream}
    end

    assert {:error, reason} =
             Runner.start_session_with_prompt(
               [
                 cwd: tmp_dir,
                 model: Mocks.mock_model(),
                 tools: [],
                 stream_fn: stream_fn
               ],
               "Say hello.",
               "Hung session",
               nil,
               nil,
               nil,
               "internal",
               task_session_timeout_ms: 100,
               task_session_poll_ms: 10
             )

    assert reason == "Task session timed out after 100ms waiting for completion"
  end
end
