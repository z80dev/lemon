defmodule Ai.Providers.Google do
  @moduledoc """
  Google Generative AI (AI Studio) provider.

  This provider implements streaming for Google's Generative AI API,
  which is the public API for Gemini models via AI Studio.

  ## Authentication

  Requires a Google AI Studio API key, which can be obtained from:
  https://aistudio.google.com/apikey

  Set via the `GOOGLE_GENERATIVE_AI_API_KEY` environment variable or
  pass as `api_key` in stream options.

  ## Features

  - Streaming text generation
  - Tool/function calling
  - Thinking/reasoning mode (for supported models)
  - Image input (for multimodal models)
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

  # ============================================================================
  # Provider Callbacks
  # ============================================================================

  @impl true
  def provider_id, do: :google

  @impl true
  def api_id, do: :google_generative_ai

  @impl true
  def get_env_api_key do
    System.get_env("GOOGLE_GENERATIVE_AI_API_KEY") ||
      System.get_env("GOOGLE_API_KEY") ||
      System.get_env("GEMINI_API_KEY")
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
      api_key = opts.api_key || get_env_api_key() || ""
      base_url = build_base_url(model)
      url = "#{base_url}/models/#{model.id}:streamGenerateContent?alt=sse"

      headers = build_headers(api_key, model, opts)
      body = build_request_body(model, context, opts)

      case make_streaming_request(url, headers, body) do
        {:ok, response_stream} ->
          process_stream(stream, response_stream, output, model, opts)

        {:error, reason} ->
          handle_error(stream, output, reason, opts)
      end
    rescue
      e ->
        handle_error(stream, output, Exception.message(e), opts)
    end
  end

  defp init_output(model) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: :google_generative_ai,
      provider: model.provider,
      model: model.id,
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp build_base_url(%Model{base_url: base_url}) when is_binary(base_url) and base_url != "" do
    String.trim_trailing(base_url, "/")
  end

  defp build_base_url(_model) do
    "https://generativelanguage.googleapis.com/v1beta"
  end

  defp build_headers(api_key, model, opts) do
    base = [
      {"Content-Type", "application/json"},
      {"x-goog-api-key", api_key}
    ]

    model_headers = Enum.map(model.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
    opts_headers = Enum.map(opts.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    base ++ model_headers ++ opts_headers
  end

  defp build_request_body(model, context, opts) do
    contents = GoogleShared.convert_messages(model, context)

    generation_config = build_generation_config(model, opts)

    body = %{
      "contents" => contents
    }

    body =
      if context.system_prompt do
        Map.put(body, "systemInstruction", %{
          "parts" => [%{"text" => GoogleShared.sanitize_surrogates(context.system_prompt)}]
        })
      else
        body
      end

    body =
      case GoogleShared.convert_tools(context.tools) do
        nil -> body
        tools -> Map.put(body, "tools", tools)
      end

    body =
      if context.tools != [] and opts_has_tool_choice?(opts) do
        tool_choice = get_tool_choice(opts)

        Map.put(body, "toolConfig", %{
          "functionCallingConfig" => %{
            "mode" => GoogleShared.map_tool_choice(tool_choice)
          }
        })
      else
        body
      end

    body =
      if map_size(generation_config) > 0 do
        Map.put(body, "generationConfig", generation_config)
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

  defp opts_has_tool_choice?(%StreamOptions{} = opts) do
    not is_nil(Map.get(opts, :tool_choice))
  end

  defp get_tool_choice(%StreamOptions{} = opts) do
    Map.get(opts, :tool_choice, :auto)
  end

  defp thinking_enabled?(%StreamOptions{reasoning: level})
       when level in [:minimal, :low, :medium, :high], do: true

  defp thinking_enabled?(_), do: false

  defp get_thinking_level(%StreamOptions{reasoning: _level, thinking_budgets: budgets}) do
    # Check if budgets has a level key
    Map.get(budgets, :level)
  end

  defp get_thinking_budget(%StreamOptions{reasoning: level, thinking_budgets: budgets}) do
    Map.get(budgets, :budget_tokens) || Map.get(budgets, level)
  end

  defp make_streaming_request(url, headers, body) do
    case Req.post(url, headers: headers, json: body, receive_timeout: 300_000, into: :self) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, :streaming}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{GoogleShared.extract_error_message(inspect(body))}"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Transport error: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp process_stream(stream, :streaming, output, model, _opts) do
    EventStream.push_async(stream, {:start, output})

    state = %{
      output: output,
      current_block: nil,
      tool_call_counter: 0
    }

    final_state = receive_sse_events(stream, state, model)

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
    candidate = get_in(chunk, ["candidates", Access.at(0)])

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
      if usage = chunk["usageMetadata"] do
        usage_struct = %Usage{
          input: usage["promptTokenCount"] || 0,
          output: (usage["candidatesTokenCount"] || 0) + (usage["thoughtsTokenCount"] || 0),
          cache_read: usage["cachedContentTokenCount"] || 0,
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
          # Start new thinking block
          block = %ThinkingContent{thinking: "", thinking_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:thinking_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {nil, false} ->
          # Start new text block
          block = %TextContent{text: "", text_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:text_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {%ThinkingContent{}, false} ->
          # End thinking, start text
          old_idx = length(state.output.content) - 1

          EventStream.push_async(
            stream,
            {:thinking_end, old_idx, state.current_block.thinking, state.output}
          )

          block = %TextContent{text: "", text_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:text_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {%TextContent{}, true} ->
          # End text, start thinking
          old_idx = length(state.output.content) - 1

          EventStream.push_async(
            stream,
            {:text_end, old_idx, state.current_block.text, state.output}
          )

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

        {%{block | thinking: block.thinking <> text, thinking_signature: new_sig},
         :thinking_delta}
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

    EventStream.push_async(
      stream,
      {:tool_call_delta, idx, Jason.encode!(tool_call.arguments), output}
    )

    EventStream.push_async(stream, {:tool_call_end, idx, tool_call, output})

    %{state | output: output, current_block: nil, tool_call_counter: state.tool_call_counter + 1}
  end

  defp handle_error(stream, output, reason, _opts) do
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
    Ai.ProviderRegistry.register(:google_generative_ai, __MODULE__)
    :ignore
  end
end
