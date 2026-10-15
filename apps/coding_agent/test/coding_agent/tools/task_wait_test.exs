defmodule CodingAgent.Tools.Task.WaitTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ParentQuestions, RunGraph, TaskStore}
  alias CodingAgent.Tools.Task.{Control, Wait}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  @opts [session_id: "wait-parent", agent_id: "parent-agent"]
  @no_tasks "No outstanding or unobserved native child tasks owned by this session"

  setup do
    TaskStore.clear()
    RunGraph.clear()
    ParentQuestions.clear()

    on_exit(fn ->
      ParentQuestions.clear()
      TaskStore.clear()
      RunGraph.clear()
    end)

    :ok
  end

  test "first of three finishing returns while siblings continue and only suppresses its winner" do
    {first_id, first_run} = running_task("first")
    {winner_id, winner_run} = running_task("winner")
    {last_id, last_run} = running_task("last")
    ids = [first_id, winner_id, last_id]

    waiter = Task.async(fn -> Wait.execute(%{"task_ids" => ids}, nil, @opts) end)
    wait_until(fn -> Enum.all?(ids, &TaskStore.auto_followup_suppressed?/1) end)

    finish_task(winner_id, winner_run, "first answer")

    assert %AgentToolResult{details: %{mode: "wait_any", tasks: [winner]}} =
             Task.await(waiter, 1_000)

    assert winner.task_id == winner_id
    assert winner.output == "first answer"
    assert winner.status == "completed"
    assert observed?(winner_id)
    assert TaskStore.auto_followup_suppressed?(winner_id)

    for {task_id, run_id} <- [{first_id, first_run}, {last_id, last_run}] do
      assert {:ok, %{status: :running}, _} = TaskStore.get(task_id)
      assert {:ok, %{status: :running}} = RunGraph.get(run_id)
      refute observed?(task_id)
      refute TaskStore.auto_followup_suppressed?(task_id)
    end

    finish_task(first_id, first_run, "second answer")

    assert %AgentToolResult{details: %{tasks: [%{task_id: ^first_id}]}} =
             Wait.execute(%{}, nil, @opts)

    finish_task(last_id, last_run, "third answer")

    assert %AgentToolResult{details: %{tasks: [%{task_id: ^last_id}]}} =
             Wait.execute(%{}, nil, @opts)

    assert {:error, @no_tasks} = Wait.execute(%{}, nil, @opts)
  end

  test "implicit waits consume each already completed child once and explicit IDs revisit it" do
    tasks = Enum.map(1..3, &running_task("precompleted #{&1}"))
    Enum.each(tasks, fn {id, run} -> finish_task(id, run, "ready") end)
    ids = Enum.map(tasks, &elem(&1, 0))

    returned =
      Enum.map(1..3, fn _ ->
        assert %AgentToolResult{details: %{tasks: [%{task_id: id, output: "ready"}]}} =
                 Wait.execute(%{}, nil, @opts)

        assert observed?(id)
        id
      end)

    assert Enum.sort(returned) == Enum.sort(ids)
    assert {:error, @no_tasks} = Wait.execute(%{}, nil, @opts)

    id = hd(returned)

    assert %AgentToolResult{details: %{tasks: [%{task_id: ^id}]}} =
             Wait.execute(%{"task_ids" => [id]}, nil, @opts)

    assert {:error, @no_tasks} = Wait.execute(%{}, nil, @opts)
  end

  test "failed and cancelled child results are returned and consumed, not swallowed" do
    {failed_id, failed_run} = running_task("failed")
    {cancelled_id, cancelled_run} = running_task("cancelled")
    TaskStore.fail(failed_id, :child_failed)
    RunGraph.fail(failed_run, :child_failed)
    TaskStore.cancel(cancelled_id, :cancelled)
    RunGraph.fail(cancelled_run, :cancelled)

    results = for _ <- 1..2, do: Wait.execute(%{}, nil, @opts)
    rows = Enum.flat_map(results, & &1.details.tasks)

    assert Enum.any?(rows, &(&1.task_id == failed_id and &1.status == "error"))
    assert Enum.any?(rows, &(&1.task_id == cancelled_id and &1.status == "cancelled"))
    assert Enum.all?(rows, &(is_binary(&1.error) and &1.error != ""))
    assert observed?(failed_id)
    assert observed?(cancelled_id)
    refute TaskStore.auto_followup_suppressed?(failed_id)
    refute TaskStore.auto_followup_suppressed?(cancelled_id)
    assert {:error, @no_tasks} = Wait.execute(%{}, nil, @opts)
  end

  test "cross-session and cross-agent IDs are rejected before reserving any followups" do
    {owned_id, owned_run} = running_task("owned")
    finish_task(owned_id, owned_run, "done")

    foreign_opts = [
      [session_id: "other-session", agent_id: "parent-agent"],
      [session_id: "wait-parent", agent_id: "other-agent"]
    ]

    for opts <- foreign_opts do
      {foreign_id, _} = running_task("foreign", opts)

      assert {:error, "Unknown task_id: " <> ^foreign_id} =
               Wait.execute(%{"task_ids" => [owned_id, foreign_id]}, nil, @opts)

      refute observed?(owned_id)
      refute TaskStore.auto_followup_suppressed?(owned_id)
      refute TaskStore.auto_followup_suppressed?(foreign_id)
    end

    assert %AgentToolResult{details: %{tasks: [%{task_id: ^owned_id}]}} =
             Wait.execute(%{}, nil, @opts)

    assert {:error, @no_tasks} = Wait.execute(%{}, nil, @opts)
  end

  test "unknown IDs and malformed arrays do not consume a valid child's result" do
    {id, run} = running_task("owned")
    finish_task(id, run, "ready")

    assert {:error, "Unknown task_id: missing-task"} =
             Wait.execute(%{"task_ids" => [id, "missing-task"]}, nil, @opts)

    for invalid <- [nil, [], id, [id, ""], [id, "  "], [id, 42], %{}] do
      assert {:error, "task_ids must be a nonempty array of nonempty strings"} =
               Wait.execute(%{"task_ids" => invalid}, nil, @opts)
    end

    refute observed?(id)
    refute TaskStore.auto_followup_suppressed?(id)
  end

  test "no jobs errors immediately and delegated or unowned records are not native children" do
    waiter = Task.async(fn -> Wait.execute(%{}, nil, @opts) end)
    assert {:error, @no_tasks} = Task.await(waiter, 1_000)

    run = RunGraph.new_run(%{type: :agent, status: :running})

    delegated =
      TaskStore.new_task(%{kind: :agent, owner: Control.owner(@opts), run_id: run})

    TaskStore.new_task(%{run_id: run})
    {foreign, _} = running_task("foreign", session_id: "other", agent_id: "parent-agent")

    waiter = Task.async(fn -> Wait.execute(%{}, nil, @opts) end)
    assert {:error, @no_tasks} = Task.await(waiter, 1_000)

    assert {:error, "Unknown task_id: " <> ^delegated} =
             Wait.execute(%{"task_ids" => [delegated]}, nil, @opts)

    refute TaskStore.auto_followup_suppressed?(delegated)
    refute TaskStore.auto_followup_suppressed?(foreign)
  end

  test "safety cap yields a snapshot without cancelling, observing or suppressing children" do
    {id, run} = running_task("slow")
    result = Wait.execute(%{}, nil, Keyword.put(@opts, :wait_timeout_ms, 1))

    assert %AgentToolResult{
             details: %{
               timed_out: true,
               interrupted: false,
               tasks: [%{task_id: ^id, status: "running"}]
             }
           } = result

    refute observed?(id)
    refute TaskStore.auto_followup_suppressed?(id)
    assert {:ok, %{status: :running}} = RunGraph.get(run)
    finish_task(id, run, "after cap")

    assert %AgentToolResult{details: %{tasks: [%{task_id: ^id, output: "after cap"}]}} =
             Wait.execute(%{}, nil, @opts)
  end

  @tag :tmp_dir
  test "steering interrupts wait without consuming the peer message", %{tmp_dir: cwd} do
    session =
      start_supervised!(
        {CodingAgent.Session,
         [
           cwd: cwd,
           workspace_dir: Path.join(cwd, "workspace"),
           model: LemonAgent.Test.Mocks.mock_model(),
           stream_fn: fn _, _, _ -> flunk("no provider calls expected") end
         ]}
      )

    {id, run} = running_task("waiting")
    opts = Keyword.put(@opts, :session_pid, session)
    waiter = Task.async(fn -> Wait.execute(%{}, nil, opts) end)
    wait_until(fn -> TaskStore.auto_followup_suppressed?(id) end)
    CodingAgent.Session.steer(session, "A peer asks you to stop waiting")

    assert %AgentToolResult{details: %{interrupted: true, timed_out: false}} =
             Task.await(waiter, 2_000)

    assert CodingAgent.Session.has_steering_messages?(session, nil)
    refute CodingAgent.Session.has_steering_messages?(session, make_ref())
    refute observed?(id)
    refute TaskStore.auto_followup_suppressed?(id)
    assert {:ok, %{status: :running}} = RunGraph.get(run)
  end

  test "aborting the wait releases reservations without cancelling or observing children" do
    tasks = Enum.map(1..3, &running_task("running #{&1}"))
    signal = AbortSignal.new()
    waiter = Task.async(fn -> Wait.execute(%{}, signal, @opts) end)

    wait_until(fn ->
      Enum.all?(tasks, fn {id, _} -> TaskStore.auto_followup_suppressed?(id) end)
    end)

    AbortSignal.abort(signal)
    assert {:error, "Operation aborted"} = Task.await(waiter, 1_000)

    for {id, run} <- tasks do
      refute TaskStore.auto_followup_suppressed?(id)
      refute observed?(id)
      assert {:ok, %{status: :running}, _} = TaskStore.get(id)
      assert {:ok, %{status: :running}} = RunGraph.get(run)
    end

    {id, run} = hd(tasks)
    finish_task(id, run, "still working")

    assert %AgentToolResult{details: %{tasks: [%{task_id: ^id}]}} =
             Wait.execute(%{}, nil, @opts)
  end

  test "parent questions yield the wait without observing or suppressing a child" do
    {id, run} = running_task("blocked")

    assert {:ok, question} =
             ParentQuestions.request(%{
               child_scope_id: run,
               child_run_id: run,
               task_id: id,
               parent_session_key: "wait-parent",
               parent_agent_id: "parent-agent",
               question: "Which option?",
               why_blocked: "Needs a parent decision"
             })

    assert %AgentToolResult{details: %{status: "needs_parent_answer", request_id: request_id}} =
             Wait.execute(%{}, nil, @opts)

    assert request_id == question.id
    refute observed?(id)
    refute TaskStore.auto_followup_suppressed?(id)

    assert :ok =
             ParentQuestions.answer(question.id, "Proceed",
               session_key: "wait-parent",
               agent_id: "parent-agent"
             )

    finish_task(id, run, "unblocked")

    assert %AgentToolResult{details: %{tasks: [%{task_id: ^id}]}} =
             Wait.execute(%{}, nil, @opts)
  end

  test "unknown runs release join reservations and leave the task unobserved" do
    id = TaskStore.new_task(%{owner: Control.owner(@opts), run_id: "missing-run"})

    assert {:error, "Unknown run_id: missing-run"} = Wait.execute(%{}, nil, @opts)
    refute observed?(id)
    refute TaskStore.auto_followup_suppressed?(id)
  end

  test "tool schema documents first-child native scope and captures trusted ownership" do
    assert %AgentTool{name: "wait"} = tool = Wait.tool("/tmp", @opts)
    assert tool.description =~ "first owned native task child result"
    assert tool.description =~ "Does not wait on shell jobs"
    assert tool.parameters["required"] == []
    assert tool.parameters["properties"]["task_ids"]["items"]["minLength"] == 1
    refute Map.has_key?(tool.parameters["properties"], "timeout_ms")

    {id, run} = running_task("owned")
    finish_task(id, run, "tool result")

    assert %AgentToolResult{details: %{tasks: [%{task_id: ^id}]}} =
             tool.execute.("wait-call", %{"session_id" => "forged"}, nil, nil)
  end

  defp running_task(label, opts \\ @opts) do
    run = RunGraph.new_run(%{type: :task, status: :running, description: label})

    id =
      TaskStore.new_task(%{
        status: :running,
        run_id: run,
        description: label,
        owner: Control.owner(opts),
        parent_session_id: Keyword.get(opts, :session_id)
      })

    {id, run}
  end

  defp finish_task(id, run, output) do
    assert :ok = TaskStore.finish(id, output)
    assert :ok = RunGraph.finish(run, output)
  end

  defp observed?(id) do
    {:ok, record, _} = TaskStore.get(id)
    not is_nil(record[:wait_observed_at])
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
