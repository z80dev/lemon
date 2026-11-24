defmodule LemonAi.Providers.GoogleShared do
  @moduledoc """
  Shared utilities for Google Generative AI, Vertex AI, and Gemini CLI providers.

  This module handles:
  - Content conversion to Gemini format
  - Tool declaration formatting
  - The shared response stream loop (`stream_response/5`)
  - Stop reason mapping
  - Thought signature validation
  - Unicode sanitization
  """

  alias LemonAi.EventStream
  alias LemonAi.Providers.StreamTransport

  import LemonAi.Providers.AssistantMessageHelper,
    only: [error_assistant_message: 2, error_assistant_message: 3]

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    Cost,
    ImageContent,
    Model,
    StreamOptions,
    TextContent,
    ThinkingContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  # ============================================================================
  # Types
  # ============================================================================

  @type google_api_type :: :google_generative_ai | :google_vertex | :google_gemini_cli

  @type content :: %{
          role: String.t(),
          parts: [part()]
        }

  @type part :: %{
          optional(:text) => String.t(),
          optional(:thought) => boolean(),
          optional(:thought_signature) => String.t(),
          optional(:inline_data) => %{mime_type: String.t(), data: String.t()},
          optional(:function_call) => %{
            required(:name) => String.t(),
            required(:args) => map(),
            optional(:id) => String.t()
          },
          optional(:function_response) => %{
            required(:name) => String.t(),
            required(:response) => map(),
            optional(:id) => String.t(),
            optional(:parts) => [part()]
          }
        }

  @type function_declaration :: %{
          name: String.t(),
          description: String.t() | nil,
          parameters: map()
        }

  @type tool_choice :: :auto | :none | :any

  @type stop_reason :: :stop | :length | :tool_use | :error | :aborted

  @type thinking_level :: :minimal | :low | :medium | :high

  # ============================================================================
  # Thinking/Reasoning Support
  # ============================================================================

  @thinking_efforts %{
    "MINIMAL" => :minimal,
    "LOW" => :low,
    "MEDIUM" => :medium,
    "HIGH" => :high,
    "XHIGH" => :xhigh,
    "MAX" => :max
  }

  @doc """
  Add thinking configuration using the model's declared reasoning efforts.

  Level-based models use `thinkingLevel`, never `thinkingBudget` (rejected by
  Gemini 4). Models without declared levels retain explicit budget overrides.
  A nil or `:none` reasoning option leaves the provider's defaults unchanged.
  """
  @spec put_thinking_config(map(), Model.t(), StreamOptions.t()) :: map()
  def put_thinking_config(config, %Model{reasoning: true} = model, %StreamOptions{} = opts)
      when opts.reasoning in [:minimal, :low, :medium, :high, :xhigh, :max] do
    budgets = opts.thinking_budgets || %{}
    effort = if opts.reasoning in [:xhigh, :max], do: :high, else: opts.reasoning
    thinking_config = %{"includeThoughts" => true}

    thinking_config =
      cond do
        model.reasoning_efforts != [] ->
          level = Map.get(budgets, :level) || opts.reasoning

          level =
            if is_binary(level) do
              Map.get(@thinking_efforts, String.upcase(level), level)
            else
              level
            end

          level = LemonAi.Models.reasoning_effort_for(model, level)
          Map.put(thinking_config, "thinkingLevel", level |> to_string() |> String.upcase())

        level = Map.get(budgets, :level) ->
          Map.put(thinking_config, "thinkingLevel", level)

        budget = Map.get(budgets, :budget_tokens) || Map.get(budgets, effort) ->
          Map.put(thinking_config, "thinkingBudget", budget)

        true ->
          thinking_config
      end

    Map.put(config, "thinkingConfig", thinking_config)
  end

  def put_thinking_config(config, _model, _opts), do: config

  @doc """
  Determines whether a streamed Gemini Part should be treated as "thinking".

  Protocol note (Gemini / Vertex AI thought signatures):
  - `thought: true` is the definitive marker for thinking content (thought summaries).
  - `thoughtSignature` is an encrypted representation of the model's internal thought process
    used to preserve reasoning context across multi-turn interactions.
  - `thoughtSignature` can appear on ANY part type (text, functionCall, etc.) - it does NOT
    indicate the part itself is thinking content.
  """
  @spec thinking_part?(map()) :: boolean()
  def thinking_part?(%{"thought" => true}), do: true
  def thinking_part?(_part), do: false

  @doc """
  Retain thought signatures during streaming.

  Some backends only send `thoughtSignature` on the first delta for a given part/block;
  later deltas may omit it. This helper preserves the last non-empty signature.
  """
  @spec retain_thought_signature(String.t() | nil, String.t() | nil) :: String.t() | nil
  def retain_thought_signature(_existing, incoming)
      when is_binary(incoming) and byte_size(incoming) > 0 do
    incoming
  end

  def retain_thought_signature(existing, _incoming), do: existing

  # Base64 pattern for thought signatures (TYPE_BYTES in Google APIs)
  @base64_pattern ~r/^[A-Za-z0-9+\/]+={0,2}$/

  @doc """
  Check if a thought signature is valid base64.
  """
  @spec valid_thought_signature?(String.t() | nil) :: boolean()
  def valid_thought_signature?(nil), do: false

  def valid_thought_signature?(signature) when is_binary(signature) do
    # Must be valid length (multiple of 4) and match base64 pattern
    rem(byte_size(signature), 4) == 0 and Regex.match?(@base64_pattern, signature)
  end

  @doc """
  Only keep signatures from the same provider/model and with valid base64.
  """
  @spec resolve_thought_signature(boolean(), String.t() | nil) :: String.t() | nil
  def resolve_thought_signature(true = _same_provider_and_model, signature) do
    if valid_thought_signature?(signature), do: signature, else: nil
  end

  def resolve_thought_signature(false, _signature), do: nil

  @doc """
  Check if a model requires explicit tool call IDs in function calls/responses.
  Claude and GPT-OSS models via Google APIs require explicit IDs.
  """
  @spec requires_tool_call_id?(String.t()) :: boolean()
  def requires_tool_call_id?(model_id) do
    String.starts_with?(model_id, "claude-") or String.starts_with?(model_id, "gpt-oss-")
  end

  # ============================================================================
  # Content Conversion
  # ============================================================================

  @doc """
  Convert internal messages to Gemini Content[] format.
  """
  @spec convert_messages(Model.t(), Context.t()) :: [content()]
  def convert_messages(%Model{} = model, %Context{} = context) do
    context.messages
    |> Enum.flat_map(&convert_message(model, &1))
    |> merge_function_responses()
  end

  defp convert_message(_model, %UserMessage{content: content}) when is_binary(content) do
    [%{"role" => "user", "parts" => [%{"text" => sanitize_surrogates(content)}]}]
  end

  defp convert_message(model, %UserMessage{content: content}) when is_list(content) do
    parts =
      content
      |> Enum.map(&convert_user_content_part(model, &1))
      |> Enum.filter(& &1)

    if parts == [], do: [], else: [%{"role" => "user", "parts" => parts}]
  end

  defp convert_message(model, %AssistantMessage{} = msg) do
    same_provider_and_model = msg.provider == model.provider and msg.model == model.id

    parts =
      msg.content
      |> Enum.map(&convert_assistant_content_part(model, &1, same_provider_and_model))
      |> Enum.filter(& &1)

    if parts == [], do: [], else: [%{"role" => "model", "parts" => parts}]
  end

  defp convert_message(model, %ToolResultMessage{} = msg) do
    text_content =
      msg.content
      |> Enum.filter(&match?(%TextContent{}, &1))
      |> Enum.map(& &1.text)
      |> Enum.join("\n")

    image_content =
      if :image in model.input do
        Enum.filter(msg.content, &match?(%ImageContent{}, &1))
      else
        []
      end

    has_text = text_content != ""
    has_images = image_content != []
    supports_multimodal_response = String.contains?(model.id, "gemini-3")

    response_value =
      cond do
        has_text -> sanitize_surrogates(text_content)
        has_images -> "(see attached image)"
        true -> ""
      end

    image_parts =
      Enum.map(image_content, fn %ImageContent{} = img ->
        %{"inlineData" => %{"mimeType" => img.mime_type, "data" => img.data}}
      end)

    include_id = requires_tool_call_id?(model.id)

    function_response_part = %{
      "functionResponse" =>
        %{
          "name" => msg.tool_name,
          "response" =>
            if(msg.is_error,
              do: %{"error" => response_value},
              else: %{"output" => response_value}
            )
        }
        |> maybe_add_id(include_id, msg.tool_call_id)
        |> maybe_add_nested_images(has_images and supports_multimodal_response, image_parts)
    }

    result = [%{"role" => "user", "parts" => [function_response_part]}]

    # For older models, add images in a separate user message
    if has_images and not supports_multimodal_response do
      result ++
        [%{"role" => "user", "parts" => [%{"text" => "Tool result image:"} | image_parts]}]
    else
      result
    end
  end

  defp convert_user_content_part(_model, %TextContent{text: text}) do
    %{"text" => sanitize_surrogates(text)}
  end

  defp convert_user_content_part(model, %ImageContent{} = img) do
    if :image in model.input do
      %{"inlineData" => %{"mimeType" => img.mime_type, "data" => img.data}}
    else
      nil
    end
  end

  defp convert_assistant_content_part(_model, %TextContent{text: text, text_signature: sig}, same)
       when is_binary(text) and text != "" do
    thought_sig = resolve_thought_signature(same, sig)

    %{"text" => sanitize_surrogates(text)}
    |> maybe_add_thought_signature(thought_sig)
  end

  defp convert_assistant_content_part(_model, %TextContent{}, _same), do: nil

  defp convert_assistant_content_part(
         _model,
         %ThinkingContent{thinking: thinking, thinking_signature: sig},
         true = _same
       )
       when is_binary(thinking) and thinking != "" do
    thought_sig = resolve_thought_signature(true, sig)

    %{"thought" => true, "text" => sanitize_surrogates(thinking)}
    |> maybe_add_thought_signature(thought_sig)
  end

  defp convert_assistant_content_part(_model, %ThinkingContent{thinking: thinking}, false = _same)
       when is_binary(thinking) and thinking != "" do
    # Convert thinking to plain text when not same provider/model
    %{"text" => sanitize_surrogates(thinking)}
  end

  defp convert_assistant_content_part(_model, %ThinkingContent{}, _same), do: nil

  defp convert_assistant_content_part(model, %ToolCall{} = tc, same) do
    thought_sig = resolve_thought_signature(same, tc.thought_signature)

    # Gemini 3 requires thoughtSignature on all function calls when thinking mode is enabled
    is_gemini_3 = String.contains?(String.downcase(model.id), "gemini-3")

    if is_gemini_3 and is_nil(thought_sig) do
      # Convert unsigned function calls to text for Gemini 3
      args_str = Jason.encode!(tc.arguments, pretty: true)

      %{
        "text" =>
          "[Historical context: a different model called tool \"#{tc.name}\" with arguments: #{args_str}. Do not mimic this format - use proper function calling.]"
      }
    else
      base = %{
        "functionCall" =>
          %{"name" => tc.name, "args" => tc.arguments}
          |> maybe_add_id(requires_tool_call_id?(model.id), tc.id)
      }

      if thought_sig do
        Map.put(base, "thoughtSignature", thought_sig)
      else
        base
      end
    end
  end

  defp maybe_add_id(map, true, id), do: Map.put(map, "id", id)
  defp maybe_add_id(map, false, _id), do: map

  defp maybe_add_nested_images(map, true, parts), do: Map.put(map, "parts", parts)
  defp maybe_add_nested_images(map, false, _parts), do: map

  defp maybe_add_thought_signature(map, nil), do: map
  defp maybe_add_thought_signature(map, sig), do: Map.put(map, "thoughtSignature", sig)

  # Merge consecutive function response messages into single user turns
  # (Cloud Code Assist API requires this)
  defp merge_function_responses(contents) do
    Enum.reduce(contents, [], fn content, acc ->
      case {acc, content} do
        {[%{"role" => "user", "parts" => prev_parts} = prev | rest],
         %{"role" => "user", "parts" => new_parts}} ->
          has_prev_fn_response = Enum.any?(prev_parts, &Map.has_key?(&1, "functionResponse"))
          has_new_fn_response = Enum.any?(new_parts, &Map.has_key?(&1, "functionResponse"))

          if has_prev_fn_response and has_new_fn_response do
            [Map.put(prev, "parts", prev_parts ++ new_parts) | rest]
          else
            [content | acc]
          end

        _ ->
          [content | acc]
      end
    end)
    |> Enum.reverse()
  end

  # ============================================================================
  # Tool Conversion
  # ============================================================================

  @doc """
  Convert tools to Gemini function declarations format.
  """
  @spec convert_tools([Tool.t()]) :: [%{functionDeclarations: [function_declaration()]}] | nil
  def convert_tools([]), do: nil

  def convert_tools(tools) do
    declarations =
      Enum.map(tools, fn %Tool{} = tool ->
        %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => strip_additional_properties(tool.parameters)
        }
      end)

    [%{"functionDeclarations" => declarations}]
  end

  # Gemini rejects `additionalProperties` in function parameter schemas.
  # Strip it recursively so tools defined for other providers work unchanged.
  defp strip_additional_properties(schema) when is_map(schema) do
    schema
    |> Map.drop(["additionalProperties"])
    |> Map.new(fn {k, v} -> {k, strip_additional_properties(v)} end)
  end

  defp strip_additional_properties(list) when is_list(list) do
    Enum.map(list, &strip_additional_properties/1)
  end

  defp strip_additional_properties(other), do: other

  @doc """
  Map tool choice to Gemini FunctionCallingConfigMode string.
  """
  @spec map_tool_choice(tool_choice()) :: String.t()
  def map_tool_choice(:auto), do: "AUTO"
  def map_tool_choice(:none), do: "NONE"
  def map_tool_choice(:any), do: "ANY"
  def map_tool_choice(_), do: "AUTO"

  # ============================================================================
  # Stop Reason Mapping
  # ============================================================================

  @doc """
  Map Gemini FinishReason string to our stop_reason.
  """
  @spec map_stop_reason(String.t()) :: stop_reason()
  def map_stop_reason("STOP"), do: :stop
  def map_stop_reason("MAX_TOKENS"), do: :length
  def map_stop_reason(_), do: :error

  # ============================================================================
  # Unicode Sanitization
  # ============================================================================

  @doc """
  Sanitize unpaired surrogates from a string.
  These can cause issues with some APIs.
  """
  @spec sanitize_surrogates(String.t()) :: String.t()
  def sanitize_surrogates(text) when is_binary(text) do
    # In Elixir/Erlang, strings are UTF-8 by default and unpaired surrogates
    # are generally not valid. This is a no-op for valid UTF-8 strings.
    # If we encounter invalid UTF-8, we replace with replacement character.
    case :unicode.characters_to_binary(text, :utf8, :utf8) do
      {:error, valid, _rest} -> valid <> "\uFFFD"
      {:incomplete, valid, _rest} -> valid <> "\uFFFD"
      result when is_binary(result) -> result
    end
  end

  def sanitize_surrogates(text), do: to_string(text)

  # ============================================================================
  # Response Streaming
  # ============================================================================

  @doc """
  Streams a Gemini `streamGenerateContent?alt=sse` response into `stream`.

  `result` is a `LemonAi.Providers.StreamTransport.post_sse/5` result, so events
  split across transport frames are decoded once complete. The Generative AI,
  Vertex and Cloud Code Assist providers share this one loop:

    * `:start` is emitted with the first content part; a response that fails
      before producing content is reported without one.
    * A candidate `finishReason` or a `promptFeedback.blockReason` is the
      terminal event. A stream that ends, fails, idles out or sends a malformed
      event before it errors with classified transient details. A finish reason
      other than `STOP`/`MAX_TOKENS`, or a blocked prompt, errors with that
      reason. Only a terminal stop completes, as `:tool_use` when it contains a
      function call.

  Options: `:unwrap_response` maps each event to its `GenerateContentResponse`
  (Cloud Code Assist wraps it in `response`), `:adjust_usage` adjusts the mapped
  `Usage` before costing, and `:empty_response_error` fails a completed response
  without content with that transient message.
  """
  @spec stream_response(
          EventStream.t(),
          AssistantMessage.t(),
          Model.t(),
          StreamTransport.result(),
          keyword()
        ) :: :ok
  def stream_response(stream, output, model, result, opts \\ [])

  def stream_response(stream, output, model, {:ok, events}, opts) do
    state = %{
      stream: stream,
      model: model,
      opts: opts,
      output: output,
      current_block: nil,
      tool_call_counter: 0,
      started?: false,
      terminal?: false,
      failure: nil
    }

    events
    |> receive_sse_events(state)
    |> close_current_block()
    |> finish_stream()
  end

  def stream_response(stream, output, _model, {:error, details, retry_after_ms}, _opts),
    do: EventStream.error(stream, error_assistant_message(output, details, retry_after_ms))

  defp receive_sse_events(events, state) do
    unwrap = Keyword.get(state.opts, :unwrap_response, & &1)

    Enum.reduce_while(events, state, fn
      %{} = event, state -> {:cont, process_response(state, unwrap.(event))}
      :done, state -> {:cont, state}
      {:stream_error, details}, state -> {:halt, %{state | failure: details}}
    end)
  end

  defp process_response(state, %{} = response) do
    candidate = get_in(response, ["candidates", Access.at(0)])

    state =
      case candidate do
        %{"content" => %{"parts" => parts}} when is_list(parts) ->
          Enum.reduce(parts, state, &process_part(&2, &1))

        _ ->
          state
      end

    state
    |> put_finish_reason(candidate)
    |> put_block_reason(response)
    |> put_usage(response["usageMetadata"])
  end

  defp process_response(state, _response), do: state

  defp put_finish_reason(state, %{"finishReason" => reason}) when is_binary(reason) do
    output =
      case map_stop_reason(reason) do
        :error ->
          %{state.output | stop_reason: :error, error_message: "Gemini stopped: #{reason}"}

        stop_reason ->
          %{state.output | stop_reason: stop_reason}
      end

    %{state | output: output, terminal?: true}
  end

  defp put_finish_reason(state, _candidate), do: state

  defp put_block_reason(state, %{"promptFeedback" => %{"blockReason" => reason}})
       when is_binary(reason) do
    output = %{
      state.output
      | stop_reason: :error,
        error_message: "Gemini blocked the prompt: #{reason}"
    }

    %{state | output: output, terminal?: true}
  end

  defp put_block_reason(state, _response), do: state

  defp put_usage(state, %{} = usage) do
    usage = %Usage{
      input: usage["promptTokenCount"] || 0,
      output: (usage["candidatesTokenCount"] || 0) + (usage["thoughtsTokenCount"] || 0),
      cache_read: usage["cachedContentTokenCount"] || 0,
      cache_write: 0,
      total_tokens: usage["totalTokenCount"] || 0,
      cost: %Cost{}
    }

    usage = Keyword.get(state.opts, :adjust_usage, & &1).(usage)
    usage = %{usage | cost: LemonAi.calculate_cost(state.model, usage)}
    %{state | output: %{state.output | usage: usage}}
  end

  defp put_usage(state, _usage), do: state

  defp process_part(state, %{"text" => _} = part),
    do: state |> ensure_started() |> process_text_part(part)

  defp process_part(state, %{"functionCall" => _} = part),
    do: state |> ensure_started() |> process_function_call_part(part)

  defp process_part(state, _part), do: state

  defp ensure_started(%{started?: true} = state), do: state

  defp ensure_started(state) do
    EventStream.push_async(state.stream, {:start, state.output})
    %{state | started?: true}
  end

  defp process_text_part(state, part) do
    text = part["text"]
    thinking? = thinking_part?(part)
    stream = state.stream

    state =
      case {state.current_block, thinking?} do
        {%ThinkingContent{}, true} -> state
        {%TextContent{}, false} -> state
        {_current, true} -> state |> close_current_block() |> open_block(%ThinkingContent{})
        {_current, false} -> state |> close_current_block() |> open_block(%TextContent{})
      end

    idx = length(state.output.content) - 1
    signature = part["thoughtSignature"]

    {block, event} =
      case state.current_block do
        %ThinkingContent{} = block ->
          {%{
             block
             | thinking: block.thinking <> text,
               thinking_signature: retain_thought_signature(block.thinking_signature, signature)
           }, :thinking_delta}

        %TextContent{} = block ->
          {%{
             block
             | text: block.text <> text,
               text_signature: retain_thought_signature(block.text_signature, signature)
           }, :text_delta}
      end

    EventStream.push_async(stream, {event, idx, text})
    content = List.replace_at(state.output.content, idx, block)
    %{state | output: %{state.output | content: content}, current_block: block}
  end

  defp open_block(state, block) do
    output = %{state.output | content: state.output.content ++ [block]}
    idx = length(output.content) - 1

    event =
      case block do
        %ThinkingContent{} -> {:thinking_start, idx}
        %TextContent{} -> {:text_start, idx}
      end

    EventStream.push_async(state.stream, event)
    %{state | output: output, current_block: block}
  end

  defp close_current_block(%{current_block: %TextContent{} = block} = state) do
    idx = length(state.output.content) - 1
    EventStream.push_async(state.stream, {:text_end, idx, block.text})
    %{state | current_block: nil}
  end

  defp close_current_block(%{current_block: %ThinkingContent{} = block} = state) do
    idx = length(state.output.content) - 1
    EventStream.push_async(state.stream, {:thinking_end, idx, block.thinking})
    %{state | current_block: nil}
  end

  defp close_current_block(state), do: state

  defp process_function_call_part(state, part) do
    state = close_current_block(state)
    func_call = part["functionCall"]
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
    stream = state.stream

    EventStream.push_async(stream, {:tool_call_start, idx, %{tool_call | arguments: %{}}})
    EventStream.push_async(stream, {:tool_call_delta, idx, Jason.encode!(tool_call.arguments)})
    EventStream.push_async(stream, {:tool_call_end, idx, tool_call})

    %{state | output: output, tool_call_counter: state.tool_call_counter + 1}
  end

  defp finish_stream(%{stream: stream, output: output} = state) do
    cond do
      not state.terminal? ->
        failure = state.failure || StreamTransport.truncated(output.provider)
        EventStream.error(stream, error_assistant_message(output, failure))

      output.stop_reason == :error ->
        EventStream.error(stream, error_assistant_message(output, output.error_message))

      output.content == [] and is_binary(state.opts[:empty_response_error]) ->
        details = %{
          LemonAi.Error.to_error_details(:closed)
          | message: state.opts[:empty_response_error]
        }

        EventStream.error(stream, error_assistant_message(output, details))

      true ->
        ensure_started(state)

        output =
          if Enum.any?(output.content, &match?(%ToolCall{}, &1)),
            do: %{output | stop_reason: :tool_use},
            else: output

        EventStream.complete(stream, output)
    end
  end

  # ============================================================================
  # Thinking Budget Helpers
  # ============================================================================

  @doc """
  Get default thinking budgets for Gemini 2.5 Pro models.
  """
  @spec default_budgets_2_5_pro() :: %{thinking_level() => non_neg_integer()}
  def default_budgets_2_5_pro do
    %{
      minimal: 128,
      low: 2048,
      medium: 8192,
      high: 32_768
    }
  end

  @doc """
  Get default thinking budgets for Gemini 2.5 Flash models.
  """
  @spec default_budgets_2_5_flash() :: %{thinking_level() => non_neg_integer()}
  def default_budgets_2_5_flash do
    %{
      minimal: 128,
      low: 2048,
      medium: 8192,
      high: 24_576
    }
  end

  @doc """
  Get thinking budget for a model and effort level.
  """
  @spec get_thinking_budget(Model.t(), thinking_level(), map()) :: integer()
  def get_thinking_budget(%Model{id: model_id}, effort, custom_budgets) do
    case Map.get(custom_budgets, effort) do
      budget when is_integer(budget) ->
        budget

      _ ->
        cond do
          String.contains?(model_id, "2.5-pro") ->
            Map.get(default_budgets_2_5_pro(), effort, -1)

          String.contains?(model_id, "2.5-flash") ->
            Map.get(default_budgets_2_5_flash(), effort, -1)

          true ->
            -1
        end
    end
  end

  @doc """
  Check if model is Gemini 3 Pro.
  """
  @spec gemini_3_pro?(String.t()) :: boolean()
  def gemini_3_pro?(model_id), do: String.contains?(model_id, "3-pro")

  @doc """
  Check if model is Gemini 3 Flash.
  """
  @spec gemini_3_flash?(String.t()) :: boolean()
  def gemini_3_flash?(model_id), do: String.contains?(model_id, "3-flash")

  @doc """
  Get thinking level for Gemini 3 models based on effort.
  """
  @spec get_gemini_3_thinking_level(thinking_level(), String.t()) :: String.t()
  def get_gemini_3_thinking_level(effort, model_id) do
    if gemini_3_pro?(model_id) do
      case effort do
        level when level in [:minimal, :low] -> "LOW"
        level when level in [:medium, :high] -> "HIGH"
      end
    else
      case effort do
        :minimal -> "MINIMAL"
        :low -> "LOW"
        :medium -> "MEDIUM"
        :high -> "HIGH"
      end
    end
  end

  @doc """
  Clamp thinking level (remove :xhigh).
  """
  @spec clamp_reasoning(atom() | nil) :: thinking_level() | nil
  def clamp_reasoning(nil), do: nil
  def clamp_reasoning(:xhigh), do: :high
  def clamp_reasoning(level) when level in [:minimal, :low, :medium, :high], do: level
  def clamp_reasoning(_), do: nil

  # ============================================================================
  # HTTP Error Classification
  # ============================================================================

  @doc """
  Classify a collected HTTP error without exposing untrusted upstream text.

  Keeps typed status, category, retryability and retry metadata. Public errors
  contain only bounded actionable summaries, never response bodies, credentials
  or transport structs. Pass a body bounded by `LemonAi.Providers.StreamTransport.error_body/1`.
  """
  @spec safe_http_error(
          non_neg_integer(),
          String.t(),
          map() | [{term(), term()}],
          atom() | String.t() | nil
        ) ::
          LemonAi.Error.parsed_error()
  def safe_http_error(status, body, headers \\ %{}, provider \\ nil) do
    details = LemonAi.Error.parse_http_error(status, body, headers, provider)

    summary =
      case details.category do
        :auth ->
          if is_nil(provider),
            do: "Authentication failed; sign in again.",
            else:
              "Authentication failed for #{provider}; sign in again or run `lemon secrets set` to configure credentials."

        :context_length ->
          "Context length exceeded; compact or shorten the request."

        :client ->
          "Invalid request; check the model and request parameters."

        :rate_limit when not details.retryable ->
          reset_at = details.rate_limit_info && details.rate_limit_info.reset_at
          reset = if reset_at, do: " Resets at #{DateTime.to_iso8601(reset_at)}.", else: ""
          "Account quota exhausted; automatic retry stopped." <> reset

        :rate_limit ->
          "Rate limit exceeded; wait before retrying."

        :server ->
          "Upstream server error; retry later."

        :transient ->
          "Service temporarily unavailable; retry later."

        :unknown ->
          "Request failed; check provider configuration."
      end

    %{
      details
      | message: "Cloud Code Assist API error (HTTP #{status}): #{summary}",
        provider_message: nil
    }
  end

  # ============================================================================
  # Cost Calculation
  # ============================================================================

  @doc """
  Calculate cost for usage based on model pricing.
  """
  @spec calculate_cost(Model.t(), map()) :: map()
  def calculate_cost(%Model{} = model, usage) do
    cost = LemonAi.calculate_cost(model, struct(LemonAi.Types.Usage, usage))
    Map.put(usage, :cost, Map.from_struct(cost))
  end
end
