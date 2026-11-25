defmodule CodingAgent.Tools.Task.EarlyCancelTest do
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.{
    BudgetTracker,
    RunGraph,
    TaskProgressBindingStore,
    TaskRuntimeHelpers,
    TaskStore
  }

  alias CodingAgent.TaskRuntime.{Control, Followup, Hub}
  alias CodingAgent.Tools.Task
  alias CodingAgent.Tools.Task.Result
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  defmodule Recorder do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:enqueue, _context, {text, entry}}, _from, owner) do
      send(owner, {:followup, text, entry})
      {:reply, :ok, owner}
    end
  end

  @key "agent:main:main"

  test "a cancel before launch terminalizes store, graph, budget and progress; join is prompt" do
    recorder = start_supervised!({Recorder, self()})
    {parent, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^parent, :normal}
    parent_run_id = RunGraph.new_run(%{type: :session})
    test = self()

    receipt =
      Task.execute(
        "early-cancel",
        %{"description" => "Never starts", "prompt" => "Work", "async" => true},
        nil,
        nil,
        "/tmp",
        session_pid: parent,
        parent_run_id: parent_run_id,
        session_key: @key,
        agent_id: "main",
        async_followup_server: recorder,
        run_override: fn _on_update, _signal ->
          send(test, :unexpected_execution)
          completed("ran")
        end
      )

    task_id = receipt.details.task_id
    run_id = receipt.details.run_id

    assert_eventually(fn ->
      match?({:ok, %{status: :cancelled}}, TaskStore.get_record(task_id)) and
        RunGraph.normalize_status(elem(RunGraph.get(run_id), 1)[:status]) in [:error, :cancelled]
    end)

    assert {:error, :not_found} = TaskProgressBindingStore.get_by_child_run_id(run_id)
    budget = BudgetTracker.get_budget(parent_run_id)
    assert budget
    refute run_id in (budget[:active_child_ids] || [])

    {elapsed_us, joined} = :timer.tc(fn -> Result.do_join(%{"task_ids" => [task_id]}) end)
    assert elapsed_us < 2_000_000

    assert %AgentToolResult{details: %{status: "completed", tasks: [%{status: "cancelled"}]}} =
             joined

    refute_received :unexpected_execution
    # The parent is gone: its cancelled child does not wake it.
    refute_receive {:followup, _text, %{task_id: ^task_id}}, 200
  end

  test "followup notices come from the stored terminal record" do
    recorder = start_supervised!({Recorder, self()})
    id = TaskStore.new_task(%{description: "Raced"})
    on_exit(fn -> TaskStore.delete_task(id) end)
    TaskStore.cancel(id, "Task aborted")

    # The worker's late success lost to the cancellation recorded first.
    :ok =
      Followup.maybe_send_async_followup(
        %{async_followup_server: recorder, session_key: @key},
        id,
        nil,
        {:ok, completed("late answer")}
      )

    assert_receive {:followup, text, %{task_id: ^id}}
    assert text =~ "was cancelled"
    refute text =~ "late answer"
  end

  test "a failure notice uses the stored reason, bounded" do
    recorder = start_supervised!({Recorder, self()})
    id = TaskStore.new_task(%{description: "Fails loudly"})
    on_exit(fn -> TaskStore.delete_task(id) end)
    TaskStore.fail(id, String.duplicate("x", 5_000))

    :ok =
      Followup.maybe_send_async_followup(
        %{async_followup_server: recorder, session_key: @key},
        id,
        nil,
        {:error, "caller reason"}
      )

    assert_receive {:followup, text, %{task_id: ^id}}
    assert text =~ "failed: " <> String.duplicate("x", 1_000) <> "…"
    refute text =~ String.duplicate("x", 1_001)
    refute text =~ "caller reason"
  end

  test "a parent abort suppresses its cancelled child's notice; a redirect does not" do
    recorder = start_supervised!({Recorder, self()})
    redirected = LemonAgent.AbortSignal.new()
    LemonAgent.AbortSignal.request_redirect(redirected)
    aborted = LemonAgent.AbortSignal.new()
    LemonAgent.AbortSignal.abort(aborted)

    for {signal, expected} <- [{aborted, :none}, {redirected, :notice}] do
      id = TaskStore.new_task(%{description: "Cancelled child"})
      on_exit(fn -> TaskStore.delete_task(id) end)
      TaskStore.cancel(id, "Task aborted")

      :ok =
        Followup.maybe_send_async_followup(
          %{async_followup_server: recorder, session_key: @key, parent_signal: signal},
          id,
          nil,
          {:error, "Task aborted"}
        )

      case expected do
        :none -> refute_receive {:followup, _text, %{task_id: ^id}}, 100
        :notice -> assert_receive {:followup, "Task " <> _, %{task_id: ^id}}
      end
    end
  end

  test "a join suppresses the followup of every task it returned, failures included" do
    recorder = start_supervised!({Recorder, self()})

    receipt =
      Task.execute(
        "join-failure",
        %{"description" => "Fails", "prompt" => "Fail", "async" => true},
        nil,
        nil,
        "/tmp",
        session_key: @key,
        agent_id: "main",
        async_followup_server: recorder,
        run_override: fn _on_update, _signal ->
          receive do
            :fail -> {:error, "boom"}
          end
        end
      )

    task_id = receipt.details.task_id
    join = Elixir.Task.async(fn -> Result.do_join(%{"task_ids" => [task_id]}) end)

    assert_eventually(fn ->
      match?({:ok, %{auto_followup_join_tokens: [_ | _]}}, TaskStore.get_record(task_id))
    end)

    [worker] = Control.worker_pids([task_id])
    send(worker, :fail)

    assert %AgentToolResult{details: %{tasks: [%{status: "error"}]}} = Elixir.Task.await(join)
    # Delivery checks this durable suppression before waking the parent.
    assert TaskStore.auto_followup_suppressed?(task_id)
  end

  describe "Agent Hub status" do
    test "a completed task shows completed after a restart, whatever its agent state" do
      root = "root-#{System.unique_integer([:positive])}"
      opts = [session_id: root, session_key: @key, agent_id: "main"]

      id =
        TaskStore.new_task(%{
          owner: Control.owner(opts),
          session_key: @key,
          parent_session_id: root,
          description: "Finished child",
          status: :completed,
          # Written by earlier releases for completed children they could not resume.
          agent_state: :aborted,
          result: completed("done")
        })

      on_exit(fn -> TaskStore.delete_task(id) end)
      assert {:ok, [%{task_id: ^id, status: "completed"}]} = Hub.list(@key, [root])
    end

    test "a completed, unresumable child keeps a completed owner phase and Hub status" do
      root = "root-#{System.unique_integer([:positive])}"
      opts = [session_id: root, session_key: @key, agent_id: "main"]

      id =
        TaskStore.new_task(%{
          owner: Control.owner(opts),
          session_key: @key,
          parent_session_id: root,
          description: "Finishes without a retained session"
        })

      on_exit(fn ->
        TaskRuntimeHelpers.stop(id)
        TaskStore.delete_task(id)
      end)

      :ok = TaskRuntimeHelpers.register(id, nil)
      :ok = TaskRuntimeHelpers.launch(id, fn -> TaskStore.finish(id, completed("done")) end)
      assert_eventually(fn -> match?({:completed, _}, TaskRuntimeHelpers.state(id)) end)
      assert {:ok, [%{status: "completed"}]} = Hub.list(@key, [root])

      # A runtime restart drops the owner; the stored record still answers.
      TaskRuntimeHelpers.stop(id)
      assert {:ok, [%{status: "completed"}]} = Hub.list(@key, [root])
    end
  end

  defp completed(text) do
    %AgentToolResult{content: [%TextContent{text: text}], details: %{status: "completed"}}
  end
end
