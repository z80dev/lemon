defmodule CodingAgent.Tools.TaskTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{RunGraph, TaskStore, ToolPolicy}
  alias CodingAgent.Tools.Task
  alias CodingAgent.Tools.Task.Params
  alias LemonAgent.AbortSignal

  setup do
    TaskStore.clear()
    RunGraph.clear()
    :ok
  end

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

  describe "join followup suppression" do
    test "wait_any suppresses only the completed winner" do
      {task_a, run_a} = running_task("a")
      {task_b, _run_b} = running_task("b")

      joiner =
        Elixir.Task.async(fn ->
          Task.execute(
            "join_any",
            %{"action" => "join", "task_ids" => [task_a, task_b], "mode" => "wait_any"},
            nil,
            nil,
            "/tmp",
            []
          )
        end)

      wait_until(fn ->
        TaskStore.auto_followup_suppressed?(task_a) and
          TaskStore.auto_followup_suppressed?(task_b)
      end)

      RunGraph.finish(run_a, "done")

      assert %LemonAgent.Types.AgentToolResult{details: %{mode: "wait_any"}} =
               Elixir.Task.await(joiner, 1_000)

      assert TaskStore.auto_followup_suppressed?(task_a)
      refute TaskStore.auto_followup_suppressed?(task_b)
    end

    test "aborted and failed joins leave no permanent suppression" do
      {aborted_task, _run_id} = running_task("abort")
      signal = AbortSignal.new()

      joiner =
        Elixir.Task.async(fn ->
          Task.execute(
            "join_abort",
            %{"action" => "join", "task_id" => aborted_task},
            signal,
            nil,
            "/tmp",
            []
          )
        end)

      wait_until(fn -> TaskStore.auto_followup_suppressed?(aborted_task) end)
      AbortSignal.abort(signal)
      assert {:error, "Operation aborted"} = Elixir.Task.await(joiner, 1_000)
      refute TaskStore.auto_followup_suppressed?(aborted_task)

      {failed_task, failed_run} = running_task("failed")

      failed_joiner =
        Elixir.Task.async(fn ->
          Task.execute(
            "join_failed",
            %{"action" => "join", "task_id" => failed_task},
            nil,
            nil,
            "/tmp",
            []
          )
        end)

      wait_until(fn -> TaskStore.auto_followup_suppressed?(failed_task) end)
      RunGraph.fail(failed_run, :boom)
      assert %LemonAgent.Types.AgentToolResult{} = Elixir.Task.await(failed_joiner, 1_000)
      refute TaskStore.auto_followup_suppressed?(failed_task)
    end
  end

  defp running_task(label) do
    run_id = RunGraph.new_run(%{status: :running, description: label})
    task_id = TaskStore.new_task(%{status: :running, run_id: run_id, description: label})
    {task_id, run_id}
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
