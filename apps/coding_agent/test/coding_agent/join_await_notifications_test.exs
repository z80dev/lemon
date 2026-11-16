defmodule CodingAgent.JoinAwaitNotificationsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{JoinAwait, ParentQuestions, RunGraph, TaskStore}
  alias LemonCore.Bus

  setup do
    run = RunGraph.new_run(%{status: :running})
    task = TaskStore.new_task(%{run_id: run, status: :running})

    on_exit(fn ->
      TaskStore.delete_task(task)
      RunGraph.delete_run(run)
    end)

    %{run: run, task: task}
  end

  test "an infinite join blocks in receive and wakes on run publication", %{run: run, task: task} do
    waiter = start_join(run, task)
    await_receive(waiter.pid)
    assert :ok = RunGraph.finish(run, :finished)
    assert {:ok, %{runs: [%{id: ^run, result: :finished}]}} = Task.await(waiter)
  end

  test "a subsequent child turn wakes from TaskStore without changing the terminal graph", %{
    run: run,
    task: task
  } do
    RunGraph.finish(run, :original)
    TaskStore.finish(task, :original)
    TaskStore.set_agent_state(task, :idle)
    assert :ok = TaskStore.begin_agent_turn(task)

    waiter = start_join(run, task)
    await_receive(waiter.pid)
    TaskStore.finish(task, :next_turn)

    assert {:ok, %{runs: [%{id: ^run, result: :next_turn}]}} = Task.await(waiter)
    assert {:ok, %{result: :original}} = RunGraph.get(run)
  end

  test "parent delivery acknowledgement wakes a join already waiting for the child", %{
    run: run,
    task: task
  } do
    assert {:ok, question} =
             ParentQuestions.request(%{
               child_scope_id: run,
               child_run_id: run,
               task_id: task,
               parent_session_key: "notification-parent-#{run}",
               parent_agent_id: "parent",
               question: "Which option?",
               why_blocked: "Needs a decision"
             })

    on_exit(fn ->
      ParentQuestions.cancel(question.id, :test_finished)

      # Remove only this fixture, in the owner mailbox; unrelated questions
      # and their durable records are left intact.
      :sys.replace_state(CodingAgent.ParentQuestionStoreServer, fn state ->
        :ets.delete(state.table, question.id)
        if state.dets_initialized, do: :dets.delete(state.dets_table, question.id)
        state
      end)
    end)

    waiter = start_join(run, task)
    await_receive(waiter.pid)
    assert :ok = ParentQuestions.mark_delivered(question.id)
    assert {:parent_question, %{id: id}} = Task.await(waiter)
    assert id == question.id
  end

  test "interruption notification checks pending input without a refresh timer", %{
    run: run,
    task: task
  } do
    input = start_supervised!({Agent, fn -> false end})
    topic = "join-interruption:#{run}"

    waiter =
      start_join(run, task,
        interruption_topic: topic,
        interrupted?: fn -> Agent.get(input, & &1) end
      )

    await_receive(waiter.pid)
    Agent.update(input, fn _ -> true end)
    Bus.broadcast(topic, {:session_coord, :steering_changed})
    assert {:yield, :interrupted} = Task.await(waiter)
    assert Agent.get(input, & &1)
  end

  test "publication between subscribing and reading cannot be missed", %{run: run, task: task} do
    parent = self()

    waiter =
      Task.async(fn ->
        JoinAwait.await([run], [task], :wait_all, nil,
          interrupted?: fn ->
            send(parent, {:subscribed, self()})

            receive do
              :continue -> false
            end
          end
        )
      end)

    assert_receive {:subscribed, pid}
    RunGraph.finish(run, :raced)
    send(pid, :continue)
    assert {:ok, %{runs: [%{result: :raced}]}} = Task.await(waiter)
  end

  # No refresh timeout or sleep drives these tests: scheduler tracing provides
  # the barrier proving the join reached its indefinite receive before mutation.
  defp start_join(run, task, opts \\ []) do
    waiter =
      Task.async(fn ->
        receive do
          :start -> JoinAwait.await([run], [task], :wait_all, nil, opts)
        end
      end)

    :erlang.trace(waiter.pid, true, [:running])
    send(waiter.pid, :start)
    waiter
  end

  defp await_receive(pid) do
    assert_receive {:trace, ^pid, :out, {JoinAwait, :wait_for_change, 4}}, 2_000
    :erlang.trace(pid, false, [:running])
  end
end
