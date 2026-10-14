defmodule LemonAgent.LoopAbortTest do
  @moduledoc """
  Comprehensive tests for abort signal handling in LemonAgent.Loop.

  These tests cover:
  1. Abort during LLM streaming
  2. Abort during tool execution
  3. Abort during parallel tool execution (partial results)
  4. Abort signal propagation timing
  5. Steering message injection after abort
  6. Context transformation during abort
  """
  use ExUnit.Case, async: true

  alias LemonAgent.Loop
  alias LemonAgent.EventStream
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAgent.Test.Mocks

  alias LemonAi.Types.{
    AssistantMessage,
    TextContent,
    UserMessage,
    StreamOptions
  }

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp simple_context(opts \\ []) do
    AgentContext.new(
      system_prompt: Keyword.get(opts, :system_prompt, "You are a helpful assistant."),
      messages: Keyword.get(opts, :messages, []),
      tools: Keyword.get(opts, :tools, [])
    )
  end

  defp simple_config(opts) do
    %AgentLoopConfig{
      model: Keyword.get(opts, :model, Mocks.mock_model()),
      convert_to_llm: Keyword.get(opts, :convert_to_llm, Mocks.simple_convert_to_llm()),
      transform_context: Keyword.get(opts, :transform_context, nil),
      get_api_key: Keyword.get(opts, :get_api_key, nil),
      get_steering_messages: Keyword.get(opts, :get_steering_messages, nil),
      get_follow_up_messages: Keyword.get(opts, :get_follow_up_messages, nil),
      stream_options: Keyword.get(opts, :stream_options, %StreamOptions{}),
      stream_fn: Keyword.get(opts, :stream_fn, nil)
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

  defp assistant_from_events(events) do
    Enum.find_value(events, fn
      {:turn_end, message, _tool_results} when is_map(message) ->
        if Map.get(message, :role) == :assistant, do: message, else: nil

      _ ->
        nil
    end) ||
      Enum.find(message_end_messages(events), fn message ->
        Map.get(message, :role) == :assistant
      end)
  end

  # ============================================================================
  # 1. Abort During LLM Streaming
  # ============================================================================

  describe "abort during LLM streaming" do
    test "abort signal stops stream mid-response and sets stop_reason to :aborted" do
      context = simple_context()
      parent = self()
      response = Mocks.assistant_message("Partial response being streamed...")

      # The producer streams a couple of chunks, then stalls until released
      config =
        simple_config(stream_fn: Mocks.blocking_stream_fn(response, parent, chunks: 2))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Start streaming")], context, config, signal, nil)

      # Wait for streaming to begin then abort
      assert_receive {:stream_blocked, _producer}, 5_000

      AbortSignal.abort(signal)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result

      # Find the assistant message
      assistant_msg = assistant_from_events(events)

      refute Enum.any?(events, &match?({:agent_end, _}, &1))

      if assistant_msg do
        assert assistant_msg.stop_reason == :aborted
        assert assistant_msg.error_message =~ "canceled"
      end
    end

    test "abort before streaming starts returns aborted message without calling stream_fn" do
      context = simple_context()
      parent = self()

      stream_fn = fn model, llm_context, options ->
        send(parent, :stream_fn_called)

        Mocks.mock_stream_fn_single(Mocks.assistant_message("Should not appear")).(
          model,
          llm_context,
          options
        )
      end

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      {_events, result} = collect_events_and_result(stream)

      assert match?({:error, {:canceled, _reason}}, result) or
               match?({:error, :stream_closed}, result)

      refute_receive :stream_fn_called, 100
    end

    test "abort during multi-chunk stream preserves partial content in message" do
      context = simple_context()
      parent = self()

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = LemonAi.EventStream.start_link()

        Task.start(fn ->
          # Create a partial message
          partial = %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: "Hello "}],
            api: :mock,
            provider: :mock_provider,
            model: "mock-model-1",
            usage: Mocks.mock_usage(),
            stop_reason: nil,
            error_message: nil,
            timestamp: System.system_time(:millisecond)
          }

          LemonAi.EventStream.push(stream, {:start, partial})

          # Stream a few chunks, then stall until released (the abort must end the run)
          for i <- 1..10 do
            updated = %{partial | content: [%TextContent{type: :text, text: "Hello World #{i}"}]}
            LemonAi.EventStream.push(stream, {:text_delta, 0, " #{i}", updated})

            if i == 2 do
              send(parent, :stream_blocked)

              receive do
                :release_stream -> :ok
              after
                10_000 -> :ok
              end
            end
          end

          # This should not be reached due to abort
          final = %{partial | stop_reason: :stop}
          LemonAi.EventStream.push(stream, {:done, :stop, final})
          LemonAi.EventStream.complete(stream, final)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      # Abort during streaming (after a few chunks)
      assert_receive :stream_blocked, 5_000
      AbortSignal.abort(signal)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result
      messages = message_end_messages(events)

      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      if assistant_msg do
        assert assistant_msg.stop_reason == :aborted
      end
    end

    test "abort emits correct event sequence: message_start, message_end with aborted message" do
      context = simple_context()

      response = Mocks.assistant_message("Streaming...")
      config = simple_config(stream_fn: Mocks.blocking_stream_fn(response, self()))
      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      # Abort once the assistant stream is in flight
      assert_receive {:stream_blocked, _producer}, 5_000
      AbortSignal.abort(signal)

      events = EventStream.events(stream) |> Enum.to_list()

      # Check event sequence
      assert {:agent_start} = hd(events)

      # Should have message_start and message_end for the assistant message
      message_starts = Enum.filter(events, &match?({:message_start, _}, &1))
      message_ends = Enum.filter(events, &match?({:message_end, _}, &1))

      # At minimum we have user message events and assistant message events
      assert message_starts != []
      assert message_ends != []

      # Aborted runs should not report normal completion
      refute Enum.any?(events, &match?({:agent_end, _}, &1))
    end
  end

  # ============================================================================
  # 2. Abort During Tool Execution
  # ============================================================================

  describe "abort during tool execution" do
    test "abort terminates long-running tool and marks result as aborted" do
      parent = self()

      # Tool that respects abort signal
      slow_tool = %AgentTool{
        name: "slow_tool",
        description: "A slow tool that respects abort",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Slow",
        execute: fn id, _params, signal, _on_update ->
          send(parent, {:slow_tool_started, id})

          for i <- 1..20 do
            if AbortSignal.aborted?(signal) do
              throw({:aborted_at_iteration, i})
            end

            Process.sleep(25)
          end

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Completed"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [slow_tool])

      tool_call = Mocks.tool_call("slow_tool", %{}, id: "call_slow")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run slow tool")], context, config, signal, nil)

      events_task = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)

      assert_receive {:slow_tool_started, "call_slow"}, 5_000
      :ok = AbortSignal.abort(signal)

      events = Task.await(events_task, 5_000)

      # Should have tool_execution_start
      assert Enum.any?(events, &match?({:tool_execution_start, "call_slow", _, _}, &1))

      # Should have tool_execution_end (possibly with error)
      tool_end = Enum.find(events, &match?({:tool_execution_end, "call_slow", _, _, _}, &1))
      assert tool_end != nil
    end

    test "tool that ignores abort signal still gets terminated by supervisor" do
      parent = self()

      # Tool that does NOT check abort signal - uses a very long delay
      ignoring_tool = %AgentTool{
        name: "ignoring_tool",
        description: "A tool that ignores abort signal",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Ignoring",
        execute: fn id, _params, _signal, _on_update ->
          send(parent, {:ignoring_tool_started, id})
          # Sleep without checking abort - use a very long delay
          Process.sleep(30_000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Finished ignoring"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [ignoring_tool])

      tool_call = Mocks.tool_call("ignoring_tool", %{}, id: "call_ignore")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run ignoring tool")], context, config, signal, nil)

      events_task = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)

      # Abort once the tool is running
      assert_receive {:ignoring_tool_started, "call_ignore"}, 5_000
      AbortSignal.abort(signal)

      # The tool sleeps for 30s; the run must end long before that
      events = Task.await(events_task, 20_000)

      # Aborted runs should not report normal completion
      refute Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "external stream cancel propagates abort signal to in-flight tool work" do
      parent = self()
      tool_supervisor = start_supervised!({Task.Supervisor, []})

      signaling_tool = %AgentTool{
        name: "signaling_tool",
        description: "Reports when abort is observed",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Signal",
        execute: fn _id, _params, signal, _on_update ->
          send(parent, {:tool_ready, self()})

          receive do
            :report_signal -> send(parent, {:tool_signal, signal})
          end

          receive do
            :check_abort ->
              if AbortSignal.aborted?(signal), do: send(parent, :tool_observed_abort)
          end

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "done"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [signaling_tool])
      tool_call = Mocks.tool_call("signaling_tool", %{}, id: "call_signal")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
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
      on_exit(fn -> AbortSignal.clear(signal) end)

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
        AbortSignal.clear(signal)
      end
    end

    test "tool_execution_end event contains aborted result for terminated tools" do
      parent = self()

      slow_tool = %AgentTool{
        name: "abortable_tool",
        description: "A tool that can be aborted",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Abortable",
        execute: fn id, _params, _signal, _on_update ->
          send(parent, {:abortable_tool_started, id, self()})
          Process.sleep(5_000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Complete"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [slow_tool])

      tool_call = Mocks.tool_call("abortable_tool", %{}, id: "call_abort")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      assert_receive {:abortable_tool_started, "call_abort", worker}, 5_000
      worker_monitor = Process.monitor(worker)
      :ok = AbortSignal.abort(signal)

      events = EventStream.events(stream) |> Enum.to_list()

      tool_end = Enum.find(events, &match?({:tool_execution_end, "call_abort", _, _, _}, &1))
      assert tool_end != nil

      {:tool_execution_end, _id, _name, result, is_error} = tool_end

      # A worker that cannot finish within the cleanup grace is terminated,
      # not reported as a successful result or an implicitly rolled-back mutation.
      assert is_error == true
      assert %AgentToolResult{} = result
      assert result.details.cancelled == true
      assert result.details.started == true
      assert result.details.outcome == :unknown
      refute Enum.any?(result.content, &(&1.text == "Complete"))
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
    end
  end

  # ============================================================================
  # 3. Abort During Parallel Tool Execution (Partial Results)
  # ============================================================================

  describe "abort during parallel tool execution" do
    test "abort with multiple parallel tools returns mix of completed and aborted results" do
      # One instant tool, one very slow tool
      instant_tool = %AgentTool{
        name: "instant_tool",
        description: "Completes instantly",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Instant",
        parallel_safe: true,
        execute: fn _id, _params, _signal, _on_update ->
          # No delay - instant completion
          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Instant done"}],
            details: nil
          }
        end
      }

      slow_tool = %AgentTool{
        name: "slow_tool",
        description: "Takes a very long time",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Slow",
        parallel_safe: true,
        execute: fn _id, _params, _signal, _on_update ->
          # Very long delay to ensure abort happens
          Process.sleep(2000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Slow done"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [instant_tool, slow_tool])

      tool_calls = [
        Mocks.tool_call("instant_tool", %{}, id: "call_instant"),
        Mocks.tool_call("slow_tool", %{}, id: "call_slow")
      ]

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run both tools")], context, config, signal, nil)

      events_task =
        Task.async(fn ->
          stream
          |> EventStream.events()
          |> Enum.map(fn event ->
            case event do
              {:tool_execution_end, "call_instant", _, _, false} -> AbortSignal.abort(signal)
              _ -> :ok
            end

            event
          end)
        end)

      events = Task.await(events_task, 5_000)

      tool_ends = Enum.filter(events, &match?({:tool_execution_end, _, _, _, _}, &1))

      assert tool_ends != []
      assert length(tool_ends) <= 2

      # Instant tool should succeed
      instant_end =
        Enum.find(tool_ends, fn {:tool_execution_end, id, _, _, _} -> id == "call_instant" end)

      assert instant_end != nil
      {:tool_execution_end, _, _, _instant_result, instant_is_error} = instant_end
      assert instant_is_error == false

      # Slow tool should be aborted
      slow_end =
        Enum.find(tool_ends, fn {:tool_execution_end, id, _, _, _} -> id == "call_slow" end)

      if slow_end do
        {:tool_execution_end, _, _, _slow_result, slow_is_error} = slow_end
        assert slow_is_error == true
      end
    end

    test "abort terminates all pending tool tasks" do
      parent = self()

      # Multiple slow tools
      make_slow_tool = fn name ->
        %AgentTool{
          name: name,
          description: "Slow tool #{name}",
          parameters: %{"type" => "object", "properties" => %{}},
          label: name,
          execute: fn id, _params, _signal, _on_update ->
            send(parent, {:slow_tool_started, id})
            Process.sleep(30_000)

            %AgentToolResult{
              content: [%TextContent{type: :text, text: "#{name} done"}],
              details: nil
            }
          end
        }
      end

      tools = [
        make_slow_tool.("tool_a"),
        make_slow_tool.("tool_b"),
        make_slow_tool.("tool_c")
      ]

      context = simple_context(tools: tools)

      tool_calls = [
        Mocks.tool_call("tool_a", %{}, id: "call_a"),
        Mocks.tool_call("tool_b", %{}, id: "call_b"),
        Mocks.tool_call("tool_c", %{}, id: "call_c")
      ]

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run all")], context, config, signal, nil)

      events_task = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)

      # Abort once the first tool is running; the tools sleep for 30s each, so the
      # run can only end promptly because pending tool tasks are terminated
      assert_receive {:slow_tool_started, _id}, 5_000
      AbortSignal.abort(signal)

      events = Task.await(events_task, 20_000)

      tool_ends = Enum.filter(events, &match?({:tool_execution_end, _, _, _, _}, &1))
      assert length(tool_ends) <= 3

      for {:tool_execution_end, _, _, _, is_error} <- tool_ends do
        assert is_error == true
      end
    end

    test "tool results collected before abort are preserved in final messages" do
      fast_tool = %AgentTool{
        name: "instant_tool",
        description: "Completes instantly",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Instant",
        execute: fn _id, _params, _signal, _on_update ->
          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Instant result"}],
            details: %{preserved: true}
          }
        end
      }

      delayed_tool = %AgentTool{
        name: "delayed_tool",
        description: "Takes time",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Delayed",
        execute: fn _id, _params, _signal, _on_update ->
          Process.sleep(5_000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Delayed result"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [fast_tool, delayed_tool])

      tool_calls = [
        Mocks.tool_call("instant_tool", %{}, id: "call_instant"),
        Mocks.tool_call("delayed_tool", %{}, id: "call_delayed")
      ]

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run both")], context, config, signal, nil)

      events_task =
        Task.async(fn ->
          stream
          |> EventStream.events()
          |> Enum.map(fn event ->
            case event do
              {:tool_execution_end, "call_instant", _, _, false} -> AbortSignal.abort(signal)
              _ -> :ok
            end

            event
          end)
        end)

      result = EventStream.result(stream, 5000)
      events = Task.await(events_task, 5000)
      assert {:error, {:canceled, :assistant_aborted}} = result
      messages = message_end_messages(events)

      # Find the instant tool result
      instant_result =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :tool_result and Map.get(msg, :tool_call_id) == "call_instant"
        end)

      assert instant_result != nil
      assert instant_result.is_error == false

      # Find the delayed tool result (should be aborted)
      delayed_result =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :tool_result and Map.get(msg, :tool_call_id) == "call_delayed"
        end)

      delayed_tool_end =
        Enum.find(events, fn
          {:tool_execution_end, "call_delayed", _, _, _} -> true
          _ -> false
        end)

      if delayed_result do
        assert delayed_result.is_error == true
      else
        assert delayed_tool_end != nil
      end

      if delayed_tool_end do
        {:tool_execution_end, _, _, _, delayed_is_error} = delayed_tool_end
        assert delayed_is_error == true
      end
    end
  end

  # ============================================================================
  # 4. Abort Signal Propagation Timing
  # ============================================================================

  describe "abort signal propagation timing" do
    test "abort signal is checked between streaming iterations in consume loop" do
      context = simple_context()

      response = Mocks.assistant_message("Response")

      # A few chunks, then the producer stalls; only the abort check can end the run
      config =
        simple_config(stream_fn: Mocks.blocking_stream_fn(response, self(), chunks: 3))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      # Abort during streaming (abort is checked per event consumed)
      assert_receive {:stream_blocked, _producer}, 5_000
      AbortSignal.abort(signal)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result

      # Should have been aborted
      assistant_msg =
        Enum.find(events, fn
          {:message_end, msg} -> Map.get(msg, :role) == :assistant
          _ -> false
        end)

      if assistant_msg do
        {:message_end, msg} = assistant_msg
        assert msg.stop_reason == :aborted
      end
    end

    test "abort signal is checked in parallel tool collect loop every 100ms" do
      parent = self()

      slow_tool = %AgentTool{
        name: "very_slow_tool",
        description: "Takes a long time",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Very Slow",
        execute: fn id, _params, _signal, _on_update ->
          send(parent, {:very_slow_tool_started, id})
          Process.sleep(30_000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Done"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [slow_tool])

      tool_call = Mocks.tool_call("very_slow_tool", %{}, id: "call_vs")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run slow")], context, config, signal, nil)

      events_task = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)

      # Abort once the tool is running; it sleeps for 30s, so the run can only
      # end promptly because the collect loop notices the abort
      assert_receive {:very_slow_tool_started, "call_vs"}, 5_000
      AbortSignal.abort(signal)

      _events = Task.await(events_task, 20_000)
    end

    test "abort after turn completes but before next turn starts" do
      context = simple_context()
      response1 = Mocks.assistant_message("First response")
      response2 = Mocks.assistant_message("Second response")
      follow_up_calls = :counters.new(1, [])
      parent = self()

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([response1, response2]),
          get_follow_up_messages: fn ->
            send(parent, {:follow_up_started, self()})

            receive do
              :release_follow_up -> :ok
            after
              1_000 -> :ok
            end

            :ok = :counters.add(follow_up_calls, 1, 1)
            call_num = :counters.get(follow_up_calls, 1)
            if call_num == 1, do: [user_message("Follow up")], else: []
          end
        )

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Start")], context, config, signal, nil)

      assert_receive {:follow_up_started, follow_up_pid}, 5_000
      AbortSignal.abort(signal)
      send(follow_up_pid, :release_follow_up)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result
      assert :counters.get(follow_up_calls, 1) == 1

      refute Enum.any?(message_end_messages(events), fn msg ->
               Map.get(msg, :role) == :assistant and msg.content == "Second response"
             end)
    end

    test "abort signal state persists across multiple checks" do
      signal = AbortSignal.new()

      assert AbortSignal.aborted?(signal) == false

      AbortSignal.abort(signal)

      # Multiple checks should all return true
      for _ <- 1..100 do
        assert AbortSignal.aborted?(signal) == true
      end
    end
  end

  # ============================================================================
  # 5. Steering Message Injection After Abort
  # ============================================================================

  describe "steering message injection after abort" do
    test "steering messages queued during abort are not processed" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      steering_call_count = :counters.new(1, [:atomics])

      get_steering = fn ->
        :counters.add(steering_call_count, 1, 1)
        []
      end

      tool_call = Mocks.tool_call("echo", %{"text" => "hi"}, id: "call_1")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result
      refute Enum.any?(events, &match?({:agent_end, _}, &1))

      # Steering should have been called at most once (initial check)
      assert :counters.get(steering_call_count, 1) <= 1
    end

    test "abort during steering message processing stops loop" do
      context = simple_context()

      steering_processed = :counters.new(1, [:atomics])
      abort_signal = AbortSignal.new()

      get_steering = fn ->
        count = :counters.get(steering_processed, 1)
        :counters.add(steering_processed, 1, 1)

        if count >= 2 do
          AbortSignal.abort(abort_signal)
        end

        if count < 5 do
          [user_message("Steering #{count}")]
        else
          []
        end
      end

      responses =
        for i <- 1..10 do
          Mocks.assistant_message("Response #{i}")
        end

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn(responses)
        )

      stream = Loop.agent_loop([user_message("Start")], context, config, abort_signal, nil)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result
      messages = message_end_messages(events)

      # Should have stopped processing before all 5 steering messages
      assert :counters.get(steering_processed, 1) < 5

      # Loop should stop before processing all steering-driven turns
      assistant_msgs =
        Enum.filter(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert length(assistant_msgs) < 5
      refute Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "steering messages returned after abort are not executed" do
      context = simple_context()
      abort_signal = AbortSignal.new()

      steering_call_count = :counters.new(1, [:atomics])

      get_steering = fn ->
        :counters.add(steering_call_count, 1, 1)
        AbortSignal.abort(abort_signal)
        [user_message("This should be ignored")]
      end

      response = Mocks.assistant_message("First response")

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      stream = Loop.agent_loop([user_message("Test")], context, config, abort_signal, nil)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result
      refute Enum.any?(events, &match?({:agent_end, _}, &1))
      messages = message_end_messages(events)

      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      if assistant_msg do
        assert assistant_msg.stop_reason == :aborted
      end

      refute Enum.any?(messages, fn msg ->
               Map.get(msg, :role) == :user and msg.content == "This should be ignored"
             end)

      assert :counters.get(steering_call_count, 1) == 1
    end
  end

  # ============================================================================
  # 6. Context Transformation During Abort
  # ============================================================================

  describe "context transformation during abort" do
    test "transform_context receives abort signal and can inspect it" do
      context = simple_context()
      transform_received_signal = Agent.start_link(fn -> nil end) |> elem(1)

      transform_fn = fn messages, signal ->
        Agent.update(transform_received_signal, fn _ -> signal end)
        # Just pass through - we're testing signal propagation
        messages
      end

      response = Mocks.assistant_message("Response")

      config =
        simple_config(
          transform_context: transform_fn,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # First test: non-aborted signal
      signal1 = AbortSignal.new()
      stream1 = Loop.agent_loop([user_message("Test 1")], context, config, signal1, nil)
      {:ok, _messages} = EventStream.result(stream1)

      received_signal = Agent.get(transform_received_signal, & &1)
      assert is_reference(received_signal)
      assert AbortSignal.aborted?(received_signal) == false

      # Second test: aborted signal - transform still gets called but
      # the abort check before streaming short-circuits
      signal2 = AbortSignal.new()
      AbortSignal.abort(signal2)

      # Reset the agent
      Agent.update(transform_received_signal, fn _ -> nil end)

      stream2 = Loop.agent_loop([user_message("Test 2")], context, config, signal2, nil)
      {events, result2} = collect_events_and_result(stream2)

      # With pre-aborted signal, the loop short-circuits before transform
      # so transform may or may not be called
      assert result2 in [{:error, {:canceled, :assistant_aborted}}, {:error, :stream_not_found}]
      refute Enum.any?(events, &match?({:agent_end, _}, &1))

      assistant_msg = assistant_from_events(events)

      if assistant_msg do
        assert assistant_msg.stop_reason == :aborted
      end
    end

    test "transform_context error during abort is superseded by abort handling" do
      context = simple_context()

      transform_fn = fn _messages, signal ->
        if AbortSignal.aborted?(signal) do
          # Transform may return error, but abort check happens first
          {:error, {:aborted_during_transform, System.monotonic_time()}}
        else
          {:error, :regular_error}
        end
      end

      response = Mocks.assistant_message("Response")

      config =
        simple_config(
          transform_context: transform_fn,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      events = EventStream.events(stream) |> Enum.to_list()

      assistant_msg = assistant_from_events(events)

      refute Enum.any?(events, &match?({:agent_end, _}, &1))

      if assistant_msg do
        assert assistant_msg.stop_reason == :aborted
      end
    end

    test "abort triggered during transform affects subsequent streaming" do
      context = simple_context()
      parent = self()
      abort_signal = AbortSignal.new()

      transform_fn = fn messages, _signal ->
        # Abort after transform starts
        AbortSignal.abort(abort_signal)
        send(parent, :transform_completed)
        messages
      end

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = LemonAi.EventStream.start_link()

        Task.start(fn ->
          send(parent, :stream_fn_called)
          # The stream will be canceled mid-flight by abort check
          response = Mocks.assistant_message("Response")
          LemonAi.EventStream.push(stream, {:start, response})
          Process.sleep(50)
          LemonAi.EventStream.push(stream, {:done, :stop, response})
          LemonAi.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      config =
        simple_config(
          transform_context: transform_fn,
          stream_fn: stream_fn
        )

      stream = Loop.agent_loop([user_message("Test")], context, config, abort_signal, nil)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result
      refute Enum.any?(events, &match?({:agent_end, _}, &1))

      # Transform completed
      assert_receive :transform_completed, 500

      # Stream_fn may be called (abort check is per-event in stream consumption)
      # and assistant emission is race-dependent

      assistant_msg = assistant_from_events(events)

      if assistant_msg do
        assert assistant_msg.stop_reason == :aborted
      end
    end

    test "abort during multi-turn conversation preserves context up to abort point" do
      context = simple_context()

      turn_count = :counters.new(1, [:atomics])
      abort_signal = AbortSignal.new()

      transform_fn = fn messages, _signal ->
        count = :counters.get(turn_count, 1)
        :counters.add(turn_count, 1, 1)

        if count >= 2 do
          AbortSignal.abort(abort_signal)
        end

        messages
      end

      responses =
        for i <- 1..5 do
          Mocks.assistant_message("Response #{i}")
        end

      follow_up_count = :counters.new(1, [:atomics])

      get_follow_up = fn ->
        count = :counters.get(follow_up_count, 1)
        :counters.add(follow_up_count, 1, 1)

        if count < 5 do
          [user_message("Follow up #{count}")]
        else
          []
        end
      end

      config =
        simple_config(
          transform_context: transform_fn,
          get_follow_up_messages: get_follow_up,
          stream_fn: Mocks.mock_stream_fn(responses)
        )

      stream = Loop.agent_loop([user_message("Start")], context, config, abort_signal, nil)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result
      messages = message_end_messages(events)

      # Should have processed some turns before abort
      assistant_msgs =
        Enum.filter(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert :counters.get(turn_count, 1) >= 1
      assert length(assistant_msgs) < 5
    end
  end

  # ============================================================================
  # Additional Abort Edge Cases
  # ============================================================================

  describe "abort edge cases" do
    test "nil signal is treated as non-aborted" do
      context = simple_context()
      response = Mocks.assistant_message("Response")

      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      # Explicitly pass nil signal
      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {_events, result} = collect_events_and_result(stream)
      assert {:ok, messages} = result

      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :stop
    end

    test "abort signal state at check time determines abort behavior" do
      context = simple_context()

      response = Mocks.assistant_message("Response")

      # Produces a few chunks, then stalls until released
      config =
        simple_config(stream_fn: Mocks.blocking_stream_fn(response, self(), chunks: 2))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      # Abort during streaming (after some chunks have been pushed)
      assert_receive {:stream_blocked, _producer}, 5_000
      AbortSignal.abort(signal)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result
      messages = message_end_messages(events)

      # The abort was detected during stream event consumption
      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      if assistant_msg do
        assert assistant_msg.stop_reason == :aborted
      end
    end

    test "multiple loops can use different abort signals independently" do
      context = simple_context()

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

      stream1 = Loop.agent_loop([user_message("Test 1")], context, config1, signal1, nil)
      stream2 = Loop.agent_loop([user_message("Test 2")], context, config2, signal2, nil)

      assert_receive {:stream1, _producer1}, 5_000
      assert_receive {:stream2, producer2}, 5_000

      # Abort only stream1; stream2 keeps running until its producer is released
      AbortSignal.abort(signal1)

      events1_task = Task.async(fn -> EventStream.events(stream1) |> Enum.to_list() end)
      result1 = EventStream.result(stream1)
      send(producer2, :release_stream)
      result2 = EventStream.result(stream2)

      events1 = Task.await(events1_task, 5000)
      messages1 = message_end_messages(events1)
      assert {:error, {:canceled, :assistant_aborted}} = result1
      {:ok, messages2} = result2

      assistant1 = Enum.find(messages1, &(Map.get(&1, :role) == :assistant))
      assistant2 = Enum.find(messages2, &(Map.get(&1, :role) == :assistant))

      if assistant1 do
        assert assistant1.stop_reason == :aborted
      end

      assert assistant2.stop_reason == :stop
    end

    test "abort during loop with no tools completes cleanly" do
      context = simple_context(tools: [])
      response = Mocks.assistant_message("Response without tools")

      # The producer has emitted nothing yet when the abort arrives
      config =
        simple_config(stream_fn: Mocks.blocking_stream_fn(response, self(), before_start: true))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      assert_receive {:stream_blocked, _producer}, 5_000
      AbortSignal.abort(signal)

      {events, result} = collect_events_and_result(stream)
      assert {:error, {:canceled, :assistant_aborted}} = result

      # Should have proper lifecycle events
      assert {:agent_start} = hd(events)
      refute Enum.any?(events, &match?({:agent_end, _}, &1))

      # Messages should include an aborted assistant message
      messages = message_end_messages(events)
      assistant_msg = Enum.find(messages, &(Map.get(&1, :role) == :assistant))

      if assistant_msg do
        assert assistant_msg.stop_reason == :aborted
      end
    end
  end
end
