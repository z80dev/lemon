defmodule CodingAgent.Tools.TaskTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task
  alias AgentCore.AbortSignal
  alias AgentCore.CliRunners.Types.ResumeToken

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Task.tool("/tmp")

      assert tool.name == "task"
      assert tool.label == "Run Task"
      assert tool.description =~ "subtask"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == []
      assert is_function(tool.execute, 4)
    end

    test "includes all expected parameters" do
      tool = Task.tool("/tmp")
      props = tool.parameters["properties"]

      assert Map.has_key?(props, "action")
      assert Map.has_key?(props, "description")
      assert Map.has_key?(props, "prompt")
      assert Map.has_key?(props, "task_id")
      assert Map.has_key?(props, "engine")
      assert Map.has_key?(props, "model")
      assert Map.has_key?(props, "thinking_level")
      assert Map.has_key?(props, "role")
      assert Map.has_key?(props, "async")
      assert props["description"]["description"] =~ "3-5 words"
    end
  end

  describe "execute/6 - parameter validation" do
    test "returns error when description is missing" do
      result =
        Task.execute("call_1", %{"prompt" => "do something"}, nil, nil, "/tmp", [])

      assert {:error, "Description is required"} = result
    end

    test "returns error when description is empty" do
      result =
        Task.execute(
          "call_1",
          %{"description" => "   ", "prompt" => "do something"},
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Description must be a non-empty string"} = result
    end

    test "returns error when description is not a string" do
      result =
        Task.execute(
          "call_1",
          %{"description" => 123, "prompt" => "do something"},
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Description must be a non-empty string"} = result
    end

    test "returns error when prompt is empty" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => ""
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Prompt must be a non-empty string"} = result
    end

    test "returns error when prompt is missing" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task"
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Prompt is required"} = result
    end

    test "returns error when prompt is nil" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => nil
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Prompt must be a non-empty string"} = result
    end

    test "returns error when prompt is not a string" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => 123
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Prompt must be a non-empty string"} = result
    end

    test "returns error when role is not a string" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => "do something",
            "role" => 42
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Role must be a string"} = result
    end

    test "treats empty role as nil" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => "do something",
            "role" => "   ",
            "engine" => "unknown"
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Engine must be one of: internal, codex, claude, kimi, opencode, pi"} =
               result
    end

    test "returns error when engine is not a string" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => "do something",
            "engine" => 123
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Engine must be a string"} = result
    end

    test "returns error when engine is unknown" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => "do something",
            "engine" => "unknown"
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Engine must be one of: internal, codex, claude, kimi, opencode, pi"} =
               result
    end

    test "returns error when model is not a string" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => "do something",
            "model" => 123
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Model must be a string"} = result
    end

    test "returns error when thinking_level is not a string" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => "do something",
            "thinking_level" => 42
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "thinking_level must be a string"} = result
    end
  end

  describe "execute/6 - abort signal handling" do
    test "returns error when signal is aborted before execution" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test",
            "prompt" => "do something"
          },
          signal,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "execute/6 - unknown role" do
    test "returns error for unknown role" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test",
            "prompt" => "do something",
            "role" => "nonexistent_role_xyz"
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, msg} = result
      assert msg =~ "Unknown role" or msg =~ "Failed to start"
    end
  end

  describe "execute/6 - poll action" do
    test "returns error when task_id is missing" do
      result = Task.execute("call_1", %{"action" => "poll"}, nil, nil, "/tmp", [])
      assert {:error, "task_id is required for action=poll"} = result
    end
  end

  describe "tool options" do
    test "tool accepts model option" do
      tool = Task.tool("/tmp", model: "test-model")
      # Tool should be created without error
      assert tool.name == "task"
    end

    test "tool accepts thinking_level option" do
      tool = Task.tool("/tmp", thinking_level: :high)
      assert tool.name == "task"
    end

    test "tool accepts parent_session option" do
      tool = Task.tool("/tmp", parent_session: "parent-123")
      assert tool.name == "task"
    end
  end

  describe "reduce_cli_events/4" do
    test "captures error from completed opts and preserves resume token" do
      token = ResumeToken.new("codex", "thread_123")

      events = [
        {:started, token},
        {:completed, "answer", [error: "cli failed", resume: token]}
      ]

      result = Task.reduce_cli_events(events, "desc", "codex", nil)

      assert result.answer == "answer"
      assert result.resume_token == token
      assert result.error == "cli failed"
    end

    test "captures stderr warning action as error" do
      events = [
        {:action, %{title: "CLI stderr output", kind: :warning, detail: %{stderr: "oops"}},
         :completed, []},
        {:completed, "answer", []}
      ]

      result = Task.reduce_cli_events(events, "desc", "claude", nil)

      assert result.answer == "answer"
      assert result.error == "oops"
    end
  end
end
