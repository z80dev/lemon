defmodule AgentCore.Loop.ToolCallsTest do
  use ExUnit.Case, async: true

  alias AgentCore.AbortSignal
  alias AgentCore.EventStream
  alias AgentCore.Loop.ToolCalls
  alias AgentCore.Test.Mocks
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}

  alias Ai.Types.{
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

    config =
      simple_config(get_steering_messages: fn -> [steering_message] end)

    signal = AbortSignal.new()
    :ok = AbortSignal.abort(signal)

    tool_call = Mocks.tool_call("slow_tool", %{}, id: "call_abort_test")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, steering_messages, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert steering_messages == [steering_message]
    assert length(results) == 1

    [tool_result_message] = results
    assert tool_result_message.role == :tool_result
    assert tool_result_message.tool_call_id == "call_abort_test"
    assert tool_result_message.is_error == true
    assert tool_result_message.details == %{error_type: :aborted}

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

    {results, steering_messages, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert steering_messages == []
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

    {results, steering_messages, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    refute_received :unexpected_tool_execution
    assert steering_messages == []
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

    {results, steering_messages, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert steering_messages == []
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

    {results, _steering_messages, updated_context, updated_new_messages} =
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

    {results, _steering_messages, _updated_context, _updated_new_messages} =
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
    config = simple_config(tool_timeout_ms: 50)
    signal = AbortSignal.new()
    tool_call = Mocks.tool_call("timeout_tool", %{}, id: "call_tool_timeout")
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {results, _steering_messages, updated_context, updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert_receive {:timeout_tool_started, "call_tool_timeout"}, 1_000
    assert [tool_result_message] = results
    assert tool_result_message.is_error == true
    assert tool_result_message.tool_call_id == "call_tool_timeout"
    assert tool_result_message.details == %{error_type: :tool_task_timeout, timeout_ms: 50}
    assert [%TextContent{text: "Tool task timed out after 50ms"}] = tool_result_message.content
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

    {results, _steering_messages, _context, _new_messages} =
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

    {results, _steering_messages, updated_context, updated_new_messages} =
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

    {results, _steering_messages, _updated_context, _updated_new_messages} =
      Task.await(runner, 5_000)

    assert length(results) == 3
    assert Enum.all?(results, &(&1.is_error == true))
    assert Enum.all?(results, &(&1.details == %{error_type: :aborted}))
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

    {results, _steering_messages, _updated_context, _updated_new_messages} =
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

    {results, _steering_messages, _updated_context, _updated_new_messages} =
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

    {results, _steering_messages, _updated_context, _updated_new_messages} =
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

    {results, _steering_messages, _updated_context, _updated_new_messages} =
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

    {results, _steering_messages, updated_context, updated_new_messages} =
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

    {results, _steering_messages, _updated_context, _updated_new_messages} =
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

    {results, _steering_messages, _updated_context, _updated_new_messages} =
      ToolCalls.execute_and_collect_tools(context, [], [tool_call], config, signal, stream)

    assert_receive {:union_params, %{"limit" => 42, "label" => "hello", "maybe" => nil}}
    assert [%{is_error: false, tool_call_id: "call_schema_union"}] = results
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
end
