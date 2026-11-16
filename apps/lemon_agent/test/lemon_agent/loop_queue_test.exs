defmodule LemonAgent.LoopQueueTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{AbortSignal, EventStream, Loop}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}

  test "steering and final follow-up requests preserve ordered system prompt blocks" do
    owner = self()
    signal = AbortSignal.new()
    initial = Mocks.user_message("initial")
    correction = Mocks.user_message("correction")
    follow_up = Mocks.user_message("follow-up")

    steering_prompt = [
      %{text: "stable prefix", directory_derived: false},
      %{text: "first directory", directory_derived: true}
    ]

    follow_up_prompt = [
      %{text: "stable prefix", directory_derived: false},
      %{text: "second directory", directory_derived: true}
    ]

    config = %AgentLoopConfig{
      model: Mocks.mock_model(),
      convert_to_llm: Mocks.simple_convert_to_llm(),
      hooks: %{queue_owner: owner, queue_ref: signal, emit_system_prompt: true},
      stream_fn: fn model, context, options ->
        send(owner, {:model_context, context})
        Mocks.mock_stream_fn_single(Mocks.assistant_message("done")).(model, context, options)
      end
    }

    stream = Loop.agent_loop([initial], AgentContext.new(), config, signal, nil)
    events = Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)

    assert_receive {:loop_queue, loop_pid, initial_ref, ^signal, :steering}, 2_000

    send(
      loop_pid,
      {:loop_queue, initial_ref,
       [
         %{message: correction, system_prompt: steering_prompt}
       ]}
    )

    assert_receive {:model_context, first_context}, 2_000
    assert first_context.system_prompt == steering_prompt
    assert first_context.messages == [initial, correction]

    assert_receive {:loop_queue, ^loop_pid, steering_ref, ^signal, :steering}, 2_000
    send(loop_pid, {:loop_queue, steering_ref, []})

    # The provider has finished and the final steering read was empty. Hold the
    # closing request itself and deliver newly accepted input at this boundary.
    assert_receive {:loop_queue, ^loop_pid, follow_up_ref, ^signal, :follow_up}, 2_000

    send(
      loop_pid,
      {:loop_queue, follow_up_ref,
       [
         %{message: follow_up, system_prompt: follow_up_prompt}
       ]}
    )

    assert_receive {:model_context, next_context}, 2_000
    assert next_context.system_prompt == follow_up_prompt
    assert List.last(next_context.messages) == follow_up

    assert_receive {:loop_queue, ^loop_pid, final_steering_ref, ^signal, :steering}, 2_000
    send(loop_pid, {:loop_queue, final_steering_ref, []})
    assert_receive {:loop_queue, ^loop_pid, closing_ref, ^signal, :follow_up}, 2_000
    send(loop_pid, {:loop_queue, closing_ref, []})

    emitted = Task.await(events)
    assert Enum.count(emitted, &match?({:agent_end, _}, &1)) == 1
    assert {:system_prompt, steering_prompt} in emitted
    assert {:system_prompt, follow_up_prompt} in emitted
    assert {:ok, [^initial, ^correction, _, ^follow_up, _]} = EventStream.result(stream)
  end

  test "a redirect already included by the queue read still receives a model retry" do
    owner = self()
    signal = AbortSignal.new()
    initial = Mocks.user_message("initial")
    correction = Mocks.user_message("answer the correction")

    config = %AgentLoopConfig{
      model: Mocks.mock_model(),
      convert_to_llm: Mocks.simple_convert_to_llm(),
      hooks: %{queue_owner: owner, queue_ref: signal},
      stream_fn: fn model, context, options ->
        send(owner, {:model_attempt, context.messages})

        Mocks.mock_stream_fn_single(Mocks.assistant_message("corrected answer")).(
          model,
          context,
          options
        )
      end
    }

    stream = Loop.agent_loop([initial], AgentContext.new(), config, signal, nil)
    events = Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)
    assert_receive {:loop_queue, loop_pid, initial_ref, ^signal, :steering}, 2_000

    # Acceptance races the queue read after the loop cleared the redirect flag:
    # both the correction and its flag are visible to the first model attempt.
    AbortSignal.request_redirect(signal)
    send(loop_pid, {:loop_queue, initial_ref, [correction]})
    assert_receive {:model_attempt, [^initial, ^correction]}, 2_000

    assert_receive {:loop_queue, ^loop_pid, redirect_ref, ^signal, :steering}, 2_000
    send(loop_pid, {:loop_queue, redirect_ref, []})
    assert_receive {:model_attempt, [^initial, ^correction]}, 2_000

    assert_receive {:loop_queue, ^loop_pid, steering_ref, ^signal, :steering}, 2_000
    send(loop_pid, {:loop_queue, steering_ref, []})
    assert_receive {:loop_queue, ^loop_pid, closing_ref, ^signal, :follow_up}, 2_000
    send(loop_pid, {:loop_queue, closing_ref, []})

    emitted = Task.await(events)
    assert Enum.any?(emitted, &match?({:turn_end, %{stop_reason: :redirected}, []}, &1))
    assert {:agent_end, messages} = List.last(emitted)
    assert List.last(messages).stop_reason == :stop
    assert Enum.count(messages, &(&1 == correction)) == 1
  end
end
