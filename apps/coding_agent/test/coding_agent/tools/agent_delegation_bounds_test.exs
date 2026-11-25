defmodule CodingAgent.Tools.AgentDelegationBoundsTest do
  @moduledoc """
  The `agent` tool bounds delegated children: a blocked parent lends its
  run permit, children inherit and enforce the parent's budget, and an
  aborted or timed-out parent aborts its children.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.{BudgetTracker, RunGraph, TaskStore}
  alias CodingAgent.Tools.Agent, as: AgentTool
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.{Bus, Event, RunRequest, Store}
  alias LemonPlatformTest.EventsFixtures

  defmodule Slots do
    @moduledoc false
    use GenServer

    def start_link({max, test}), do: GenServer.start_link(__MODULE__, {max, test}, name: __MODULE__)
    def acquire(run_id), do: GenServer.call(__MODULE__, {:acquire, run_id}, :infinity)
    def release(run_id), do: GenServer.call(__MODULE__, {:release, run_id})
    def lend(run_id), do: GenServer.call(__MODULE__, {:lend, run_id})
    def return(run_id, mode), do: GenServer.call(__MODULE__, {:return, run_id, mode}, :infinity)
    def stats, do: GenServer.call(__MODULE__, :stats)

    @impl true
    def init({max, test}), do: {:ok, %{max: max, test: test, active: MapSet.new(), waiting: :queue.new()}}

    @impl true
    def handle_call({:acquire, run_id}, from, state) do
      {:noreply, admit(%{state | waiting: :queue.in({run_id, from}, state.waiting)})}
    end

    def handle_call({:release, run_id}, _from, state) do
      waiting = :queue.filter(fn {id, _} -> id != run_id end, state.waiting)
      {:reply, :ok, admit(%{state | active: MapSet.delete(state.active, run_id), waiting: waiting})}
    end

    def handle_call({:lend, run_id}, _from, state) do
      if MapSet.member?(state.active, run_id) do
        send(state.test, {:slot_lent, run_id})
        {:reply, {:ok, run_id}, admit(%{state | active: MapSet.delete(state.active, run_id)})}
      else
        {:reply, :none, state}
      end
    end

    def handle_call({:return, run_id, mode}, from, state) do
      send(state.test, {:slot_returned, run_id, mode})
      waiter = if mode == :wait, do: from, else: nil
      state = admit(%{state | waiting: :queue.in_r({run_id, waiter}, state.waiting)})
      if waiter, do: {:noreply, state}, else: {:reply, :ok, state}
    end

    def handle_call(:stats, _from, state) do
      {:reply, {:ok, %{in_flight: MapSet.size(state.active), waitq: :queue.len(state.waiting), max: state.max}}, state}
    end

    defp admit(state) do
      with true <- MapSet.size(state.active) < state.max,
           {{:value, {id, waiter}}, waiting} <- :queue.out(state.waiting) do
        if waiter, do: GenServer.reply(waiter, :ok)
        admit(%{state | active: MapSet.put(state.active, id), waiting: waiting})
      else
        _ -> state
      end
    end
  end

  defmodule FakeGateway do
    @moduledoc false
    # Each submitted request must acquire a permit before executing.
    use Agent

    alias CodingAgent.Tools.AgentDelegationBoundsTest, as: Test

    def start_link(test),
      do: Agent.start_link(fn -> %{test: test, runs: %{}} end, name: __MODULE__)

    def submit(%RunRequest{run_id: run_id} = request) do
      test = Agent.get(__MODULE__, & &1.test)
      pid = spawn(fn -> run(request, test) end)
      Agent.update(__MODULE__, &put_in(&1, [:runs, run_id], pid))
      send(test, {:submitted, request})
      {:ok, run_id}
    end

    def abort_run(run_id, reason) do
      %{test: test, runs: runs} = Agent.get(__MODULE__, & &1)
      send(test, {:abort_requested, run_id, reason})

      case Map.get(runs, run_id) do
        pid when is_pid(pid) -> send(pid, {:abort, reason})
        nil -> :ok
      end

      :ok
    end

    defp run(%RunRequest{run_id: run_id, prompt: prompt}, test) do
      :ok = Slots.acquire(run_id)
      send(test, {:admitted, run_id})

      {ok, answer, error} =
        case prompt do
          "delegate:" <> rest ->
            # The child's own session delegates synchronously in turn.
            case AgentTool.execute(
                   "nested",
                   Test.params(rest),
                   nil,
                   nil,
                   "/tmp",
                   Test.opts(run_id)
                 ) do
              %AgentToolResult{} = result ->
                {true, "nested(" <> LemonAgent.get_text(result) <> ")", nil}

              {:error, message} ->
                {false, "", message}
            end

          "hang" ->
            receive do: ({:abort, reason} -> {false, "", reason})

          answer ->
            {true, "done:" <> answer, nil}
        end

      completed = %{ok: ok, answer: answer, error: error, usage: %{total_tokens: 7}}
      # Real completion is durable before notification.
      :ok = Store.finalize_run(run_id, %{completed: completed})

      Bus.broadcast(
        Bus.run_topic(run_id),
        Event.new(:run_completed, EventsFixtures.run_completed(completed: completed))
      )

      :ok = Slots.release(run_id)
      send(test, {:terminal, run_id, ok})
    end
  end

  def params(prompt, overrides \\ %{}) do
    Map.merge(
      %{"agent_id" => "worker", "prompt" => prompt, "async" => false, "timeout_ms" => 5_000},
      overrides
    )
  end

  def opts(run_id, extra \\ []) do
    Keyword.merge(
      [
        run_id: run_id,
        session_key: "agent:main:#{run_id}",
        agent_id: "main",
        run_orchestrator: FakeGateway,
        slot_lender: Slots,
        agent_tool_abort_grace_ms: 2_000
      ],
      extra
    )
  end

  setup do
    TaskStore.clear()
    RunGraph.clear()
    start_supervised!({FakeGateway, self()})
    :ok
  end

  defp start_slots(max), do: start_supervised!({Slots, {max, self()}})

  # A parent Run admitted by Slots that runs one `agent` call.
  defp parent_run(run_id, params, extra \\ []) do
    test = self()

    spawn_link(fn ->
      :ok = Slots.acquire(run_id)
      result = AgentTool.execute("call", params, extra[:signal], nil, "/tmp", opts(run_id, extra))
      :ok = Slots.release(run_id)
      send(test, {:parent_result, run_id, result})
    end)
  end

  test "two parents with sync children complete under cap 2" do
    start_slots(2)
    parent_run("parent-a", params("a"))
    parent_run("parent-b", params("b"))

    assert_receive {:parent_result, "parent-a", %AgentToolResult{} = a}, 5_000
    assert_receive {:parent_result, "parent-b", %AgentToolResult{} = b}, 5_000
    assert LemonAgent.get_text(a) == "done:a"
    assert LemonAgent.get_text(b) == "done:b"
    assert eventually(fn -> Slots.stats() == {:ok, %{in_flight: 0, waitq: 0, max: 2}} end)
  end

  test "depth-2 delegation does not deadlock, even under cap 1" do
    start_slots(1)
    parent_run("root", params("delegate:leaf"))

    assert_receive {:parent_result, "root", %AgentToolResult{} = result}, 5_000
    assert LemonAgent.get_text(result) == "nested(done:leaf)"
    assert_receive {:slot_lent, "root"}
    assert_receive {:slot_returned, "root", :wait}
    assert eventually(fn -> Slots.stats() == {:ok, %{in_flight: 0, waitq: 0, max: 1}} end)
  end

  test "aborting a parent aborts its sync child, which emits a terminal event" do
    start_slots(1)
    signal = AbortSignal.new()
    parent_run("parent", params("hang"), signal: signal)

    assert_receive {:submitted, %RunRequest{run_id: child}}
    Bus.subscribe(Bus.run_topic(child))
    assert_receive {:admitted, ^child}, 2_000
    AbortSignal.abort(signal)

    assert_receive {:abort_requested, ^child, :parent_aborted}, 2_000
    assert_receive {:terminal, ^child, false}, 2_000
    assert_receive %Event{type: :run_completed}, 2_000
    assert_receive {:parent_result, "parent", {:error, message}}, 2_000
    assert_receive {:slot_returned, "parent", :nowait}
    assert message =~ "aborted"
    assert {:ok, %{status: :error}} = RunGraph.get(child)
  end

  test "aborting the delegating run aborts its async children" do
    start_slots(2)
    signal = AbortSignal.new()

    assert %AgentToolResult{details: %{task_id: task_id, run_id: child}} =
             AgentTool.execute(
               "async",
               params("hang", %{"async" => true, "auto_followup" => false}),
               signal,
               nil,
               "/tmp",
               opts("async-parent")
             )

    assert_receive {:admitted, ^child}, 2_000
    AbortSignal.abort(signal)

    assert_receive {:abort_requested, ^child, :parent_aborted}, 2_000
    assert_receive {:terminal, ^child, false}, 2_000
    assert eventually(fn -> match?({:ok, %{status: :error}}, TaskStore.get_record(task_id)) end)
  end

  test "a sync timeout aborts the child" do
    start_slots(2)
    parent_run("timeout-parent", params("hang", %{"timeout_ms" => 50}))

    assert_receive {:submitted, %RunRequest{run_id: child}}
    assert_receive {:abort_requested, ^child, :delegation_timeout}, 2_000
    assert_receive {:terminal, ^child, false}, 2_000
    assert_receive {:parent_result, "timeout-parent", {:error, message}}, 2_000
    assert message =~ "Timed out"
  end

  test "join defaults to a bounded wait and lends the parent permit" do
    start_slots(1)
    test = self()

    spawn_link(fn ->
      :ok = Slots.acquire("joiner")

      %AgentToolResult{details: %{task_id: task_id}} =
        AgentTool.execute(
          "async",
          params("joined", %{"async" => true, "auto_followup" => false}),
          nil,
          nil,
          "/tmp",
          opts("joiner")
        )

      result =
        AgentTool.execute(
          "join",
          %{"action" => "join", "task_id" => task_id},
          nil,
          nil,
          "/tmp",
          opts("joiner")
        )

      :ok = Slots.release("joiner")
      send(test, {:joined, result})
    end)

    # Under cap 1 the child can only run while the joining parent lends its slot.
    assert_receive {:joined, %AgentToolResult{} = joined}, 5_000
    assert LemonAgent.get_text(joined) =~ "done:joined"

    assert {:error, "timeout_ms must be a non-negative integer"} =
             AgentTool.execute(
               "join",
               %{"action" => "join", "task_id" => "x", "timeout_ms" => -1},
               nil,
               nil,
               "/tmp",
               opts("joiner")
             )
  end

  describe "budget" do
    setup do
      start_slots(2)
      parent = RunGraph.new_run(%{type: :task, status: :running})
      %{parent: parent}
    end

    test "a child inherits its parent's limits and its usage is charged back", %{parent: parent} do
      :ok =
        BudgetTracker.store_budget(
          parent,
          BudgetTracker.create_budget(max_tokens: 1_000, max_cost: 2.5)
        )

      assert %AgentToolResult{} =
               AgentTool.execute("call", params("budgeted"), nil, nil, "/tmp", opts(parent))

      assert_receive {:submitted, %RunRequest{run_id: child, meta: meta}}
      # The child session receives the reservation and stops when it exceeds it.
      assert meta.delegated_budget == %{max_run_tokens: 1_000, max_run_cost_usd: 2.5}
      assert {:ok, %{parent: ^parent, status: :completed}} = RunGraph.get(child)

      assert %{active_children: 0, completed_child_ids: [^child], used_tokens: 7} =
               BudgetTracker.get_budget(parent)
    end

    test "model-supplied meta cannot set the child's budget", %{parent: parent} do
      assert %AgentToolResult{} =
               AgentTool.execute(
                 "call",
                 params("forged", %{"meta" => %{"delegated_budget" => %{"max_run_tokens" => 1}}}),
                 nil,
                 nil,
                 "/tmp",
                 opts(parent)
               )

      assert_receive {:submitted, %RunRequest{meta: meta}}
      refute Map.has_key?(meta, "delegated_budget")
      refute Map.has_key?(meta, :delegated_budget)
    end

    test "an exhausted parent budget refuses delegation before submission", %{parent: parent} do
      budget = BudgetTracker.create_budget(max_tokens: 10)
      :ok = BudgetTracker.store_budget(parent, %{budget | used_tokens: 11})

      assert {:error, message} =
               AgentTool.execute("call", params("refused"), nil, nil, "/tmp", opts(parent))

      assert message =~ "budget" or message =~ "Budget" or message =~ "Token"
      refute_receive {:submitted, _}
    end

    test "the parent's child limit bounds concurrent delegated children", %{parent: parent} do
      :ok = BudgetTracker.store_budget(parent, BudgetTracker.create_budget(max_children: 1))

      assert %AgentToolResult{details: %{run_id: first}} =
               AgentTool.execute(
                 "first",
                 params("hang", %{"async" => true, "auto_followup" => false}),
                 nil,
                 nil,
                 "/tmp",
                 opts(parent)
               )

      assert {:error, _message} =
               AgentTool.execute("second", params("refused"), nil, nil, "/tmp", opts(parent))

      assert_receive {:submitted, %RunRequest{run_id: ^first}}
      refute_receive {:submitted, _}, 50
      FakeGateway.abort_run(first, :test_cleanup)
      assert_receive {:terminal, ^first, false}, 2_000
    end
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
