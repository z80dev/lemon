defmodule CodingAgent.Tools.TaskTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task
  alias AgentCore.AbortSignal

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Task.tool("/tmp")

      assert tool.name == "task"
      assert tool.label == "Run Task"
      assert tool.description =~ "subtask"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["description", "prompt"]
      assert is_function(tool.execute, 4)
    end

    test "includes all expected parameters" do
      tool = Task.tool("/tmp")
      props = tool.parameters["properties"]

      assert Map.has_key?(props, "description")
      assert Map.has_key?(props, "prompt")
      assert Map.has_key?(props, "subagent")
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

    test "returns error when subagent is not a string" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Test task",
            "prompt" => "do something",
            "subagent" => 42
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Subagent must be a string"} = result
    end
  end

  describe "execute/6 - abort signal handling" do
    test "returns error when signal is aborted before execution" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = Task.execute("call_1", %{
        "description" => "Test",
        "prompt" => "do something"
      }, signal, nil, "/tmp", [])

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "execute/6 - unknown subagent" do
    test "returns error for unknown subagent" do
      result = Task.execute("call_1", %{
        "description" => "Test",
        "prompt" => "do something",
        "subagent" => "nonexistent_subagent_xyz"
      }, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "Unknown subagent" or msg =~ "Failed to start"
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
end
