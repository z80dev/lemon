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

  @tag :tmp_dir
  test "task children gate writes in inherited contexts, including coordinator parent pids", %{
    tmp_dir: tmp_dir
  } do
    owner = self()
    policy = ToolPolicy.custom(deny: ["bash"], require_approval: ["write"])

    parent =
      start_supervised!(
        {CodingAgent.Session,
         [
           cwd: tmp_dir,
           model: LemonAgent.Test.Mocks.mock_model(),
           tools: [],
           invocation_context_key: "parent-client",
           invocation_mcp_servers: [],
           tool_policy: policy
         ]}
      )

    for {trusted_opts, expected_key} <- [
          {[
             approval_context: %{invocation_context_key: "tool-client"},
             tool_policy: policy,
             invocation_mcp_servers: []
           ], "tool-client"},
          {[
             invocation_context_key: "direct-client",
             tool_policy: policy,
             invocation_mcp_servers: []
           ], "direct-client"},
          {[parent_session: parent], "parent-client"},
          {[tool_policy: policy, invocation_mcp_servers: []], nil}
        ] do
      validated = %{
        tool_policy: ToolPolicy.custom(approvals: %{"write" => :never}),
        invocation_context_key: "forged-validated-client",
        agent_id: "child-writer"
      }

      opts =
        Params.build_session_opts(
          tmp_dir,
          Keyword.merge(
            [model: LemonAgent.Test.Mocks.mock_model(), child_run_id: "child-run"],
            trusted_opts
          ),
          validated
        )
        |> Keyword.put(:approval_context, %{
          approval_request_fun: fn request ->
            send(owner, {:child_approval, request})
            {:ok, :denied}
          end
        })

      {:ok, child} = CodingAgent.Session.start_link(opts)

      try do
        write = Enum.find(CodingAgent.Session.get_state(child).tools, &(&1.name == "write"))
        refute Enum.any?(CodingAgent.Session.get_state(child).tools, &(&1.name == "bash"))
        assert CodingAgent.Session.get_state(child).approval_context.invocation_mcp_servers == []
        path = Path.join(tmp_dir, "denied-#{expected_key || "legacy"}.txt")

        result =
          write.execute.(
            "child-write",
            %{
              "path" => path,
              "content" => "MUST NOT WRITE",
              "invocation_context_key" => "forged"
            },
            nil,
            nil
          )

        assert result.is_error
        assert_receive {:child_approval, request}
        assert request.invocation_context_key == expected_key
        assert request.agent_id == "child-writer"
        refute File.exists?(path)
      after
        GenServer.stop(child)
      end
    end
  end

  @tag :tmp_dir
  test "an empty parent allow list cannot be widened by a full-access child", %{tmp_dir: tmp_dir} do
    opts =
      Params.build_session_opts(
        tmp_dir,
        [
          model: LemonAgent.Test.Mocks.mock_model(),
          tool_policy: ToolPolicy.custom(allow: [])
        ],
        %{tool_policy: ToolPolicy.from_profile(:full_access)}
      )

    assert {:error, :not_found} = CodingAgent.ToolRegistry.get_tool(tmp_dir, "write", opts)
    assert {:error, :not_found} = CodingAgent.ToolRegistry.get_tool(tmp_dir, "bash", opts)
    assert {:error, :not_found} = CodingAgent.ToolRegistry.get_tool(tmp_dir, "read", opts)
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

  defp wait_until(fun, attempts \\ 1000)
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
