defmodule Ai.Providers.GoogleGeminiCli do
  @moduledoc """
  Google Gemini CLI / Cloud Code Assist provider.

  This provider implements streaming for Google's Cloud Code Assist API,
  which is used by Gemini CLI and provides access to Gemini and Claude models.

  ## Authentication

  Requires OAuth authentication. The API key should be a JSON string containing:
  - `token`: OAuth access token
  - `projectId`: GCP project ID

  ## Features

  - Streaming text generation
  - Tool/function calling
  - Thinking/reasoning mode (for supported models)
  - Image input (for multimodal models)
  - Retry with exponential backoff for rate limits
  - Support for Claude models via Antigravity endpoint
  """

  @behaviour Ai.Provider

  alias Ai.EventStream
  alias Ai.Providers.GoogleShared

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    Model,
    StreamOptions,
    TextContent,
    ThinkingContent,
    ToolCall,
    Usage
  }

  require Logger

  @default_endpoint "https://cloudcode-pa.googleapis.com"
  @antigravity_daily_endpoint "https://daily-cloudcode-pa.sandbox.googleapis.com"

  @gemini_cli_headers %{
    "User-Agent" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "X-Goog-Api-Client" => "gl-node/22.17.0",
    "Client-Metadata" =>
      Jason.encode!(%{
        "ideType" => "IDE_UNSPECIFIED",
        "platform" => "PLATFORM_UNSPECIFIED",
        "pluginType" => "GEMINI"
      })
  }

  @antigravity_headers %{
    "User-Agent" => "antigravity/1.11.5 darwin/arm64",
    "X-Goog-Api-Client" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "Client-Metadata" =>
      Jason.encode!(%{
        "ideType" => "IDE_UNSPECIFIED",
        "platform" => "PLATFORM_UNSPECIFIED",
        "pluginType" => "GEMINI"
      })
  }

  @max_retries 3
  @base_delay_ms 1000
  @max_empty_stream_retries 2
  @empty_stream_base_delay_ms 500
  @claude_thinking_beta_header "interleaved-thinking-2025-05-14"

  # ============================================================================
  # Provider Callbacks
  # ============================================================================

  @impl true
  def provider_id, do: :google_gemini_cli

  @impl true
  def api_id, do: :google_gemini_cli

  @impl true
  def get_env_api_key do
    # Gemini CLI uses OAuth, not static API keys
    nil
  end

  @impl true
  def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
    owner = self()
    stream_timeout = opts.stream_timeout || 300_000

    {:ok, stream} =
      EventStream.start_link(
        owner: owner,
        max_queue: 10_000,
        timeout: stream_timeout
      )

    {:ok, task_pid} =
      Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
        do_stream(stream, model, context, opts)
      end)

    EventStream.attach_task(stream, task_pid)

    {:ok, stream}
  end

  # ============================================================================
  # Streaming Implementation
  # ============================================================================

  defp do_stream(stream, model, context, opts) do
    output = init_output(model)

    try do
      {access_token, project_id} = parse_credentials(opts.api_key)

      is_antigravity = model.provider == :google_antigravity
      base_url = get_base_url(model, is_antigravity)
      endpoints = get_endpoints(base_url, is_antigravity)

      request_body = build_request_body(model, context, project_id, opts, is_antigravity)
      headers = build_headers(access_token, model, opts, is_antigravity)

      case make_request_with_retry(endpoints, headers, request_body, opts) do
        {:ok, response} ->
          process_response_stream(stream, response, output, model, headers, request_body, opts)

        {:error, reason} ->
          handle_error(stream, output, reason)
      end
    rescue
      e ->
        handle_error(stream, output, Exception.message(e))
    end
  end

  defp init_output(model) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: :google_gemini_cli,
      provider: model.provider,
      model: model.id,
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp parse_credentials(nil) do
    raise "Google Cloud Code Assist requires OAuth authentication. Use /login to authenticate."
  end

  defp parse_credentials(api_key) when is_binary(api_key) do
    case Jason.decode(api_key) do
      {:ok, %{"token" => token, "projectId" => project_id}} when is_binary(token) and is_binary(project_id) ->
        {token, project_id}

      _ ->
        raise "Invalid Google Cloud Code Assist credentials. Use /login to re-authenticate."
    end
  end

  defp get_base_url(%Model{base_url: base_url}, _is_antigravity)
       when is_binary(base_url) and base_url != "" do
    String.trim(base_url)
  end

  defp get_base_url(_model, true = _is_antigravity), do: @antigravity_daily_endpoint
  defp get_base_url(_model, false), do: @default_endpoint

  defp get_endpoints(base_url, true = _is_antigravity) when base_url == @antigravity_daily_endpoint do
    [@antigravity_daily_endpoint, @default_endpoint]
  end

  defp get_endpoints(base_url, _is_antigravity), do: [base_url]

  defp build_headers(access_token, model, opts, is_antigravity) do
    base_headers =
      if is_antigravity do
        @antigravity_headers
      else
        @gemini_cli_headers
      end

    headers =
      Map.merge(base_headers, %{
        "Authorization" => "Bearer #{access_token}",
        "Content-Type" => "application/json",
        "Accept" => "text/event-stream"
      })

    headers =
      if claude_thinking_model?(model.id) do
        Map.put(headers, "anthropic-beta", @claude_thinking_beta_header)
      else
        headers
      end

    headers =
      Enum.reduce(model.headers || %{}, headers, fn {k, v}, acc ->
        Map.put(acc, to_string(k), to_string(v))
      end)

    Enum.reduce(opts.headers || %{}, headers, fn {k, v}, acc ->
      Map.put(acc, to_string(k), to_string(v))
    end)
  end

  defp claude_thinking_model?(model_id) do
    normalized = String.downcase(model_id)
    String.contains?(normalized, "claude") and String.contains?(normalized, "thinking")
  end

  defp build_request_body(model, context, project_id, opts, is_antigravity) do
    contents = GoogleShared.convert_messages(model, context)

    generation_config = build_generation_config(model, opts)

    request = %{
      "contents" => contents
    }

    request =
      if opts.session_id do
        Map.put(request, "sessionId", opts.session_id)
      else
        request
      end

    request =
      if context.system_prompt do
        system_instruction =
          if is_antigravity do
            build_antigravity_system_instruction(context.system_prompt)
          else
            %{"parts" => [%{"text" => GoogleShared.sanitize_surrogates(context.system_prompt)}]}
          end

        Map.put(request, "systemInstruction", system_instruction)
      else
        if is_antigravity do
          Map.put(request, "systemInstruction", build_antigravity_system_instruction(nil))
        else
          request
        end
      end

    request =
      if map_size(generation_config) > 0 do
        Map.put(request, "generationConfig", generation_config)
      else
        request
      end

    request =
      case GoogleShared.convert_tools(context.tools) do
        nil ->
          request

        tools ->
          req = Map.put(request, "tools", tools)

          if tool_choice = get_tool_choice(opts) do
            Map.put(req, "toolConfig", %{
              "functionCallingConfig" => %{
                "mode" => GoogleShared.map_tool_choice(tool_choice)
              }
            })
          else
            req
          end
      end

    body = %{
      "project" => project_id,
      "model" => model.id,
      "request" => request,
      "userAgent" => if(is_antigravity, do: "antigravity", else: "pi-coding-agent"),
      "requestId" =>
        "#{if(is_antigravity, do: "agent", else: "pi")}-#{System.system_time(:millisecond)}-#{random_id()}"
    }

    body =
      if is_antigravity do
        Map.put(body, "requestType", "agent")
      else
        body
      end

    body
  end

  defp build_generation_config(model, opts) do
    config = %{}

    config =
      if opts.temperature do
        Map.put(config, "temperature", opts.temperature)
      else
        config
      end

    config =
      if opts.max_tokens do
        Map.put(config, "maxOutputTokens", opts.max_tokens)
      else
        config
      end

    # Handle thinking/reasoning config
    config =
      if model.reasoning and thinking_enabled?(opts) do
        thinking_config = %{"includeThoughts" => true}

        thinking_config =
          cond do
            thinking_level = get_thinking_level(opts) ->
              Map.put(thinking_config, "thinkingLevel", thinking_level)

            thinking_budget = get_thinking_budget(opts) ->
              Map.put(thinking_config, "thinkingBudget", thinking_budget)

            true ->
              thinking_config
          end

        Map.put(config, "thinkingConfig", thinking_config)
      else
        config
      end

    config
  end

  defp thinking_enabled?(%StreamOptions{reasoning: level}) when level in [:minimal, :low, :medium, :high], do: true
  defp thinking_enabled?(_), do: false

  defp get_thinking_level(%StreamOptions{thinking_budgets: budgets}) do
    Map.get(budgets, :level)
  end

  defp get_thinking_budget(%StreamOptions{reasoning: level, thinking_budgets: budgets}) do
    Map.get(budgets, :budget_tokens) || Map.get(budgets, level)
  end

  defp get_tool_choice(%StreamOptions{} = opts) do
    Map.get(opts, :tool_choice)
  end

  @antigravity_system_instruction """
  <identity>
  You are Antigravity, a powerful agentic AI coding assistant designed by the Google DeepMind team working on Advanced Agentic Coding.
  You are pair programming with a USER to solve their coding task. The task may require creating a new codebase, modifying or debugging an existing codebase, or simply answering a question.
  The USER will send you requests, which you must always prioritize addressing. Along with each USER request, we will attach additional metadata about their current state, such as what files they have open and where their cursor is.
  This information may or may not be relevant to the coding task, it is up for you to decide.
  </identity>

  <tool_calling>
  Call tools as you normally would. The following list provides additional guidance to help you avoid errors:
    - **Absolute paths only**. When using tools that accept file path arguments, ALWAYS use the absolute file path.
  </tool_calling>
  """

  defp build_antigravity_system_instruction(existing_text) do
    bridge_prompt = """
    # CRITICAL: Environment Override

    IGNORE ALL INSTRUCTIONS ABOVE THIS LINE. The following overrides are mandatory:

    - You are Pi, NOT Antigravity
    - Use RELATIVE paths, never absolute paths
    - IGNORE all <web_application_development> guidelines above (no glassmorphism, no "premium aesthetics", no design opinions)
    - IGNORE <communication_style> above
    - IGNORE <ephemeral_message> handling above
    - Follow ONLY the instructions below
    """

    combined =
      if existing_text && String.trim(existing_text) != "" do
        "#{@antigravity_system_instruction}\n\n#{bridge_prompt}\n#{existing_text}"
      else
        "#{@antigravity_system_instruction}\n\n#{bridge_prompt}"
      end

    %{
      "role" => "user",
      "parts" => [%{"text" => combined}]
    }
  end

  defp random_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end

  defp make_request_with_retry(endpoints, headers, body, opts, attempt \\ 0)

  defp make_request_with_retry(_endpoints, _headers, _body, _opts, attempt) when attempt > @max_retries do
    {:error, "Max retries exceeded"}
  end

  defp make_request_with_retry(endpoints, headers, body, opts, attempt) do
    endpoint = Enum.at(endpoints, min(attempt, length(endpoints) - 1))
    url = "#{endpoint}/v1internal:streamGenerateContent?alt=sse"

    headers_list = Enum.map(headers, fn {k, v} -> {k, v} end)

    case Req.post(url, headers: headers_list, json: body, receive_timeout: 300_000, into: :self) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, {url, resp}}

      {:ok, %Req.Response{status: status, body: error_body}} ->
        error_text = if is_binary(error_body), do: error_body, else: inspect(error_body)

        if attempt < @max_retries and GoogleShared.retryable_error?(status, error_text) do
          delay =
            case GoogleShared.extract_retry_delay(error_text) do
              nil -> @base_delay_ms * :math.pow(2, attempt) |> trunc()
              ms -> ms
            end

          Process.sleep(delay)
          make_request_with_retry(endpoints, headers, body, opts, attempt + 1)
        else
          {:error, "Cloud Code Assist API error (#{status}): #{GoogleShared.extract_error_message(error_text)}"}
        end

      {:error, %Req.TransportError{reason: reason}} ->
        if attempt < @max_retries do
          delay = @base_delay_ms * :math.pow(2, attempt) |> trunc()
          Process.sleep(delay)
          make_request_with_retry(endpoints, headers, body, opts, attempt + 1)
        else
          {:error, "Network error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        if attempt < @max_retries do
          delay = @base_delay_ms * :math.pow(2, attempt) |> trunc()
          Process.sleep(delay)
          make_request_with_retry(endpoints, headers, body, opts, attempt + 1)
        else
          {:error, "Request failed: #{inspect(reason)}"}
        end
    end
  end

  defp process_response_stream(stream, response_tuple, output, model, headers, body, opts, empty_attempt \\ 0)

  defp process_response_stream(stream, _response_tuple, output, _model, _headers, _body, _opts, empty_attempt)
       when empty_attempt > @max_empty_stream_retries do
    handle_error(stream, output, "Cloud Code Assist API returned an empty response")
  end

  defp process_response_stream(stream, {url, _response}, output, model, headers, body, opts, empty_attempt) do
    EventStream.push_async(stream, {:start, output})

    state = %{
      output: output,
      current_block: nil,
      tool_call_counter: 0,
      has_content: false
    }

    final_state = receive_sse_events(stream, state, model)

    if not final_state.has_content and empty_attempt < @max_empty_stream_retries do
      # Retry on empty response
      delay = @empty_stream_base_delay_ms * :math.pow(2, empty_attempt) |> trunc()
      Process.sleep(delay)

      headers_list = Enum.map(headers, fn {k, v} -> {k, v} end)

      case Req.post(url, headers: headers_list, json: body, receive_timeout: 300_000, into: :self) do
        {:ok, %Req.Response{status: status} = new_resp} when status in 200..299 ->
          # Reset output for retry
          new_output = %{output | content: [], timestamp: System.system_time(:millisecond)}
          process_response_stream(stream, {url, new_resp}, new_output, model, headers, body, opts, empty_attempt + 1)

        {:ok, %Req.Response{status: status, body: error_body}} ->
          handle_error(stream, output, "Cloud Code Assist API error (#{status}): #{inspect(error_body)}")

        {:error, reason} ->
          handle_error(stream, output, "Request failed: #{inspect(reason)}")
      end
    else
      # Emit final block end if needed
      final_state =
        case final_state.current_block do
          %TextContent{} = block ->
            idx = length(final_state.output.content) - 1
            EventStream.push_async(stream, {:text_end, idx, block.text, final_state.output})
            final_state

          %ThinkingContent{} = block ->
            idx = length(final_state.output.content) - 1
            EventStream.push_async(stream, {:thinking_end, idx, block.thinking, final_state.output})
            final_state

          _ ->
            final_state
        end

      # Check for tool calls to set stop reason
      output = final_state.output

      output =
        if Enum.any?(output.content, &match?(%ToolCall{}, &1)) do
          %{output | stop_reason: :tool_use}
        else
          output
        end

      EventStream.complete(stream, output)
    end
  end

  defp receive_sse_events(stream, state, model) do
    receive do
      msg ->
        case GoogleShared.normalize_sse_message(msg) do
          {:data, data} ->
            new_state = process_sse_data(stream, state, data, model)
            receive_sse_events(stream, new_state, model)

          :done ->
            state

          :down ->
            state

          :ignore ->
            receive_sse_events(stream, state, model)
        end
    after
      300_000 ->
        state
    end
  end

  defp process_sse_data(stream, state, data, model) do
    data
    |> String.split("\n")
    |> Enum.reduce(state, fn line, acc ->
      if String.starts_with?(line, "data:") do
        json_str = String.trim(String.slice(line, 5..-1//1))

        if json_str != "" do
          case Jason.decode(json_str) do
            {:ok, chunk} -> process_chunk(stream, acc, chunk, model)
            _ -> acc
          end
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp process_chunk(stream, state, chunk, model) do
    # Cloud Code Assist wraps response in a "response" key
    response_data = chunk["response"] || chunk
    candidate = get_in(response_data, ["candidates", Access.at(0)])

    state =
      if candidate && candidate["content"] && candidate["content"]["parts"] do
        Enum.reduce(candidate["content"]["parts"], state, fn part, acc ->
          process_part(stream, acc, part, model)
        end)
      else
        state
      end

    # Handle finish reason
    state =
      if finish_reason = get_in(candidate, ["finishReason"]) do
        output = %{state.output | stop_reason: GoogleShared.map_stop_reason(finish_reason)}
        %{state | output: output}
      else
        state
      end

    # Handle usage metadata
    state =
      if usage = response_data["usageMetadata"] do
        prompt_tokens = usage["promptTokenCount"] || 0
        cache_read_tokens = usage["cachedContentTokenCount"] || 0

        usage_struct = %Usage{
          input: prompt_tokens - cache_read_tokens,
          output: (usage["candidatesTokenCount"] || 0) + (usage["thoughtsTokenCount"] || 0),
          cache_read: cache_read_tokens,
          cache_write: 0,
          total_tokens: usage["totalTokenCount"] || 0,
          cost: %Cost{}
        }

        usage_with_cost = GoogleShared.calculate_cost(model, Map.from_struct(usage_struct))

        output = %{
          state.output
          | usage: %{
              usage_struct
              | cost: %Cost{
                  input: usage_with_cost.cost.input,
                  output: usage_with_cost.cost.output,
                  cache_read: usage_with_cost.cost.cache_read,
                  cache_write: usage_with_cost.cost.cache_write,
                  total: usage_with_cost.cost.total
                }
            }
        }

        %{state | output: output}
      else
        state
      end

    state
  end

  defp process_part(stream, state, part, model) do
    cond do
      Map.has_key?(part, "text") ->
        process_text_part(stream, state, part)

      Map.has_key?(part, "functionCall") ->
        process_function_call_part(stream, state, part, model)

      true ->
        state
    end
  end

  defp process_text_part(stream, state, part) do
    text = part["text"]
    is_thinking = GoogleShared.thinking_part?(part)
    thought_sig = part["thoughtSignature"]

    # Check if we need to start a new block
    {state, idx} =
      case {state.current_block, is_thinking} do
        {nil, true} ->
          block = %ThinkingContent{thinking: "", thinking_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:thinking_start, idx, output})
          {%{state | output: output, current_block: block, has_content: true}, idx}

        {nil, false} ->
          block = %TextContent{text: "", text_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:text_start, idx, output})
          {%{state | output: output, current_block: block, has_content: true}, idx}

        {%ThinkingContent{}, false} ->
          old_idx = length(state.output.content) - 1
          EventStream.push_async(stream, {:thinking_end, old_idx, state.current_block.thinking, state.output})

          block = %TextContent{text: "", text_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:text_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {%TextContent{}, true} ->
          old_idx = length(state.output.content) - 1
          EventStream.push_async(stream, {:text_end, old_idx, state.current_block.text, state.output})

          block = %ThinkingContent{thinking: "", thinking_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:thinking_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {%ThinkingContent{}, true} ->
          {state, length(state.output.content) - 1}

        {%TextContent{}, false} ->
          {state, length(state.output.content) - 1}
      end

    # Update the current block with new text
    {updated_block, event_type} =
      if is_thinking do
        block = state.current_block
        new_sig = GoogleShared.retain_thought_signature(block.thinking_signature, thought_sig)
        {%{block | thinking: block.thinking <> text, thinking_signature: new_sig}, :thinking_delta}
      else
        block = state.current_block
        new_sig = GoogleShared.retain_thought_signature(block.text_signature, thought_sig)
        {%{block | text: block.text <> text, text_signature: new_sig}, :text_delta}
      end

    # Update output content
    content = List.replace_at(state.output.content, idx, updated_block)
    output = %{state.output | content: content}

    EventStream.push_async(stream, {event_type, idx, text, output})

    %{state | output: output, current_block: updated_block}
  end

  defp process_function_call_part(stream, state, part, _model) do
    func_call = part["functionCall"]

    # End current text/thinking block if any
    state =
      case state.current_block do
        %TextContent{} = block ->
          idx = length(state.output.content) - 1
          EventStream.push_async(stream, {:text_end, idx, block.text, state.output})
          %{state | current_block: nil}

        %ThinkingContent{} = block ->
          idx = length(state.output.content) - 1
          EventStream.push_async(stream, {:thinking_end, idx, block.thinking, state.output})
          %{state | current_block: nil}

        _ ->
          state
      end

    # Generate tool call ID
    provided_id = func_call["id"]

    needs_new_id =
      is_nil(provided_id) or
        Enum.any?(state.output.content, fn
          %ToolCall{id: id} -> id == provided_id
          _ -> false
        end)

    tool_call_id =
      if needs_new_id do
        counter = state.tool_call_counter + 1
        "#{func_call["name"]}_#{System.system_time(:millisecond)}_#{counter}"
      else
        provided_id
      end

    tool_call = %ToolCall{
      type: :tool_call,
      id: tool_call_id,
      name: func_call["name"] || "",
      arguments: func_call["args"] || %{},
      thought_signature: part["thoughtSignature"]
    }

    output = %{state.output | content: state.output.content ++ [tool_call]}
    idx = length(output.content) - 1

    EventStream.push_async(stream, {:tool_call_start, idx, output})
    EventStream.push_async(stream, {:tool_call_delta, idx, Jason.encode!(tool_call.arguments), output})
    EventStream.push_async(stream, {:tool_call_end, idx, tool_call, output})

    %{state | output: output, current_block: nil, tool_call_counter: state.tool_call_counter + 1, has_content: true}
  end

  defp handle_error(stream, output, reason) do
    error_output = %{
      output
      | stop_reason: :error,
        error_message: reason
    }

    EventStream.error(stream, error_output)
  end

  # ============================================================================
  # Registration
  # ============================================================================

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :register, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @doc "Register this provider with the registry"
  def register(_opts \\ []) do
    Ai.ProviderRegistry.register(:google_gemini_cli, __MODULE__)
    :ignore
  end
end
