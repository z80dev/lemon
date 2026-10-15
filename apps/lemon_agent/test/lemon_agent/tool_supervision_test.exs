defmodule LemonAgent.ToolSupervisionTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Loop
  alias LemonAgent.EventStream
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAgent.Test.Mocks

  alias LemonAi.Types.{TextContent, StreamOptions, UserMessage}

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp simple_context(opts) do
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

  # ============================================================================
  # Tool Task Supervisor Tests
  # ============================================================================

  describe "LemonAgent.ToolTaskSupervisor" do
    test "tool tasks run under ToolTaskSupervisor" do
      test_pid = self()

      pid_reporter_tool = %AgentTool{
        name: "pid_reporter",
        description: "Reports its pid",
        parameters: %{},
        label: "PID Reporter",
        execute: fn _id, _params, _abort, _on_update ->
          send(test_pid, {:tool_pid, self()})

          receive do
            :release_tool -> :ok
          end

          %AgentToolResult{content: [%TextContent{type: :text, text: "done"}]}
        end
      }

      context = simple_context(tools: [pid_reporter_tool])

      tool_call = Mocks.tool_call("pid_reporter", %{}, id: "call_pid_test")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      stream = Loop.agent_loop([user_message("Run pid_reporter")], context, config, nil, nil)

      # Wait for the tool to report its pid
      assert_receive {:tool_pid, tool_pid}, 5000

      # Verify the tool pid is a child of ToolTaskSupervisor
      children = Task.Supervisor.children(LemonAgent.ToolTaskSupervisor)
      assert tool_pid in children

      send(tool_pid, :release_tool)

      # Consume the stream to completion
      {:ok, _messages} = EventStream.result(stream)
    end

    test "tool task crash is handled gracefully" do
      crash_tool = %AgentTool{
        name: "crash_tool",
        description: "Crashes during execution",
        parameters: %{},
        label: "Crash Tool",
        execute: fn _id, _params, _abort, _on_update ->
          raise "intentional crash"
        end
      }

      context = simple_context(tools: [crash_tool])

      tool_call = Mocks.tool_call("crash_tool", %{}, id: "call_crash")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled the crash")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      events = Loop.stream([user_message("Crash please")], context, config) |> Enum.to_list()

      # Should get a tool_execution_end event with is_error = true
      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_crash", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, result, is_error} = tool_end
      assert is_error == true
      [%TextContent{text: error_text}] = result.content
      assert error_text =~ "intentional crash"

      # The loop should complete successfully despite the crash
      assert {:agent_end, _} = List.last(events)

      # ToolTaskSupervisor should still be alive
      assert Process.alive?(Process.whereis(LemonAgent.ToolTaskSupervisor))
    end

    test "abort terminates remaining tool tasks" do
      test_pid = self()

      slow_tool = %AgentTool{
        name: "slow_tool",
        description: "Takes a long time",
        parameters: %{},
        label: "Slow Tool",
        execute: fn _id, _params, abort_signal, _on_update ->
          send(test_pid, {:slow_tool_started, self()})

          result =
            Enum.reduce_while(1..100, nil, fn _, _ ->
              if AbortSignal.aborted?(abort_signal) do
                {:halt, :aborted}
              else
                Process.sleep(50)
                {:cont, nil}
              end
            end)

          if result == :aborted do
            %AgentToolResult{content: [%TextContent{type: :text, text: "aborted"}]}
          else
            %AgentToolResult{content: [%TextContent{type: :text, text: "done"}]}
          end
        end
      }

      context = simple_context(tools: [slow_tool])

      tool_call = Mocks.tool_call("slow_tool", %{}, id: "call_slow")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      signal = AbortSignal.new()

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      stream = Loop.agent_loop([user_message("Run slow tool")], context, config, signal, nil)

      # Wait for the tool to start
      assert_receive {:slow_tool_started, tool_pid}, 5000
      tool_ref = Process.monitor(tool_pid)

      # Verify the tool is a child of ToolTaskSupervisor
      children = Task.Supervisor.children(LemonAgent.ToolTaskSupervisor)
      assert tool_pid in children

      # Trigger abort
      :ok = AbortSignal.abort(signal)

      # The tool task should be terminated or finish due to abort
      assert_receive {:DOWN, ^tool_ref, :process, ^tool_pid, _reason}, 5000

      # Consume the stream
      _result = EventStream.result(stream)
    end

    test "multiple parallel tool tasks all run under ToolTaskSupervisor" do
      test_pid = self()

      reporting_tool = %AgentTool{
        name: "reporting_tool",
        description: "Reports its pid",
        parameters: %{"id" => %{"type" => "string"}},
        label: "Reporting Tool",
        parallel_safe: true,
        execute: fn _id, %{"id" => tool_id}, _abort, _on_update ->
          send(test_pid, {:tool_started, tool_id, self()})

          receive do
            :release_tool -> :ok
          end

          %AgentToolResult{content: [%TextContent{type: :text, text: "done #{tool_id}"}]}
        end
      }

      context = simple_context(tools: [reporting_tool])

      tool_call1 = Mocks.tool_call("reporting_tool", %{"id" => "1"}, id: "call_1")
      tool_call2 = Mocks.tool_call("reporting_tool", %{"id" => "2"}, id: "call_2")
      tool_call3 = Mocks.tool_call("reporting_tool", %{"id" => "3"}, id: "call_3")

      tool_response =
        Mocks.assistant_message_with_tool_calls([tool_call1, tool_call2, tool_call3])

      final_response = Mocks.assistant_message("All done")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      stream = Loop.agent_loop([user_message("Run all tools")], context, config, nil, nil)

      # Collect all tool pids
      tool_pids =
        for _ <- 1..3 do
          assert_receive {:tool_started, _id, pid}, 5000
          pid
        end

      # Verify all are children of ToolTaskSupervisor
      children = Task.Supervisor.children(LemonAgent.ToolTaskSupervisor)

      for pid <- tool_pids do
        assert pid in children
      end

      for pid <- tool_pids, do: send(pid, :release_tool)

      # Consume the stream to completion
      {:ok, messages} = EventStream.result(stream)

      # Should have 3 tool results
      tool_results = Enum.filter(messages, fn m -> Map.get(m, :role) == :tool_result end)
      assert length(tool_results) == 3
    end

    test "tool task supervisor survives multiple crashes" do
      crash_tool = %AgentTool{
        name: "crash_tool",
        description: "Crashes",
        parameters: %{},
        label: "Crash Tool",
        execute: fn _id, _params, _abort, _on_update ->
          raise "boom"
        end
      }

      context = simple_context(tools: [crash_tool])

      # Run multiple loops with crashing tools
      for i <- 1..3 do
        tool_call = Mocks.tool_call("crash_tool", %{}, id: "call_crash_#{i}")
        tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
        final_response = Mocks.assistant_message("Handled crash #{i}")

        config =
          simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

        events = Loop.stream([user_message("Crash #{i}")], context, config) |> Enum.to_list()

        # Should still complete
        assert {:agent_end, _} = List.last(events)
      end

      # ToolTaskSupervisor should still be alive
      assert Process.alive?(Process.whereis(LemonAgent.ToolTaskSupervisor))
    end
  end
end
