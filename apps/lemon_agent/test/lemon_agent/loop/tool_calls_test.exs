defmodule LemonAgent.Loop.ToolCallsTest do
  use ExUnit.Case, async: true

  alias LemonAgent.AbortSignal
  alias LemonAgent.EventStream
  alias LemonAgent.Loop.ToolCalls
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}

  import LemonCore.Testing.AsyncHelpers

  alias LemonAi.Types.{
    StreamOptions,
    TextContent,
    UserMessage
  }

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
      has_steering_messages: Keyword.get(opts, :has_steering_messages, nil),
      get_follow_up_messages: Keyword.get(opts, :get_follow_up_messages, nil),
      max_tool_concurrency: Keyword.get(opts, :max_tool_concurrency, nil),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, nil),
      tool_task_supervisor: Keyword.get(opts, :tool_task_supervisor, nil),
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

  defp blocking_tool(parent, name, opts \\ []) do
    LemonAgent.new_tool(
      name: name,
      description: "Waits for the test to release the invocation",
      parameters: %{"type" => "object", "properties" => %{}},
      label: name,
      parallel_safe: Keyword.get(opts, :parallel_safe, false),
      execute: fn id, _params, _signal, _on_update ->
        send(parent, {:tool_started, id, self()})

        receive do
          :finish ->
            %AgentToolResult{
              content: [%TextContent{type: :text, text: "result #{id}"}],
              details: nil
            }
        end
      end
    )
  end

  test "returns aborted tool_result messages with details when signal is pre-aborted" do
    slow_tool = %AgentTool{
      name: "slow_tool",
      description: "Sleeps for a long time",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Slow",
      execute: fn _id, _params, _signal, _on_update ->
        Process.sleep(5_000)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "done"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [slow_tool])
    steering_message = user_message("follow steering")
    steering_queue = start_supervised!({Agent, fn -> [steering_message] end})

    config =
      simple_config(
        has_steering_messages: fn -> Agent.get(steering_queue, &(&1 != [])) end,
        get_steering_messages: fn ->
          Agent.get_and_update(steering_queue, fn messages -> {messages, []} end)
        end
      )

    signal = AbortSignal.new()
    :ok = AbortSignal.abort(signal)

    tool_call = Mocks.tool_call("slow_tool", %{}, id: "call_abort_test")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert Agent.get(steering_queue, & &1) == [steering_message]
    assert length(results) == 1

    [tool_result_message] = results
    assert tool_result_message.role == :tool_result
    assert tool_result_message.tool_call_id == "call_abort_test"
    assert tool_result_message.is_error == true

    assert %{error_type: :aborted, cancelled: true, started: false, outcome: :not_started} =
             tool_result_message.details

    assert Enum.any?(tool_result_message.content, fn
             %TextContent{text: text} when is_binary(text) -> String.contains?(text, "aborted")
             _ -> false
           end)

    assert List.last(updated_context.messages).tool_call_id == "call_abort_test"
    assert List.last(updated_new_messages).tool_call_id == "call_abort_test"

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    refute Enum.any?(events, &match?({:tool_execution_start, "call_abort_test", _, _}, &1))
    assert Enum.any?(events, &match?({:tool_execution_end, "call_abort_test", _, _, true}, &1))
  end

  test "abort during a tool batch returns one aborted result for pending and queued calls" do
    parent = self()

    slow_tool = %AgentTool{
      name: "slow_tool",
      description: "Sleeps until the batch is aborted",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Slow",
      execute: fn id, _params, _signal, _on_update ->
        send(parent, {:slow_tool_started, id})
        Process.sleep(5_000)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "unexpected"}],
          details: nil
        }
      end
    }

    queued_tool = %AgentTool{
      name: "queued_tool",
      description: "Must not start after abort",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Queued",
      execute: fn id, _params, _signal, _on_update ->
        send(parent, {:queued_tool_started, id})

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "unexpected"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [slow_tool, queued_tool])
    steering_message = user_message("do not continue")
    steering_queue = start_supervised!({Agent, fn -> [] end})

    config =
      simple_config(
        max_tool_concurrency: 1,
        has_steering_messages: fn -> Agent.get(steering_queue, &(&1 != [])) end,
        get_steering_messages: fn ->
          Agent.get_and_update(steering_queue, fn messages -> {messages, []} end)
        end
      )

    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_calls = [
      Mocks.tool_call("slow_tool", %{}, id: "call_abort_pending"),
      Mocks.tool_call("queued_tool", %{}, id: "call_abort_queued")
    ]

    runner =
      Task.async(fn ->
        ToolCalls.execute_and_collect_tools(context, [], tool_calls, config, signal, stream)
      end)

    assert_receive {:slow_tool_started, "call_abort_pending"}, 5_000
    Agent.update(steering_queue, fn _ -> [steering_message] end)
    :ok = AbortSignal.abort(signal)

    {results, updated_context, updated_new_messages} =
      Task.await(runner, 5_000)

    assert Agent.get(steering_queue, & &1) == [steering_message]

    refute_received {:queued_tool_started, "call_abort_queued"}

    assert Enum.map(results, & &1.tool_call_id) == [
             "call_abort_pending",
             "call_abort_queued"
           ]

    assert Enum.all?(results, &(&1.is_error == true))
    assert Enum.all?(results, &(&1.details.error_type == :aborted and &1.details.cancelled))

    assert Enum.map(updated_context.messages, & &1.tool_call_id) == [
             "call_abort_pending",
             "call_abort_queued"
           ]

    assert Enum.map(updated_new_messages, & &1.tool_call_id) == [
             "call_abort_pending",
             "call_abort_queued"
           ]

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, &match?({:tool_execution_start, "call_abort_pending", _, _}, &1))
    refute Enum.any?(events, &match?({:tool_execution_start, "call_abort_queued", _, _}, &1))

    assert Enum.any?(
             events,
             &match?({:tool_execution_end, "call_abort_pending", _, _, true}, &1)
           )

    assert Enum.any?(
             events,
             &match?({:tool_execution_end, "call_abort_queued", _, _, true}, &1)
           )
  end

  test "emits error tool_result for tool execution errors" do
    error_tool = %AgentTool{
      name: "failing_tool",
      description: "Always fails",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Failing",
      execute: fn _id, _params, _signal, _on_update ->
        {:error, "tool failed hard"}
      end
    }

    context = simple_context(tools: [error_tool])
    config = simple_config([])
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("failing_tool", %{}, id: "call_tool_error")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert length(results) == 1

    [tool_result_message] = results
    assert tool_result_message.role == :tool_result
    assert tool_result_message.tool_call_id == "call_tool_error"
    assert tool_result_message.tool_name == "failing_tool"
    assert tool_result_message.is_error == true

    assert tool_result_message.details == %{
             error_type: :tool_error,
             reason: ~s("tool failed hard")
           }

    assert Enum.any?(tool_result_message.content, fn
             %TextContent{text: "tool failed hard"} -> true
             _ -> false
           end)

    assert List.last(updated_context.messages).tool_call_id == "call_tool_error"
    assert List.last(updated_new_messages).tool_call_id == "call_tool_error"

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, &match?({:tool_execution_start, "call_tool_error", _, _}, &1))
    assert Enum.any?(events, &match?({:tool_execution_end, "call_tool_error", _, _, true}, &1))
  end

  test "a result flagged is_error is an error tool_result that keeps its details" do
    denied_tool = %AgentTool{
      name: "denied_tool",
      description: "Reports an approval denial",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Denied",
      execute: fn _id, _params, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "denied"}],
          details: %{denied: true},
          is_error: true
        }
      end
    }

    context = simple_context(tools: [denied_tool])
    tool_call = Mocks.tool_call("denied_tool", %{}, id: "call_denied")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {[tool_result_message], _context, _new_messages} =
      ToolCalls.execute_and_collect_tools(
        context,
        [],
        [tool_call],
        simple_config([]),
        AbortSignal.new(),
        stream
      )

    assert tool_result_message.is_error == true
    assert tool_result_message.details == %{denied: true}
  end

  test "emits error tool_result when tool task supervisor cannot start a task" do
    parent = self()

    tool = %AgentTool{
      name: "startup_failure_tool",
      description: "Should not run when the task supervisor is missing",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Startup failure",
      execute: fn _id, _params, _signal, _on_update ->
        send(parent, :unexpected_tool_execution)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "unexpected"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [tool])
    config = simple_config(tool_task_supervisor: :missing_tool_task_supervisor)
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("startup_failure_tool", %{}, id: "call_start_failure")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    refute_received :unexpected_tool_execution
    assert length(results) == 1

    [tool_result_message] = results
    assert tool_result_message.role == :tool_result
    assert tool_result_message.tool_call_id == "call_start_failure"
    assert tool_result_message.tool_name == "startup_failure_tool"
    assert tool_result_message.is_error == true
    assert tool_result_message.details.error_type == :tool_task_start_failed

    assert Enum.any?(tool_result_message.content, fn
             %TextContent{text: text} -> String.contains?(text, "Tool task failed to start")
             _ -> false
           end)

    assert List.last(updated_context.messages).tool_call_id == "call_start_failure"
    assert List.last(updated_new_messages).tool_call_id == "call_start_failure"

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, &match?({:tool_execution_start, "call_start_failure", _, _}, &1))
    assert Enum.any?(events, &match?({:tool_execution_end, "call_start_failure", _, _, true}, &1))
  end

  test "emits structured error tool_result when tool task process crashes" do
    crashing_tool = %AgentTool{
      name: "crashing_tool",
      description: "Kills its task process",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Crashing",
      execute: fn _id, _params, _signal, _on_update ->
        Process.exit(self(), :kill)
      end
    }

    context = simple_context(tools: [crashing_tool])
    config = simple_config([])
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("crashing_tool", %{}, id: "call_task_crash")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert length(results) == 1

    [tool_result_message] = results
    assert tool_result_message.role == :tool_result
    assert tool_result_message.tool_call_id == "call_task_crash"
    assert tool_result_message.tool_name == "crashing_tool"
    assert tool_result_message.is_error == true
    assert tool_result_message.details.error_type == :tool_task_crashed
    assert tool_result_message.details.reason in [":killed", ":noproc"]

    assert Enum.any?(tool_result_message.content, fn
             %TextContent{text: text} -> String.contains?(text, "Tool task crashed:")
             _ -> false
           end)

    assert List.last(updated_context.messages).tool_call_id == "call_task_crash"
    assert List.last(updated_new_messages).tool_call_id == "call_task_crash"

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, &match?({:tool_execution_start, "call_task_crash", _, _}, &1))
    assert Enum.any?(events, &match?({:tool_execution_end, "call_task_crash", _, _, true}, &1))
  end

  test "emits structured error tool_result when tool raises" do
    raising_tool = %AgentTool{
      name: "raising_tool",
      description: "Raises an exception",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Raising",
      execute: fn _id, _params, _signal, _on_update ->
        raise "tool exploded"
      end
    }

    context = simple_context(tools: [raising_tool])
    config = simple_config([])
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("raising_tool", %{}, id: "call_tool_exception")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert [tool_result_message] = results
    assert tool_result_message.is_error == true
    assert tool_result_message.tool_call_id == "call_tool_exception"

    assert tool_result_message.details == %{
             error_type: :tool_exception,
             exception: RuntimeError,
             message: "tool exploded"
           }

    assert [%TextContent{text: "tool exploded"}] = tool_result_message.content
    assert List.last(updated_context.messages).tool_call_id == "call_tool_exception"
    assert List.last(updated_new_messages).tool_call_id == "call_tool_exception"
  end

  test "emits structured error tool_result for unexpected tool return values" do
    weird_tool = %AgentTool{
      name: "weird_tool",
      description: "Returns an unsupported shape",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Weird",
      execute: fn _id, _params, _signal, _on_update ->
        {:unexpected, "shape"}
      end
    }

    context = simple_context(tools: [weird_tool])
    config = simple_config([])
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("weird_tool", %{}, id: "call_unexpected_result")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, _updated_context, _updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert [tool_result_message] = results
    assert tool_result_message.is_error == true
    assert tool_result_message.details.error_type == :unexpected_tool_result
    assert tool_result_message.details.result == ~s({:unexpected, "shape"})

    assert [%TextContent{text: text}] = tool_result_message.content
    assert text == ~s(Unexpected tool result: {:unexpected, "shape"})
  end

  test "terminates long-running tool task after configured timeout" do
    parent = self()

    slow_tool = %AgentTool{
      name: "timeout_tool",
      description: "Runs longer than the configured timeout",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Timeout",
      execute: fn id, _params, _signal, _on_update ->
        send(parent, {:timeout_tool_started, id})
        Process.sleep(5_000)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "unexpected"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [slow_tool])
    config = simple_config(tool_timeout_ms: 250)
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("timeout_tool", %{}, id: "call_tool_timeout")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert_receive {:timeout_tool_started, "call_tool_timeout"}, 5_000
    assert [tool_result_message] = results
    assert tool_result_message.is_error == true
    assert tool_result_message.tool_call_id == "call_tool_timeout"
    assert tool_result_message.details == %{error_type: :tool_task_timeout, timeout_ms: 250}
    assert [%TextContent{text: "Tool task timed out after 250ms"}] = tool_result_message.content
    assert List.last(updated_context.messages).tool_call_id == "call_tool_timeout"
    assert List.last(updated_new_messages).tool_call_id == "call_tool_timeout"

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()

    assert Enum.any?(events, &match?({:tool_execution_start, "call_tool_timeout", _, _}, &1))
    assert Enum.any?(events, &match?({:tool_execution_end, "call_tool_timeout", _, _, true}, &1))
  end

  test "respects max_tool_concurrency while executing tool calls" do
    {:ok, counter} = Agent.start_link(fn -> %{current: 0, max: 0} end)

    controlled_tool = %AgentTool{
      name: "controlled_tool",
      description: "tracks concurrent executions",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Controlled",
      parallel_safe: true,
      execute: fn _id, _params, _signal, _on_update ->
        Agent.update(counter, fn %{current: current, max: max_seen} ->
          current = current + 1
          %{current: current, max: max(max_seen, current)}
        end)

        Process.sleep(120)

        Agent.update(counter, fn %{current: current} = state ->
          %{state | current: max(current - 1, 0)}
        end)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "ok"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [controlled_tool])
    config = simple_config(max_tool_concurrency: 2)
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_calls =
      for i <- 1..4 do
        Mocks.tool_call("controlled_tool", %{}, id: "call_concurrency_#{i}")
      end

    {results, _context, _new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], tool_calls, config, signal, stream)

    assert length(results) == 4
    assert Agent.get(counter, & &1.max) <= 2
  end

  test "returns parallel tool results in assistant tool-call order" do
    ordered_tool = %AgentTool{
      name: "ordered_tool",
      description: "finishes at configurable times",
      parameters: %{
        "type" => "object",
        "properties" => %{"delay_ms" => %{"type" => "integer"}}
      },
      label: "Ordered",
      parallel_safe: true,
      execute: fn id, %{"delay_ms" => delay_ms}, _signal, _on_update ->
        Process.sleep(delay_ms)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "result #{id}"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [ordered_tool])
    config = simple_config(max_tool_concurrency: 2)
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_calls = [
      Mocks.tool_call("ordered_tool", %{"delay_ms" => 120}, id: "call_order_1"),
      Mocks.tool_call("ordered_tool", %{"delay_ms" => 5}, id: "call_order_2")
    ]

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], tool_calls, config, signal, stream)

    assert Enum.map(results, & &1.tool_call_id) == ["call_order_1", "call_order_2"]

    assert Enum.map(updated_context.messages, & &1.tool_call_id) == [
             "call_order_1",
             "call_order_2"
           ]

    assert Enum.map(updated_new_messages, & &1.tool_call_id) == ["call_order_1", "call_order_2"]
  end

  test "abort marks both running and queued tool calls as aborted when max_tool_concurrency is 1" do
    parent = self()

    slow_tool = %AgentTool{
      name: "slow_tool",
      description: "slow tool",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Slow",
      execute: fn id, _params, _signal, _on_update ->
        send(parent, {:tool_started, id})
        Process.sleep(5_000)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "done"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [slow_tool])
    config = simple_config(max_tool_concurrency: 1)
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_calls =
      for i <- 1..3 do
        Mocks.tool_call("slow_tool", %{}, id: "call_abort_queue_#{i}")
      end

    runner =
      Task.async(fn ->
        ToolCalls.execute_and_collect_tools(context, [], tool_calls, config, signal, stream)
      end)

    assert_receive {:tool_started, "call_abort_queue_1"}, 1_000
    :ok = AbortSignal.abort(signal)

    {results, _updated_context, _updated_new_messages} =
      Task.await(runner, 5_000)

    assert length(results) == 3
    assert Enum.all?(results, &(&1.is_error == true))
    assert Enum.all?(results, &(&1.details.error_type == :aborted and &1.details.cancelled))
  end

  test "finds tool with whitespace-padded name via normalization" do
    tool = %AgentTool{
      name: "read_file",
      description: "Reads a file",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "File",
      execute: fn _id, _params, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "file content"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [tool])
    config = simple_config([])
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    # Tool call with leading/trailing whitespace
    tool_call = Mocks.tool_call("  read_file  ", %{}, id: "call_whitespace")

    {results, _updated_context, _updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert length(results) == 1
    [tool_result_message] = results
    assert tool_result_message.is_error == false

    assert Enum.any?(tool_result_message.content, fn
             %TextContent{text: "file content"} -> true
             _ -> false
           end)
  end

  test "finds tool with internal whitespace via normalization" do
    # Tool with internal space in name
    tool = %AgentTool{
      name: "write file",
      description: "Writes a file",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "File",
      execute: fn _id, _params, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "written"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [tool])
    config = simple_config([])
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    # Tool call with tabs instead of spaces - should normalize to match
    tool_call = Mocks.tool_call("write\t\t\tfile", %{}, id: "call_internal_ws")

    {results, _updated_context, _updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert length(results) == 1
    [tool_result_message] = results
    assert tool_result_message.is_error == false
  end

  test "returns error for tool not found after normalization" do
    tool = %AgentTool{
      name: "existing_tool",
      description: "An existing tool",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Test",
      execute: fn _id, _params, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "ok"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [tool])
    config = simple_config([])
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    # Tool call that won't match even after normalization
    tool_call = Mocks.tool_call("nonexistent_tool", %{}, id: "call_not_found")

    {results, _updated_context, _updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert length(results) == 1
    [tool_result_message] = results
    assert tool_result_message.is_error == true

    assert tool_result_message.details == %{
             error_type: :unknown_tool,
             tool_name: "nonexistent_tool"
           }

    assert Enum.any?(tool_result_message.content, fn
             %TextContent{text: text} -> String.contains?(text, "not found")
             _ -> false
           end)
  end

  test "coerces safe schema-shaped arguments before executing tool task" do
    parent = self()

    tool = %AgentTool{
      name: "schema_tool",
      description: "captures coerced args",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "flag" => %{"type" => "boolean"},
          "count" => %{"type" => "integer"},
          "ratio" => %{"type" => "number"},
          "config" => %{
            "type" => "object",
            "properties" => %{"mode" => %{"type" => "string"}},
            "required" => ["mode"]
          },
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["flag", "count", "ratio", "config", "tags"]
      },
      label: "Schema",
      execute: fn _id, params, _signal, _on_update ->
        send(parent, {:coerced_params, params})

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "ok"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [tool])
    config = simple_config([])
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_call =
      Mocks.tool_call(
        "schema_tool",
        %{
          "flag" => "true",
          "count" => "42",
          "ratio" => "2.5",
          "config" => ~s({"mode":"fast"}),
          "tags" => "blue"
        },
        id: "call_schema_coerce"
      )

    {results, _updated_context, _updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert_receive {:coerced_params,
                    %{
                      "flag" => true,
                      "count" => 42,
                      "ratio" => 2.5,
                      "config" => %{"mode" => "fast"},
                      "tags" => ["blue"]
                    }}

    assert [%{is_error: false, tool_call_id: "call_schema_coerce"}] = results
  end

  test "rejects invalid schema-shaped arguments before starting tool task" do
    parent = self()

    tool = %AgentTool{
      name: "schema_tool",
      description: "must not execute with invalid args",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "count" => %{"type" => "integer"},
          "config" => %{"type" => "object"}
        },
        "required" => ["count", "config"]
      },
      label: "Schema",
      execute: fn _id, _params, _signal, _on_update ->
        send(parent, :unexpected_schema_tool_execution)

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "unexpected"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [tool])
    config = simple_config([])
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_call =
      Mocks.tool_call(
        "schema_tool",
        %{"count" => "forty-two", "config" => "not json"},
        id: "call_schema_invalid"
      )

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    refute_received :unexpected_schema_tool_execution

    assert [tool_result_message] = results
    assert tool_result_message.is_error == true
    assert tool_result_message.tool_call_id == "call_schema_invalid"
    assert tool_result_message.details.error_type == :invalid_tool_arguments
    assert "count: expected integer" in tool_result_message.details.errors
    assert "config: expected object, got string" in tool_result_message.details.errors

    assert List.last(updated_context.messages).tool_call_id == "call_schema_invalid"
    assert List.last(updated_new_messages).tool_call_id == "call_schema_invalid"
  end

  test "coerces nullable object and array string nulls before executing tool task" do
    parent = self()

    tool = %AgentTool{
      name: "nullable_schema_tool",
      description: "captures nullable coerced args",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "setting" => %{"type" => "object", "nullable" => true},
          "stages" => %{"type" => "array", "items" => %{"type" => "object"}, "nullable" => true}
        },
        "required" => ["setting", "stages"]
      },
      label: "Nullable schema",
      execute: fn _id, params, _signal, _on_update ->
        send(parent, {:nullable_params, params})

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "ok"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [tool])
    config = simple_config([])
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_call =
      Mocks.tool_call(
        "nullable_schema_tool",
        %{"setting" => "null", "stages" => "null"},
        id: "call_schema_nullable"
      )

    {results, _updated_context, _updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert_receive {:nullable_params, %{"setting" => nil, "stages" => nil}}
    assert [%{is_error: false, tool_call_id: "call_schema_nullable"}] = results
  end

  test "coerces JSON schema union types in declared order" do
    parent = self()

    tool = %AgentTool{
      name: "union_schema_tool",
      description: "captures union coerced args",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{"type" => ["integer", "string"]},
          "label" => %{"type" => ["integer", "boolean", "string"]},
          "maybe" => %{"type" => ["null", "object"]}
        },
        "required" => ["limit", "label", "maybe"]
      },
      label: "Union schema",
      execute: fn _id, params, _signal, _on_update ->
        send(parent, {:union_params, params})

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "ok"}],
          details: nil
        }
      end
    }

    context = simple_context(tools: [tool])
    config = simple_config([])
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_call =
      Mocks.tool_call(
        "union_schema_tool",
        %{"limit" => "42", "label" => "hello", "maybe" => "null"},
        id: "call_schema_union"
      )

    {results, _updated_context, _updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert_receive {:union_params, %{"limit" => 42, "label" => "hello", "maybe" => nil}}
    assert [%{is_error: false, tool_call_id: "call_schema_union"}] = results
  end

  test "unsafe tools are sequential barriers between contiguous safe groups" do
    supervisor = start_supervised!(Task.Supervisor)
    read_tool = blocking_tool(self(), "read", parallel_safe: true)
    mutate_tool = blocking_tool(self(), "mutate")
    previous_message = user_message("existing conversation")
    context = simple_context(tools: [read_tool, mutate_tool], messages: [previous_message])
    config = simple_config(max_tool_concurrency: 2, tool_task_supervisor: supervisor)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    tool_calls = [
      Mocks.tool_call("read", %{}, id: "read_1"),
      Mocks.tool_call("read", %{}, id: "read_2"),
      Mocks.tool_call("mutate", %{}, id: "mutate_1"),
      Mocks.tool_call("read", %{}, id: "read_3"),
      Mocks.tool_call("read", %{}, id: "read_4"),
      Mocks.tool_call("mutate", %{}, id: "mutate_2"),
      Mocks.tool_call("read", %{}, id: "read_5")
    ]

    runner =
      Task.async(fn ->
        ToolCalls.execute_and_collect_tools(
          context,
          [previous_message],
          tool_calls,
          config,
          nil,
          stream
        )
      end)

    assert_receive {:tool_started, "read_1", read_1}, 1_000
    assert_receive {:tool_started, "read_2", read_2}, 1_000
    refute_receive {:tool_started, "mutate_1", _}, 50
    send(read_2, :finish)
    refute_receive {:tool_started, "mutate_1", _}, 50
    send(read_1, :finish)

    assert_receive {:tool_started, "mutate_1", mutate_1}, 1_000
    refute_receive {:tool_started, "read_3", _}, 50
    send(mutate_1, :finish)

    assert_receive {:tool_started, "read_3", read_3}, 1_000
    assert_receive {:tool_started, "read_4", read_4}, 1_000
    send(read_3, :finish)
    refute_receive {:tool_started, "mutate_2", _}, 50
    send(read_4, :finish)

    assert_receive {:tool_started, "mutate_2", mutate_2}, 1_000
    refute_receive {:tool_started, "read_5", _}, 50
    send(mutate_2, :finish)
    assert_receive {:tool_started, "read_5", read_5}, 1_000
    send(read_5, :finish)

    {results, updated_context, updated_new_messages} = Task.await(runner, 5_000)
    expected_ids = Enum.map(tool_calls, & &1.id)

    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.map(results, & &1.tool_call_id) == expected_ids
    assert updated_context.messages == [previous_message | results]
    assert updated_new_messages == [previous_message | results]

    EventStream.complete(stream, [])

    started_ids =
      EventStream.events(stream)
      |> Enum.flat_map(fn
        {:tool_execution_start, id, _, _} -> [id]
        _ -> []
      end)

    assert started_ids == expected_ids
  end

  test "opted-in safe reads overlap without exceeding the configured concurrency limit" do
    supervisor = start_supervised!(Task.Supervisor)
    tool = blocking_tool(self(), "read", parallel_safe: true)
    context = simple_context(tools: [tool])
    config = simple_config(max_tool_concurrency: 2, tool_task_supervisor: supervisor)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)
    calls = for i <- 1..3, do: Mocks.tool_call("read", %{}, id: "safe_read_#{i}")

    runner =
      Task.async(fn ->
        ToolCalls.execute_and_collect_tools(context, [], calls, config, nil, stream)
      end)

    assert_receive {:tool_started, "safe_read_1", first}, 1_000
    assert_receive {:tool_started, "safe_read_2", second}, 1_000
    assert Process.alive?(first)
    assert Process.alive?(second)
    refute_receive {:tool_started, "safe_read_3", _}, 50

    send(second, :finish)
    assert_receive {:tool_started, "safe_read_3", third}, 1_000
    assert Process.alive?(first)
    send(third, :finish)
    send(first, :finish)

    {results, _, _} = Task.await(runner, 5_000)
    assert Enum.map(results, & &1.tool_call_id) == Enum.map(calls, & &1.id)
    assert Enum.all?(results, &(&1.is_error == false))
  end

  test "steering queued by a sequential tool prevents the next mutating invocation" do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)
    steering_message = user_message("leave the file unchanged")
    steering_queue = start_supervised!({Agent, fn -> [] end})
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    first_tool = %AgentTool{
      name: "inspect",
      description: "Queues a correction before returning",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Inspect",
      execute: fn _id, _params, _signal, _on_update ->
        Agent.update(steering_queue, fn _ -> [steering_message] end)
        %AgentToolResult{content: [%TextContent{text: "inspection complete"}]}
      end
    }

    mutating_tool = %AgentTool{
      name: "mutate",
      description: "Must not apply the superseded mutation",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Mutate",
      execute: fn _id, _params, _signal, _on_update ->
        send(parent, :mutation_applied)
        %AgentToolResult{content: [%TextContent{text: "mutated"}]}
      end
    }

    config =
      simple_config(
        tool_task_supervisor: supervisor,
        has_steering_messages: fn -> Agent.get(steering_queue, &(&1 != [])) end,
        get_steering_messages: fn ->
          EventStream.push(stream, {:turn_start})
          Agent.get_and_update(steering_queue, fn messages -> {messages, []} end)
        end
      )

    calls = [
      Mocks.tool_call("inspect", %{}, id: "inspect_before_steering"),
      Mocks.tool_call("mutate", %{}, id: "superseded_mutation")
    ]

    {results, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(
        simple_context(tools: [first_tool, mutating_tool]),
        [],
        calls,
        config,
        nil,
        stream
      )

    refute_received :mutation_applied
    assert Agent.get(steering_queue, & &1) == [steering_message]
    assert config.get_steering_messages.() == [steering_message]
    assert Agent.get(steering_queue, & &1) == []
    assert [completed, skipped] = results
    assert completed.is_error == false
    assert skipped.tool_call_id == "superseded_mutation"
    assert skipped.is_error == true
    assert skipped.details == %{error_type: :skipped, reason: :steering}
    assert updated_context.messages == results
    assert updated_new_messages == results

    EventStream.complete(stream, [])
    events = EventStream.events(stream) |> Enum.to_list()
    {before_drain, [{:turn_start} | _]} = Enum.split_while(events, &(&1 != {:turn_start}))

    paired_ids =
      Enum.flat_map(before_drain, fn
        {:message_end, %{role: :tool_result, tool_call_id: id}} -> [id]
        _ -> []
      end)

    assert paired_ids == Enum.map(calls, & &1.id)
    refute Enum.any?(events, &match?({:tool_execution_start, "superseded_mutation", _, _}, &1))
  end

  test "steering is observed while safe tools wait without canceling started invocations" do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)
    steering_message = user_message("use different reads next")
    steering_queue = start_supervised!({Agent, fn -> [] end})
    tool = blocking_tool(parent, "read", parallel_safe: true)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    config =
      simple_config(
        max_tool_concurrency: 2,
        tool_task_supervisor: supervisor,
        has_steering_messages: fn ->
          queued? = Agent.get(steering_queue, &(&1 != []))
          if queued?, do: send(parent, :steering_observed)
          queued?
        end,
        get_steering_messages: fn ->
          send(parent, :steering_drained)
          Agent.get_and_update(steering_queue, fn messages -> {messages, []} end)
        end
      )

    calls = for i <- 1..3, do: Mocks.tool_call("read", %{}, id: "steered_read_#{i}")

    runner =
      Task.async(fn ->
        ToolCalls.execute_and_collect_tools(
          simple_context(tools: [tool]),
          [],
          calls,
          config,
          nil,
          stream
        )
      end)

    assert_receive {:tool_started, "steered_read_1", first}, 1_000
    assert_receive {:tool_started, "steered_read_2", second}, 1_000
    Agent.update(steering_queue, fn _ -> [steering_message] end)
    assert_receive :steering_observed, 1_000
    assert Process.alive?(first)
    assert Process.alive?(second)
    refute_received :steering_drained
    refute_received {:tool_started, "steered_read_3", _}

    send(second, :finish)
    send(first, :finish)
    {results, context, messages} = Task.await(runner, 5_000)

    refute_received :steering_drained
    assert Agent.get(steering_queue, & &1) == [steering_message]
    assert config.get_steering_messages.() == [steering_message]
    assert_receive :steering_drained
    assert [first_result, second_result, skipped] = results
    assert first_result.is_error == false
    assert second_result.is_error == false
    assert skipped.tool_call_id == "steered_read_3"
    assert skipped.details == %{error_type: :skipped, reason: :steering}
    assert context.messages == results
    assert messages == results
    refute_received {:tool_started, "steered_read_3", _}
  end

  test "aborting running tasks cancels every pending tool timeout" do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)
    tool = blocking_tool(parent, "read", parallel_safe: true)
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    config =
      simple_config(
        max_tool_concurrency: 2,
        tool_timeout_ms: 500,
        tool_task_supervisor: supervisor
      )

    calls = for i <- 1..2, do: Mocks.tool_call("read", %{}, id: "abort_timer_#{i}")

    runner =
      Task.async(fn ->
        result =
          ToolCalls.execute_and_collect_tools(
            simple_context(tools: [tool]),
            [],
            calls,
            config,
            signal,
            stream
          )

        send(parent, {:aborted_batch_finished, result})

        receive do
          {:tool_task_timeout, _ref} -> :timer_leaked
        after
          600 -> :timers_canceled
        end
      end)

    assert_receive {:tool_started, "abort_timer_1", first}, 1_000
    assert_receive {:tool_started, "abort_timer_2", second}, 1_000
    first_monitor = Process.monitor(first)
    second_monitor = Process.monitor(second)
    AbortSignal.abort(signal)

    assert_receive {:aborted_batch_finished, {results, _, _}}, 1_000
    assert Enum.all?(results, &(&1.details.error_type == :aborted and &1.details.cancelled))
    assert_receive {:DOWN, ^first_monitor, :process, ^first, _}, 1_000
    assert_receive {:DOWN, ^second_monitor, :process, ^second, _}, 1_000
    assert Task.await(runner, 5_000) == :timers_canceled
  end

  test "invalid and nonbinary tool names produce unknown-tool results without invoking a tool" do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    tool = %AgentTool{
      name: "existing_tool",
      description: "Must not run for malformed names",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Existing",
      execute: fn _id, _params, _signal, _on_update ->
        send(parent, :unexpected_tool_execution)
        %AgentToolResult{content: [%TextContent{text: "unexpected"}]}
      end
    }

    names = [
      nil,
      :existing_tool,
      42,
      %{"name" => "existing_tool"},
      ["existing_tool"],
      <<255>>,
      ""
    ]

    calls =
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, index} ->
        Mocks.tool_call(name, %{}, id: "invalid_name_#{index}")
      end)

    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, context, messages} =
      ToolCalls.execute_and_collect_tools(
        simple_context(tools: [tool]),
        [],
        calls,
        simple_config(max_tool_concurrency: 1, tool_task_supervisor: supervisor),
        nil,
        stream
      )

    refute_received :unexpected_tool_execution
    assert Enum.map(results, & &1.tool_call_id) == Enum.map(calls, & &1.id)
    assert Enum.map(results, & &1.details.tool_name) == names
    assert Enum.all?(results, &(&1.is_error and &1.details.error_type == :unknown_tool))

    assert Enum.all?(results, fn result ->
             [%TextContent{text: text}] = result.content
             String.valid?(text)
           end)

    assert context.messages == results
    assert messages == results
  end

  test "normalize_tool_name/1 trims whitespace and normalizes Unicode" do
    # Basic trimming
    assert ToolCalls.normalize_tool_name("  read_file  ") == "read_file"
    assert ToolCalls.normalize_tool_name("\t\nread_file\r\n") == "read_file"

    # Internal whitespace normalization
    assert ToolCalls.normalize_tool_name("read\t\tfile") == "read file"
    assert ToolCalls.normalize_tool_name("read   file") == "read file"

    # Unicode whitespace (non-breaking space)
    assert ToolCalls.normalize_tool_name("read\u00A0file") == "read file"

    # Already normalized passes through
    assert ToolCalls.normalize_tool_name("read_file") == "read_file"
  end

  test "abort lets cooperative tools finish resource cleanup before returning" do
    parent = self()
    signal = AbortSignal.new()
    on_exit(fn -> AbortSignal.clear(signal) end)

    wait_for_abort = fn wait_for_abort ->
      if AbortSignal.aborted?(signal) do
        send(parent, :abort_observed)

        # Cleanup only finishes once the test says so (after the loop has begun
        # draining aborted tools), instead of racing the loop's abort poll.
        receive do
          :finish_cleanup -> :ok
        after
          5_000 -> :ok
        end

        send(parent, {:resource_cleanup_finished, AbortSignal.aborted?(signal)})
        {:error, "aborted after cleanup"}
      else
        Process.sleep(10)
        wait_for_abort.(wait_for_abort)
      end
    end

    tool =
      LemonAgent.new_tool(
        name: "external_work",
        description: "Stops an external resource",
        execute: fn _, _, _, _ ->
          send(parent, {:external_tool_started, self()})
          wait_for_abort.(wait_for_abort)
        end
      )

    supervisor = start_supervised!(Task.Supervisor)
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    runner =
      Task.async(fn ->
        ToolCalls.execute_and_collect_tools(
          simple_context(tools: [tool]),
          [],
          [Mocks.tool_call("external_work", %{}, id: "external")],
          simple_config(tool_task_supervisor: supervisor),
          signal,
          stream
        )
      end)

    assert_receive {:external_tool_started, worker}
    monitor = Process.monitor(worker)
    AbortSignal.abort(signal)
    assert_receive :abort_observed, 5_000

    # Wait until the loop has noticed the abort and is draining the tool
    # (inside its bounded cleanup receive), then let the cleanup finish.
    runner_pid = runner.pid

    assert_eventually(
      fn ->
        match?(
          {:current_function, {LemonAgent.Loop.ToolCalls, :await_tool_cleanup, _}},
          Process.info(runner_pid, :current_function)
        )
      end,
      timeout: 5_000,
      interval: 1
    )

    send(worker, :finish_cleanup)
    assert_receive {:resource_cleanup_finished, true}, 5_000

    assert {[%{is_error: true, details: %{error_type: :tool_error, cancelled: true}}], _, _} =
             Task.await(runner, 5_000)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert Task.Supervisor.children(supervisor) == []
    EventStream.complete(stream, [])
  end
end
