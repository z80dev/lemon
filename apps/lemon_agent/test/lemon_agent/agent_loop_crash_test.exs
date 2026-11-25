defmodule LemonAgent.AgentLoopCrashTest do
  @moduledoc """
  A run whose forwarder dies abnormally still delivers exactly one terminal
  event, leaves the agent idle and accepts the next prompt.
  """
  use ExUnit.Case, async: true

  alias LemonAgent.Agent
  alias LemonAgent.Test.Mocks

  defp start_agent(stream_fn) do
    {:ok, agent} =
      Agent.start_link(
        initial_state: %{
          system_prompt: "You are helpful.",
          model: Mocks.mock_model(),
          tools: []
        },
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_fn: stream_fn
      )

    on_exit(fn -> if Process.alive?(agent), do: Process.exit(agent, :kill) end)
    agent
  end

  defp blocking_then_reply_stream_fn(parent) do
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    fn model, context, options ->
      case Elixir.Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          Mocks.blocking_stream_fn(Mocks.assistant_message("never"), parent, chunks: 1).(
            model,
            context,
            options
          )

        _ ->
          Mocks.mock_stream_fn_single(Mocks.assistant_message("second")).(
            model,
            context,
            options
          )
      end
    end
  end

  defp running_task(agent) do
    Enum.find_value(1..100, fn _ ->
      case :sys.get_state(agent).running_task do
        %Task{} = task ->
          task

        _ ->
          Process.sleep(10)
          nil
      end
    end) || flunk("running_task did not start")
  end

  defp terminal?({:agent_end, _}), do: true
  defp terminal?({:error, _, _}), do: true
  defp terminal?({:canceled, _}), do: true
  defp terminal?(_), do: false

  defp collect_terminals(acc, timeout) do
    receive do
      {:agent_event, event} ->
        if terminal?(event),
          do: collect_terminals([event | acc], timeout),
          else: collect_terminals(acc, timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  test "killing the forwarder mid-stream delivers one loop_crashed terminal and idles the agent" do
    agent = start_agent(blocking_then_reply_stream_fn(self()))
    _unsubscribe = Agent.subscribe(agent, self())

    :ok = Agent.prompt(agent, "hello")
    assert_receive {:stream_blocked, producer}, 2_000
    on_exit(fn -> send(producer, :release_stream) end)

    %Task{pid: forwarder} = running_task(agent)
    Process.exit(forwarder, :kill)

    assert_receive {:agent_event, {:error, {:loop_crashed, :killed}, %{}}}, 1_000
    assert collect_terminals([], 200) == []

    assert :ok = Agent.wait_for_idle(agent, 1_000)
    state = Agent.get_state(agent)
    refute state.is_streaming
    assert state.error == "Agent loop crashed (killed)"

    # The agent accepts and completes the next run.
    :ok = Agent.prompt(agent, "again")
    assert_receive {:agent_event, {:agent_end, _messages}}, 2_000
    assert :ok = Agent.wait_for_idle(agent, 1_000)
    refute Agent.get_state(agent).is_streaming
  end

  test "a forwarder exit after its terminal event emits no second terminal" do
    agent = start_agent(blocking_then_reply_stream_fn(self()))
    _unsubscribe = Agent.subscribe(agent, self())

    :ok = Agent.prompt(agent, "hello")
    assert_receive {:stream_blocked, producer}, 2_000
    on_exit(fn -> send(producer, :release_stream) end)

    %Task{pid: forwarder} = running_task(agent)

    # The run's terminal event is delivered, then a stray duplicate, then the
    # forwarder dies before its task result.
    send(agent, {:agent_event, {:agent_end, []}})
    send(agent, {:agent_event, {:error, :late_duplicate, %{}}})
    Process.exit(forwarder, :kill)

    assert collect_terminals([], 300) == [{:agent_end, []}]
    assert :ok = Agent.wait_for_idle(agent, 1_000)

    state = Agent.get_state(agent)
    refute state.is_streaming
    assert state.error == nil
  end
end
