defmodule CodingAgent.Tools.Task.SpeculationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{
    BudgetTracker,
    RunGraph,
    Session,
    SessionManager,
    SettingsManager,
    TaskStore,
    ToolPolicy,
    ToolRegistry
  }

  alias CodingAgent.Extensions.ToolHooks
  alias CodingAgent.Tools.Task, as: TaskTool
  alias LemonAgent.AbortSignal
  alias LemonAgent.Loop.ToolCalls
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @batch ~s({"agent":"scout","context":"shared","auto_followup":false,"tasks":[) <>
           ~s({"description":"one","prompt":"first"},) <>
           ~s({"description":"two","prompt":"second"}]})

  setup do
    TaskStore.clear()
    RunGraph.clear()
    :ok
  end

  test "items launch while the call streams and dispatch adopts them without relaunching" do
    tool = task_tool()
    {at, length} = :binary.match(@batch, ~s("first"}))

    stream(tool, "call-adopt", binary_part(@batch, 0, at + length))
    assert_receive {:started, first, prompt}, 2_000
    assert prompt =~ "first" and prompt =~ "shared"
    refute_receive {:started, _, _}, 50

    stream(tool, "call-adopt", @batch, from: at + length)
    assert_receive {:started, second, prompt}, 2_000
    assert prompt =~ "second"

    result = dispatch(tool, "call-adopt", @batch)
    assert result.details.task_ids == [first, second]
    assert Enum.all?(result.details.tasks, &(&1.status == "queued"))
    refute_receive {:started, _, _}, 100

    for id <- [first, second] do
      assert {:ok, :running} = TaskStore.get_status(id)
      refute TaskStore.auto_followup_suppressed?(id)
    end

    cancel(tool, [first, second])
  end

  test "a finished call that differs cancels every launch and dispatches the finished items" do
    parent_run = RunGraph.new_run(%{type: :parent})
    BudgetTracker.store_budget(parent_run, BudgetTracker.create_budget(max_children: 2))
    tool = task_tool(run_id: parent_run)

    # A top-level option streamed after tasks changes every inherited item.
    json = String.replace_suffix(@batch, "}", ~s(,"request_budget":50}))
    stream(tool, "call-differs", json)
    assert_receive {:started, first, _}, 2_000
    assert_receive {:started, second, _}, 2_000
    assert BudgetTracker.get_budget(parent_run).active_children == 2

    result = dispatch(tool, "call-differs", json)
    assert [third, fourth] = result.details.task_ids
    assert MapSet.disjoint?(MapSet.new([first, second]), MapSet.new([third, fourth]))
    assert Enum.all?(result.details.tasks, &(&1.status == "queued"))
    assert_receive {:started, ^third, _}, 2_000
    assert_receive {:started, ^fourth, _}, 2_000

    assert_cancelled([first, second])
    assert BudgetTracker.get_budget(parent_run).active_children == 2
    cancel(tool, [third, fourth])
  end

  test "a call settled without dispatch cancels and terminalizes its launches" do
    tool = task_tool()
    stream(tool, "call-dropped", @batch)
    assert_receive {:started, first, _}, 2_000
    assert_receive {:started, second, _}, 2_000

    # What the loop sends for an aborted turn, a blocked or invalid call, or a retry.
    tool.on_stream.({:settle, "call-dropped"})

    assert_cancelled([first, second])
    assert_receive {:aborted, ^first}, 2_000
    assert_receive {:aborted, ^second}, 2_000
  end

  test "an invalid finished call cancels the launches it would have adopted" do
    tool = task_tool()

    json =
      ~s({"agent":"scout","tasks":[{"name":"Same","prompt":"first"},{"name":"Same","prompt":"second"}]})

    stream(tool, "call-invalid", json)
    assert_receive {:started, first, _}, 2_000
    # Speculation stops at the duplicate name instead of launching it.
    refute_receive {:started, _, _}, 50

    {:ok, args} = ToolCalls.prepare_arguments(tool, Jason.decode!(json))

    assert {:error, "Task names must be unique within a batch"} =
             tool.execute.("call-invalid", args, nil, nil)

    assert_cancelled([first])
  end

  test "launches end with the loop process that streamed them" do
    tool = task_tool()
    test = self()

    loop =
      spawn(fn ->
        stream(tool, "call-orphaned", @batch)
        send(test, :streamed)

        receive do
          :exit -> :ok
        end
      end)

    assert_receive :streamed, 2_000
    assert_receive {:started, first, _}, 2_000
    assert_receive {:started, second, _}, 2_000
    send(loop, :exit)

    assert_cancelled([first, second])
  end

  test "an aborted parent signal cancels launches before dispatch" do
    tool = task_tool()
    signal = AbortSignal.new()
    stream(tool, "call-aborted", @batch, signal: signal)
    assert_receive {:started, first, _}, 2_000
    assert_receive {:started, second, _}, 2_000

    AbortSignal.abort(signal)
    assert_receive {:aborted, ^first}, 2_000
    assert_receive {:aborted, ^second}, 2_000
    tool.on_stream.({:settle, "call-aborted"})
    assert_cancelled([first, second])
  end

  test "nothing launches while the setting is off" do
    settings = %SettingsManager{task: %{%SettingsManager{}.task | speculative_launch: false}}
    tool = task_tool(settings_manager: settings)

    stream(tool, "call-off", @batch)
    refute_receive {:started, _, _}, 100

    result = dispatch(tool, "call-off", @batch)
    assert [first, second] = result.details.task_ids
    assert_receive {:started, ^first, _}, 2_000
    assert_receive {:started, ^second, _}, 2_000
    cancel(tool, [first, second])
  end

  test "items dispatch would refuse are not speculated" do
    # At the nesting cap the call itself is refused.
    capped = task_tool(task_depth: 2)
    stream(capped, "call-capped", @batch)
    refute_receive {:started, _, _}, 100

    # Worktree items and non-run actions wait for dispatch.
    tool = task_tool()

    stream(
      tool,
      "call-worktree",
      ~s({"agent":"scout","tasks":[{"prompt":"isolated","worktree":true},{"prompt":"shared"}]})
    )

    assert_receive {:started, shared, prompt}, 2_000
    assert prompt =~ "shared"
    refute_receive {:started, _, _}, 50
    tool.on_stream.({:settle, "call-worktree"})
    assert_cancelled([shared])

    stream(tool, "call-swarm", ~s({"action":"swarm","tasks":[{"name":"A","prompt":"x"}]}))
    refute_receive {:started, _, _}, 100
  end

  test "only read-only items start before the call finishes streaming" do
    tool = task_tool()

    # A write-capable item could otherwise edit the checkout before a later
    # top-level option (here worktree) isolates it; it waits for dispatch.
    json =
      ~s({"tasks":[{"prompt":"edit"},{"agent":"scout","prompt":"look"},) <>
        ~s({"prompt":"inspect","tool_policy":{"allow":["read","grep"]}}]})

    stream(tool, "call-mixed", json)
    started = for _ <- 1..2, do: assert_receive({:started, _, _} = message, 2_000)
    refute_receive {:started, _, _}, 100

    assert [{_, reader, inspect}, {_, scout, look}] =
             Enum.sort_by(started, fn {_, _, prompt} -> prompt end)

    assert inspect =~ "inspect" and look =~ "look"

    result = dispatch(tool, "call-mixed", json)
    assert_receive {:started, editor, prompt}, 2_000
    assert prompt =~ "edit"
    assert result.details.task_ids == [editor, scout, reader]
    refute_receive {:started, _, _}, 100
    cancel(tool, [editor, scout, reader])
  end

  @tag :tmp_dir
  test "only a task tool that runs without review or hooks keeps its stream callback", %{
    tmp_dir: tmp_dir
  } do
    task = fn policy ->
      tmp_dir
      |> ToolRegistry.get_tools(
        include_extensions: false,
        include_mcp: false,
        enabled_only: ["task"],
        settings_manager: %SettingsManager{},
        tool_policy: policy
      )
      |> Enum.find(&(&1.name == "task"))
    end

    assert is_function(task.(ToolPolicy.custom(approval_mode: :yolo)).on_stream, 1)
    assert task.(ToolPolicy.custom(approval_mode: :write)).on_stream == nil
    assert task.(ToolPolicy.custom(approvals: %{"task" => :always})).on_stream == nil

    hooked = ToolHooks.wrap_tool(task_tool(), [on_tool_call: [fn _ -> :ok end]], %{})
    assert hooked.on_stream == nil
  end

  @tag :tmp_dir
  test "a session starts batch items while the model is still streaming the call", %{
    tmp_dir: tmp_dir
  } do
    test = self()
    {at, length} = :binary.match(@batch, ~s("first"}))
    head = binary_part(@batch, 0, at + length)
    tail = binary_part(@batch, at + length, byte_size(@batch) - at - length)
    call = Mocks.tool_call("task", Jason.decode!(@batch), id: "call-session")
    partial = Mocks.assistant_message_with_tool_calls([%{call | arguments: %{}}])
    final = Mocks.assistant_message_with_tool_calls([call])
    {:ok, requests} = Agent.start_link(fn -> 0 end)

    stream_fn = fn _model, _context, _options ->
      {:ok, stream} = LemonAi.EventStream.start_link()

      if Agent.get_and_update(requests, &{&1, &1 + 1}) == 0 do
        Task.start(fn ->
          push(stream, [
            {:start, %{partial | content: []}},
            {:tool_call_start, 0, partial},
            {:tool_call_delta, 0, head, partial}
          ])

          # Hold the rest of the call until the test has seen the first child.
          send(test, {:streaming, self()})
          receive do: (:continue -> :ok)

          push(stream, [
            {:tool_call_delta, 0, tail, partial},
            {:tool_call_end, 0, call, final},
            {:done, :tool_use, final}
          ])

          LemonAi.EventStream.complete(stream, final)
        end)
      else
        done = Mocks.assistant_message("done")
        push(stream, [{:done, :stop, done}])
        LemonAi.EventStream.complete(stream, done)
      end

      {:ok, stream}
    end

    session =
      start_supervised!(
        {Session,
         [
           cwd: tmp_dir,
           workspace_dir: Path.join(tmp_dir, "workspace"),
           model: Mocks.mock_model(),
           stream_fn: stream_fn,
           run_override: run_override(test),
           settings_manager: %SettingsManager{
             extension_paths: [],
             extension_auto_load_default_paths: false,
             compaction_enabled: false
           }
         ]}
      )

    on_exit(fn -> File.rm_rf!(SessionManager.get_session_dir(tmp_dir)) end)
    Session.subscribe(session)
    :ok = Session.prompt(session, "fan out")

    assert_receive {:streaming, provider}, 5_000
    assert_receive {:started, first, prompt}, 5_000
    assert prompt =~ "first"
    refute_received {:session_event, _, {:tool_execution_start, "call-session", _, _}}

    send(provider, :continue)
    assert_receive {:started, second, _}, 5_000

    assert_receive {:session_event, _,
                    {:tool_execution_end, "call-session", "task", result, false}},
                   5_000

    assert result.details.task_ids == [first, second]
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000
    refute_received {:started, _, _}

    CodingAgent.Tools.Task.Control.cancel_parent(session)
    assert_receive {:aborted, ^first}, 2_000
    assert_receive {:aborted, ^second}, 2_000
  end

  defp task_tool(extra \\ []) do
    opts =
      Keyword.merge(
        [
          parent_session: "speculation-#{System.unique_integer([:positive])}",
          settings_manager: %SettingsManager{},
          run_override: run_override(self())
        ],
        extra
      )

    TaskTool.tool("/tmp", opts)
  end

  defp run_override(test) do
    fn _update, signal, context ->
      send(test, {:started, context.task_id, context.prompt})
      await_abort(signal, context.task_id, test)
    end
  end

  defp push(stream, events), do: Enum.each(events, &LemonAi.EventStream.push(stream, &1))

  defp await_abort(signal, task_id, test) do
    if AbortSignal.aborted?(signal) do
      send(test, {:aborted, task_id})
      {:error, "Task aborted"}
    else
      receive do
        :finish -> %AgentToolResult{content: [%TextContent{text: "done"}]}
      after
        10 -> await_abort(signal, task_id, test)
      end
    end
  end

  # Feeds growing prefixes of `json` the way the loop reports argument deltas;
  # `from` continues a stream that already reported that many bytes.
  defp stream(tool, id, json, opts \\ []) do
    from = Keyword.get(opts, :from, 0)
    signal = Keyword.get(opts, :signal)
    sizes = Enum.to_list((from + 7)..byte_size(json)//7) ++ [byte_size(json)]

    for size <- Enum.uniq(sizes) do
      tool.on_stream.(
        {:args,
         %{
           id: id,
           json: binary_part(json, 0, size),
           signal: signal,
           prepare: &ToolCalls.prepare_arguments(tool, &1)
         }}
      )
    end

    :ok
  end

  # Executes the finished call, then settles it, as the loop does.
  defp dispatch(tool, id, json) do
    {:ok, args} = ToolCalls.prepare_arguments(tool, Jason.decode!(json))
    result = tool.execute.(id, args, nil, nil)
    tool.on_stream.({:settle, id})
    result
  end

  defp assert_cancelled(task_ids) do
    for id <- task_ids do
      assert %{status: :cancelled, run_id: run_id} = await_terminal(id)
      assert TaskStore.auto_followup_suppressed?(id)
      assert {:ok, _} = RunGraph.await([run_id], :wait_all, 3_000)
      assert {:ok, %{status: :error}} = RunGraph.get(run_id)
    end
  end

  defp await_terminal(task_id, attempts \\ 150) do
    case TaskStore.get_record(task_id) do
      {:ok, %{status: status} = record} when status not in [:queued, :running] ->
        record

      _ when attempts > 0 ->
        Process.sleep(20)
        await_terminal(task_id, attempts - 1)

      _ ->
        flunk("Task #{task_id} did not terminalize")
    end
  end

  defp cancel(tool, task_ids) do
    for id <- task_ids do
      tool.execute.("cancel-#{id}", %{"action" => "cancel", "task_id" => id}, nil, nil)
    end

    for id <- task_ids, do: assert_receive({:aborted, ^id}, 2_000)
  end
end
