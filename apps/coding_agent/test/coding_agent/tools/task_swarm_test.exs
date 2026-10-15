defmodule CodingAgent.Tools.TaskSwarmTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.{Control, Result}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{TextContent, ThinkingContent}
  alias LemonCore.{ExecutionContext, ToolPolicy}

  setup do
    parent = self()

    opts = [
      parent_session: "swarm-test-#{System.unique_integer([:positive])}",
      session_pid: parent,
      run_override: fn update, signal, context ->
        send(parent, {:started, context.name, self(), signal, context})
        result = controlled_child(update, signal)
        if AbortSignal.aborted?(signal), do: send(parent, {:observed_abort, context.task_id})
        result
      end
    ]

    on_exit(fn -> Control.cancel_parent(parent) end)
    %{opts: opts}
  end

  test "two dependency waves honor the cap and expose only visible dependency output", %{
    opts: opts
  } do
    tasks = [
      task_node("a"),
      task_node("b"),
      task_node("c", ["a", "b"]),
      task_node("d", ["a", "b"])
    ]

    receipt = launch(tasks, opts, concurrency: 2)

    assert_receive {:started, "a", a, _, a_context}, 2_000
    assert_receive {:started, "b", b, _, b_context}, 2_000
    assert a_context.parent_run_id == receipt.details.run_id
    assert b_context.parent_run_id == receipt.details.run_id
    refute_receive {:started, _, _, _, _}, 80

    send(a, {:finish, result("alpha-visible", %{structured_output: %{"answer" => "alpha"}})})
    await_terminal(a_context.task_id)
    refute_receive {:started, _, _, _, _}, 80
    send(b, {:finish, result("beta-visible")})

    assert_receive {:started, "c", c, _, c_context}, 2_000
    assert_receive {:started, "d", d, _, d_context}, 2_000

    for context <- [c_context, d_context] do
      assert context.prompt =~ "alpha-visible"
      assert context.prompt =~ "beta-visible"
      refute context.prompt =~ "secret-thinking"
    end

    send(c, {:finish, result("charlie")})
    send(d, {:finish, result("delta")})
    report = await_report(receipt)
    assert report.details.structured_output.status == "completed"
    assert Enum.map(report.details.structured_output.tasks, & &1.name) == ["a", "b", "c", "d"]
    assert Enum.all?(report.details.structured_output.tasks, &(&1.status == "completed"))
    assert hd(report.details.structured_output.tasks).structured_output == %{"answer" => "alpha"}
    refute Result.visible_output_text(report) =~ "secret-thinking"

    assert_receive {:task_progress, "swarm-test",
                    %AgentToolResult{details: %{swarm: %{tasks: [_ | _]}}}},
                   1_000

    child_id = a_context.task_id

    assert_receive {:task_progress, "swarm-test",
                    %AgentToolResult{details: %{task_id: ^child_id}}},
                   1_000
  end

  test "the cap includes launched children until they finish", %{opts: opts} do
    receipt = launch([task_node("a"), task_node("b"), task_node("c")], opts, concurrency: 1)
    assert_receive {:started, "a", a, _, _}, 2_000
    refute_receive {:started, _, _, _, _}, 80
    send(a, {:finish, result("a")})
    assert_receive {:started, "b", b, _, _}, 2_000
    refute_receive {:started, _, _, _, _}, 80
    send(b, {:finish, result("b")})
    assert_receive {:started, "c", c, _, _}, 2_000
    send(c, {:finish, result("c")})
    assert await_report(receipt).details.structured_output.status == "completed"
  end

  test "failed dependencies block transitively while an independent branch continues", %{
    opts: opts
  } do
    receipt =
      launch([task_node("a"), task_node("b", ["a"]), task_node("c", ["b"]), task_node("d")], opts,
        concurrency: 1
      )

    assert_receive {:started, "a", a, _, _}, 2_000
    send(a, :fail)
    assert_receive {:started, "d", d, _, _}, 2_000
    send(d, {:finish, result("independent output")})
    report = await_report(receipt)
    assert report.is_error
    assert report.details.structured_output.status == "partial_failure"

    assert Enum.map(report.details.structured_output.tasks, & &1.status) ==
             ["error", "blocked", "blocked", "completed"]

    root_id = receipt.details.task_id

    assert_receive {:task_progress, "swarm-test",
                    %AgentToolResult{
                      is_error: true,
                      details: %{
                        task_id: ^root_id,
                        status: "error",
                        structured_output: %{status: "partial_failure"}
                      }
                    }}

    refute_receive {:started, _, _, _, _}, 80
  end

  test "error-valued child results are not successful dependencies", %{opts: opts} do
    receipt = launch([task_node("a"), task_node("b", ["a"])], opts)
    assert_receive {:started, "a", a, _, _}, 2_000
    send(a, {:finish, %{result("visible failure") | is_error: true}})
    report = await_report(receipt)
    assert report.is_error
    assert Enum.map(report.details.structured_output.tasks, & &1.status) == ["error", "blocked"]
  end

  test "native budget concurrency queues ready nodes rather than failing them", %{opts: opts} do
    opts = Keyword.put(opts, :max_children, 1)
    receipt = launch([task_node("a"), task_node("b"), task_node("c")], opts, concurrency: 8)

    for name <- ["a", "b", "c"] do
      assert_receive {:started, ^name, worker, _, _}, 2_000
      refute_receive {:started, _, _, _, _}, 50
      send(worker, {:finish, result(name)})
    end

    assert await_report(receipt).details.structured_output.status == "completed"
  end

  test "root cancellation aborts active children without launching dependents", %{opts: opts} do
    signal = AbortSignal.new()

    receipt =
      launch([task_node("a"), task_node("b"), task_node("c", ["a"])], opts, signal: signal)

    assert_receive {:started, "a", _, _, a_context}, 2_000
    assert_receive {:started, "b", _, _, b_context}, 2_000
    AbortSignal.abort(signal)

    assert await_terminal(receipt.details.task_id).status == :cancelled
    assert await_terminal(a_context.task_id).status == :cancelled
    assert await_terminal(b_context.task_id).status == :cancelled
    a_id = a_context.task_id
    b_id = b_context.task_id
    assert_receive {:observed_abort, ^a_id}
    assert_receive {:observed_abort, ^b_id}
    refute_receive {:started, "c", _, _, _}, 80
  end

  test "scheduler owner death cancels children while the real parent remains alive", %{opts: opts} do
    parent = self()

    receipt = launch([task_node("a"), task_node("b", ["a"])], opts)
    assert_receive {:task_progress, "swarm-test", %AgentToolResult{details: %{swarm: _}}}, 2_000
    coordinator = :sys.get_state(Control)[receipt.details.task_id].worker
    assert_receive {:started, "a", _, _, context}, 2_000
    assert coordinator != parent
    Process.exit(coordinator, :kill)
    assert await_terminal(receipt.details.task_id).status == :error
    assert await_terminal(context.task_id).status == :cancelled
    child_id = context.task_id
    assert_receive {:observed_abort, ^child_id}
    refute_receive {:started, "b", _, _, _}, 80
  end

  test "a crashed child is failed rather than leaving the graph waiting", %{opts: opts} do
    receipt =
      launch([task_node("a"), task_node("b", ["a"]), task_node("c")], opts, concurrency: 1)

    assert_receive {:started, "a", a, _, _}, 2_000
    Process.exit(a, :kill)
    assert_receive {:started, "c", c, _, _}, 2_000
    send(c, {:finish, result("surviving branch")})
    report = await_report(receipt)
    assert report.is_error

    assert Enum.map(report.details.structured_output.tasks, & &1.status) ==
             ["error", "blocked", "completed"]

    assert hd(report.details.structured_output.tasks).error =~ "worker exited"
  end

  test "tracking loss fails the node and aborts its worker without stopping independent work", %{
    opts: opts
  } do
    receipt =
      launch([task_node("a"), task_node("b", ["a"]), task_node("c")], opts, concurrency: 1)

    assert_receive {:started, "a", a, _, context}, 2_000
    worker_ref = Process.monitor(a)
    :ok = TaskStore.mark_tracking_lost(context.task_id, "tracking lost")
    assert_receive {:started, "c", c, _, _}, 2_000
    assert_receive {:DOWN, ^worker_ref, :process, ^a, _}, 2_000
    child_id = context.task_id
    assert_receive {:observed_abort, ^child_id}
    send(c, {:finish, result("independent")})
    report = await_report(receipt)
    assert report.is_error

    assert Enum.map(report.details.structured_output.tasks, & &1.status) ==
             ["error", "blocked", "completed"]
  end

  test "invalid graphs and invalid native options launch neither root nor children", %{opts: opts} do
    invalid = [
      [task_node("a"), task_node("a")],
      [task_node("a", ["missing"])],
      [task_node("a", ["b"]), task_node("b", ["a"])],
      [task_node("a"), Map.put(task_node("b"), "async", "not-a-boolean")],
      [task_node("a"), Map.delete(task_node("b"), "name")]
    ]

    for tasks <- invalid do
      assert {:error, _} = launch(tasks, opts)
    end

    assert {:error, _} = launch([task_node("a")], opts, concurrency: 0)
    owner = Control.owner(opts)
    refute Enum.any?(TaskStore.list(), fn {_, record} -> record[:owner] == owner end)
    refute_receive {:started, _, _, _, _}, 80
  end

  test "native supervisor admission failures become report rows and block descendants", %{
    opts: opts
  } do
    supervisor = start_supervised!({Task.Supervisor, max_children: 1})
    opts = Keyword.put(opts, :task_supervisor, supervisor)
    receipt = launch([task_node("a"), task_node("b", ["a"]), task_node("c")], opts)
    report = await_report(receipt)
    assert report.is_error

    assert Enum.map(report.details.structured_output.tasks, & &1.status) == [
             "error",
             "blocked",
             "error"
           ]

    refute_receive {:started, _, _, _, _}, 80
  end

  test "arity-two overrides belong to children and synchronous roots return the merged report", %{
    opts: opts
  } do
    parent = self()

    opts =
      Keyword.put(opts, :run_override, fn _, _ ->
        send(parent, :child_override)
        result("child output")
      end)

    report = launch([task_node("a")], opts, async: false)
    assert report.details.structured_output.status == "completed"
    assert_receive :child_override
    refute_receive :child_override, 80
  end

  test "child output schemas do not constrain the coordinator report", %{opts: opts} do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    receipt = launch([task_node("a")], opts, output_schema: schema)
    assert_receive {:started, "a", a, _, _}, 2_000
    send(a, {:finish, result(~s({"ok":true}))})
    report = await_report(receipt)
    assert report.details.structured_output.status == "completed"
    assert hd(report.details.structured_output.tasks).structured_output == %{"ok" => true}
  end

  test "admitted nodes inherit authority through the real coordinator identity", %{opts: opts} do
    assert {:ok, parent} =
             ExecutionContext.new(
               run_id: "swarm-parent-#{System.unique_integer([:positive])}",
               agent_id: "swarm-owner",
               cwd: "/tmp",
               tool_policy:
                 ToolPolicy.custom(
                   deny: ["bash"],
                   require_approval: ["write"],
                   max_file_size: 64
                 ),
               capabilities: ["read", "write", "task"],
               limits: %{max_steps: 4, max_tokens: 2_048}
             )

    opts =
      Keyword.merge(opts,
        execution_context: parent,
        run_id: parent.run_id,
        tool_policy: ToolPolicy.from_profile(:full_access),
        settings_manager: %CodingAgent.SettingsManager{}
      )

    tasks = [
      Map.put(task_node("a"), "tool_policy", %{"profile" => "full_access"}),
      task_node("b", ["a"])
      |> Map.put("cwd", "/tmp/other")
      |> Map.put("tool_policy", %{"profile" => "full_access"})
    ]

    receipt = launch(tasks, opts, cwd: "/tmp/default")

    for {name, cwd} <- [{"a", "/tmp/default"}, {"b", "/tmp/other"}] do
      assert_receive {:started, ^name, worker, _, context}, 2_000
      authority = context.execution_context
      assert authority.run_id == context.run_id
      assert authority.run_id != receipt.details.run_id
      assert authority.parent_run_id == receipt.details.run_id
      assert context.parent_run_id == receipt.details.run_id
      assert authority.provenance.delegated_by.run_id == receipt.details.run_id
      assert authority.provenance.delegated_by.principal == parent.principal
      assert authority.principal == parent.principal
      assert authority.workspace_scope == %{root: cwd, mode: :read_write}
      assert authority.capabilities == parent.capabilities
      assert authority.limits == parent.limits
      assert ExecutionContext.subset?(authority, parent)
      assert ToolPolicy.allowed?(authority.tool_policy, "task")
      assert ToolPolicy.requires_approval?(authority.tool_policy, "write")
      refute ToolPolicy.allowed?(authority.tool_policy, "bash")
      send(worker, {:finish, result(name)})
    end

    assert await_report(receipt).details.structured_output.status == "completed"
  end

  @tag :tmp_dir
  test "native swarm sessions cannot widen inherited read-only authority", %{
    opts: opts,
    tmp_dir: cwd
  } do
    owner = self()
    path = Path.join(cwd, "forbidden.txt")

    assert {:ok, parent} =
             ExecutionContext.new(
               run_id: "swarm-parent-#{System.unique_integer([:positive])}",
               agent_id: "swarm-owner",
               cwd: cwd,
               tool_policy: ToolPolicy.custom(allow: ["read", "task"]),
               workspace_scope: %{root: cwd, mode: :read_only},
               capabilities: ["read", "task"],
               limits: %{max_steps: 4}
             )

    stream_fn = fn model, context, options ->
      response =
        case Enum.find(context.messages, &(Map.get(&1, :role) == :tool_result)) do
          nil ->
            send(owner, {:native_swarm_tools, Enum.map(context.tools, & &1.name)})

            Mocks.assistant_message_with_tool_calls([
              Mocks.tool_call("write", %{"path" => path, "content" => "MUST NOT WRITE"})
            ])

          tool_result ->
            send(owner, {:native_swarm_tool_result, tool_result})
            Mocks.assistant_message("Write refused.")
        end

      Mocks.mock_stream_fn_single(response).(model, context, options)
    end

    opts =
      opts
      |> Keyword.delete(:run_override)
      |> Keyword.merge(
        execution_context: parent,
        run_id: parent.run_id,
        tool_policy: ToolPolicy.from_profile(:full_access),
        model: "openai-codex:gpt-6.1-sol",
        settings_manager: %CodingAgent.SettingsManager{},
        stream_fn: stream_fn
      )

    report =
      CodingAgent.Tools.Task.execute(
        "native-swarm-authority",
        %{
          "action" => "swarm",
          "tasks" => [task_node("Worker")],
          "tool_policy" => %{"profile" => "full_access"},
          "async" => false,
          "auto_followup" => false
        },
        nil,
        nil,
        cwd,
        opts
      )

    assert report.details.structured_output.status == "completed"
    assert_receive {:native_swarm_tools, names}, 2_000
    assert "read" in names
    assert "task" in names
    refute "write" in names
    refute "bash" in names
    assert_receive {:native_swarm_tool_result, %{tool_name: "write", is_error: true}}, 2_000
    refute File.exists?(path)
  end

  test "invalid inherited authority launches neither the coordinator nor nodes", %{opts: opts} do
    assert {:error, message} =
             launch([task_node("a")], Keyword.put(opts, :execution_context, %{}))

    assert message =~ "Task execution authority is invalid"
    owner = Control.owner(opts)
    refute Enum.any?(TaskStore.list(), fn {_, record} -> record[:owner] == owner end)
    refute_receive {:started, _, _, _, _}, 80
  end

  defp task_node(name, dependencies \\ []) do
    %{"name" => name, "prompt" => "Do #{name}", "depends_on" => dependencies}
  end

  defp launch(tasks, opts, options \\ []) do
    params = %{
      "action" => "swarm",
      "tasks" => tasks,
      "async" => Keyword.get(options, :async, true),
      "auto_followup" => false,
      "concurrency" => Keyword.get(options, :concurrency, 8)
    }

    params =
      Enum.reduce([:output_schema, :cwd], params, fn key, acc ->
        if Keyword.has_key?(options, key),
          do: Map.put(acc, Atom.to_string(key), options[key]),
          else: acc
      end)

    CodingAgent.Tools.Task.execute(
      "swarm-test",
      params,
      options[:signal],
      options[:on_update],
      "/tmp",
      opts
    )
  end

  defp result(text, details \\ %{}) do
    %AgentToolResult{
      content: [%ThinkingContent{thinking: "secret-thinking"}, %TextContent{text: text}],
      details: Map.put(details, :status, "completed")
    }
  end

  defp controlled_child(update, signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Task aborted"}
    else
      receive do
        {:finish, result} ->
          update.(%AgentToolResult{
            content: [%TextContent{text: "child progress"}],
            details: %{status: "running"}
          })

          result

        :fail ->
          {:error, "controlled child failure"}
      after
        10 -> controlled_child(update, signal)
      end
    end
  end

  defp await_report(receipt) do
    record = await_terminal(receipt.details.task_id)
    assert record.status == :completed
    assert %AgentToolResult{} = record.result
    record.result
  end

  defp await_terminal(task_id, remaining \\ 500)
  defp await_terminal(task_id, 0), do: flunk("Task #{task_id} did not terminalize")

  defp await_terminal(task_id, remaining) do
    case TaskStore.get_record(task_id) do
      {:ok, %{status: status} = record} when status not in [:queued, :running] ->
        record

      _ ->
        Process.sleep(20)
        await_terminal(task_id, remaining - 1)
    end
  end
end
