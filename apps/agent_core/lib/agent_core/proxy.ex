defmodule AgentCore.Proxy do
  @moduledoc """
  Proxy stream function for apps that route LLM calls through a server.

  The server manages authentication and proxies requests to LLM providers.
  This module reconstructs partial messages from server-sent events (SSE)
  that have the `partial` field stripped to reduce bandwidth.

  ## Usage

  Use `stream_proxy/3` as the `stream_fn` option when creating an Agent
  that needs to go through a proxy:

      config = %AgentLoopConfig{
        model: model,
        stream_fn: fn model, context, opts ->
          AgentCore.Proxy.stream_proxy(model, context, %ProxyStreamOptions{
            auth_token: get_auth_token(),
            proxy_url: "https://genai.example.com",
            temperature: opts.temperature,
            max_tokens: opts.max_tokens,
            reasoning: opts.reasoning
          })
        end,
        ...
      }
  """

  alias AgentCore.AbortSignal
  alias Ai.EventStream
  alias Ai.Types.{AssistantMessage, TextContent, ThinkingContent, ToolCall, Usage, Cost}

  # ============================================================================
  # Types
  # ============================================================================

  defmodule ProxyStreamOptions do
    @moduledoc """
    Options for proxy streaming requests.

    ## Fields

    - `auth_token` - Auth token for the proxy server (required)
    - `proxy_url` - Proxy server URL, e.g., "https://genai.example.com" (required)
    - `temperature` - Temperature for sampling (optional)
    - `max_tokens` - Maximum tokens to generate (optional)
    - `reasoning` - Thinking/reasoning level (optional)
    - `signal` - Abort signal reference for cancellation (optional)
    """
    @type thinking_level :: :minimal | :low | :medium | :high | :xhigh
    @type t :: %__MODULE__{
            auth_token: String.t(),
            proxy_url: String.t(),
            temperature: float() | nil,
            max_tokens: non_neg_integer() | nil,
            reasoning: thinking_level() | nil,
            signal: reference() | nil
          }
    defstruct auth_token: "",
              proxy_url: "",
              temperature: nil,
              max_tokens: nil,
              reasoning: nil,
              signal: nil
  end

  @typedoc """
  Proxy event types - server sends these with partial field stripped to reduce bandwidth.

  Events:
  - `{:start}` - Stream started
  - `{:text_start, content_index}` - Text content block started
  - `{:text_delta, content_index, delta}` - Text content delta
  - `{:text_end, content_index, content_signature}` - Text content block ended
  - `{:thinking_start, content_index}` - Thinking content block started
  - `{:thinking_delta, content_index, delta}` - Thinking content delta
  - `{:thinking_end, content_index, content_signature}` - Thinking content block ended
  - `{:tool_call_start, content_index, id, tool_name}` - Tool call started
  - `{:tool_call_delta, content_index, delta}` - Tool call arguments delta (JSON)
  - `{:tool_call_end, content_index}` - Tool call ended
  - `{:done, reason, usage}` - Stream completed successfully
  - `{:error, reason, error_message, usage}` - Stream ended with error
  """
  @type proxy_assistant_message_event ::
          {:start}
          | {:text_start, non_neg_integer()}
          | {:text_delta, non_neg_integer(), String.t()}
          | {:text_end, non_neg_integer(), String.t() | nil}
          | {:thinking_start, non_neg_integer()}
          | {:thinking_delta, non_neg_integer(), String.t()}
          | {:thinking_end, non_neg_integer(), String.t() | nil}
          | {:tool_call_start, non_neg_integer(), String.t(), String.t()}
          | {:tool_call_delta, non_neg_integer(), String.t()}
          | {:tool_call_end, non_neg_integer()}
          | {:done, :stop | :length | :tool_use, Usage.t()}
          | {:error, :aborted | :error, String.t() | nil, Usage.t()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Stream function that proxies through a server instead of calling LLM providers directly.

  The server strips the partial field from delta events to reduce bandwidth.
  We reconstruct the partial message client-side.

  ## Parameters

  - `model` - The AI model to use
  - `context` - The conversation context
  - `options` - ProxyStreamOptions with auth and proxy configuration

  ## Returns

  Returns an `Ai.EventStream` that emits events as they arrive from the proxy server.
  """
  @spec stream_proxy(Ai.Types.Model.t(), Ai.Types.Context.t(), ProxyStreamOptions.t()) ::
          EventStream.t()
  def stream_proxy(model, context, %ProxyStreamOptions{} = options) do
    {:ok, stream} = EventStream.start_link()

    # Spawn the streaming task
    Task.start(fn ->
      run_proxy_stream(model, context, options, stream)
    end)

    stream
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp run_proxy_stream(model, context, options, stream) do
    # Initialize the partial message that we'll build up from events
    partial = %AssistantMessage{
      role: :assistant,
      stop_reason: :stop,
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: %Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      },
      timestamp: System.system_time(:millisecond)
    }

    # State for tracking partial JSON in tool calls
    state = %{
      partial: partial,
      partial_json: %{}
    }

    url = "#{options.proxy_url}/api/stream"

    headers = [
      {"authorization", "Bearer #{options.auth_token}"},
      {"content-type", "application/json"}
    ]

    body =
      Jason.encode!(%{
        model: encode_model(model),
        context: encode_context(context),
        options: %{
          temperature: options.temperature,
          maxTokens: options.max_tokens,
          reasoning: options.reasoning
        }
      })

    try do
      # Make the streaming request using Req
      case Req.post(url,
             headers: headers,
             body: body,
             into: :self,
             receive_timeout: :infinity
           ) do
        {:ok, response} when response.status == 200 ->
          # Process the SSE stream
          process_sse_stream(stream, state, options.signal)

        {:ok, response} ->
          # Handle error response
          error_message =
            case Jason.decode(response.body) do
              {:ok, %{"error" => error}} -> "Proxy error: #{error}"
              _ -> "Proxy error: #{response.status}"
            end

          error_partial = %{state.partial | stop_reason: :error, error_message: error_message}
          EventStream.error(stream, error_partial)

        {:error, reason} ->
          error_message = "Proxy connection error: #{inspect(reason)}"
          error_partial = %{state.partial | stop_reason: :error, error_message: error_message}
          EventStream.error(stream, error_partial)
      end
    rescue
      e ->
        error_message = "Proxy error: #{Exception.message(e)}"
        error_partial = %{state.partial | stop_reason: :error, error_message: error_message}
        EventStream.error(stream, error_partial)
    end
  end

  defp process_sse_stream(stream, state, signal) do
    buffer = ""
    do_process_sse_stream(stream, state, signal, buffer)
  end

  defp do_process_sse_stream(stream, state, signal, buffer) do
    # Check for abort
    if AbortSignal.aborted?(signal) do
      error_partial = %{
        state.partial
        | stop_reason: :aborted,
          error_message: "Request aborted by user"
      }

      EventStream.error(stream, error_partial)
    else
      receive do
        {_ref, {:data, data}} ->
          # Received chunk of data
          buffer = buffer <> data
          {lines, remaining_buffer} = split_lines(buffer)

          state =
            Enum.reduce(lines, state, fn line, acc_state ->
              process_sse_line(line, acc_state, stream)
            end)

          do_process_sse_stream(stream, state, signal, remaining_buffer)

        {_ref, :done} ->
          # Stream complete - already handled by :done event
          :ok

        {:DOWN, _ref, :process, _pid, _reason} ->
          # Request process died
          :ok
      after
        # Timeout for checking abort signal
        100 ->
          if AbortSignal.aborted?(signal) do
            error_partial = %{
              state.partial
              | stop_reason: :aborted,
                error_message: "Request aborted by user"
            }

            EventStream.error(stream, error_partial)
          else
            do_process_sse_stream(stream, state, signal, buffer)
          end
      end
    end
  end

  defp split_lines(buffer) do
    lines = String.split(buffer, "\n")
    # Last element might be incomplete
    {complete, [last]} = Enum.split(lines, -1)
    {complete, last}
  end

  defp process_sse_line(line, state, stream) do
    if String.starts_with?(line, "data:") do
      data =
        line
        |> String.replace_prefix("data:", "")
        |> String.trim()

      if data != "" do
        case Jason.decode(data) do
          {:ok, proxy_event} ->
            process_proxy_event(proxy_event, state, stream)

          {:error, _} ->
            state
        end
      else
        state
      end
    else
      state
    end
  end

  @doc false
  @spec process_proxy_event(map(), map(), EventStream.t()) :: map()
  defp process_proxy_event(%{"type" => "start"}, state, stream) do
    event = {:start, state.partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "text_start", "contentIndex" => content_index},
         state,
         stream
       ) do
    new_content = %TextContent{type: :text, text: ""}
    partial = update_content_at(state.partial, content_index, new_content)
    state = %{state | partial: partial}

    event = {:text_start, content_index, partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "text_delta", "contentIndex" => content_index, "delta" => delta},
         state,
         stream
       ) do
    partial =
      update_content_at(state.partial, content_index, fn
        %TextContent{} = content -> %{content | text: content.text <> delta}
        other -> other
      end)

    state = %{state | partial: partial}

    event = {:text_delta, content_index, delta, partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "text_end", "contentIndex" => content_index} = event_data,
         state,
         stream
       ) do
    content_signature = Map.get(event_data, "contentSignature")

    partial =
      update_content_at(state.partial, content_index, fn
        %TextContent{} = content -> %{content | text_signature: content_signature}
        other -> other
      end)

    state = %{state | partial: partial}

    # Get the text content for the end event
    text =
      case Enum.at(partial.content, content_index) do
        %TextContent{text: t} -> t
        _ -> ""
      end

    event = {:text_end, content_index, text, partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "thinking_start", "contentIndex" => content_index},
         state,
         stream
       ) do
    new_content = %ThinkingContent{type: :thinking, thinking: ""}
    partial = update_content_at(state.partial, content_index, new_content)
    state = %{state | partial: partial}

    event = {:thinking_start, content_index, partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "thinking_delta", "contentIndex" => content_index, "delta" => delta},
         state,
         stream
       ) do
    partial =
      update_content_at(state.partial, content_index, fn
        %ThinkingContent{} = content -> %{content | thinking: content.thinking <> delta}
        other -> other
      end)

    state = %{state | partial: partial}

    event = {:thinking_delta, content_index, delta, partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "thinking_end", "contentIndex" => content_index} = event_data,
         state,
         stream
       ) do
    content_signature = Map.get(event_data, "contentSignature")

    partial =
      update_content_at(state.partial, content_index, fn
        %ThinkingContent{} = content -> %{content | thinking_signature: content_signature}
        other -> other
      end)

    state = %{state | partial: partial}

    # Get the thinking content for the end event
    thinking =
      case Enum.at(partial.content, content_index) do
        %ThinkingContent{thinking: t} -> t
        _ -> ""
      end

    event = {:thinking_end, content_index, thinking, partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{
           "type" => "toolcall_start",
           "contentIndex" => content_index,
           "id" => id,
           "toolName" => tool_name
         },
         state,
         stream
       ) do
    new_content = %ToolCall{
      type: :tool_call,
      id: id,
      name: tool_name,
      arguments: %{}
    }

    partial = update_content_at(state.partial, content_index, new_content)
    partial_json = Map.put(state.partial_json, content_index, "")
    state = %{state | partial: partial, partial_json: partial_json}

    event = {:tool_call_start, content_index, partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "toolcall_delta", "contentIndex" => content_index, "delta" => delta},
         state,
         stream
       ) do
    # Accumulate partial JSON
    current_json = Map.get(state.partial_json, content_index, "")
    new_json = current_json <> delta
    partial_json = Map.put(state.partial_json, content_index, new_json)

    # Try to parse the partial JSON
    parsed_args = parse_streaming_json(new_json)

    partial =
      update_content_at(state.partial, content_index, fn
        %ToolCall{} = content -> %{content | arguments: parsed_args}
        other -> other
      end)

    state = %{state | partial: partial, partial_json: partial_json}

    event = {:tool_call_delta, content_index, delta, partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "toolcall_end", "contentIndex" => content_index},
         state,
         stream
       ) do
    # Get the final tool call
    tool_call = Enum.at(state.partial.content, content_index)

    # Clean up partial JSON state
    partial_json = Map.delete(state.partial_json, content_index)
    state = %{state | partial_json: partial_json}

    event = {:tool_call_end, content_index, tool_call, state.partial}
    EventStream.push(stream, event)
    state
  end

  defp process_proxy_event(
         %{"type" => "done", "reason" => reason, "usage" => usage_data},
         state,
         stream
       ) do
    usage = decode_usage(usage_data)
    stop_reason = decode_stop_reason(reason)

    partial = %{state.partial | stop_reason: stop_reason, usage: usage}
    state = %{state | partial: partial}

    EventStream.complete(stream, partial)
    state
  end

  defp process_proxy_event(
         %{"type" => "error", "reason" => reason} = event_data,
         state,
         stream
       ) do
    usage = decode_usage(Map.get(event_data, "usage", %{}))
    stop_reason = decode_stop_reason(reason)
    error_message = Map.get(event_data, "errorMessage")

    partial = %{
      state.partial
      | stop_reason: stop_reason,
        usage: usage,
        error_message: error_message
    }

    state = %{state | partial: partial}

    EventStream.error(stream, partial)
    state
  end

  defp process_proxy_event(_unknown, state, _stream) do
    # Ignore unknown event types
    state
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp update_content_at(partial, index, content_or_fn) do
    # Ensure content list is long enough
    content_list = partial.content
    padded = pad_list(content_list, index + 1, nil)

    updated =
      case content_or_fn do
        fun when is_function(fun, 1) ->
          current = Enum.at(padded, index)
          List.replace_at(padded, index, fun.(current))

        value ->
          List.replace_at(padded, index, value)
      end

    %{partial | content: updated}
  end

  defp pad_list(list, target_length, padding) do
    current_length = length(list)

    if current_length >= target_length do
      list
    else
      list ++ List.duplicate(padding, target_length - current_length)
    end
  end

  defp decode_stop_reason("stop"), do: :stop
  defp decode_stop_reason("length"), do: :length
  defp decode_stop_reason("toolUse"), do: :tool_use
  defp decode_stop_reason("tool_use"), do: :tool_use
  defp decode_stop_reason("aborted"), do: :aborted
  defp decode_stop_reason("error"), do: :error
  defp decode_stop_reason(_), do: :stop

  defp decode_usage(nil), do: %Usage{}

  defp decode_usage(usage_data) when is_map(usage_data) do
    cost_data = Map.get(usage_data, "cost", %{})

    %Usage{
      input: Map.get(usage_data, "input", 0),
      output: Map.get(usage_data, "output", 0),
      cache_read: Map.get(usage_data, "cacheRead", 0),
      cache_write: Map.get(usage_data, "cacheWrite", 0),
      total_tokens: Map.get(usage_data, "totalTokens", 0),
      cost: %Cost{
        input: Map.get(cost_data, "input", 0.0),
        output: Map.get(cost_data, "output", 0.0),
        cache_read: Map.get(cost_data, "cacheRead", 0.0),
        cache_write: Map.get(cost_data, "cacheWrite", 0.0),
        total: Map.get(cost_data, "total", 0.0)
      }
    }
  end

  defp encode_model(model) do
    %{
      id: model.id,
      name: model.name,
      api: to_string(model.api),
      provider: to_string(model.provider),
      baseUrl: model.base_url,
      reasoning: model.reasoning,
      input: Enum.map(model.input, &to_string/1),
      cost: %{
        input: model.cost.input,
        output: model.cost.output,
        cacheRead: model.cost.cache_read,
        cacheWrite: model.cost.cache_write
      },
      contextWindow: model.context_window,
      maxTokens: model.max_tokens,
      headers: model.headers,
      compat: model.compat
    }
  end

  defp encode_context(context) do
    %{
      systemPrompt: context.system_prompt,
      messages: Enum.map(context.messages, &encode_message/1),
      tools: Enum.map(context.tools, &encode_tool/1)
    }
  end

  defp encode_message(%Ai.Types.UserMessage{} = msg) do
    %{
      role: "user",
      content: encode_content(msg.content),
      timestamp: msg.timestamp
    }
  end

  defp encode_message(%Ai.Types.AssistantMessage{} = msg) do
    %{
      role: "assistant",
      content: Enum.map(msg.content, &encode_content_block/1),
      api: to_string(msg.api),
      provider: to_string(msg.provider),
      model: msg.model,
      usage: encode_usage(msg.usage),
      stopReason: encode_stop_reason(msg.stop_reason),
      errorMessage: msg.error_message,
      timestamp: msg.timestamp
    }
  end

  defp encode_message(%Ai.Types.ToolResultMessage{} = msg) do
    %{
      role: "tool_result",
      toolCallId: msg.tool_call_id,
      toolName: msg.tool_name,
      content: Enum.map(msg.content, &encode_content_block/1),
      details: msg.details,
      isError: msg.is_error,
      timestamp: msg.timestamp
    }
  end

  defp encode_content(content) when is_binary(content), do: content

  defp encode_content(content) when is_list(content) do
    Enum.map(content, &encode_content_block/1)
  end

  defp encode_content_block(%Ai.Types.TextContent{} = c) do
    %{type: "text", text: c.text, textSignature: c.text_signature}
  end

  defp encode_content_block(%Ai.Types.ThinkingContent{} = c) do
    %{type: "thinking", thinking: c.thinking, thinkingSignature: c.thinking_signature}
  end

  defp encode_content_block(%Ai.Types.ImageContent{} = c) do
    %{type: "image", data: c.data, mimeType: c.mime_type}
  end

  defp encode_content_block(%Ai.Types.ToolCall{} = c) do
    %{
      type: "toolCall",
      id: c.id,
      name: c.name,
      arguments: c.arguments,
      thoughtSignature: c.thought_signature
    }
  end

  defp encode_tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  end

  defp encode_usage(nil), do: nil

  defp encode_usage(usage) do
    %{
      input: usage.input,
      output: usage.output,
      cacheRead: usage.cache_read,
      cacheWrite: usage.cache_write,
      totalTokens: usage.total_tokens,
      cost: %{
        input: usage.cost.input,
        output: usage.cost.output,
        cacheRead: usage.cost.cache_read,
        cacheWrite: usage.cost.cache_write,
        total: usage.cost.total
      }
    }
  end

  defp encode_stop_reason(:stop), do: "stop"
  defp encode_stop_reason(:length), do: "length"
  defp encode_stop_reason(:tool_use), do: "toolUse"
  defp encode_stop_reason(:aborted), do: "aborted"
  defp encode_stop_reason(:error), do: "error"
  defp encode_stop_reason(nil), do: nil

  @doc """
  Parse partial/streaming JSON, attempting to complete incomplete JSON.

  Returns an empty map if parsing fails.
  """
  @spec parse_streaming_json(String.t()) :: map()
  def parse_streaming_json(json) when is_binary(json) do
    # Try to parse as complete JSON first
    case Jason.decode(json) do
      {:ok, result} when is_map(result) ->
        result

      _ ->
        # Try to complete the JSON and parse
        completed = complete_json(json)

        case Jason.decode(completed) do
          {:ok, result} when is_map(result) -> result
          _ -> %{}
        end
    end
  end

  def parse_streaming_json(_), do: %{}

  defp complete_json(json) do
    # Count unmatched brackets and braces
    {open_braces, open_brackets} =
      json
      |> String.graphemes()
      |> Enum.reduce({0, 0}, fn
        "{", {b, a} -> {b + 1, a}
        "}", {b, a} -> {b - 1, a}
        "[", {b, a} -> {b, a + 1}
        "]", {b, a} -> {b, a - 1}
        _, acc -> acc
      end)

    # Add closing characters.
    # Close brackets before braces (e.g. `{ "items": [1,2` needs `]}` not `}]`).
    closing =
      String.duplicate("]", max(open_brackets, 0)) <> String.duplicate("}", max(open_braces, 0))

    json <> closing
  end
end
