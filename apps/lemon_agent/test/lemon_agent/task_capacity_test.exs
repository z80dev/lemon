defmodule LemonAgent.TaskCapacityTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Agent, as: RuntimeAgent
  alias LemonAgent.{AutoThinking, EventStream, Loop}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}
  alias LemonAi.Types.StreamOptions

  setup do
    :ok = Supervisor.terminate_child(LemonAgent.Supervisor, LemonAgent.LoopTaskSupervisor)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(LemonAgent.Supervisor, LemonAgent.LoopTaskSupervisor)
    end)

    supervisor =
      start_supervised!(
        {LemonCore.TaskSupervisor, name: LemonAgent.LoopTaskSupervisor, max_children: 1}
      )

    {:ok, blocker} =
      LemonCore.TaskSupervisor.start_child(supervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    %{supervisor: supervisor, blocker: blocker}
  end

  for {availability, reason} <- [
        {:full, :task_capacity_reached},
        {:missing, :task_supervisor_unavailable}
      ] do
    test "prompt, continue, direct streams and classifier handle #{availability} supervision" do
      if unquote(availability) == :missing do
        stop_supervised!(LemonAgent.LoopTaskSupervisor)
      end

      reason = unquote(reason)
      parent = self()
      prompt = Mocks.user_message("existing prompt")
      model = %{Mocks.mock_model(reasoning: true) | reasoning_efforts: [:low, :medium, :high]}

      stream_fn = fn _, _, _ ->
        send(parent, :unexpected_provider)
        {:error, :unexpected_provider}
      end

      agent =
        start_supervised!(
          {RuntimeAgent, initial_state: %{model: model, messages: [prompt]}, stream_fn: stream_fn}
        )

      RuntimeAgent.subscribe(agent, self())
      before_state = RuntimeAgent.get_state(agent)
      assert {:error, ^reason} = RuntimeAgent.prompt(agent, "must not append")
      assert {:error, ^reason} = RuntimeAgent.continue(agent)
      assert RuntimeAgent.get_state(agent) == before_state
      assert :ok = RuntimeAgent.wait_for_idle(agent)
      assert Process.alive?(agent)
      refute_received {:agent_event, _}

      context = AgentContext.new(messages: [prompt])
      config = %AgentLoopConfig{model: model, convert_to_llm: Mocks.simple_convert_to_llm()}

      stream = Loop.agent_loop([prompt], context, config, nil, stream_fn)
      assert {:error, {:task_start_failed, ^reason}, nil} = EventStream.result(stream)

      assert [{:error, {:task_start_failed, ^reason}, nil}] =
               Enum.to_list(EventStream.events(stream))

      GenServer.stop(stream, :normal)

      continued = Loop.agent_loop_continue(context, config, nil, stream_fn)
      assert {:error, {:task_start_failed, ^reason}, nil} = EventStream.result(continued)
      GenServer.stop(continued, :normal)

      assert {:ok, :medium} =
               AutoThinking.resolve(model, prompt, nil,
                 resolve_classifier: fn ->
                   send(parent, :unexpected_classifier)
                   {model, %StreamOptions{}}
                 end
               )

      refute_received :unexpected_provider
      refute_received :unexpected_classifier
    end
  end

  test "a rejected inner loop ends an admitted agent run without invoking the model", %{
    supervisor: supervisor,
    blocker: blocker
  } do
    :ok = Task.Supervisor.terminate_child(supervisor, blocker)
    parent = self()

    agent =
      start_supervised!(
        {RuntimeAgent,
         initial_state: %{model: Mocks.mock_model()},
         stream_fn: fn _, _, _ ->
           send(parent, :unexpected_provider)
           {:error, :unexpected_provider}
         end}
      )

    RuntimeAgent.subscribe(agent, self())
    assert :ok = RuntimeAgent.prompt(agent, "one outer task fills the supervisor")
    assert :ok = RuntimeAgent.wait_for_idle(agent)
    assert_receive {:agent_event, {:error, {:task_start_failed, :task_capacity_reached}, nil}}
    state = RuntimeAgent.get_state(agent)
    refute state.is_streaming
    assert state.messages == []
    refute_received :unexpected_provider
  end
end
