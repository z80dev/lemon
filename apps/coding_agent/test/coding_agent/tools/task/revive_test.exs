defmodule CodingAgent.Tools.Task.ReviveTest do
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.{RunGraph, TaskStore}
  alias CodingAgent.Tools.Read
  alias CodingAgent.Tools.Task.{Async, Control, Messaging, Result, Runner}
  alias CodingAgent.Tools.Write
  alias LemonAgent.{AbortSignal, Test.Mocks}
  alias LemonAgent.Types.AgentToolResult

  defmodule Parent do
    def handle_async_followup(pid, message) do
      send(pid, {:child_reply, message})
      :ok
    end
  end

  @tag :tmp_dir
  test "write wakes an idle child in the same session and auto-delivers its reply", %{
    tmp_dir: cwd
  } do
    child = launch(cwd, idle_ttl_ms: 0)
    assert {:ok, session} = CodingAgent.lookup_session(child.session_id)
    TaskStore.suppress_auto_followup(child.id)

    assert %AgentToolResult{details: %{delivery: "woken"}} =
             Write.execute(
               "wake",
               %{
                 "path" => "agent://#{child.id}",
                 "content" => "Remember the original assignment"
               },
               nil,
               nil,
               cwd,
               child.opts
             )

    assert_receive {:model_call, 2, model, context}, 5_000
    assert model == Mocks.mock_model()
    assert context.tools == []
    assert inspect(context.messages) =~ "original assignment"
    assert inspect(context.messages) =~ "answer-1"
    assert inspect(context.messages) =~ "Remember the original assignment"
    assert_receive {:child_reply, reply}, 5_000
    assert inspect(reply.content) =~ "answer-2"
    assert {:ok, ^session} = CodingAgent.lookup_session(child.session_id)
    assert_phase(child.id, :idle)
  end

  @tag :tmp_dir
  test "TTL parks the session and messaging restores its persisted conversation", %{tmp_dir: cwd} do
    child = launch(cwd, idle_ttl_ms: 40)
    session = child.session
    assert_phase(child.id, :parked)
    assert_process_dead(session)
    assert File.regular?(child.session_file)

    assert %AgentToolResult{details: %{delivery: "revived"}} =
             Messaging.send(child.id, "Continue with prior context", child.opts)

    assert_receive {:model_call, 2, _, context}, 5_000
    assert inspect(context.messages) =~ "original assignment"
    assert inspect(context.messages) =~ "answer-1"
    assert inspect(context.messages) =~ "Continue with prior context"
    assert_receive {:child_reply, _}, 5_000
    assert {:ok, %{session_id: session_id, cwd: ^cwd}} = TaskStore.get_record(child.id)
    assert session_id == child.session_id
    assert %AgentToolResult{} = Messaging.read("agent://#{child.id}", child.opts)
  end

  @tag :tmp_dir
  test "zero TTL stays idle and stale parking timers cannot stop a new turn", %{tmp_dir: cwd} do
    child = launch(cwd, idle_ttl_ms: 0, block_second: true)
    assert {:ok, session} = CodingAgent.lookup_session(child.session_id)
    token = :sys.get_state(Control)[child.id].idle_token

    assert %AgentToolResult{details: %{delivery: "woken"}} =
             Messaging.send(child.id, "Work", child.opts)

    assert_receive {:stream_blocked, producer}, 5_000
    send(Control, {:park, child.id, token})

    assert %AgentToolResult{details: %{timed_out: true}} =
             Result.do_join(%{"task_ids" => [child.id]}, nil, timeout_ms: 30)

    assert Control.roster(child.opts)
           |> elem(1)
           |> Enum.any?(&(&1[:task_id] == child.id and &1.status == :running))

    assert Process.alive?(session)
    send(producer, :release_stream)
    assert_receive {:child_reply, _}, 5_000
    assert_phase(child.id, :idle)
    assert Process.alive?(session)

    assert %AgentToolResult{details: %{tasks: [%{output: "answer-2"}]}} =
             Result.do_join(%{"task_ids" => [child.id]})
  end

  @tag :tmp_dir
  test "cancelled children refuse resurrection and point to their readable history", %{
    tmp_dir: cwd
  } do
    child = launch(cwd, idle_ttl_ms: 0)
    assert :ok = Control.command(child.id, "cancel", nil, child.opts)
    assert {:error, error} = Messaging.send(child.id, "Do not revive", child.opts)
    assert error =~ "cancelled"
    assert error =~ "history://#{child.id}"
    assert {:ok, %{agent_state: :killed}} = TaskStore.get_record(child.id)
    assert %AgentToolResult{} = Messaging.read("agent://#{child.id}", child.opts)

    assert %AgentToolResult{} =
             Read.execute(
               "history",
               %{"path" => "history://#{child.id}"},
               nil,
               nil,
               cwd,
               child.opts
             )

    refute_receive {:model_call, 2, _, _}
  end

  @tag :tmp_dir
  test "a removed workspace cannot be revived", %{tmp_dir: cwd} do
    worktree = Path.join(cwd, "worktree")
    File.mkdir_p!(worktree)
    child = launch(worktree, idle_ttl_ms: 20)
    assert_phase(child.id, :parked)
    File.rm_rf!(worktree)
    assert {:error, error} = Messaging.send(child.id, "Do not recreate the worktree", child.opts)
    assert error =~ "workspace/worktree was removed"
    assert error =~ "history://#{child.id}"
    refute File.exists?(worktree)
    refute_receive {:model_call, 2, _, _}
  end

  @tag :tmp_dir
  test "missing transcripts fail without opening a replacement session", %{tmp_dir: cwd} do
    child = launch(cwd, idle_ttl_ms: 20)
    assert_phase(child.id, :parked)
    File.rm!(child.session_file)
    assert {:error, error} = Messaging.send(child.id, "Do not lose prior context", child.opts)
    assert error =~ "transcript is unavailable"
    assert error =~ "history://#{child.id}"
    refute_receive {:model_call, 2, _, _}
  end

  @tag :tmp_dir
  test "failed revival admission reports failed and releases the idle session", %{tmp_dir: cwd} do
    child = launch(cwd, idle_ttl_ms: 0)
    entry = :sys.get_state(Control)[child.id]
    context = put_in(entry.continuation.lifecycle[:task_supervisor], :missing_revive_supervisor)
    Control.configure(child.id, context)

    assert %AgentToolResult{is_error: true, details: %{status: "failed", delivery: "failed"}} =
             Messaging.send(child.id, "Admission must fail", child.opts)

    assert_process_dead(child.session)
    assert {:ok, %{status: :error, agent_state: :aborted}} = TaskStore.get_record(child.id)
    assert {:error, error} = Messaging.send(child.id, "No resurrection after failure", child.opts)
    assert error =~ "history://#{child.id}"
    refute_receive {:model_call, 2, _, _}
  end

  @tag :tmp_dir
  test "concurrent messages to a parked child coalesce into one revived session", %{tmp_dir: cwd} do
    child = launch(cwd, idle_ttl_ms: 20, block_second: true)
    assert_phase(child.id, :parked)

    receipts =
      1..8
      |> Enum.map(fn n ->
        Task.async(fn -> Messaging.send(child.id, "message #{n}", child.opts) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    deliveries = Enum.map(receipts, & &1.details.delivery)
    assert Enum.count(deliveries, &(&1 == "revived")) == 1
    assert Enum.count(deliveries, &(&1 == "injected")) == 7
    assert_receive {:stream_blocked, producer}, 5_000
    assert {:ok, session} = CodingAgent.lookup_session(child.session_id)
    entry = :sys.get_state(Control)[child.id]
    assert entry.session == session
    assert is_pid(entry.worker)
    assert Process.alive?(entry.worker)
    send(producer, :release_stream)
    assert_receive {:child_reply, _}, 5_000

    assert_eventually(fn ->
      {:ok, record} = TaskStore.get_record(child.id)
      record.status == :completed
    end)

    assert_phase(child.id, :parked)
    assert_process_dead(session)
    {:ok, stored} = CodingAgent.SessionManager.load_from_file(child.session_file)
    transcript = Jason.encode!(CodingAgent.SessionManager.build_session_context(stored).messages)
    for n <- 1..8, do: assert(transcript =~ "message #{n}")
  end

  defp launch(cwd, options) do
    owner = self()
    count = :atomics.new(1, [])
    opts = [parent_session: "parent-#{System.unique_integer([:positive])}", session_pid: owner]
    run_id = RunGraph.new_run(%{type: :task, description: "Lifecycle child"})

    id =
      TaskStore.new_task(%{
        owner: Control.owner(opts),
        name: "Worker",
        prompt: "original assignment",
        run_id: run_id
      })

    signal = AbortSignal.new()

    stream_fn = fn model, context, stream_options ->
      n = :atomics.add_get(count, 1, 1)
      send(owner, {:model_call, n, model, context})
      response = Mocks.assistant_message("answer-#{n}")

      stream =
        cond do
          n == 1 -> Mocks.blocking_stream_fn(response, owner, tag: :initial_stream)
          options[:block_second] == true and n == 2 -> Mocks.blocking_stream_fn(response, owner)
          true -> Mocks.mock_stream_fn_single(response)
        end

      stream.(model, context, stream_options)
    end

    lifecycle = %{
      signal: signal,
      description: "Lifecycle child",
      parent_session_pid: owner,
      run_id: run_id
    }

    followup = %{
      auto_followup: false,
      session_pid: owner,
      session_module: Parent,
      queue_mode: :followup
    }

    start_opts = [
      cwd: cwd,
      workspace_dir: cwd,
      register: true,
      tools: [],
      model: Mocks.mock_model(),
      stream_fn: stream_fn
    ]

    runner_opts = [task_id: id, idle_ttl_ms: options[:idle_ttl_ms], task_session_poll_ms: 10]

    assert :ok =
             Async.run_async(
               id,
               run_id,
               fn ->
                 Runner.start_session_with_prompt(
                   start_opts,
                   "original assignment",
                   "Lifecycle child",
                   signal,
                   nil,
                   nil,
                   runner_opts
                 )
               end,
               followup,
               lifecycle
             )

    assert_receive {:model_call, 1, _, _}, 5_000
    assert_receive {:initial_stream, producer}, 5_000
    session = :sys.get_state(Control)[id].session
    send(producer, :release_stream)

    assert_eventually(
      fn ->
        {:ok, record} = TaskStore.get_record(id)
        record[:agent_state] in [:idle, :parked]
      end,
      timeout: 5_000
    )

    {:ok, record} = TaskStore.get_record(id)

    on_exit(fn ->
      Control.command(id, "cancel", nil, opts)
      Control.complete(id)
      TaskStore.delete_task(id)
    end)

    %{
      id: id,
      opts: opts,
      session: session,
      session_id: record.session_id,
      session_file: record.session_file
    }
  end

  defp assert_phase(id, phase) do
    assert_eventually(
      fn ->
        case TaskStore.get_record(id) do
          {:ok, record} -> record[:agent_state] == phase
          _ -> false
        end
      end,
      timeout: 5_000
    )
  end
end
