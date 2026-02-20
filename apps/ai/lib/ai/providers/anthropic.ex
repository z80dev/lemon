defmodule Ai.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API provider implementation.

  Implements the `Ai.Provider` behaviour for streaming responses from
  Anthropic's Claude models via the Messages API.

  ## Features

  - Server-Sent Events (SSE) streaming
  - Content blocks: text, thinking, tool_use
  - Token usage tracking
  - Prompt caching support

  ## Configuration

  The API key can be provided via:
  - `api_key` option in StreamOptions
  - `ANTHROPIC_API_KEY` environment variable
  """

  @behaviour Ai.Provider

  alias Ai.EventStream
  alias Ai.Providers.HttpTrace

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    Model,
    StreamOptions,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    Usage
  }

  @api_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  @max_retries 2
  @base_retry_delay_ms 400
  @kimi_history_limit_env "LEMON_KIMI_MAX_REQUEST_MESSAGES"
  @kimi_default_history_limit 200

  # ============================================================================
  # Provider Callbacks
  # ============================================================================

  @impl true
  def api_id, do: :anthropic_messages

  @impl true
  def provider_id, do: :anthropic

  @impl true
  def get_env_api_key do
    System.get_env("ANTHROPIC_API_KEY")
  end

  @impl true
  def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
    owner = self()

    # Start EventStream with owner monitoring and timeout
    stream_timeout = opts.stream_timeout || 300_000

    {:ok, stream} =
      EventStream.start_link(
        owner: owner,
        max_queue: 10_000,
        timeout: stream_timeout
      )

    # Start streaming task under supervision
    {:ok, task_pid} =
      Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
        do_stream(stream, model, context, opts)
      end)

    # Attach task to stream for lifecycle management
    EventStream.attach_task(stream, task_pid)

    {:ok, stream}
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp do_stream(stream, model, context, opts) do
    output = init_assistant_message(model)

    try do
      api_key = resolve_api_key(model, opts)

      if api_key == "" do
        raise missing_api_key_error(model.provider)
      end

      base_url =
        if model.base_url != "" do
          String.trim_trailing(model.base_url, "/")
        else
          @api_base_url
        end

      url = "#{base_url}/v1/messages"

      headers = build_headers(api_key, model.headers, opts.headers)
      {body, history_info} = build_request_body(model, context, opts)
      trace_id = HttpTrace.new_trace_id("anthropic")
      messages = Map.get(body, "messages", [])

      request_summary =
        summarize_http_request(trace_id, model, context, opts, url, body, messages, history_info)

      HttpTrace.log("anthropic", "request_start", request_summary)

      if messages == [] do
        HttpTrace.log_error("anthropic", "request_invalid_empty_messages", request_summary)

        error_output =
          %{
            output
            | stop_reason: :error,
              error_message: "No text remained after provider message filtering."
          }

        EventStream.error(stream, error_output)
      else
        debug_log("request", %{
          trace_id: trace_id,
          url: url,
          model: model.id,
          base_url: base_url,
          headers: redact_headers(headers),
          body: body
        })

        EventStream.push_async(stream, {:start, output})

        # Initial state for SSE parsing and block tracking
        initial_state = %{
          output: output,
          stream: stream,
          blocks: [],
          sse_buffer: "",
          model: model
        }

        result = stream_request_with_retries(url, headers, body, initial_state, trace_id)

        case result do
          {:ok, %Req.Response{status: 200, private: %{sse_state: final_state}}} ->
            debug_log("response", %{status: 200, streamed: true})
            # Process any remaining buffer
            final_state = flush_sse_buffer(final_state)
            finalize_stream(final_state)

          {:ok, %Req.Response{status: 200} = resp} ->
            debug_log("response", %{status: 200, streamed: false})
            # No streaming occurred (empty response or single chunk)
            final_state = resp.private[:sse_state] || initial_state
            final_state = flush_sse_buffer(final_state)
            finalize_stream(final_state)

          {:ok, %Req.Response{status: status, body: body, headers: response_headers}} ->
            debug_log("response_error", %{status: status, body: body})

            HttpTrace.log_error("anthropic", "response_error", %{
              trace_id: trace_id,
              status: status,
              provider_request_id:
                HttpTrace.response_header_value(response_headers, [
                  "x-request-id",
                  "request-id",
                  "anthropic-request-id"
                ]),
              body_bytes: HttpTrace.body_bytes(body),
              body_preview: HttpTrace.body_preview(body),
              model: model.id,
              session_id: opts.session_id,
              converted_messages: length(messages)
            })

            error_msg = extract_error_message(body, status)
            error_output = %{output | stop_reason: :error, error_message: error_msg}
            EventStream.error(stream, error_output)

          {:error, reason} ->
            debug_log("response_error", %{error: inspect(reason)})

            HttpTrace.log_error("anthropic", "transport_error", %{
              trace_id: trace_id,
              error: inspect(reason, limit: 50, printable_limit: 8_000),
              model: model.id,
              session_id: opts.session_id
            })

            error_output = %{output | stop_reason: :error, error_message: inspect(reason)}
            EventStream.error(stream, error_output)
        end
      end
    rescue
      e ->
        HttpTrace.log_error("anthropic", "stream_exception", %{
          error: Exception.message(e),
          exception: inspect(e, limit: 20, printable_limit: 2_000),
          model: model.id,
          session_id: opts.session_id
        })

        error_output = %{output | stop_reason: :error, error_message: Exception.message(e)}
        EventStream.error(stream, error_output)
    end
  end

  defp resolve_api_key(model, opts) do
    cond do
      is_binary(opts.api_key) and opts.api_key != "" ->
        opts.api_key

      api_key = get_provider_env_api_key(model.provider) ->
        api_key

      api_key = get_env_api_key() ->
        api_key

      true ->
        ""
    end
  end

  defp get_provider_env_api_key(provider) do
    provider
    |> provider_env_vars()
    |> Enum.find_value(&env_value/1)
  end

  defp provider_env_vars(:kimi), do: ["KIMI_API_KEY", "MOONSHOT_API_KEY", "ANTHROPIC_API_KEY"]
  defp provider_env_vars("kimi"), do: ["KIMI_API_KEY", "MOONSHOT_API_KEY", "ANTHROPIC_API_KEY"]
  defp provider_env_vars(_), do: ["ANTHROPIC_API_KEY"]

  defp env_value(name) when is_binary(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp missing_api_key_error(:kimi),
    do:
      "No API key provided for Kimi. Set KIMI_API_KEY (or MOONSHOT_API_KEY) or pass api_key in options."

  defp missing_api_key_error("kimi"),
    do:
      "No API key provided for Kimi. Set KIMI_API_KEY (or MOONSHOT_API_KEY) or pass api_key in options."

  defp missing_api_key_error(_),
    do: "No API key provided for Anthropic. Set ANTHROPIC_API_KEY or pass api_key in options."

  defp flush_sse_buffer(%{sse_buffer: ""} = state), do: state

  defp flush_sse_buffer(%{sse_buffer: buffer} = state) do
    # Try to parse any remaining complete events in the buffer
    {events, _remaining} = parse_sse_events(buffer <> "\n\n")

    Enum.reduce(events, state, fn event, acc_state ->
      process_sse_event(event, acc_state)
    end)
  end

  defp finalize_stream(%{output: output, stream: stream}) do
    case output.stop_reason do
      reason when reason in [:error, :aborted] ->
        EventStream.error(stream, output)

      _ ->
        EventStream.complete(stream, output)
    end
  end

  defp stream_request_with_retries(url, headers, body, initial_state, trace_id, attempt \\ 0) do
    chunk_key = {__MODULE__, :chunk_seen, make_ref()}
    Process.put(chunk_key, false)

    result =
      Req.post(url,
        headers: headers,
        json: body,
        into: fn {:data, data}, {req, resp} ->
          Process.put(chunk_key, true)
          debug_log("sse_chunk", data)

          # Get current accumulated state from response private data, or use initial
          acc_state = resp.private[:sse_state] || initial_state

          # Process the SSE chunk
          new_state = process_sse_chunk(data, acc_state)

          # Store updated state in response private data
          resp = put_in(resp.private[:sse_state], new_state)

          {:cont, {req, resp}}
        end,
        receive_timeout: 300_000
      )

    saw_chunk = Process.get(chunk_key, false)
    Process.delete(chunk_key)

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        result

      {:ok, %Req.Response{status: status}} = response ->
        if attempt < @max_retries and retryable_http_status?(status) do
          retry_delay = retry_delay_ms(attempt)

          debug_log("retry_http", %{
            status: status,
            attempt: attempt + 1,
            max_retries: @max_retries,
            delay_ms: retry_delay
          })

          HttpTrace.log("anthropic", "retry_http", %{
            trace_id: trace_id,
            status: status,
            attempt: attempt + 1,
            max_retries: @max_retries,
            delay_ms: retry_delay
          })

          Process.sleep(retry_delay)
          stream_request_with_retries(url, headers, body, initial_state, trace_id, attempt + 1)
        else
          response
        end

      {:error, reason} = error ->
        if attempt < @max_retries and not saw_chunk and retryable_transport_error?(reason) do
          retry_delay = retry_delay_ms(attempt)

          debug_log("retry_transport", %{
            reason: inspect(reason),
            attempt: attempt + 1,
            max_retries: @max_retries,
            delay_ms: retry_delay
          })

          HttpTrace.log("anthropic", "retry_transport", %{
            trace_id: trace_id,
            reason: inspect(reason, limit: 50, printable_limit: 8_000),
            attempt: attempt + 1,
            max_retries: @max_retries,
            delay_ms: retry_delay
          })

          Process.sleep(retry_delay)
          stream_request_with_retries(url, headers, body, initial_state, trace_id, attempt + 1)
        else
          error
        end
    end
  end

  defp retry_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    (@base_retry_delay_ms * :math.pow(2, attempt)) |> trunc()
  end

  defp retryable_http_status?(status) when is_integer(status) do
    status in [408, 409, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]
  end

  defp retryable_http_status?(_), do: false

  defp retryable_transport_error?(%Req.TransportError{reason: reason}) do
    retryable_transport_reason?(reason)
  end

  defp retryable_transport_error?(reason), do: retryable_transport_reason?(reason)

  defp retryable_transport_reason?(reason)
       when reason in [
              :timeout,
              :closed,
              :econnrefused,
              :econnreset,
              :enetdown,
              :enetwork_unreachable,
              :nxdomain,
              :ehostunreach,
              :unreachable
            ],
       do: true

  defp retryable_transport_reason?({:tls_alert, {_alert, _detail}}), do: true
  defp retryable_transport_reason?({:failed_connect, _}), do: true
  defp retryable_transport_reason?({:closed, _}), do: true

  defp retryable_transport_reason?(reason) when is_tuple(reason) do
    reason_text = reason |> inspect() |> String.downcase()

    String.contains?(reason_text, "timeout") or
      String.contains?(reason_text, "temporarily unavailable") or
      String.contains?(reason_text, "bad_record_mac")
  end

  defp retryable_transport_reason?(_), do: false

  # ============================================================================
  # SSE Parsing
  # ============================================================================

  defp process_sse_chunk(chunk, state) when is_binary(chunk) do
    # Append to buffer and process complete events
    buffer = state.sse_buffer <> chunk
    {events, remaining_buffer} = parse_sse_events(buffer)

    state = %{state | sse_buffer: remaining_buffer}

    # Process each event
    Enum.reduce(events, state, fn event, acc_state ->
      process_sse_event(event, acc_state)
    end)
  end

  defp parse_sse_events(buffer) do
    # Split by double newline (SSE event separator)
    # Handle both \n\n and \r\n\r\n
    parts = String.split(buffer, ~r/\r?\n\r?\n/)

    case parts do
      [single] ->
        # No complete event yet
        {[], single}

      parts ->
        # Last part may be incomplete
        {complete, [incomplete]} = Enum.split(parts, -1)

        events =
          complete
          |> Enum.map(&parse_sse_event/1)
          |> Enum.reject(&is_nil/1)

        {events, incomplete}
    end
  end

  defp parse_sse_event(event_text) do
    lines = String.split(event_text, ~r/\r?\n/)

    event =
      Enum.reduce(lines, %{event: nil, data: nil}, fn line, acc ->
        cond do
          String.starts_with?(line, "event:") ->
            event = String.trim_leading(line, "event:")
            %{acc | event: String.trim_leading(event, " ")}

          String.starts_with?(line, "data:") ->
            data = String.trim_leading(line, "data:")
            %{acc | data: String.trim_leading(data, " ")}

          true ->
            acc
        end
      end)

    if event.event && event.data do
      case Jason.decode(event.data) do
        {:ok, json} -> {event.event, json}
        {:error, _} -> nil
      end
    else
      nil
    end
  end

  # ============================================================================
  # Event Processing
  # ============================================================================

  defp process_sse_event({"message_start", %{"message" => message}}, state) do
    # Capture initial token usage
    usage = message["usage"] || %{}

    output =
      update_usage(
        state.output,
        %{
          "input_tokens" => usage["input_tokens"],
          "output_tokens" => usage["output_tokens"],
          "cache_read_input_tokens" => usage["cache_read_input_tokens"],
          "cache_creation_input_tokens" => usage["cache_creation_input_tokens"]
        },
        state.model
      )

    %{state | output: output}
  end

  defp process_sse_event(
         {"content_block_start", %{"index" => index, "content_block" => block}},
         state
       ) do
    case block["type"] do
      "text" ->
        text_block = %TextContent{type: :text, text: ""}
        content_index = length(state.output.content)
        blocks = state.blocks ++ [{index, text_block}]
        output = %{state.output | content: state.output.content ++ [text_block]}
        EventStream.push_async(state.stream, {:text_start, content_index, output})
        %{state | blocks: blocks, output: output}

      "thinking" ->
        thinking_block = %ThinkingContent{type: :thinking, thinking: "", thinking_signature: nil}
        content_index = length(state.output.content)
        blocks = state.blocks ++ [{index, thinking_block}]
        output = %{state.output | content: state.output.content ++ [thinking_block]}
        EventStream.push_async(state.stream, {:thinking_start, content_index, output})
        %{state | blocks: blocks, output: output}

      "tool_use" ->
        tool_call = %ToolCall{
          type: :tool_call,
          id: block["id"] || "",
          name: block["name"] || "",
          arguments: %{}
        }

        content_index = length(state.output.content)
        blocks = state.blocks ++ [{index, tool_call, ""}]
        output = %{state.output | content: state.output.content ++ [tool_call]}
        EventStream.push_async(state.stream, {:tool_call_start, content_index, output})
        %{state | blocks: blocks, output: output}

      _ ->
        state
    end
  end

  defp process_sse_event({"content_block_delta", %{"index" => index, "delta" => delta}}, state) do
    case delta["type"] do
      "text_delta" ->
        text = delta["text"] || ""
        update_text_block(state, index, text)

      "thinking_delta" ->
        thinking = delta["thinking"] || ""
        update_thinking_block(state, index, thinking)

      "input_json_delta" ->
        partial_json = delta["partial_json"] || ""
        update_tool_call_block(state, index, partial_json)

      "signature_delta" ->
        signature = delta["signature"] || ""
        update_thinking_signature(state, index, signature)

      _ ->
        state
    end
  end

  defp process_sse_event({"content_block_stop", %{"index" => index}}, state) do
    case find_block_by_index(state.blocks, index) do
      {content_index, %TextContent{} = block} ->
        EventStream.push_async(state.stream, {:text_end, content_index, block.text, state.output})
        state

      {content_index, %ThinkingContent{} = block} ->
        EventStream.push_async(
          state.stream,
          {:thinking_end, content_index, block.thinking, state.output}
        )

        state

      {content_index, %ToolCall{} = block, _partial_json} ->
        EventStream.push_async(state.stream, {:tool_call_end, content_index, block, state.output})
        state

      _ ->
        state
    end
  end

  defp process_sse_event({"message_delta", %{"delta" => delta, "usage" => usage}}, state) do
    # Update stop reason
    output =
      case delta["stop_reason"] do
        nil -> state.output
        reason -> %{state.output | stop_reason: map_stop_reason(reason)}
      end

    # Update usage
    output = update_usage(output, usage, state.model)

    %{state | output: output}
  end

  defp process_sse_event({"message_stop", _data}, state) do
    state
  end

  defp process_sse_event({"ping", _data}, state) do
    state
  end

  defp process_sse_event({"error", %{"error" => error}}, state) do
    error_msg = error["message"] || "Unknown error"
    output = %{state.output | stop_reason: :error, error_message: error_msg}
    %{state | output: output}
  end

  defp process_sse_event({_event_type, _data}, state) do
    # Unknown event type, ignore
    state
  end

  defp debug_log(tag, payload) do
    if System.get_env("LEMON_AI_DEBUG") == "1" do
      file = System.get_env("LEMON_AI_DEBUG_FILE") || "/tmp/lemon_anthropic_sse.log"
      line = "[#{DateTime.utc_now()}] #{tag}: #{inspect(payload)}\n"
      File.write(file, line, [:append])
    end
  end

  defp redact_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {"x-api-key", _} -> {"x-api-key", "***"}
      {k, v} -> {k, v}
    end)
  end

  defp summarize_http_request(trace_id, model, context, opts, url, body, messages, history_info) do
    %{
      trace_id: trace_id,
      model: model.id,
      provider: model.provider,
      api: model.api,
      session_id: opts.session_id,
      run_id: trace_header(opts.headers, "x-lemon-run-id"),
      session_key: trace_header(opts.headers, "x-lemon-session-key"),
      agent_id: trace_header(opts.headers, "x-lemon-agent-id"),
      url: url,
      raw_message_count: length(context.messages || []),
      prepared_message_count: Map.get(history_info, :prepared_message_count),
      converted_message_count: length(messages),
      history_limit: Map.get(history_info, :max_messages),
      history_dropped: Map.get(history_info, :dropped_count, 0),
      history_dropped_orphan_tool_results: Map.get(history_info, :dropped_orphan_tool_results, 0),
      converted_message_summary: summarize_messages(messages),
      system_prompt_bytes: HttpTrace.summarize_text_size(context.system_prompt),
      tools_count: length(context.tools || []),
      max_tokens: Map.get(body, "max_tokens"),
      temperature: opts.temperature
    }
  end

  defp summarize_messages(messages) when is_list(messages) do
    messages
    |> Enum.take(20)
    |> Enum.map(fn
      message when is_map(message) ->
        content = Map.get(message, "content")

        %{
          role: Map.get(message, "role"),
          content_items:
            if(is_list(content),
              do: length(content),
              else: if(is_binary(content), do: 1, else: 0)
            ),
          content_types: summarize_content_types(content),
          text_bytes: summarize_text_bytes(content)
        }

      other ->
        %{
          role: "unknown",
          content_items: 0,
          content_types: %{},
          text_bytes: 0,
          raw: inspect(other)
        }
    end)
  end

  defp summarize_messages(_), do: []

  defp trace_header(headers, key) when is_map(headers), do: Map.get(headers, key)

  defp trace_header(headers, key) when is_list(headers) do
    key_down = String.downcase(key)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        if String.downcase(k) == key_down, do: v, else: nil

      _ ->
        nil
    end)
  end

  defp trace_header(_headers, _key), do: nil

  defp summarize_content_types(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => type} -> type
      _ -> "unknown"
    end)
    |> Enum.frequencies()
  end

  defp summarize_content_types(content) when is_binary(content), do: %{"text" => 1}
  defp summarize_content_types(_), do: %{}

  defp summarize_text_bytes(content) when is_binary(content), do: byte_size(content)

  defp summarize_text_bytes(content) when is_list(content) do
    Enum.reduce(content, 0, fn
      %{"text" => text}, acc when is_binary(text) ->
        acc + byte_size(text)

      %{"type" => "text", "text" => text}, acc when is_binary(text) ->
        acc + byte_size(text)

      _, acc ->
        acc
    end)
  end

  defp summarize_text_bytes(_), do: 0

  # ============================================================================
  # Block Update Helpers
  # ============================================================================

  defp update_text_block(state, index, delta_text) do
    case find_block_by_index(state.blocks, index) do
      {content_index, %TextContent{} = block} ->
        updated_block = %{block | text: block.text <> delta_text}
        blocks = update_block_at_index(state.blocks, index, updated_block)
        output = update_content_at_index(state.output, content_index, updated_block)
        EventStream.push_async(state.stream, {:text_delta, content_index, delta_text, output})
        %{state | blocks: blocks, output: output}

      _ ->
        state
    end
  end

  defp update_thinking_block(state, index, delta_thinking) do
    case find_block_by_index(state.blocks, index) do
      {content_index, %ThinkingContent{} = block} ->
        updated_block = %{block | thinking: block.thinking <> delta_thinking}
        blocks = update_block_at_index(state.blocks, index, updated_block)
        output = update_content_at_index(state.output, content_index, updated_block)

        EventStream.push_async(
          state.stream,
          {:thinking_delta, content_index, delta_thinking, output}
        )

        %{state | blocks: blocks, output: output}

      _ ->
        state
    end
  end

  defp update_thinking_signature(state, index, delta_signature) do
    case find_block_by_index(state.blocks, index) do
      {content_index, %ThinkingContent{} = block} ->
        current_sig = block.thinking_signature || ""
        updated_block = %{block | thinking_signature: current_sig <> delta_signature}
        blocks = update_block_at_index(state.blocks, index, updated_block)
        output = update_content_at_index(state.output, content_index, updated_block)
        %{state | blocks: blocks, output: output}

      _ ->
        state
    end
  end

  defp update_tool_call_block(state, index, partial_json) do
    case find_block_by_index(state.blocks, index) do
      {content_index, %ToolCall{} = block, current_json} ->
        new_json = current_json <> partial_json
        # Parse the accumulated JSON to update arguments
        arguments = parse_partial_json(new_json)
        updated_block = %{block | arguments: arguments}
        blocks = update_tool_block_at_index(state.blocks, index, updated_block, new_json)
        output = update_content_at_index(state.output, content_index, updated_block)

        EventStream.push_async(
          state.stream,
          {:tool_call_delta, content_index, partial_json, output}
        )

        %{state | blocks: blocks, output: output}

      _ ->
        state
    end
  end

  defp find_block_by_index(blocks, target_index) do
    blocks
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{^target_index, block}, content_index} ->
        {content_index, block}

      {{^target_index, block, partial_json}, content_index} ->
        {content_index, block, partial_json}

      _ ->
        nil
    end)
  end

  defp update_block_at_index(blocks, target_index, updated_block) do
    Enum.map(blocks, fn
      {^target_index, _block} -> {target_index, updated_block}
      other -> other
    end)
  end

  defp update_tool_block_at_index(blocks, target_index, updated_block, new_json) do
    Enum.map(blocks, fn
      {^target_index, _block, _json} -> {target_index, updated_block, new_json}
      other -> other
    end)
  end

  defp update_content_at_index(output, content_index, updated_block) do
    content = List.replace_at(output.content, content_index, updated_block)
    %{output | content: content}
  end

  # ============================================================================
  # Request Building
  # ============================================================================

  defp build_headers(api_key, model_headers, opts_headers) do
    beta_features = ["fine-grained-tool-streaming-2025-05-14"]

    base_headers = [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"anthropic-beta", Enum.join(beta_features, ",")}
    ]

    # Merge model and options headers
    extra_headers =
      Map.merge(model_headers || %{}, opts_headers || %{})
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    base_headers ++ extra_headers
  end

  defp build_request_body(model, context, opts) do
    {history_messages, history_info} = limit_history_for_provider(context.messages || [], model)

    body = %{
      "model" => model.id,
      "messages" => convert_messages(history_messages, model),
      "max_tokens" => opts.max_tokens || div(model.max_tokens, 3),
      "stream" => true
    }

    # Add system prompt (skip if empty to avoid API errors on some providers)
    body =
      if context.system_prompt && String.trim(context.system_prompt) != "" do
        Map.put(body, "system", [
          %{
            "type" => "text",
            "text" => context.system_prompt,
            "cache_control" => %{"type" => "ephemeral"}
          }
        ])
      else
        body
      end

    # Add temperature
    body =
      if opts.temperature do
        Map.put(body, "temperature", opts.temperature)
      else
        body
      end

    # Add tools
    body =
      if context.tools && length(context.tools) > 0 do
        Map.put(body, "tools", convert_tools(context.tools))
      else
        body
      end

    # Add thinking/extended thinking if model supports reasoning
    body =
      if model.reasoning && opts.reasoning do
        thinking_budget = get_thinking_budget(opts.reasoning, opts.thinking_budgets)

        Map.put(body, "thinking", %{
          "type" => "enabled",
          "budget_tokens" => thinking_budget
        })
      else
        body
      end

    {body, history_info}
  end

  @doc false
  @spec request_history_limit(Model.t() | map()) :: pos_integer() | nil
  def request_history_limit(%Model{provider: :kimi}), do: kimi_history_limit()
  def request_history_limit(%Model{provider: "kimi"}), do: kimi_history_limit()
  def request_history_limit(_), do: nil

  defp limit_history_for_provider(messages, %Model{provider: :kimi} = model)
       when is_list(messages) do
    max_messages = request_history_limit(model) || @kimi_default_history_limit
    trimmed = Enum.take(messages, -max_messages)
    dropped_by_limit = max(length(messages) - length(trimmed), 0)
    {trimmed, dropped_orphans} = drop_leading_tool_result_messages(trimmed)

    {trimmed,
     %{
       max_messages: max_messages,
       prepared_message_count: length(trimmed),
       dropped_count: dropped_by_limit + dropped_orphans,
       dropped_orphan_tool_results: dropped_orphans
     }}
  end

  defp limit_history_for_provider(messages, _model) when is_list(messages) do
    {messages,
     %{
       max_messages: nil,
       prepared_message_count: length(messages),
       dropped_count: 0,
       dropped_orphan_tool_results: 0
     }}
  end

  defp limit_history_for_provider(_messages, model), do: limit_history_for_provider([], model)

  defp drop_leading_tool_result_messages(messages) do
    {dropped, rest} =
      Enum.split_while(messages, fn
        %ToolResultMessage{} -> true
        _ -> false
      end)

    {rest, length(dropped)}
  end

  defp kimi_history_limit do
    case System.get_env(@kimi_history_limit_env) do
      nil ->
        @kimi_default_history_limit

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {limit, ""} when limit > 0 -> limit
          _ -> @kimi_default_history_limit
        end
    end
  end

  defp convert_messages(messages, model) do
    messages
    |> Enum.map(fn msg -> convert_message(msg, model) end)
    |> Enum.reject(&is_nil/1)
    |> add_cache_control_to_last_user_message()
  end

  defp convert_message(%Ai.Types.UserMessage{content: content}, _model) when is_binary(content) do
    if String.trim(content) != "" do
      %{
        "role" => "user",
        "content" => content
      }
    else
      nil
    end
  end

  defp convert_message(%Ai.Types.UserMessage{content: content}, model) when is_list(content) do
    blocks =
      content
      |> Enum.map(&convert_user_content_block(&1, model))
      |> Enum.reject(&is_nil/1)

    if length(blocks) > 0 do
      %{
        "role" => "user",
        "content" => blocks
      }
    else
      nil
    end
  end

  defp convert_message(%AssistantMessage{content: content}, _model) do
    blocks =
      content
      |> Enum.map(&convert_assistant_content_block/1)
      |> Enum.reject(&is_nil/1)

    if length(blocks) > 0 do
      %{
        "role" => "assistant",
        "content" => blocks
      }
    else
      nil
    end
  end

  defp convert_message(%Ai.Types.ToolResultMessage{} = msg, _model) do
    content = convert_tool_result_content(msg.content)

    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => msg.tool_call_id,
          "content" => content,
          "is_error" => msg.is_error
        }
      ]
    }
  end

  defp convert_message(_, _), do: nil

  defp convert_user_content_block(%TextContent{text: text}, _model) do
    if String.trim(text) != "" do
      %{"type" => "text", "text" => text}
    else
      nil
    end
  end

  defp convert_user_content_block(%Ai.Types.ImageContent{data: data, mime_type: mime_type}, model) do
    if :image in model.input do
      %{
        "type" => "image",
        "source" => %{
          "type" => "base64",
          "media_type" => mime_type,
          "data" => data
        }
      }
    else
      nil
    end
  end

  defp convert_user_content_block(_, _), do: nil

  defp convert_assistant_content_block(%TextContent{text: text}) do
    if String.trim(text) != "" do
      %{"type" => "text", "text" => text}
    else
      nil
    end
  end

  defp convert_assistant_content_block(%ThinkingContent{
         thinking: thinking,
         thinking_signature: sig
       }) do
    if String.trim(thinking) != "" do
      # If signature is missing, convert to plain text
      if sig && String.trim(sig) != "" do
        %{
          "type" => "thinking",
          "thinking" => thinking,
          "signature" => sig
        }
      else
        %{"type" => "text", "text" => thinking}
      end
    else
      nil
    end
  end

  defp convert_assistant_content_block(%ToolCall{id: id, name: name, arguments: args}) do
    %{
      "type" => "tool_use",
      "id" => id,
      "name" => name,
      "input" => args
    }
  end

  defp convert_assistant_content_block(_), do: nil

  defp convert_tool_result_content(content) when is_list(content) do
    text_parts =
      content
      |> Enum.filter(fn
        %TextContent{} -> true
        _ -> false
      end)
      |> Enum.map(fn %TextContent{text: text} -> text end)
      |> Enum.join("\n")

    if text_parts != "", do: text_parts, else: "(empty result)"
  end

  defp convert_tool_result_content(_), do: "(empty result)"

  defp add_cache_control_to_last_user_message([]), do: []

  defp add_cache_control_to_last_user_message(messages) do
    {last, rest} = List.pop_at(messages, -1)

    if last["role"] == "user" do
      updated_last = add_cache_control_to_message(last)
      rest ++ [updated_last]
    else
      messages
    end
  end

  defp add_cache_control_to_message(%{"content" => content} = msg) when is_list(content) do
    case List.pop_at(content, -1) do
      {nil, _} ->
        msg

      {last_block, rest_blocks} ->
        updated_block = Map.put(last_block, "cache_control", %{"type" => "ephemeral"})
        %{msg | "content" => rest_blocks ++ [updated_block]}
    end
  end

  defp add_cache_control_to_message(msg), do: msg

  defp convert_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => %{
          "type" => "object",
          "properties" => tool.parameters["properties"] || %{},
          "required" => tool.parameters["required"] || []
        }
      }
    end)
  end

  # ============================================================================
  # Usage & Cost Helpers
  # ============================================================================

  defp init_assistant_message(model) do
    %AssistantMessage{
      role: :assistant,
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
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp update_usage(output, usage_data, model) do
    usage = output.usage

    input = usage_data["input_tokens"] || usage.input
    output_tokens = usage_data["output_tokens"] || usage.output
    cache_read = usage_data["cache_read_input_tokens"] || usage.cache_read
    cache_write = usage_data["cache_creation_input_tokens"] || usage.cache_write

    total_tokens = input + output_tokens + cache_read + cache_write

    updated_usage = %{
      usage
      | input: input,
        output: output_tokens,
        cache_read: cache_read,
        cache_write: cache_write,
        total_tokens: total_tokens
    }

    # Calculate cost based on model pricing
    cost = Ai.calculate_cost(model, updated_usage)

    %{output | usage: %{updated_usage | cost: cost}}
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  defp map_stop_reason("end_turn"), do: :stop
  defp map_stop_reason("max_tokens"), do: :length
  defp map_stop_reason("tool_use"), do: :tool_use
  defp map_stop_reason("refusal"), do: :error
  defp map_stop_reason("pause_turn"), do: :stop
  defp map_stop_reason("stop_sequence"), do: :stop
  defp map_stop_reason("sensitive"), do: :error
  defp map_stop_reason(_), do: :stop

  defp get_thinking_budget(reasoning_level, budgets) do
    default_budgets = %{
      minimal: 1024,
      low: 4096,
      medium: 10_000,
      high: 32_000,
      xhigh: 64_000
    }

    budgets = Map.merge(default_budgets, budgets || %{})
    Map.get(budgets, reasoning_level, 10_000)
  end

  defp parse_partial_json(""), do: %{}

  defp parse_partial_json(json_str) do
    # Try to parse the JSON, handling incomplete JSON gracefully
    case Jason.decode(json_str) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp extract_error_message(body, status) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} -> msg
      {:ok, %{"error" => error}} when is_binary(error) -> error
      _ -> "HTTP #{status}: #{body}"
    end
  end

  defp extract_error_message(body, status) when is_map(body) do
    case body do
      %{"error" => %{"message" => msg}} -> msg
      %{"error" => error} when is_binary(error) -> error
      _ -> "HTTP #{status}"
    end
  end

  defp extract_error_message(_, status), do: "HTTP #{status}"

  # ============================================================================
  # Provider Registration
  # ============================================================================

  @doc false
  def register do
    Ai.ProviderRegistry.register(:anthropic_messages, __MODULE__)
  end
end
