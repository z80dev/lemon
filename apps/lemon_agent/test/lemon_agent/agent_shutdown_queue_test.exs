defmodule LemonAgent.AgentShutdownQueueTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Agent, as: CoreAgent
  alias LemonAgent.Test.Mocks

  test "terminal notification does not permit a second loop before task completion" do
    state = running_state()
    {:noreply, state} = CoreAgent.handle_info({:agent_event, {:agent_end, []}}, state)

    {:reply, {:error, :already_streaming}, unchanged} =
      CoreAgent.handle_call({:prompt, "overlap"}, nil, state)

    assert unchanged.running_task == state.running_task
  end

  test "follow-up before the closing handshake is consumed in this run" do
    state = running_state()
    message = Mocks.user_message("follow-up")
    {:reply, :ok, state} = CoreAgent.handle_call({:follow_up, message}, nil, state)
    ref = make_ref()

    {:noreply, state} =
      CoreAgent.handle_info({:loop_queue, self(), ref, state.abort_ref, :follow_up}, state)

    assert_receive {:loop_queue, ^ref, [^message]}
    refute state.loop_closing
    assert state.follow_up_queue == []
  end

  for boundary <- [:closing_reply, :terminal_event, :task_completion] do
    test "follow-up at #{boundary} starts the next run without a timer" do
      parent = self()

      stream_fn = fn _model, context, _options ->
        send(parent, {:next_run, context.messages})
        {:error, :test_complete}
      end

      state = running_state(stream_fn)
      closing_ref = make_ref()

      {:noreply, state} =
        CoreAgent.handle_info(
          {:loop_queue, self(), closing_ref, state.abort_ref, :follow_up},
          state
        )

      assert_receive {:loop_queue, ^closing_ref, []}
      assert state.loop_closing
      state = advance_boundary(state, unquote(boundary))
      message = Mocks.user_message("accepted at #{unquote(boundary)}")
      {:reply, :ok, state} = CoreAgent.handle_call({:follow_up, message}, nil, state)
      state = complete_task(state, unquote(boundary))
      assert state.running_task != nil

      queue_ref = make_ref()

      {:noreply, state} =
        CoreAgent.handle_info({:loop_queue, self(), queue_ref, state.abort_ref, :steering}, state)

      assert_receive {:loop_queue, ^queue_ref, [^message]}
      assert state.steering_queue == []
      Process.exit(state.running_task.pid, :kill)
    end
  end

  test "withdrawal succeeds only while the stable input id is unbound" do
    state = running_state()
    message = Map.put(Mocks.user_message("steer"), :id, "steer-1")
    {:reply, :ok, state} = CoreAgent.handle_call({:steer, message}, nil, state)
    {:reply, :ok, state} = CoreAgent.handle_call({:withdraw_steer, "steer-1"}, nil, state)
    assert state.steering_queue == []

    {:reply, {:error, :not_found}, _state} =
      CoreAgent.handle_call({:withdraw_steer, "steer-1"}, nil, state)

    {:reply, :ok, state} = CoreAgent.handle_call({:steer, message}, nil, state)
    ref = make_ref()

    {:noreply, state} =
      CoreAgent.handle_info({:loop_queue, self(), ref, state.abort_ref, :steering}, state)

    assert_receive {:loop_queue, ^ref, [^message]}

    {:reply, {:error, :not_found}, _state} =
      CoreAgent.handle_call({:withdraw_steer, "steer-1"}, nil, state)
  end

  test "binding notification precedes queue delivery and withdrawal cannot cross it" do
    state = %{running_state() | listeners: [{self(), make_ref()}]}
    message = Map.put(Mocks.user_message("durable steer"), :id, "bound-input")
    {:reply, :ok, state} = CoreAgent.handle_call({:steer, message}, nil, state)
    ref = make_ref()

    {:noreply, state} =
      CoreAgent.handle_info({:loop_queue, self(), ref, state.abort_ref, :steering}, state)

    assert_receive {:agent_event, {:input_bound, ["bound-input"]}}
    assert_receive {:loop_queue, ^ref, [^message]}

    assert {:reply, {:error, :not_found}, ^state} =
             CoreAgent.handle_call({:withdraw_steer, "bound-input"}, nil, state)
  end

  test "journal replay with stable ids does not enqueue the same input twice" do
    state = running_state()
    message = Map.put(Mocks.user_message("pending"), :id, "replay-input")
    {:reply, :ok, state} = CoreAgent.handle_call({:steer, message, true}, nil, state)
    {:reply, :ok, state} = CoreAgent.handle_call({:steer, message, true}, nil, state)
    {:reply, :ok, state} = CoreAgent.handle_call({:follow_up, message, true}, nil, state)
    assert state.steering_queue == [message]
    assert state.follow_up_queue == []
    ref = make_ref()

    {:noreply, state} =
      CoreAgent.handle_info({:loop_queue, self(), ref, state.abort_ref, :steering}, state)

    assert_receive {:loop_queue, ^ref, [^message]}
    {:reply, :ok, state} = CoreAgent.handle_call({:steer, message, true}, nil, state)
    assert state.steering_queue == []
  end

  test "idle waiters span the deterministic automatic next run" do
    state = running_state(fn _model, _context, _options -> {:error, :test_complete} end)
    waiter_ref = make_ref()
    message = Mocks.user_message("next run")

    state = %{
      state
      | loop_closing: true,
        follow_up_queue: [message],
        waiters: [{:notify, self(), waiter_ref}]
    }

    state = finish(state)
    assert state.running_task != nil
    assert state.waiters == [{:notify, self(), waiter_ref}]
    refute_received {:wait_for_idle, ^waiter_ref, :ok}
    Process.exit(state.running_task.pid, :kill)
  end

  defp running_state(stream_fn \\ nil) do
    {:ok, state} =
      CoreAgent.init(initial_state: %{model: Mocks.mock_model()}, stream_fn: stream_fn)

    task = %Task{pid: self(), ref: make_ref(), owner: self(), mfa: {__MODULE__, :test, 0}}
    %{state | abort_ref: LemonAgent.AbortSignal.new(), running_task: task}
  end

  defp advance_boundary(state, :closing_reply), do: state

  defp advance_boundary(state, :terminal_event) do
    {:noreply, state} = CoreAgent.handle_info({:agent_event, {:agent_end, []}}, state)
    state
  end

  defp advance_boundary(state, :task_completion), do: finish(state)

  defp complete_task(state, :task_completion), do: state
  defp complete_task(state, _boundary), do: finish(state)

  defp finish(state) do
    {:noreply, state} = CoreAgent.handle_info({state.running_task.ref, :ok}, state)
    state
  end
end
