defmodule CodingAgent.Tools.AwaitTest do
  @moduledoc """
  Tests for the Await tool.
  """

  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias CodingAgent.Tools.Await
  alias CodingAgent.ProcessStore

  setup do
    # Clear process store before each test
    ProcessStore.clear()
    :ok
  end

  describe "tool/1" do
    test "returns correct tool definition" do
      tool = Await.tool("/tmp")

      assert tool.name == "await"
      assert is_binary(tool.description)
      assert tool.parameters["type"] == "object"
      assert "job_ids" in Map.keys(tool.parameters["properties"])
      assert "timeout" in Map.keys(tool.parameters["properties"])
      assert is_function(tool.execute, 4)
    end

    test "job_ids parameter is optional array" do
      tool = Await.tool("/tmp")
      job_ids_schema = tool.parameters["properties"]["job_ids"]

      assert job_ids_schema["type"] == "array"
      assert job_ids_schema["items"]["type"] == "string"
      refute "job_ids" in tool.parameters["required"]
    end

    test "timeout parameter is optional integer" do
      tool = Await.tool("/tmp")
      timeout_schema = tool.parameters["properties"]["timeout"]

      assert timeout_schema["type"] == "integer"
      refute "timeout" in tool.parameters["required"]
    end
  end

  describe "execute/6 with no jobs" do
    test "returns no jobs result when no job_ids specified and no active jobs" do
      result = Await.execute("call_1", %{}, nil, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "No jobs to watch"
      assert result.details.status == :no_jobs
    end

    test "returns no jobs result when specified job_ids don't exist" do
      result = Await.execute("call_1", %{"job_ids" => ["nonexistent"]}, nil, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "No jobs to watch"
    end
  end

  describe "execute/6 with completed jobs" do
    test "returns immediately when job is already completed" do
      # Create a completed process
      process_id = ProcessStore.new_process(%{
        command: "echo test",
        status: :completed,
        exit_code: 0
      })

      result = Await.execute("call_1", %{"job_ids" => [process_id]}, nil, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "1 of 1 job(s) finished"
      assert text =~ process_id
      assert text =~ "COMPLETED"
      assert result.details.status == :completed
    end

    test "returns immediately when job has error status" do
      process_id = ProcessStore.new_process(%{
        command: "false",
        status: :error,
        error: "Command failed"
      })

      result = Await.execute("call_1", %{"job_ids" => [process_id]}, nil, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "1 of 1 job(s) finished"
      assert text =~ "ERROR"
    end

    test "returns immediately when job is killed" do
      process_id = ProcessStore.new_process(%{
        command: "sleep 100",
        status: :killed
      })

      result = Await.execute("call_1", %{"job_ids" => [process_id]}, nil, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "1 of 1 job(s) finished"
      assert text =~ "KILLED"
    end

    test "returns results for multiple jobs when at least one completes" do
      id1 = ProcessStore.new_process(%{command: "echo 1", status: :running})
      id2 = ProcessStore.new_process(%{command: "echo 2", status: :completed, exit_code: 0})

      result = Await.execute("call_1", %{"job_ids" => [id1, id2]}, nil, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "1 of 2 job(s) finished"
      assert text =~ id1
      assert text =~ id2
    end
  end

  describe "execute/6 with timeout" do
    test "returns timeout when no jobs complete within timeout" do
      # Create a running process that won't complete
      process_id = ProcessStore.new_process(%{
        command: "sleep 1000",
        status: :running
      })

      # Poll with 0 second timeout
      result = Await.execute(
        "call_1",
        %{"job_ids" => [process_id], "timeout" => 0},
        nil,
        nil,
        "/tmp",
        []
      )

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "Timeout"
      assert text =~ process_id
      assert text =~ "RUNNING"
      assert result.details.status == :timeout
    end
  end

  describe "execute/6 with abort signal" do
    test "returns aborted when signal is aborted" do
      process_id = ProcessStore.new_process(%{
        command: "sleep 100",
        status: :running
      })

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = Await.execute("call_1", %{"job_ids" => [process_id]}, signal, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "Polling aborted"
      assert result.details.status == :aborted
    end
  end

  describe "execute/6 watching all jobs" do
    test "watches all jobs when job_ids is empty list" do
      # Create multiple processes
      id1 = ProcessStore.new_process(%{command: "echo 1", status: :running})
      id2 = ProcessStore.new_process(%{command: "echo 2", status: :completed, exit_code: 0})

      result = Await.execute("call_1", %{"job_ids" => []}, nil, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      assert text =~ "1 of 2 job(s) finished"
      assert text =~ id1
      assert text =~ id2
    end
  end

  describe "result details" do
    test "includes job details in result" do
      process_id = ProcessStore.new_process(%{
        command: "echo test",
        status: :completed,
        exit_code: 0
      })

      result = Await.execute("call_1", %{"job_ids" => [process_id]}, nil, nil, "/tmp", [])

      assert is_list(result.details.jobs)
      assert length(result.details.jobs) == 1

      job = hd(result.details.jobs)
      assert job.id == process_id
      assert job.status == :completed
      assert job.exit_code == 0
      assert job.command == "echo test"
    end
  end

  describe "command truncation" do
    test "truncates long commands in output" do
      long_command = String.duplicate("a", 100)

      process_id = ProcessStore.new_process(%{
        command: long_command,
        status: :completed
      })

      result = Await.execute("call_1", %{"job_ids" => [process_id]}, nil, nil, "/tmp", [])

      assert %AgentToolResult{content: [%{text: text}]} = result
      # Should show truncated command with ...
      assert text =~ "..."
      refute text =~ String.duplicate("a", 100)
    end
  end
end
