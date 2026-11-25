defmodule LemonAgent.LoopAbortTest do
  @moduledoc """
  Abort-signal handling in `LemonAgent.Loop`: while the provider streams, before
  and between turns, and while tools run.

  `AbortSignal` itself is covered by `abort_signal*_test.exs`; tool-batch
  cancellation internals by `loop/tool_calls_test.exs` and
  `loop/cancellation_notifications_test.exs`.
  """
  use ExUnit.Case, async: true

  alias LemonAgent.AbortSignal
  alias LemonAgent.EventStream
  alias LemonAgent.Loop
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}

  alias LemonAi.Types.{StreamOptions, TextContent, UserMessage}

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp simple_context(opts \\ []) do
    AgentContext.new(
      system_prompt: "You are a helpful assistant.",
      tools: Keyword.get(opts, :tools, [])
    )
  end

  defp simple_config(opts) do
    %AgentLoopConfig{
      model: Mocks.mock_model(),
      convert_to_llm: Mocks.simple_convert_to_llm(),
      transform_context: Keyword.get(opts, :transform_context, nil),
      get_steering_messages: Keyword.get(opts, :get_steering_messages, nil),
      get_follow_up_messages: Keyword.get(opts, :get_follow_up_messages, nil),
      stream_options: %StreamOptions{},
      stream_fn: Keyword.get(opts, :stream_fn, nil)
    }
  end

  defp tool_turn_stream_fn(tool_calls) do
    Mocks.mock_stream_fn([
      Mocks.assistant_message_with_tool_calls(tool_calls),
      Mocks.assistant_message("Done")
    ])
  end

  defp tool(name, execute) do
    %AgentTool{
      name: name,
      description: name,
      parameters: %{"type" => "object", "properties" => %{}},
      label: name,
      execute: execute
    }
  end

  defp user_message(text) do
    %UserMessage{
      role: :user,
      content: text,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp collect_events_and_result(stream, timeout \\ 5000) do
    events_task = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
    result = EventStream.result(stream, timeout)
    {Task.await(events_task, timeout), result}
  end

  defp message_end_messages(events) do
    for {:message_end, message} <- events, do: message
  end

  defp assistant_messages(events) do
    Enum.filter(message_end_messages(events), &(Map.get(&1, :role) == :assistant))
  end

  defp assert_aborted_run({events, result}) do
    assert {:error, {:canceled, :assistant_aborted}} = result
    assert {:agent_start} = hd(events)
    refute Enum.any?(events, &match?({:agent_end, _}, &1))
    events
  end

  # ============================================================================
  # Abort Around the Provider Stream
  # ============================================================================

  describe "abort around the provider stream" do
    test "abort while the provider stream is stalled ends the run with an aborted assistant" do
      for opts <- [[chunks: 2], [before_start: true]] do
        response = Mocks.assistant_message("Partial response being streamed...")
        config = simple_config(stream_fn: Mocks.blocking_stream_fn(response, self(), opts))
        signal = AbortSignal.new()

        stream = Loop.agent_loop([user_message("Start")], simple_context(), config, signal, nil)

        assert_receive {:stream_blocked, _producer}, 5_000
        AbortSignal.abort(signal)

        events = stream |> collect_events_and_result() |> assert_aborted_run()

        assert [%{stop_reason: :aborted, error_message: error_message}] =
                 assistant_messages(events)

        assert error_message =~ "canceled"
      end
    end

    test "a pre-aborted signal short-circuits before transform, steering or stream_fn" do
      parent = self()
      steering_calls = :counters.new(1, [:atomics])

      config =
        simple_config(
          transform_context: fn _messages, _signal -> {:error, :transform_should_not_win} end,
          get_steering_messages: fn ->
            :counters.add(steering_calls, 1, 1)
            []
          end,
          stream_fn: fn _model, _context, _options ->
            send(parent, :stream_fn_called)
            {:error, :should_not_be_called}
          end
        )

      signal = AbortSignal.new()
      :ok = AbortSignal.abort(signal)

      stream = Loop.agent_loop([user_message("Test")], simple_context(), config, signal, nil)

      events = stream |> collect_events_and_result() |> assert_aborted_run()

      assert assistant_messages(events) == []
      assert :counters.get(steering_calls, 1) <= 1
      refute_receive :stream_fn_called, 100
    end

    test "transform_context receives the run's abort signal" do
      parent = self()

      config =
        simple_config(
          transform_context: fn messages, signal ->
            send(parent, {:transform_signal, signal})
            messages
          end,
          stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("Response"))
        )

      signal = AbortSignal.new()
      stream = Loop.agent_loop([user_message("Test")], simple_context(), config, signal, nil)

      assert {:ok, _messages} = EventStream.result(stream)
      assert_receive {:transform_signal, ^signal}
    end

    test "abort raised while transforming context cancels the turn" do
      signal = AbortSignal.new()

      config =
        simple_config(
          transform_context: fn messages, _signal ->
            AbortSignal.abort(signal)
            messages
          end,
          stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("Response"))
        )

      stream = Loop.agent_loop([user_message("Test")], simple_context(), config, signal, nil)

      events = stream |> collect_events_and_result() |> assert_aborted_run()
      assert Enum.all?(assistant_messages(events), &(&1.stop_reason == :aborted))
    end

    test "multiple loops can use different abort signals independently" do
      signal1 = AbortSignal.new()
      signal2 = AbortSignal.new()

      config1 =
        simple_config(
          stream_fn:
            Mocks.blocking_stream_fn(Mocks.assistant_message("Response 1"), self(), tag: :stream1)
        )

      config2 =
        simple_config(
          stream_fn:
            Mocks.blocking_stream_fn(Mocks.assistant_message("Response 2"), self(), tag: :stream2)
        )

      stream1 = Loop.agent_loop([user_message("Test 1")], simple_context(), config1, signal1, nil)
      stream2 = Loop.agent_loop([user_message("Test 2")], simple_context(), config2, signal2, nil)

      assert_receive {:stream1, _producer1}, 5_000
      assert_receive {:stream2, producer2}, 5_000

      # Abort only stream1; stream2 keeps running until its producer is released
      AbortSignal.abort(signal1)

      events1 = stream1 |> collect_events_and_result() |> assert_aborted_run()
      send(producer2, :release_stream)

      assert {:ok, messages2} = EventStream.result(stream2)
      assert [%{stop_reason: :aborted}] = assistant_messages(events1)
      assert [%{stop_reason: :stop}] = Enum.filter(messages2, &(&1.role == :assistant))
      refute AbortSignal.aborted?(signal2)
    end
  end

  # ============================================================================
  # Abort Between Turns
  # ============================================================================

  describe "abort between turns" do
    test "abort after a turn completes prevents the follow-up turn" do
      follow_up_calls = :counters.new(1, [])
      parent = self()

      config =
        simple_config(
          stream_fn:
            Mocks.mock_stream_fn([
              Mocks.assistant_message("First response"),
              Mocks.assistant_message("Second response")
            ]),
          get_follow_up_messages: fn ->
            send(parent, {:follow_up_started, self()})

            receive do
              :release_follow_up -> :ok
            after
              1_000 -> :ok
            end

            :ok = :counters.add(follow_up_calls, 1, 1)
            if :counters.get(follow_up_calls, 1) == 1, do: [user_message("Follow up")], else: []
          end
        )

      signal = AbortSignal.new()
      stream = Loop.agent_loop([user_message("Start")], simple_context(), config, signal, nil)

      assert_receive {:follow_up_started, follow_up_pid}, 5_000
      AbortSignal.abort(signal)
      send(follow_up_pid, :release_follow_up)

      events = stream |> collect_events_and_result() |> assert_aborted_run()
      assert :counters.get(follow_up_calls, 1) == 1

      refute Enum.any?(assistant_messages(events), fn msg ->
               msg.content == [%TextContent{type: :text, text: "Second response"}]
             end)
    end

    test "steering messages returned after abort are not executed" do
      signal = AbortSignal.new()
      steering_calls = :counters.new(1, [:atomics])

      config =
        simple_config(
          get_steering_messages: fn ->
            :counters.add(steering_calls, 1, 1)
            AbortSignal.abort(signal)
            [user_message("This should be ignored")]
          end,
          stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("First response"))
        )

      stream = Loop.agent_loop([user_message("Test")], simple_context(), config, signal, nil)

      events = stream |> collect_events_and_result() |> assert_aborted_run()

      assert Enum.all?(assistant_messages(events), &(&1.stop_reason == :aborted))

      refute Enum.any?(message_end_messages(events), fn msg ->
               Map.get(msg, :role) == :user and msg.content == "This should be ignored"
             end)

      assert :counters.get(steering_calls, 1) == 1
    end
  end

  # ============================================================================
  # Abort During Tool Execution
  # ============================================================================

  describe "abort during tool execution" do
    test "external stream cancel propagates abort signal to in-flight tool work" do
      parent = self()
      tool_supervisor = start_supervised!({Task.Supervisor, []})

      signaling_tool =
        tool("signaling_tool", fn _id, _params, signal, _on_update ->
          send(parent, {:tool_ready, self()})

          receive do
            :report_signal -> send(parent, {:tool_signal, signal})
          end

          receive do
            :check_abort ->
              if AbortSignal.aborted?(signal), do: send(parent, :tool_observed_abort)
          end

          %AgentToolResult{content: [%TextContent{type: :text, text: "done"}]}
        end)

      tool_response =
        Mocks.assistant_message_with_tool_calls([
          Mocks.tool_call("signaling_tool", %{}, id: "call_signal")
        ])

      config =
        simple_config(
          stream_fn: fn _model, llm_context, _options ->
            if Enum.any?(llm_context.messages, &(Map.get(&1, :role) == :tool_result)) do
              send(parent, :unexpected_model_call_after_cancel)
              {:error, :unexpected_model_call_after_cancel}
            else
              {:ok, response_stream} = LemonAi.EventStream.start_link(timeout: :infinity)
              :ok = LemonAi.EventStream.push(response_stream, {:start, tool_response})

              :ok =
                LemonAi.EventStream.push(
                  response_stream,
                  {:done, tool_response.stop_reason, tool_response}
                )

              :ok = LemonAi.EventStream.complete(response_stream, tool_response)
              {:ok, response_stream}
            end
          end
        )

      config = %{config | tool_task_supervisor: tool_supervisor}
      signal = AbortSignal.new()
      context = simple_context(tools: [signaling_tool])

      stream = Loop.agent_loop([user_message("Run")], context, config, signal, nil)
      on_exit(fn -> EventStream.cancel(stream, :test_cleanup) end)
      events_task = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)

      # Startup is not the cancellation deadline. Keep the tool blocked until
      # both the test and the loop have reached the in-flight tool phase.
      assert_receive {:tool_ready, tool_pid}, 5000
      tool_ref = Process.monitor(tool_pid)

      try do
        send(tool_pid, :report_signal)
        assert_receive {:tool_signal, ^signal}, 1000
        EventStream.cancel(stream, :user_abort)
        # A result call from the same sender is a barrier for the cancel cast.
        result = EventStream.result(stream, 5000)
        refute match?({:ok, _}, result)
        assert AbortSignal.aborted?(signal)

        # Check from inside the still-running tool, without polling or a timer
        # that could let it finish before the cancellation arrives.
        send(tool_pid, :check_abort)
        assert_receive :tool_observed_abort, 5000
        assert_receive {:DOWN, ^tool_ref, :process, ^tool_pid, :normal}, 5000

        events = Task.await(events_task, 5000)
        refute Enum.any?(events, &match?({:agent_end, _}, &1))
        refute_received :unexpected_model_call_after_cancel
      after
        if Process.alive?(tool_pid) do
          Task.Supervisor.terminate_child(tool_supervisor, tool_pid)
        end

        Process.demonitor(tool_ref, [:flush])
        Task.shutdown(events_task, :brutal_kill)
      end
    end

    test "abort terminates an uncooperative tool and settles every call as aborted" do
      parent = self()

      slow_tool =
        tool("uncooperative", fn id, _params, _signal, _on_update ->
          send(parent, {:tool_started, id, self()})
          Process.sleep(30_000)
          send(parent, {:tool_finished, id})
          %AgentToolResult{content: [%TextContent{type: :text, text: "Complete"}]}
        end)

      calls = [
        Mocks.tool_call("uncooperative", %{}, id: "call_running"),
        Mocks.tool_call("uncooperative", %{}, id: "call_queued")
      ]

      config = simple_config(stream_fn: tool_turn_stream_fn(calls))
      signal = AbortSignal.new()
      context = simple_context(tools: [slow_tool])

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      assert_receive {:tool_started, "call_running", worker}, 5_000
      worker_monitor = Process.monitor(worker)
      :ok = AbortSignal.abort(signal)

      events = stream |> collect_events_and_result() |> assert_aborted_run()

      # A worker that cannot finish within the cleanup grace is terminated,
      # not reported as a successful result or an implicitly rolled-back mutation.
      assert [
               {:tool_execution_end, "call_running", _, running, true},
               {:tool_execution_end, "call_queued", _, queued, true}
             ] = for({:tool_execution_end, _, _, _, _} = event <- events, do: event)

      assert %AgentToolResult{
               details: %{
                 cancelled: true,
                 started: true,
                 outcome: :unknown,
                 reason: :aborted,
                 error_type: :aborted
               }
             } = running

      assert Enum.any?(
               running.content,
               &String.contains?(
                 &1.text,
                 "Do not assume it did not run or automatically repeat it."
               )
             )

      assert %AgentToolResult{details: %{outcome: :not_started, reason: :aborted}} = queued
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
      refute_received {:tool_started, "call_queued", _}
      refute_received {:tool_finished, _}
    end

    test "tool results collected before abort are preserved in final messages" do
      instant_tool =
        tool("instant_tool", fn _id, _params, _signal, _on_update ->
          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Instant result"}],
            details: %{preserved: true}
          }
        end)

      delayed_tool =
        tool("delayed_tool", fn _id, _params, _signal, _on_update ->
          Process.sleep(5_000)
          %AgentToolResult{content: [%TextContent{type: :text, text: "Delayed result"}]}
        end)

      calls = [
        Mocks.tool_call("instant_tool", %{}, id: "call_instant"),
        Mocks.tool_call("delayed_tool", %{}, id: "call_delayed")
      ]

      config = simple_config(stream_fn: tool_turn_stream_fn(calls))
      signal = AbortSignal.new()
      context = simple_context(tools: [instant_tool, delayed_tool])

      stream = Loop.agent_loop([user_message("Run both")], context, config, signal, nil)

      events_task =
        Task.async(fn ->
          stream
          |> EventStream.events()
          |> Enum.map(fn event ->
            if match?({:tool_execution_end, "call_instant", _, _, false}, event),
              do: AbortSignal.abort(signal)

            event
          end)
        end)

      result = EventStream.result(stream, 5000)
      events = Task.await(events_task, 5000)
      assert {:error, {:canceled, :assistant_aborted}} = result

      tool_results =
        for %{role: :tool_result} = message <- message_end_messages(events),
            do: {message.tool_call_id, message.is_error}

      assert tool_results == [{"call_instant", false}, {"call_delayed", true}]
    end
  end
end
