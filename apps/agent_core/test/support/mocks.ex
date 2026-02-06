defmodule AgentCore.Test.Mocks do
  @moduledoc """
  Mock modules and helper functions for testing AgentCore.
  """

  alias Ai.Types.{
    AssistantMessage,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    UserMessage,
    Usage,
    Cost,
    Model,
    ModelCost
  }

  alias AgentCore.Types.{AgentTool, AgentToolResult}

  # ============================================================================
  # Mock Model
  # ============================================================================

  @doc """
  Creates a mock model for testing.
  """
  def mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-1"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: Keyword.get(opts, :base_url, "https://api.mock.test"),
      reasoning: Keyword.get(opts, :reasoning, false),
      input: Keyword.get(opts, :input, [:text]),
      cost: Keyword.get(opts, :cost, %ModelCost{input: 0.01, output: 0.03}),
      context_window: Keyword.get(opts, :context_window, 128_000),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      headers: Keyword.get(opts, :headers, %{}),
      compat: Keyword.get(opts, :compat, nil)
    }
  end

  # ============================================================================
  # Mock Messages
  # ============================================================================

  @doc """
  Creates a mock user message.
  """
  def user_message(content, opts \\ []) do
    %UserMessage{
      role: :user,
      content: content,
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    }
  end

  @doc """
  Creates a mock assistant message with text content.
  """
  def assistant_message(text, opts \\ []) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      model: Keyword.get(opts, :model, "mock-model-1"),
      usage: Keyword.get(opts, :usage, mock_usage()),
      stop_reason: Keyword.get(opts, :stop_reason, :stop),
      error_message: Keyword.get(opts, :error_message, nil),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    }
  end

  @doc """
  Creates a mock assistant message with tool calls.
  """
  def assistant_message_with_tool_calls(tool_calls, opts \\ []) when is_list(tool_calls) do
    %AssistantMessage{
      role: :assistant,
      content: tool_calls,
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      model: Keyword.get(opts, :model, "mock-model-1"),
      usage: Keyword.get(opts, :usage, mock_usage()),
      stop_reason: Keyword.get(opts, :stop_reason, :tool_use),
      error_message: Keyword.get(opts, :error_message, nil),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    }
  end

  @doc """
  Creates a mock tool call.
  """
  def tool_call(name, arguments, opts \\ []) do
    %ToolCall{
      type: :tool_call,
      id: Keyword.get(opts, :id, generate_id()),
      name: name,
      arguments: arguments,
      thought_signature: Keyword.get(opts, :thought_signature, nil)
    }
  end

  @doc """
  Creates a mock tool result message.
  """
  def tool_result_message(tool_call_id, tool_name, content, opts \\ []) do
    %ToolResultMessage{
      role: :tool_result,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      content: [%TextContent{type: :text, text: content}],
      details: Keyword.get(opts, :details, nil),
      is_error: Keyword.get(opts, :is_error, false),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    }
  end

  @doc """
  Creates mock usage data.
  """
  def mock_usage(opts \\ []) do
    %Usage{
      input: Keyword.get(opts, :input, 100),
      output: Keyword.get(opts, :output, 50),
      cache_read: Keyword.get(opts, :cache_read, 0),
      cache_write: Keyword.get(opts, :cache_write, 0),
      total_tokens: Keyword.get(opts, :total_tokens, 150),
      cost: Keyword.get(opts, :cost, %Cost{input: 0.001, output: 0.0015, total: 0.0025})
    }
  end

  # ============================================================================
  # Mock Tools
  # ============================================================================

  @doc """
  Creates a mock agent tool that echoes the input.
  """
  def echo_tool do
    %AgentTool{
      name: "echo",
      description: "Echoes the input text back",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{"type" => "string", "description" => "The text to echo"}
        },
        "required" => ["text"]
      },
      label: "Echo",
      execute: fn _id, %{"text" => text}, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "Echo: #{text}"}],
          details: nil
        }
      end
    }
  end

  @doc """
  Creates a mock agent tool that adds two numbers.
  """
  def add_tool do
    %AgentTool{
      name: "add",
      description: "Adds two numbers together",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number", "description" => "First number"},
          "b" => %{"type" => "number", "description" => "Second number"}
        },
        "required" => ["a", "b"]
      },
      label: "Add",
      execute: fn _id, %{"a" => a, "b" => b}, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "#{a + b}"}],
          details: %{sum: a + b}
        }
      end
    }
  end

  @doc """
  Creates a mock agent tool that returns an error.
  """
  def error_tool do
    %AgentTool{
      name: "error_tool",
      description: "A tool that always returns an error",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string", "description" => "Error message"}
        },
        "required" => ["message"]
      },
      label: "Error Tool",
      execute: fn _id, %{"message" => message}, _signal, _on_update ->
        {:error, message}
      end
    }
  end

  @doc """
  Creates a mock agent tool that streams updates.
  """
  def streaming_tool do
    %AgentTool{
      name: "streaming_tool",
      description: "A tool that streams updates",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "count" => %{"type" => "integer", "description" => "Number of updates"}
        },
        "required" => ["count"]
      },
      label: "Streaming Tool",
      execute: fn _id, %{"count" => count}, _signal, on_update ->
        for i <- 1..count do
          if on_update do
            on_update.(%AgentToolResult{
              content: [%TextContent{type: :text, text: "Progress: #{i}/#{count}"}],
              details: %{progress: i, total: count}
            })
          end

          Process.sleep(10)
        end

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "Completed #{count} updates"}],
          details: %{completed: true}
        }
      end
    }
  end

  # ============================================================================
  # Mock Stream Functions
  # ============================================================================

  @doc """
  Creates a mock stream function that returns canned responses.

  The `responses` argument should be a list of AssistantMessage structs.
  Each call to the stream function will consume and return the next response.
  """
  def mock_stream_fn(responses) when is_list(responses) do
    # Use an Agent to track which response to return
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _model, _context, _options ->
      case Agent.get_and_update(agent, fn
             [] -> {nil, []}
             [head | tail] -> {head, tail}
           end) do
        nil ->
          # No more responses, return empty stream
          {:ok, empty_event_stream()}

        response ->
          {:ok, response_to_event_stream(response)}
      end
    end
  end

  @doc """
  Creates a mock stream function that returns a single canned response.
  """
  def mock_stream_fn_single(response) do
    fn _model, _context, _options ->
      {:ok, response_to_event_stream(response)}
    end
  end

  @doc """
  Creates a mock stream function that returns the stream directly.
  """
  def mock_stream_fn_single_direct(response) do
    fn _model, _context, _options ->
      response_to_event_stream(response)
    end
  end

  @doc """
  Creates a mock stream function that returns an error.
  """
  def mock_stream_fn_error(error_reason) do
    fn _model, _context, _options ->
      {:error, error_reason}
    end
  end

  # Convert a response to an event stream (simulating Ai.EventStream)
  defp response_to_event_stream(response) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      # Emit start event
      Ai.EventStream.push(stream, {:start, response})

      # Emit text deltas for each text content
      Enum.with_index(response.content)
      |> Enum.each(fn {content, idx} ->
        case content do
          %TextContent{text: text} ->
            Ai.EventStream.push(stream, {:text_start, idx, response})
            Ai.EventStream.push(stream, {:text_delta, idx, text, response})
            Ai.EventStream.push(stream, {:text_end, idx, response})

          %ThinkingContent{thinking: thinking} ->
            Ai.EventStream.push(stream, {:thinking_start, idx, response})
            Ai.EventStream.push(stream, {:thinking_delta, idx, thinking, response})
            Ai.EventStream.push(stream, {:thinking_end, idx, response})

          %ToolCall{} = tool_call ->
            Ai.EventStream.push(stream, {:tool_call_start, idx, tool_call, response})
            Ai.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})

          _ ->
            :ok
        end
      end)

      # Emit done event
      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end

  defp empty_event_stream do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.complete(stream, assistant_message("", stop_reason: :stop))
    end)

    stream
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc """
  Generates a unique ID for tool calls.
  """
  def generate_id do
    "call_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  @doc """
  Creates a simple convert_to_llm function that passes through standard messages.
  """
  def simple_convert_to_llm do
    fn messages ->
      Enum.filter(messages, fn msg ->
        case msg do
          %{role: role} when role in [:user, :assistant, :tool_result] -> true
          _ -> false
        end
      end)
    end
  end

  @doc """
  Collects all events from an EventStream into a list.
  """
  def collect_events(event_stream) do
    event_stream
    |> AgentCore.EventStream.events()
    |> Enum.to_list()
  end

  @doc """
  Waits for a specific event type and returns it.
  """
  def wait_for_event(event_stream, event_type, timeout \\ 5000) do
    task =
      Task.async(fn ->
        event_stream
        |> AgentCore.EventStream.events()
        |> Enum.find(fn event ->
          case event do
            {^event_type} -> true
            {^event_type, _} -> true
            {^event_type, _, _} -> true
            {^event_type, _, _, _} -> true
            {^event_type, _, _, _, _} -> true
            _ -> false
          end
        end)
      end)

    Task.await(task, timeout)
  end
end
