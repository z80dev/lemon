defmodule CodingAgent.Tools.TaskOrchestrationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.Control
  alias CodingAgent.TaskStore
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  defmodule ProgressEmitter do
    def emit_action_event(owner, fields) do
      send(owner, {:action, fields})
      owner
    end
  end

  defmodule ChildMailbox do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:steer, text, false}, _from, owner) do
      send(owner, {:child_message, text})
      {:reply, :ok, owner}
    end

    def handle_cast(:abort, owner), do: {:noreply, owner}
  end

  test "batch launches all children before waiting and returns structured sibling failures" do
    parent = self()

    opts = [
      parent_session: unique_id(),
      run_override: fn update, _signal ->
        send(parent, {:started, self()})

        receive do
          {:finish, text} ->
            update.(%AgentToolResult{
              content: [%TextContent{text: text}],
              details: %{status: "running"}
            })

            %AgentToolResult{content: [%TextContent{text: text}], details: %{status: "completed"}}

          :fail ->
            {:error, "child failed"}
        end
      end
    ]

    result =
      TaskTool.execute(
        "fanout",
        %{"tasks" => tasks(3), "auto_followup" => false},
        nil,
        fn update -> send(parent, {:progress, update.details}) end,
        "/tmp",
        opts
      )

    assert length(result.details.task_ids) == 3

    workers =
      for _ <- 1..3 do
        assert_receive {:started, pid}, 2_000
        pid
      end

    [first, second, third] = workers
    send(first, {:finish, "first output"})
    send(second, :fail)
    send(third, {:finish, "third output"})

    joined =
      TaskTool.execute(
        "join",
        %{"action" => "join", "task_ids" => result.details.task_ids},
        nil,
        nil,
        "/tmp",
        opts
      )

    assert Enum.count(joined.details.tasks, &(&1.status == "completed")) == 2
    assert Enum.any?(joined.details.tasks, &(&1[:error] == "child failed"))
    assert Enum.any?(joined.details.tasks, &(&1[:output] == "first output"))
    assert_receive {:progress, %{status: "completed", task_id: _}}, 1_000
  end

  test "parent cancellation reaches every child after the launch call has returned" do
    parent = self()

    opts = [
      parent_session: unique_id(),
      session_pid: parent,
      run_override: fn _update, signal ->
        send(parent, {:started, self()})
        wait_for_abort(signal)
      end
    ]

    receipt =
      TaskTool.execute(
        "cancel-parent",
        %{"tasks" => tasks(3), "auto_followup" => false},
        nil,
        nil,
        "/tmp",
        opts
      )

    for _ <- 1..3, do: assert_receive({:started, _}, 2_000)
    Control.cancel_parent(parent)

    joined =
      TaskTool.execute(
        "join",
        %{"action" => "join", "task_ids" => receipt.details.task_ids},
        nil,
        nil,
        "/tmp",
        opts
      )

    assert Enum.all?(joined.details.tasks, &(&1.status == "cancelled"))
  end

  test "child cancellation is owner scoped and does not cancel its sibling" do
    parent = self()

    opts = [
      parent_session: unique_id(),
      run_override: fn _update, signal ->
        send(parent, {:started, self()})
        wait_for_abort(signal)
      end
    ]

    receipt =
      TaskTool.execute(
        "cancel-one",
        %{"tasks" => tasks(2), "auto_followup" => false},
        nil,
        nil,
        "/tmp",
        opts
      )

    for _ <- 1..2, do: assert_receive({:started, _}, 2_000)
    [one, two] = receipt.details.task_ids

    assert {:error, _not_found} =
             TaskTool.execute(
               "foreign",
               %{"action" => "cancel", "task_id" => one},
               nil,
               nil,
               "/tmp",
               parent_session: unique_id()
             )

    assert %AgentToolResult{} =
             TaskTool.execute(
               "cancel",
               %{"action" => "cancel", "task_id" => one},
               nil,
               nil,
               "/tmp",
               opts
             )

    TaskTool.execute(
      "join-one",
      %{"action" => "join", "task_ids" => [one]},
      nil,
      nil,
      "/tmp",
      opts
    )

    assert {:ok, %{status: :running}, _} = TaskStore.get(two)

    TaskTool.execute(
      "cancel-two",
      %{"action" => "cancel", "task_id" => two},
      nil,
      nil,
      "/tmp",
      opts
    )

    TaskTool.execute(
      "join-two",
      %{"action" => "join", "task_ids" => [two]},
      nil,
      nil,
      "/tmp",
      opts
    )
  end

  test "killed workers terminalize instead of leaving joins hanging" do
    parent = self()

    opts = [
      parent_session: unique_id(),
      run_override: fn _, _ ->
        send(parent, {:started, self()})

        receive do
          :never -> :ok
        end
      end
    ]

    receipt =
      TaskTool.execute(
        "kill-worker",
        %{"prompt" => "work", "auto_followup" => false},
        nil,
        nil,
        "/tmp",
        opts
      )

    assert_receive {:started, pid}, 2_000
    Process.exit(pid, :kill)

    joined =
      TaskTool.execute(
        "join-killed",
        %{"action" => "join", "task_id" => receipt.details.task_id},
        nil,
        nil,
        "/tmp",
        opts
      )

    assert [%{status: "error", error: error}] = joined.details.tasks
    assert error =~ "worker exited"
  end

  test "task session options force subagent bootstrap even without lineage" do
    {:ok, params} =
      CodingAgent.Tools.Task.Params.validate_run_params(%{"prompt" => "work"}, "/tmp")

    opts =
      CodingAgent.Tools.Task.Params.build_session_opts("/tmp", [session_scope: :main], params)

    assert opts[:session_scope] == :subagent
  end

  test "queued child messages are delivered when its session becomes available" do
    parent = self()

    opts = [
      parent_session: unique_id(),
      run_override: fn _, signal ->
        send(parent, :worker_started)
        wait_for_abort(signal)
      end
    ]

    receipt =
      TaskTool.execute(
        "message-child",
        %{"prompt" => "work", "auto_followup" => false},
        nil,
        nil,
        "/tmp",
        opts
      )

    id = receipt.details.task_id
    assert_receive :worker_started, 2_000

    assert %AgentToolResult{} =
             TaskTool.execute(
               "message",
               %{"action" => "message", "task_id" => id, "message" => "focus on parser"},
               nil,
               nil,
               "/tmp",
               opts
             )

    child = start_supervised!({ChildMailbox, self()})
    :ok = Control.attach_session(id, child)
    assert_receive {:child_message, envelope}
    [_notice, payload] = String.split(envelope, "\n", parts: 2)
    assert %{"sender" => "agent://parent", "body" => "focus on parser"} = Jason.decode!(payload)
    TaskTool.execute("cancel", %{"action" => "cancel", "task_id" => id}, nil, nil, "/tmp", opts)
    TaskTool.execute("join", %{"action" => "join", "task_id" => id}, nil, nil, "/tmp", opts)
  end

  test "completed launch actions still forward asynchronous child progress" do
    alias CodingAgent.Session.RunTranslator

    translator =
      RunTranslator.new(
        emitter: ProgressEmitter,
        emitter_state: self(),
        engine: "lemon",
        label: "Lemon",
        cwd: "/tmp"
      )

    translator =
      RunTranslator.handle_event(translator, {:tool_execution_start, "launch", "task", %{}})

    translator =
      RunTranslator.handle_event(
        translator,
        {:tool_execution_end, "launch", "task",
         %AgentToolResult{content: [%TextContent{text: "queued"}]}, false}
      )

    assert translator.pending_actions == %{}
    partial = %AgentToolResult{details: %{task_id: "child", status: "running"}}

    RunTranslator.handle_event(
      translator,
      {:tool_execution_update, "launch", "task", %{}, partial}
    )

    assert_receive {:action,
                    %{
                      id: "task_child",
                      phase: :started,
                      detail: %{partial_result: ^partial, parent_action_id: "tool_launch"}
                    }}
  end

  defp tasks(count),
    do: for(n <- 1..count, do: %{"description" => "child #{n}", "prompt" => "work #{n}"})

  defp unique_id, do: "task-owner-#{System.unique_integer([:positive])}"

  defp wait_for_abort(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Task aborted"}
    else
      receive do
        :finish -> %AgentToolResult{content: [%TextContent{text: "done"}]}
      after
        10 -> wait_for_abort(signal)
      end
    end
  end
end
