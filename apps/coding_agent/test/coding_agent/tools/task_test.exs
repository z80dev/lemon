defmodule CodingAgent.Tools.TaskTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ToolPolicy
  alias CodingAgent.Tools.Task
  alias CodingAgent.Tools.Task.Params

  describe "tool/2" do
    test "exposes only native task execution controls" do
      tool = Task.tool("/tmp")
      properties = tool.parameters["properties"]

      assert tool.name == "task"
      assert tool.label == "Run Task"
      assert tool.description =~ "focused native session"
      refute Map.has_key?(properties, "engine")
      assert Map.has_key?(properties, "model")
      assert Map.has_key?(properties, "thinking_level")
      assert Map.has_key?(properties, "role")
    end
  end

  describe "validate_run_params/2" do
    test "builds a native execution context" do
      assert {:ok, validated} =
               Params.validate_run_params(
                 %{"description" => "inspect files", "prompt" => "Inspect the files."},
                 "/tmp"
               )

      refute Map.has_key?(validated, :engine)
      assert validated.tool_policy.profile == :leaf_worker
      refute ToolPolicy.allowed?(validated.tool_policy, "task")
      refute ToolPolicy.allowed?(validated.tool_policy, "agent")
    end

    test "rejects the removed engine parameter" do
      assert {:error, "The 'engine' parameter has been removed; all subagent tasks run natively."} =
               Params.validate_run_params(
                 %{
                   "description" => "inspect files",
                   "prompt" => "Inspect the files.",
                   "engine" => "codex"
                 },
                 "/tmp"
               )
    end

    test "still permits an explicitly null historical engine field" do
      assert {:ok, validated} =
               Params.validate_run_params(
                 %{
                   "description" => "inspect files",
                   "prompt" => "Inspect the files.",
                   "engine" => nil
                 },
                 "/tmp"
               )

      refute Map.has_key?(validated, :engine)
    end
  end
end
