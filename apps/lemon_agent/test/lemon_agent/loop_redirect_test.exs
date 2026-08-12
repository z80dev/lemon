defmodule LemonAgent.LoopRedirectTest do
  @moduledoc """
  Tests for redirect handling in LemonAgent.Loop.

  A redirect cancels only the in-flight model request — completed tool results
  are preserved — then appends the queued correction and retries. It degrades
  to steering while tools are executing and never terminates the run the way
  abort does.
  """
  use ExUnit.Case, async: true

  alias LemonAgent.Loop
  alias LemonAgent.EventStream
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAgent.Test.Mocks

  alias LemonAi.Types.{
    StreamOptions,
    TextContent,
    UserMessage
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

  # A mutable steering queue the loop's get_steering_messages fn pops from.
  defp start_steering_queue do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  defp push_steering(queue, message), do: Agent.update(queue, &(&1 ++ [message]))

  defp pop_all_steering(queue), do: Agent.get_and_update(queue, fn msgs -> {msgs, []} end)

  # A stream_fn that dispatches on call number and reports each call's
  # (already converted) message list to the test process.
  defp scripted_stream_fn(parent, calls) do
    counter = :counters.new(1, [:atomics])

    fn model, llm_context, options ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(parent, {:llm_call, n, llm_context.messages})

      case Map.fetch!(calls, n) do
        {:slow, notify_tag} ->
          {:ok, stream} = LemonAi.EventStream.start_link()

          Task.start(fn ->
            response = Mocks.assistant_message("Partial response before redirect")
            LemonAi.EventStream.push(stream, {:start, response})

            for i <- 1..20 do
              send(parent, {notify_tag, i})
              Process.sleep(30)
              LemonAi.EventStream.push(stream, {:text_delta, 0, "chunk #{i}", response})
            end

            LemonAi.EventStream.push(stream, {:done, :stop, response})
            LemonAi.EventStream.complete(stream, response)
          end)

          {:ok, stream}

        {:respond, response} ->
          Mocks.mock_stream_fn_single(response).(model, llm_context, options)
      end
    end
  end

  defp user_content?(message, text) do
    Map.get(message, :role) == :user and
      (message.content == text or
         (is_list(message.content) and
            Enum.any?(message.content, fn
              %TextContent{text: ^text} -> true
              _ -> false
            end)))
  end

  # ============================================================================
  # Redirect mid-stream
  # ============================================================================

  describe "redirect during LLM streaming" do
    test "cancels model call, drops partial, appends correction, retries, and completes" do
      context = simple_context()
      parent = self()
      queue = start_steering_queue()
      correction = user_message("Actually, do it in French")

      stream_fn =
        scripted_stream_fn(parent, %{
          1 => {:slow, :streaming_chunk},
          2 => {:respond, Mocks.assistant_message("After redirect")}
        })

      config =
        simple_config(
          stream_fn: stream_fn,
          get_steering_messages: fn -> pop_all_steering(queue) end
        )

      signal = AbortSignal.new()
      stream = Loop.agent_loop([user_message("Start")], context, config, signal, nil)

      assert_receive {:streaming_chunk, 2}, 2000
      push_steering(queue, correction)
      AbortSignal.request_redirect(signal)

      {events, result} = collect_events_and_result(stream)

      # The run completes normally (unlike abort)
      assert {:ok, messages} = result
      assert Enum.any?(events, &match?({:agent_end, _}, &1))

      # A redirected assistant message was finalized and emitted
      redirected =
        Enum.find(message_end_messages(events), fn msg ->
          Map.get(msg, :role) == :assistant and Map.get(msg, :stop_reason) == :redirected
        end)

      assert redirected != nil
      assert redirected.error_message == nil

      # The correction was appended and the retry produced the final answer
      assert Enum.any?(messages, &user_content?(&1, "Actually, do it in French"))

      final =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant and Map.get(msg, :stop_reason) == :stop
        end)

      assert final != nil

      assert Enum.any?(final.content, fn
               %TextContent{text: "After redirect"} -> true
               _ -> false
             end)

      # The retried model call did not see the dropped partial but did see the
      # correction
      assert_receive {:llm_call, 2, retry_messages}, 2000

      refute Enum.any?(retry_messages, fn msg ->
               Map.get(msg, :role) == :assistant and
                 Map.get(msg, :stop_reason) == :redirected
             end)

      assert Enum.any?(retry_messages, &user_content?(&1, "Actually, do it in French"))

      # Redirect flag is cleared once handled
      refute AbortSignal.redirect_requested?(signal)
    end

    test "preserves completed tool results from earlier turns across the redirect" do
      parent = self()
      queue = start_steering_queue()
      correction = user_message("Change of plans")

      echo_tool = %AgentTool{
        name: "echo",
        description: "Echoes text",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Echo",
        execute: fn _id, _params, _signal, _on_update ->
          %AgentToolResult{
            content: [%TextContent{type: :text, text: "echoed!"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hi"}, id: "call_echo_1")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])

      stream_fn =
        scripted_stream_fn(parent, %{
          1 => {:respond, tool_response},
          2 => {:slow, :second_call_chunk},
          3 => {:respond, Mocks.assistant_message("Done after redirect")}
        })

      config =
        simple_config(
          stream_fn: stream_fn,
          get_steering_messages: fn -> pop_all_steering(queue) end
        )

      signal = AbortSignal.new()
      stream = Loop.agent_loop([user_message("Run the tool")], context, config, signal, nil)

      # Redirect while the SECOND model call is streaming (after the tool
      # completed)
      assert_receive {:second_call_chunk, 2}, 3000
      push_steering(queue, correction)
      AbortSignal.request_redirect(signal)

      {events, result} = collect_events_and_result(stream, 8000)

      assert {:ok, messages} = result
      assert Enum.any?(events, &match?({:agent_end, _}, &1))

      # The completed tool result survives the redirect
      tool_result =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :tool_result and Map.get(msg, :tool_call_id) == "call_echo_1"
        end)

      assert tool_result != nil
      assert tool_result.is_error == false

      # The retried model call (3) sees the tool call + result and the
      # correction — and TranscriptValidator accepted it (the call happened)
      assert_receive {:llm_call, 3, retry_messages}, 3000

      assert Enum.any?(retry_messages, fn msg ->
               Map.get(msg, :role) == :tool_result and
                 Map.get(msg, :tool_call_id) == "call_echo_1"
             end)

      assert Enum.any?(retry_messages, &user_content?(&1, "Change of plans"))

      refute Enum.any?(retry_messages, fn msg ->
               Map.get(msg, :role) == :assistant and
                 Map.get(msg, :stop_reason) == :redirected
             end)
    end

    test "abort wins over redirect when both are set" do
      context = simple_context()
      parent = self()

      stream_fn =
        scripted_stream_fn(parent, %{
          1 => {:slow, :streaming_chunk},
          2 => {:respond, Mocks.assistant_message("Should not happen")}
        })

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Start")], context, config, signal, nil)

      assert_receive {:streaming_chunk, 2}, 2000
      AbortSignal.request_redirect(signal)
      AbortSignal.abort(signal)

      {events, result} = collect_events_and_result(stream)

      assert {:error, {:canceled, :assistant_aborted}} = result
      refute Enum.any?(events, &match?({:agent_end, _}, &1))

      refute Enum.any?(message_end_messages(events), fn msg ->
               Map.get(msg, :stop_reason) == :redirected
             end)
    end

    test "redirect requested before the call starts is cleared and the call proceeds" do
      context = simple_context()
      parent = self()

      stream_fn =
        scripted_stream_fn(parent, %{
          1 => {:respond, Mocks.assistant_message("Completed fine")}
        })

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()
      AbortSignal.request_redirect(signal)

      stream = Loop.agent_loop([user_message("Start")], context, config, signal, nil)

      {events, result} = collect_events_and_result(stream)

      assert {:ok, messages} = result
      assert Enum.any?(events, &match?({:agent_end, _}, &1))

      final = Enum.find(messages, fn msg -> Map.get(msg, :role) == :assistant end)
      assert final.stop_reason == :stop
      refute AbortSignal.redirect_requested?(signal)
    end
  end

  # ============================================================================
  # Redirect during tool execution degrades to steering
  # ============================================================================

  describe "redirect during tool execution" do
    test "tools finish, correction lands before the next call, no spurious cancel" do
      parent = self()
      queue = start_steering_queue()
      correction = user_message("Redirect while tool ran")

      blocking_tool = %AgentTool{
        name: "blocking_tool",
        description: "Blocks until released",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Blocking",
        execute: fn id, _params, _signal, _on_update ->
          send(parent, {:tool_started, id, self()})

          receive do
            :release -> :ok
          after
            3000 -> :ok
          end

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "tool finished"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [blocking_tool])

      tool_call = Mocks.tool_call("blocking_tool", %{}, id: "call_block")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])

      stream_fn =
        scripted_stream_fn(parent, %{
          1 => {:respond, tool_response},
          2 => {:respond, Mocks.assistant_message("Final answer")}
        })

      config =
        simple_config(
          stream_fn: stream_fn,
          get_steering_messages: fn -> pop_all_steering(queue) end
        )

      signal = AbortSignal.new()
      stream = Loop.agent_loop([user_message("Run tool")], context, config, signal, nil)

      assert_receive {:tool_started, "call_block", tool_pid}, 3000

      # Redirect arrives while the tool is executing
      push_steering(queue, correction)
      AbortSignal.request_redirect(signal)
      send(tool_pid, :release)

      {events, result} = collect_events_and_result(stream, 8000)

      assert {:ok, messages} = result
      assert Enum.any?(events, &match?({:agent_end, _}, &1))

      # The tool completed normally (not canceled, not error)
      tool_end = Enum.find(events, &match?({:tool_execution_end, "call_block", _, _, _}, &1))
      assert {:tool_execution_end, _, _, _, false} = tool_end

      tool_result =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :tool_result and Map.get(msg, :tool_call_id) == "call_block"
        end)

      assert tool_result != nil
      assert tool_result.is_error == false

      # No model call was canceled: nothing carries stop_reason :redirected
      refute Enum.any?(message_end_messages(events), fn msg ->
               Map.get(msg, :stop_reason) == :redirected
             end)

      # The correction was delivered before the next model call
      assert_receive {:llm_call, 2, retry_messages}, 3000
      assert Enum.any?(retry_messages, &user_content?(&1, "Redirect while tool ran"))

      # The stale redirect bit was cleared by the pre-call check, so the next
      # call completed normally
      final =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant and Map.get(msg, :stop_reason) == :stop
        end)

      assert final != nil
      refute AbortSignal.redirect_requested?(signal)
    end
  end
end
