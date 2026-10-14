defmodule LemonAi.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API provider implementation.

  Implements the `LemonAi.Provider` behaviour for streaming responses from
  Anthropic's Claude models via the Messages API.

  ## Features

  - Server-Sent Events (SSE) streaming
  - Content blocks: text, thinking, tool_use; tool results with text and image blocks
  - Thinking shape from the model's capability flags: adaptive thinking + effort for
    `adaptive_thinking` models, manual `budget_tokens` otherwise
    (summarized output when `compat.anthropic_thinking_display` permits it)
  - Token usage tracking and cost from catalog pricing
  - Prompt caching for string and block messages; provider option `cache_retention`
    accepts `:none`, `:short` (default), or `:long` (one hour on Anthropic)
  - Full conversation history is preserved; provider message limits are compaction
    hints, never permission to silently discard messages
  - Incomplete SSE responses fail with partial content instead of reporting success
  - Retries for 429/529/5xx and transport errors per
    `LemonAi.Providers.RetryHelper.policy/0`, honoring `retry-after` and
    `anthropic-ratelimit-*-reset`; the final error carries `retry_after_ms`

  ## Configuration

  The API key can be provided via:
  - `api_key` option in StreamOptions
  - `ANTHROPIC_API_KEY` environment variable
  """

  @behaviour LemonAi.Provider

  alias LemonAi.EventStream
  alias LemonAi.Providers.{HttpTrace, OpenCodeGoSession, RetryHelper}
  import LemonAi.Providers.AssistantMessageHelper

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    Model,
    StreamOptions,
    TextContent,
    ThinkingContent,
    ToolCall
  }

  @api_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"
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
    LemonAi.Providers.StreamingHelper.start_streaming(model, context, opts, &do_stream/4)
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp do_stream(stream, model, context, opts) do
    output = init_assistant_message(model)
    resolved_provider_opts = resolve_provider_options(model, opts)

    try do
      api_key = resolve_api_key(model, opts, resolved_provider_opts)

      if api_key == "" and not match?(%{allow_missing_api_key: true}, model.compat) do
        raise missing_api_key_error(model.provider)
      end

      base_url =
        case Map.get(resolved_provider_opts, :base_url) do
          override when is_binary(override) and override != "" ->
            String.trim_trailing(override, "/")

          _ ->
            if model.base_url != "" do
              String.trim_trailing(model.base_url, "/")
            else
              @api_base_url
            end
        end

      url = "#{base_url}/v1/messages"

      headers = build_headers(api_key, model, context, opts)
      {body, history_info} = build_request_body(model, context, opts, api_key)
      trace_id = HttpTrace.new_trace_id("anthropic")
      messages = Map.get(body, "messages", [])

      request_summary =
        summarize_http_request(trace_id, model, context, opts, url, body, messages, history_info)

      _ = HttpTrace.log("anthropic", "request_start", request_summary)

      if messages == [] do
        _ = HttpTrace.log_error("anthropic", "request_invalid_empty_messages", request_summary)

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
          terminal?: false,
          cache_creation: %{},
          model: model,
          oauth_request?: anthropic_oauth_request?(model.provider, api_key)
        }

        result =
          stream_request_with_retries(
            url,
            headers,
            body,
            initial_state,
            trace_id,
            RetryHelper.policy(),
            0
          )

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

            error_output = %{
              output
              | stop_reason: :error,
                error_message: error_msg,
                retry_after_ms: RetryHelper.retry_after_ms(response_headers)
            }

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

  defp resolve_api_key(model, opts, resolved_provider_opts) do
    cond do
      is_binary(opts.api_key) and opts.api_key != "" ->
        opts.api_key

      api_key = Map.get(resolved_provider_opts, :api_key) ->
        api_key

      api_key = get_provider_env_api_key(model.provider) ->
        api_key

      true ->
        ""
    end
  end

  defp resolve_provider_options(model, opts) do
    provider_options(opts, model.provider)
  end

  defp get_provider_env_api_key(provider) do
    provider
    |> provider_env_vars()
    |> Enum.find_value(&env_value/1)
  end

  defp provider_env_vars(:kimi), do: ["KIMI_API_KEY", "MOONSHOT_API_KEY", "ANTHROPIC_API_KEY"]
  defp provider_env_vars("kimi"), do: ["KIMI_API_KEY", "MOONSHOT_API_KEY", "ANTHROPIC_API_KEY"]
  defp provider_env_vars(:opencode), do: ["OPENCODE_API_KEY", "ANTHROPIC_API_KEY"]
  defp provider_env_vars("opencode"), do: ["OPENCODE_API_KEY", "ANTHROPIC_API_KEY"]
  defp provider_env_vars(:minimax), do: ["MINIMAX_API_KEY", "ANTHROPIC_API_KEY"]
  defp provider_env_vars("minimax"), do: ["MINIMAX_API_KEY", "ANTHROPIC_API_KEY"]

  defp provider_env_vars(:minimax_cn),
    do: ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY", "ANTHROPIC_API_KEY"]

  defp provider_env_vars("minimax_cn"),
    do: ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY", "ANTHROPIC_API_KEY"]

  defp provider_env_vars("anthropic"), do: ["ANTHROPIC_API_KEY"]
  defp provider_env_vars(provider) when is_atom(provider), do: ["ANTHROPIC_API_KEY"]
  # Other binary providers are user-configured custom endpoints: they only get
  # their own credential, never the ambient Anthropic key.
  defp provider_env_vars(_provider), do: []

  defp env_value(name) when is_binary(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp provider_options(%StreamOptions{provider_options: options}, key)
       when is_map(options) and is_atom(key) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key)) || %{}
  end

  # Binary providers are looked up as-is (custom providers) or by their
  # underscored name; never converted to a new atom.
  defp provider_options(%StreamOptions{provider_options: options}, key)
       when is_map(options) and is_binary(key) do
    normalized = String.replace(key, "-", "_")

    Map.get(options, key) || Map.get(options, normalized) ||
      Map.get(options, existing_atom(normalized)) || %{}
  end

  defp provider_options(_, _), do: %{}

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp missing_api_key_error(:kimi),
    do:
      "No API key provided for Kimi. Set KIMI_API_KEY (or MOONSHOT_API_KEY) or pass api_key in options."

  defp missing_api_key_error("kimi"),
    do:
      "No API key provided for Kimi. Set KIMI_API_KEY (or MOONSHOT_API_KEY) or pass api_key in options."

  defp missing_api_key_error(:opencode),
    do:
      "No API key provided for OpenCode. Set OPENCODE_API_KEY (or ANTHROPIC_API_KEY) or pass api_key in options."

  defp missing_api_key_error("opencode"),
    do:
      "No API key provided for OpenCode. Set OPENCODE_API_KEY (or ANTHROPIC_API_KEY) or pass api_key in options."

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

  defp finalize_stream(%{output: output, stream: stream, terminal?: terminal?}) do
    output =
      if not terminal? and output.stop_reason not in [:error, :aborted] do
        %{
          output
          | stop_reason: :error,
            error_message: "Anthropic stream ended before message_stop or a stop reason"
        }
      else
        output
      end

    case output.stop_reason do
      reason when reason in [:error, :aborted] ->
        EventStream.error(stream, output)

      _ ->
        EventStream.complete(stream, output)
    end
  end

  defp stream_request_with_retries(
         url,
         headers,
         body,
         initial_state,
         trace_id,
         policy,
         attempt
       ) do
    chunk_key = {__MODULE__, :chunk_seen, make_ref()}
    output_seen_key = {__MODULE__, :meaningful_output_seen, make_ref()}
    Process.put(chunk_key, false)
    Process.put(output_seen_key, false)

    result =
      Req.post(url,
        headers: headers,
        json: body,
        into: fn {:data, data}, {req, resp} ->
          if resp.status == 200 do
            Process.put(chunk_key, true)
            debug_log("sse_chunk", data)
            acc_state = resp.private[:sse_state] || initial_state
            new_state = process_sse_chunk(data, acc_state)

            if meaningful_output_transition?(acc_state, new_state) do
              Process.put(output_seen_key, true)
            end

            resp = put_in(resp.private[:sse_state], new_state)
            {:cont, {req, resp}}
          else
            # Keep HTTP error bodies available to classification and retry policy.
            {:cont, {req, %{resp | body: (resp.body || "") <> data}}}
          end
        end,
        receive_timeout: 300_000
      )

    _saw_chunk = Process.get(chunk_key, false)
    saw_meaningful_output = Process.get(output_seen_key, false)
    Process.delete(chunk_key)
    Process.delete(output_seen_key)

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        result

      {:ok, %Req.Response{status: status} = response} = wrapped_response ->
        retry_delay =
          if RetryHelper.retry_allowed?(attempt, policy) and
               retryable_http_response?(response, initial_state.model) do
            RetryHelper.http_retry_delay_ms(attempt, response.headers, policy)
          else
            :give_up
          end

        case retry_delay do
          :give_up ->
            wrapped_response

          delay_ms ->
            log_retry(trace_id, "retry_http", %{status: status}, attempt, policy, delay_ms)
            RetryHelper.sleep(delay_ms)

            stream_request_with_retries(
              url,
              headers,
              body,
              initial_state,
              trace_id,
              policy,
              attempt + 1
            )
        end

      {:error, reason} = error ->
        if RetryHelper.retry_allowed?(attempt, policy) and not saw_meaningful_output and
             RetryHelper.retryable_transport_error?(reason) do
          delay_ms = RetryHelper.backoff_delay_ms(attempt, policy)

          log_retry(
            trace_id,
            "retry_transport",
            %{reason: inspect(reason, limit: 50, printable_limit: 8_000)},
            attempt,
            policy,
            delay_ms
          )

          RetryHelper.sleep(delay_ms)

          stream_request_with_retries(
            url,
            headers,
            body,
            initial_state,
            trace_id,
            policy,
            attempt + 1
          )
        else
          error
        end
    end
  end

  defp log_retry(trace_id, tag, details, attempt, policy, delay_ms) do
    payload =
      Map.merge(details, %{
        attempt: attempt + 1,
        max_attempts: policy.max_attempts,
        delay_ms: delay_ms
      })

    debug_log(tag, payload)
    HttpTrace.log("anthropic", tag, Map.put(payload, :trace_id, trace_id))
  end

  defp meaningful_output_transition?(acc_state, new_state) do
    acc_size = content_size(acc_state)
    new_size = content_size(new_state)
    new_size > acc_size
  rescue
    _ -> false
  end

  defp content_size(%{output: %{content: content}}) when is_list(content), do: length(content)
  defp content_size(_), do: 0

  defp retryable_http_response?(%Req.Response{status: status} = response, model) do
    RetryHelper.retryable_http_error?(status, response.body) or
      retryable_kimi_empty_400?(response, model)
  end

  defp retryable_kimi_empty_400?(%Req.Response{status: 400} = response, %Model{provider: provider})
       when provider in [:kimi, "kimi"] do
    empty_http_response?(response)
  end

  defp retryable_kimi_empty_400?(_response, _model), do: false

  defp empty_http_body?(nil), do: true
  defp empty_http_body?(body) when is_binary(body), do: String.trim(body) == ""
  defp empty_http_body?(%{} = body), do: map_size(body) == 0
  defp empty_http_body?(_), do: false

  defp empty_http_response?(%Req.Response{body: body, private: private}) do
    empty_http_body?(body) and empty_stream_buffer?(private)
  end

  defp empty_stream_buffer?(%{sse_state: %{sse_buffer: buffer}}) when is_binary(buffer) do
    String.trim(buffer) == ""
  end

  defp empty_stream_buffer?(_), do: true

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
    {event_type, data_lines} =
      event_text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({nil, []}, fn
        "event:" <> value, {_event, data} ->
          {String.replace_prefix(value, " ", ""), data}

        "data:" <> value, {event, data} ->
          {event, [String.replace_prefix(value, " ", "") | data]}

        _, acc ->
          acc
      end)

    case data_lines |> Enum.reverse() |> Enum.join("\n") |> Jason.decode() do
      {:ok, %{} = json} ->
        case event_type || json["type"] do
          type when is_binary(type) -> {type, json}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ============================================================================
  # Event Processing
  # ============================================================================

  defp process_sse_event(_event, %{terminal?: true} = state), do: state

  defp process_sse_event({"message_start", %{"message" => message}}, state) do
    # Capture initial token usage
    usage = message["usage"] || %{}
    cache_creation = usage["cache_creation"] || state.cache_creation
    output = update_usage(state.output, usage, state.model, cache_creation)
    %{state | output: output, cache_creation: cache_creation}
  end

  defp process_sse_event(
         {"content_block_start", %{"index" => index, "content_block" => block}},
         state
       ) do
    case block["type"] do
      "text" ->
        text_block = %TextContent{type: :text, text: block["text"] || ""}
        content_index = length(state.output.content)
        blocks = state.blocks ++ [{index, text_block}]
        output = %{state.output | content: state.output.content ++ [text_block]}
        EventStream.push_async(state.stream, {:text_start, content_index, output})
        %{state | blocks: blocks, output: output}

      "thinking" ->
        thinking_block = %ThinkingContent{
          type: :thinking,
          thinking: block["thinking"] || "",
          thinking_signature: block["signature"]
        }

        content_index = length(state.output.content)
        blocks = state.blocks ++ [{index, thinking_block}]
        output = %{state.output | content: state.output.content ++ [thinking_block]}
        EventStream.push_async(state.stream, {:thinking_start, content_index, output})
        %{state | blocks: blocks, output: output}

      "tool_use" ->
        tool_call = %ToolCall{
          type: :tool_call,
          id: block["id"] || "",
          name: maybe_strip_oauth_tool_name(block["name"] || "", state.oauth_request?),
          arguments: block["input"] || %{}
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

  defp process_sse_event({"message_delta", %{"delta" => delta} = event}, state) do
    # Update stop reason
    output =
      case delta["stop_reason"] do
        nil -> state.output
        reason -> %{state.output | stop_reason: map_stop_reason(reason)}
      end

    usage = event["usage"] || %{}
    cache_creation = usage["cache_creation"] || state.cache_creation
    output = update_usage(output, usage, state.model, cache_creation)

    %{
      state
      | output: output,
        cache_creation: cache_creation,
        terminal?: not is_nil(delta["stop_reason"])
    }
  end

  defp process_sse_event({"message_stop", _data}, state) do
    %{state | terminal?: true}
  end

  defp process_sse_event({"ping", _data}, state) do
    state
  end

  defp process_sse_event({"error", %{"error" => error}}, state) do
    error_msg = error["message"] || "Unknown error"
    output = %{state.output | stop_reason: :error, error_message: error_msg}
    %{state | output: output, terminal?: true}
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
      {k, _} when k in ["x-api-key", "authorization"] -> {k, "***"}
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

  @copilot_providers [:github_copilot, :"github-copilot"]
  @kimi_providers [:kimi, :kimi_coding, "kimi", "kimi_coding"]
  @common_beta_features [
    "interleaved-thinking-2025-05-14",
    "fine-grained-tool-streaming-2025-05-14"
  ]
  @claude_code_system_prefix "You are Claude Code, Anthropic's official CLI for Claude."
  @oauth_tool_prefix "mcp_"
  @adaptive_thinking_effort_map %{
    minimal: "low",
    low: "low",
    medium: "medium",
    high: "high",
    xhigh: "max"
  }
  @manual_thinking_min_output_tokens 4096

  defp build_headers(api_key, model, context, opts) do
    provider = model.provider
    is_copilot = provider in @copilot_providers

    is_anthropic_oauth =
      anthropic_oauth_provider?(provider) and LemonAi.Auth.AnthropicOAuth.oauth_token?(api_key)

    # Kimi Code OAuth tokens authenticate as a bearer with the Kimi CLI fingerprint.
    is_kimi_oauth =
      provider in @kimi_providers and LemonAi.Auth.KimiCodeOAuth.oauth_token?(api_key)

    auth_headers =
      cond do
        api_key == "" ->
          []

        is_copilot or is_anthropic_oauth or is_kimi_oauth ->
          [{"authorization", "Bearer #{api_key}"}]

        true ->
          [{"x-api-key", api_key}]
      end

    beta_features =
      if is_anthropic_oauth do
        @common_beta_features ++ LemonAi.Auth.AnthropicOAuth.oauth_beta_features()
      else
        @common_beta_features
      end

    beta_features =
      if cache_control(model, opts)["ttl"] == "1h" do
        beta_features ++ ["extended-cache-ttl-2025-04-11"]
      else
        beta_features
      end

    beta_features =
      if model.reasoning and model.adaptive_thinking and not is_nil(opts.reasoning) do
        beta_features ++ ["effort-2025-11-24"]
      else
        beta_features
      end

    base_headers = [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"anthropic-version", @api_version},
      {"anthropic-beta", Enum.join(beta_features, ",")}
    ]

    copilot_headers =
      if is_copilot do
        [
          {"editor-version", "vscode/1.107.0"},
          {"editor-plugin-version", "copilot-chat/0.35.0"},
          {"user-agent", "GitHubCopilotChat/0.35.0"},
          {"copilot-integration-id", "vscode-chat"}
        ]
      else
        []
      end

    oauth_headers =
      cond do
        is_anthropic_oauth -> LemonAi.Auth.AnthropicOAuth.oauth_headers()
        is_kimi_oauth -> LemonAi.Auth.KimiCodeOAuth.request_headers()
        true -> []
      end

    # Merge beta tokens rather than letting an extra header remove required betas.
    extra_headers =
      Enum.reduce(
        [
          OpenCodeGoSession.headers(model, context, opts),
          model.headers || %{},
          opts.headers || %{}
        ],
        %{},
        fn headers, acc -> LemonAi.Providers.RequestHeaders.merge(acc, headers) end
      )

    headers = Map.new(base_headers ++ auth_headers ++ copilot_headers ++ oauth_headers)

    Map.merge(headers, extra_headers, fn
      "anthropic-beta", required, extra ->
        (String.split(required, ",") ++ String.split(extra, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.join(",")

      _, _, value ->
        value
    end)
    |> Map.to_list()
  end

  defp anthropic_oauth_provider?(:anthropic), do: true
  defp anthropic_oauth_provider?("anthropic"), do: true
  defp anthropic_oauth_provider?(_), do: false

  defp build_request_body(model, context, opts, api_key) do
    history_messages = context.messages || []
    history_info = %{prepared_message_count: length(history_messages)}
    cache_control = cache_control(model, opts)
    oauth_request? = anthropic_oauth_request?(model.provider, api_key)

    body = %{
      "model" => model.id,
      "messages" =>
        convert_messages(history_messages, model,
          oauth_request?: oauth_request?,
          cache_control: cache_control
        ),
      "max_tokens" => min(opts.max_tokens || div(model.max_tokens, 3), model.max_tokens),
      "stream" => true
    }

    # Add system prompt (skip if empty to avoid API errors on some providers)
    body =
      case build_system_prompt(context.system_prompt, oauth_request?, cache_control) do
        nil ->
          body

        system_prompt ->
          Map.put(body, "system", system_prompt)
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
      if context.tools && context.tools != [] do
        Map.put(body, "tools", convert_tools(context.tools, oauth_request?: oauth_request?))
      else
        body
      end

    body = maybe_apply_tool_choice(body, opts.tool_choice, oauth_request?)

    # Thinking request shape is driven by the model's capability flags:
    # adaptive-thinking models take effort levels, older models a manual budget.
    body =
      cond do
        !model.reasoning or !opts.reasoning ->
          body

        get_in(body, ["tool_choice", "type"]) in ["any", "tool"] ->
          if model.adaptive_thinking do
            body
            |> Map.delete("temperature")
            |> Map.put("output_config", %{"effort" => "low"})
          else
            body
          end

        model.adaptive_thinking ->
          effort = LemonAi.Models.reasoning_effort_for(model, opts.reasoning)
          compat = model.compat || %{}

          thinking =
            if Map.get(compat, :anthropic_thinking_display) ||
                 Map.get(compat, "anthropic_thinking_display") do
              %{"type" => "adaptive", "display" => "summarized"}
            else
              %{"type" => "adaptive"}
            end

          body
          |> Map.delete("temperature")
          |> Map.put("thinking", thinking)
          |> Map.put("output_config", %{
            "effort" => Map.get(@adaptive_thinking_effort_map, effort, "medium")
          })

        true ->
          thinking_budget = get_thinking_budget(opts.reasoning, opts.thinking_budgets)

          max_tokens =
            min(
              max(body["max_tokens"], thinking_budget + @manual_thinking_min_output_tokens),
              model.max_tokens
            )

          thinking_budget = min(thinking_budget, max_tokens - @manual_thinking_min_output_tokens)

          if thinking_budget < 1024 do
            raise ArgumentError,
                  "Anthropic thinking requires room for at least 1024 thinking tokens and #{@manual_thinking_min_output_tokens} output tokens"
          end

          body
          |> Map.put("thinking", %{
            "type" => "enabled",
            "budget_tokens" => thinking_budget
          })
          |> Map.put("temperature", 1)
          |> Map.put("max_tokens", max_tokens)
      end

    {body, history_info}
  end

  @doc """
  Message-count hint for caller-owned compaction. Requests preserve all messages.
  """
  @spec request_history_limit(Model.t() | map()) :: pos_integer() | nil
  def request_history_limit(%Model{provider: :kimi}), do: kimi_history_limit()
  def request_history_limit(%Model{provider: "kimi"}), do: kimi_history_limit()
  def request_history_limit(_), do: nil

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

  defp convert_messages(messages, model, opts) do
    messages
    |> Enum.map(fn msg -> convert_message(msg, model, opts) end)
    |> Enum.reject(&is_nil/1)
    |> add_cache_control_to_last_user_message(Keyword.get(opts, :cache_control))
  end

  defp convert_message(%LemonAi.Types.UserMessage{content: content}, _model, _opts)
       when is_binary(content) do
    if String.trim(content) != "" do
      %{
        "role" => "user",
        "content" => content
      }
    else
      nil
    end
  end

  defp convert_message(%LemonAi.Types.UserMessage{content: content}, model, _opts)
       when is_list(content) do
    blocks =
      content
      |> Enum.map(&convert_user_content_block(&1, model))
      |> Enum.reject(&is_nil/1)

    if blocks != [] do
      %{
        "role" => "user",
        "content" => blocks
      }
    else
      nil
    end
  end

  defp convert_message(%AssistantMessage{content: content}, _model, opts) do
    oauth_request? = Keyword.get(opts, :oauth_request?, false)

    blocks =
      content
      |> Enum.map(&convert_assistant_content_block(&1, oauth_request?))
      |> Enum.reject(&is_nil/1)

    if blocks != [] do
      %{
        "role" => "assistant",
        "content" => blocks
      }
    else
      nil
    end
  end

  defp convert_message(%LemonAi.Types.ToolResultMessage{} = msg, model, _opts) do
    content = convert_tool_result_content(msg.content, model)

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

  defp convert_message(_, _, _), do: nil

  defp convert_user_content_block(%TextContent{text: text}, _model) do
    if String.trim(text) != "" do
      %{"type" => "text", "text" => text}
    else
      nil
    end
  end

  defp convert_user_content_block(%{"type" => "text", "text" => text}, _model)
       when is_binary(text) do
    if String.trim(text) != "" do
      %{"type" => "text", "text" => text}
    else
      nil
    end
  end

  defp convert_user_content_block(%{type: :text, text: text}, model) do
    convert_user_content_block(%{"type" => "text", "text" => text}, model)
  end

  defp convert_user_content_block(
         %LemonAi.Types.ImageContent{data: data, mime_type: mime_type},
         model
       ) do
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

  defp convert_user_content_block(
         %{
           "type" => "image",
           "source" => %{
             "type" => "base64",
             "media_type" => mime_type,
             "data" => data
           }
         },
         model
       )
       when is_binary(mime_type) and is_binary(data) do
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

  defp convert_user_content_block(%{type: :image, data: data, mime_type: mime_type}, model) do
    convert_user_content_block(
      %{
        "type" => "image",
        "source" => %{
          "type" => "base64",
          "media_type" => mime_type,
          "data" => data
        }
      },
      model
    )
  end

  defp convert_user_content_block(_, _), do: nil

  defp convert_assistant_content_block(%TextContent{text: text}, _oauth_request?) do
    if String.trim(text) != "" do
      %{"type" => "text", "text" => text}
    else
      nil
    end
  end

  defp convert_assistant_content_block(%{"type" => "text", "text" => text}, oauth_request?)
       when is_binary(text) do
    convert_assistant_content_block(%TextContent{text: text}, oauth_request?)
  end

  defp convert_assistant_content_block(%{type: :text, text: text}, oauth_request?) do
    convert_assistant_content_block(%{"type" => "text", "text" => text}, oauth_request?)
  end

  defp convert_assistant_content_block(
         %ThinkingContent{
           thinking: thinking,
           thinking_signature: sig
         },
         _oauth_request?
       ) do
    cond do
      is_binary(sig) and sig != "" ->
        # Signatures bind the original bytes, including empty/whitespace thinking.
        %{"type" => "thinking", "thinking" => thinking, "signature" => sig}

      String.trim(thinking) != "" ->
        %{"type" => "text", "text" => thinking}

      true ->
        nil
    end
  end

  defp convert_assistant_content_block(
         %{"type" => "thinking", "thinking" => thinking} = block,
         oauth_request?
       )
       when is_binary(thinking) do
    convert_assistant_content_block(
      %ThinkingContent{
        thinking: thinking,
        thinking_signature: Map.get(block, "signature")
      },
      oauth_request?
    )
  end

  defp convert_assistant_content_block(
         %{type: :thinking, thinking: thinking} = block,
         oauth_request?
       )
       when is_binary(thinking) do
    convert_assistant_content_block(
      %{"type" => "thinking", "thinking" => thinking, "signature" => Map.get(block, :signature)},
      oauth_request?
    )
  end

  defp convert_assistant_content_block(
         %ToolCall{id: id, name: name, arguments: args},
         oauth_request?
       ) do
    %{
      "type" => "tool_use",
      "id" => id,
      "name" => maybe_prefix_oauth_tool_name(name, oauth_request?),
      "input" => args
    }
  end

  defp convert_assistant_content_block(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => args},
         oauth_request?
       )
       when is_binary(id) and is_binary(name) and is_map(args) do
    convert_assistant_content_block(
      %ToolCall{id: id, name: name, arguments: args},
      oauth_request?
    )
  end

  defp convert_assistant_content_block(
         %{type: :tool_use, id: id, name: name, input: args},
         oauth_request?
       )
       when is_binary(id) and is_binary(name) and is_map(args) do
    convert_assistant_content_block(
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => args},
      oauth_request?
    )
  end

  defp convert_assistant_content_block(_, _oauth_request?), do: nil

  # Text parts are joined into one text block; image parts become Anthropic
  # `image` blocks inside `tool_result.content` when the model accepts images.
  # A text-only result keeps the plain-string form.
  defp convert_tool_result_content(content, model) when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %TextContent{text: text} -> [text]
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        %{type: :text, text: text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")

    images =
      content
      |> Enum.filter(&tool_result_image?/1)
      |> Enum.map(&convert_user_content_block(&1, model))
      |> Enum.reject(&is_nil/1)

    cond do
      images == [] and text != "" -> text
      images == [] -> "(empty result)"
      text == "" -> images
      true -> [%{"type" => "text", "text" => text} | images]
    end
  end

  defp convert_tool_result_content(_, _model), do: "(empty result)"

  defp tool_result_image?(%LemonAi.Types.ImageContent{}), do: true
  defp tool_result_image?(%{"type" => "image"}), do: true
  defp tool_result_image?(%{type: :image}), do: true
  defp tool_result_image?(_), do: false

  defp cache_control(model, opts) do
    options = resolve_provider_options(model, opts)

    case Map.get(options, :cache_retention) || Map.get(options, "cache_retention") do
      retention when retention in [:none, "none"] ->
        nil

      retention
      when retention in [:long, "long"] and model.provider in [:anthropic, "anthropic"] ->
        %{"type" => "ephemeral", "ttl" => "1h"}

      _ ->
        %{"type" => "ephemeral"}
    end
  end

  defp add_cache_control_to_last_user_message(messages, nil), do: messages

  defp add_cache_control_to_last_user_message(messages, cache_control) do
    case messages
         |> Enum.with_index()
         |> Enum.reverse()
         |> Enum.find(fn {msg, _} ->
           msg["role"] == "user"
         end) do
      nil ->
        messages

      {message, index} ->
        List.replace_at(messages, index, add_cache_control_to_message(message, cache_control))
    end
  end

  defp add_cache_control_to_message(%{"content" => content} = msg, cache_control)
       when is_binary(content) do
    block = %{"type" => "text", "text" => content, "cache_control" => cache_control}
    %{msg | "content" => [block]}
  end

  defp add_cache_control_to_message(%{"content" => content} = msg, cache_control)
       when is_list(content) do
    case List.pop_at(content, -1) do
      {nil, _} ->
        msg

      {last_block, rest_blocks} ->
        updated_block = Map.put(last_block, "cache_control", cache_control)
        %{msg | "content" => rest_blocks ++ [updated_block]}
    end
  end

  defp maybe_cache_block(block, nil), do: block
  defp maybe_cache_block(block, cache_control), do: Map.put(block, "cache_control", cache_control)

  defp convert_tools(tools, opts) do
    oauth_request? = Keyword.get(opts, :oauth_request?, false)

    Enum.map(tools, fn tool ->
      %{
        "name" => maybe_prefix_oauth_tool_name(tool.name, oauth_request?),
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

  defp update_usage(output, usage_data, model, cache_creation) do
    usage = output.usage

    input = usage_data["input_tokens"] || usage.input
    output_tokens = usage_data["output_tokens"] || usage.output
    cache_read = usage_data["cache_read_input_tokens"] || usage.cache_read

    cache_write =
      usage_data["cache_creation_input_tokens"] ||
        if(is_map(usage_data["cache_creation"]),
          do:
            (cache_creation["ephemeral_5m_input_tokens"] || 0) +
              (cache_creation["ephemeral_1h_input_tokens"] || 0),
          else: usage.cache_write
        )

    total_tokens = input + output_tokens + cache_read + cache_write

    updated_usage = %{
      usage
      | input: input,
        output: output_tokens,
        cache_read: cache_read,
        cache_write: cache_write,
        cache_write_long: cache_creation["ephemeral_1h_input_tokens"] || 0,
        total_tokens: total_tokens
    }

    # Calculate cost based on model pricing
    cost = LemonAi.calculate_cost(model, updated_usage)

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

  defp anthropic_oauth_request?(provider, api_key) do
    anthropic_oauth_provider?(provider) and LemonAi.Auth.AnthropicOAuth.oauth_token?(api_key)
  end

  defp build_system_prompt(system_prompt, true, cache_control) do
    cc_block = %{"type" => "text", "text" => @claude_code_system_prefix}

    case system_prompt do
      prompt when is_binary(prompt) ->
        if String.trim(prompt) != "" do
          [
            cc_block,
            maybe_cache_block(
              %{"type" => "text", "text" => sanitize_oauth_system_prompt(prompt)},
              cache_control
            )
          ]
        else
          [cc_block]
        end

      _ ->
        [cc_block]
    end
  end

  defp build_system_prompt(system_prompt, false, cache_control) when is_binary(system_prompt) do
    if String.trim(system_prompt) != "" do
      [
        maybe_cache_block(%{"type" => "text", "text" => system_prompt}, cache_control)
      ]
    else
      nil
    end
  end

  defp build_system_prompt(_, false, _cache_control), do: nil

  defp maybe_prefix_oauth_tool_name(name, true) when is_binary(name) do
    @oauth_tool_prefix <> strip_all_oauth_tool_prefixes(name)
  end

  defp maybe_prefix_oauth_tool_name(name, _), do: name

  defp maybe_apply_tool_choice(body, nil, _oauth_request?), do: body

  defp maybe_apply_tool_choice(body, :none, _oauth_request?) when is_map(body) do
    body
    |> Map.delete("tools")
    |> Map.delete("tool_choice")
  end

  defp maybe_apply_tool_choice(body, tool_choice, oauth_request?) when is_map(body) do
    case normalize_tool_choice(tool_choice, oauth_request?) do
      nil ->
        body

      value ->
        Map.put(body, "tool_choice", value)
    end
  end

  defp normalize_tool_choice(:auto, _oauth_request?), do: %{"type" => "auto"}
  defp normalize_tool_choice(:any, _oauth_request?), do: %{"type" => "any"}

  defp normalize_tool_choice(tool_name, oauth_request?) when is_binary(tool_name) do
    %{"type" => "tool", "name" => maybe_prefix_oauth_tool_name(tool_name, oauth_request?)}
  end

  defp normalize_tool_choice(tool_name, oauth_request?)
       when is_atom(tool_name) and not is_nil(tool_name) do
    tool_name
    |> Atom.to_string()
    |> normalize_tool_choice(oauth_request?)
  end

  defp normalize_tool_choice(_, _oauth_request?), do: nil

  defp maybe_strip_oauth_tool_name(name, true) when is_binary(name) do
    strip_all_oauth_tool_prefixes(name)
  end

  defp maybe_strip_oauth_tool_name(name, _), do: name

  defp strip_all_oauth_tool_prefixes(name) when is_binary(name) do
    if String.starts_with?(name, @oauth_tool_prefix) do
      name
      |> String.replace_prefix(@oauth_tool_prefix, "")
      |> strip_all_oauth_tool_prefixes()
    else
      name
    end
  end

  defp sanitize_oauth_system_prompt(text) when is_binary(text) do
    text
    |> String.replace("Hermes Agent", "Claude Code")
    |> String.replace("Hermes agent", "Claude Code")
    |> String.replace("hermes-agent", "claude-code")
    |> String.replace("Nous Research", "Anthropic")
  end

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
    LemonAi.ProviderRegistry.register(:anthropic_messages, __MODULE__)
  end
end
