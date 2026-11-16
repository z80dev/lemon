defmodule LemonAgent.Loop.QueueTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Loop.Queue
  alias LemonAgent.Types.AgentLoopConfig
  alias LemonAi.Types.UserMessage

  test "requests are run-bound, correlated and take precedence over standalone callbacks" do
    owner = self()
    queue_ref = make_ref()
    stale_ref = make_ref()
    message = %UserMessage{content: "correction", timestamp: 0}
    unexpected_callback = fn -> flunk("owner-backed queues must not invoke callbacks") end

    config = %AgentLoopConfig{
      hooks: %{queue_owner: owner, queue_ref: queue_ref},
      get_steering_messages: unexpected_callback,
      has_steering_messages: unexpected_callback,
      get_follow_up_messages: unexpected_callback
    }

    task =
      Task.async(fn ->
        send(self(), {:loop_queue, stale_ref, [:stale]})
        steering = Queue.steering(config)
        has_steering = Queue.has_steering?(config)
        follow_up = Queue.follow_up(config)

        assert_received {:loop_queue, ^stale_ref, [:stale]}
        {steering, has_steering, follow_up}
      end)

    assert_receive {:loop_queue, loop_pid, steering_ref, ^queue_ref, :steering}
    assert loop_pid == task.pid
    send(loop_pid, {:loop_queue, steering_ref, [message]})

    assert_receive {:loop_queue, ^loop_pid, peek_ref, ^queue_ref, :has_steering}
    refute peek_ref == steering_ref
    send(loop_pid, {:loop_queue, peek_ref, false})

    assert_receive {:loop_queue, ^loop_pid, follow_up_ref, ^queue_ref, :follow_up}
    refute follow_up_ref in [steering_ref, peek_ref]
    send(loop_pid, {:loop_queue, follow_up_ref, []})

    assert Task.await(task) == {[message], false, []}
  end

  test "owner death fails closed rather than reporting an empty queue" do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:loop_queue, _loop_pid, _request_ref, _queue_ref, :follow_up} ->
            send(parent, :request_received)
        end
      end)

    config = %AgentLoopConfig{hooks: %{queue_owner: owner, queue_ref: make_ref()}}
    task = Task.async(fn -> catch_exit(Queue.follow_up(config)) end)

    assert_receive :request_received
    assert Task.await(task) == {:loop_queue_failed, {:owner_down, :normal}}
  end

  test "a missing reply fails at the configured deadline without consuming other messages" do
    config = %AgentLoopConfig{
      hooks: %{queue_owner: self(), queue_ref: make_ref(), queue_timeout: 0}
    }

    monitors_before = Process.info(self(), :monitors)
    send(self(), :unrelated)

    assert catch_exit(Queue.steering(config)) == {:loop_queue_failed, :timeout}
    assert_received {:loop_queue, loop_pid, request_ref, queue_ref, :steering}
    assert loop_pid == self()
    assert is_reference(request_ref)
    assert queue_ref == config.hooks.queue_ref
    assert_received :unrelated
    assert Process.info(self(), :monitors) == monitors_before
  end

  test "standalone loops retain their callback API without a queue owner" do
    assert Queue.steering(%AgentLoopConfig{}) == []
    refute Queue.has_steering?(%AgentLoopConfig{})
    assert Queue.follow_up(%AgentLoopConfig{}) == []

    message = %UserMessage{content: "standalone", timestamp: 0}

    config = %AgentLoopConfig{
      get_steering_messages: fn -> [message] end,
      has_steering_messages: fn -> true end,
      get_follow_up_messages: fn -> [message] end
    }

    assert Queue.steering(config) == [message]
    assert Queue.has_steering?(config)
    assert Queue.follow_up(config) == [message]
  end
end
