defmodule Ai.Providers.OpenAIResponsesShared do
  @moduledoc """
  Shared utilities for OpenAI Responses API family.

  This module provides common message conversion, tool conversion,
  and stream processing logic used by:
  - OpenAI Responses API
  - OpenAI Codex Responses API (ChatGPT Plus/Pro)
  - Azure OpenAI Responses API
  """

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    ImageContent,
    Model,
    TextContent,
    ThinkingContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  alias Ai.EventStream
  alias Ai.Providers.TextSanitizer
  require Logger

  @max_function_call_output_bytes 10_485_760

  # ============================================================================
  # Types
  # ============================================================================

  @type reasoning_effort :: :minimal | :low | :medium | :high | :xhigh | :none
  @type reasoning_summary :: :auto | :detailed | :concise | :off | :on | nil

  @type stream_options :: %{
          optional(:service_tier) => String.t() | nil,
          optional(:apply_service_tier_pricing) => (Usage.t(), String.t() | nil -> Usage.t())
        }

  @type message_options :: %{
          optional(:include_system_prompt) => boolean()
        }

  @type tool_options :: %{
          optional(:strict) => boolean() | nil
        }

  # ============================================================================
  # Utilities
  # ============================================================================

  @doc """
  Fast deterministic hash to shorten long strings.
  Used for truncating message IDs to fit OpenAI's 64-char limit.
  """
  @spec short_hash(String.t()) :: String.t()
  def short_hash(str) do
    # Use Erlang's phash2 for fast deterministic hashing
    h1 = :erlang.phash2(str, 0xFFFFFFFF)
    h2 = :erlang.phash2({str, :salt}, 0xFFFFFFFF)
    Integer.to_string(h1, 36) <> Integer.to_string(h2, 36)
  end

  @doc """
  Sanitize unicode surrogates from a string.
  Some APIs reject unpaired surrogate characters.
  """
  @spec sanitize_surrogates(String.t()) :: String.t()
  def sanitize_surrogates(str), do: TextSanitizer.sanitize(str)

  # ============================================================================
  # Message Conversion
  # ============================================================================

  @doc """
  Convert context messages to OpenAI Responses API input format.

  ## Options
  - `:include_system_prompt` - Whether to include system prompt (default: true)
  """
  @spec convert_messages(Model.t(), Context.t(), MapSet.t(atom()), message_options()) :: [map()]
  def convert_messages(model, context, allowed_tool_call_providers, opts \\ %{}) do
    include_system_prompt = Map.get(opts, :include_system_prompt, true)
    messages = []

    # Add system prompt
    messages =
      if include_system_prompt && context.system_prompt do
        role = if model.reasoning, do: "developer", else: "system"

        [
          %{
            "role" => role,
            "content" => sanitize_surrogates(context.system_prompt)
          }
          | messages
        ]
      else
        messages
      end

    # Transform messages with tool call ID normalization
    transformed = transform_messages(context.messages, model, allowed_tool_call_providers)

    # Convert each message
    {converted, _msg_index} =
      Enum.reduce(transformed, {messages, 0}, fn msg, {acc, idx} ->
        case convert_message(msg, model, idx, allowed_tool_call_providers) do
          nil -> {acc, idx + 1}
          [] -> {acc, idx + 1}
          converted when is_list(converted) -> {acc ++ converted, idx + 1}
          converted -> {acc ++ [converted], idx + 1}
        end
      end)

    converted
  end

  defp convert_message(%UserMessage{content: content}, _model, _idx, _providers)
       when is_binary(content) do
    %{
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => sanitize_surrogates(content)}]
    }
  end

  defp convert_message(%UserMessage{content: content}, model, _idx, _providers)
       when is_list(content) do
    input_content =
      content
      |> Enum.map(fn
        %TextContent{text: text} ->
          %{"type" => "input_text", "text" => sanitize_surrogates(text)}

        %ImageContent{data: data, mime_type: mime_type} ->
          %{
            "type" => "input_image",
            "detail" => "auto",
            "image_url" => "data:#{mime_type};base64,#{data}"
          }
      end)

    # Filter out images if model doesn't support them
    filtered =
      if :image in model.input do
        input_content
      else
        Enum.filter(input_content, &(&1["type"] != "input_image"))
      end

    if Enum.empty?(filtered), do: nil, else: %{"role" => "user", "content" => filtered}
  end

  defp convert_message(%AssistantMessage{} = msg, model, msg_index, _providers) do
    is_different_model =
      msg.model != model.id &&
        msg.provider == model.provider &&
        msg.api == model.api

    output =
      msg.content
      |> Enum.map(fn block -> convert_assistant_block(block, msg_index, is_different_model) end)
      |> Enum.filter(& &1)

    if Enum.empty?(output), do: nil, else: output
  end

  defp convert_message(%ToolResultMessage{} = msg, model, _idx, _providers) do
    # Extract text content
    text_result =
      msg.content
      |> Enum.filter(&match?(%TextContent{}, &1))
      |> Enum.map(& &1.text)
      |> Enum.join("\n")

    has_images = Enum.any?(msg.content, &match?(%ImageContent{}, &1))
    has_text = String.length(text_result) > 0

    # Extract call_id from tool_call_id (format: "call_id|item_id")
    [call_id | _] = String.split(msg.tool_call_id, "|")

    # Build function call output
    output_text = if has_text, do: text_result, else: "(see attached image)"

    output_text =
      output_text
      |> sanitize_surrogates()
      |> truncate_function_call_output(call_id, msg.tool_name)

    result = [
      %{
        "type" => "function_call_output",
        "call_id" => call_id,
        "output" => output_text
      }
    ]

    # Add images as follow-up user message if model supports them
    if has_images && :image in model.input do
      image_parts =
        msg.content
        |> Enum.filter(&match?(%ImageContent{}, &1))
        |> Enum.map(fn %ImageContent{data: data, mime_type: mime_type} ->
          %{
            "type" => "input_image",
            "detail" => "auto",
            "image_url" => "data:#{mime_type};base64,#{data}"
          }
        end)

      content_parts = [
        %{"type" => "input_text", "text" => "Attached image(s) from tool result:"}
        | image_parts
      ]

      result ++ [%{"role" => "user", "content" => content_parts}]
    else
      result
    end
  end

  defp convert_message(_msg, _model, _idx, _providers), do: nil

  defp truncate_function_call_output(text, _call_id, _tool_name)
       when byte_size(text) <= @max_function_call_output_bytes do
    text
  end

  defp truncate_function_call_output(text, call_id, tool_name) do
    truncated =
      text
      |> binary_part(0, @max_function_call_output_bytes)
      |> trim_to_valid_utf8()

    Logger.warning(
      "OpenAI function_call_output truncated " <>
        "call_id=#{inspect(call_id)} tool_name=#{inspect(tool_name)} " <>
        "original_bytes=#{byte_size(text)} truncated_bytes=#{byte_size(truncated)} " <>
        "limit_bytes=#{@max_function_call_output_bytes}"
    )

    truncated
  end

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_valid_utf8()
    end
  end

  defp convert_assistant_block(%ThinkingContent{} = block, _msg_index, _is_different_model) do
    if block.thinking_signature do
      # Parse and return the reasoning item from signature
      case Jason.decode(block.thinking_signature) do
        {:ok, reasoning_item} -> reasoning_item
        _ -> nil
      end
    else
      nil
    end
  end

  defp convert_assistant_block(%TextContent{} = block, msg_index, _is_different_model) do
    # OpenAI requires id to be max 64 characters
    msg_id =
      cond do
        block.text_signature && String.length(block.text_signature) <= 64 ->
          block.text_signature

        block.text_signature ->
          "msg_#{short_hash(block.text_signature)}"

        true ->
          "msg_#{msg_index}"
      end

    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{"type" => "output_text", "text" => sanitize_surrogates(block.text), "annotations" => []}
      ],
      "status" => "completed",
      "id" => msg_id
    }
  end

  defp convert_assistant_block(%ToolCall{} = block, _msg_index, is_different_model) do
    [call_id, item_id_raw] =
      case String.split(block.id, "|") do
        [c, i] -> [c, i]
        [c] -> [c, nil]
      end

    # For different-model messages, set id to nil to avoid pairing validation
    item_id =
      if is_different_model && item_id_raw && String.starts_with?(item_id_raw, "fc_") do
        nil
      else
        item_id_raw
      end

    base = %{
      "type" => "function_call",
      "call_id" => call_id,
      "name" => block.name,
      "arguments" => Jason.encode!(block.arguments)
    }

    if item_id, do: Map.put(base, "id", item_id), else: base
  end

  defp convert_assistant_block(_block, _msg_index, _is_different_model), do: nil

  # ============================================================================
  # Message Transformation
  # ============================================================================

  @doc """
  Transform messages for cross-provider compatibility.
  Normalizes tool call IDs and handles thinking blocks.
  """
  @spec transform_messages([map()], Model.t(), MapSet.t(atom())) :: [map()]
  def transform_messages(messages, model, allowed_tool_call_providers) do
    # Build tool call ID map for normalization
    {transformed, tool_call_id_map} =
      Enum.map_reduce(messages, %{}, fn msg, id_map ->
        transform_message(msg, model, allowed_tool_call_providers, id_map)
      end)

    # Apply tool call ID normalization to tool results
    transformed =
      Enum.map(transformed, fn
        %ToolResultMessage{tool_call_id: id} = msg ->
          case Map.get(tool_call_id_map, id) do
            nil -> msg
            normalized_id -> %{msg | tool_call_id: normalized_id}
          end

        msg ->
          msg
      end)

    # Insert synthetic tool results for orphaned tool calls
    insert_synthetic_tool_results(transformed)
  end

  defp transform_message(%UserMessage{} = msg, _model, _providers, id_map) do
    {msg, id_map}
  end

  defp transform_message(%AssistantMessage{} = msg, model, providers, id_map) do
    # Skip errored/aborted messages
    if msg.stop_reason in [:error, :aborted] do
      {nil, id_map}
    else
      is_same_model =
        msg.provider == model.provider &&
          msg.api == model.api &&
          msg.model == model.id

      {transformed_content, new_id_map} =
        Enum.map_reduce(msg.content, id_map, fn block, acc ->
          transform_block(block, model, providers, is_same_model, msg, acc)
        end)

      transformed_content = List.flatten(transformed_content) |> Enum.filter(& &1)
      {%{msg | content: transformed_content}, new_id_map}
    end
  end

  defp transform_message(%ToolResultMessage{} = msg, _model, _providers, id_map) do
    {msg, id_map}
  end

  defp transform_message(msg, _model, _providers, id_map), do: {msg, id_map}

  defp transform_block(
         %ThinkingContent{} = block,
         _model,
         _providers,
         is_same_model,
         _msg,
         id_map
       ) do
    result =
      cond do
        # Keep thinking with signature for same model
        is_same_model && block.thinking_signature ->
          block

        # Skip empty thinking blocks
        !block.thinking || String.trim(block.thinking) == "" ->
          nil

        # Keep for same model
        is_same_model ->
          block

        # Convert to text for different model
        true ->
          %TextContent{type: :text, text: block.thinking}
      end

    {result, id_map}
  end

  defp transform_block(%TextContent{} = block, _model, _providers, is_same_model, _msg, id_map) do
    result =
      if is_same_model do
        block
      else
        %TextContent{type: :text, text: block.text}
      end

    {result, id_map}
  end

  defp transform_block(%ToolCall{} = block, model, providers, is_same_model, _msg, id_map) do
    block =
      if !is_same_model && block.thought_signature do
        %{block | thought_signature: nil}
      else
        block
      end

    {block, new_id_map} =
      if !is_same_model && MapSet.member?(providers, model.provider) do
        normalized_id = normalize_tool_call_id(block.id, model.provider)

        if normalized_id != block.id do
          {%{block | id: normalized_id}, Map.put(id_map, block.id, normalized_id)}
        else
          {block, id_map}
        end
      else
        {block, id_map}
      end

    {block, new_id_map}
  end

  defp transform_block(block, _model, _providers, _is_same_model, _msg, id_map),
    do: {block, id_map}

  defp normalize_tool_call_id(id, provider)
       when provider in [:openai, :"openai-codex", :opencode] do
    if not String.contains?(id, "|") do
      id
    else
      [call_id, item_id] = String.split(id, "|", parts: 2)

      # Sanitize: only alphanumeric, underscore, hyphen
      sanitized_call_id = String.replace(call_id, ~r/[^a-zA-Z0-9_-]/, "_")

      sanitized_item_id =
        item_id
        |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
        |> then(fn s ->
          if String.starts_with?(s, "fc"), do: s, else: "fc_#{s}"
        end)

      # Truncate to 64 chars and strip trailing underscores
      normalized_call_id =
        sanitized_call_id
        |> String.slice(0, 64)
        |> String.replace(~r/_+$/, "")
        |> then(fn value ->
          if value == "" do
            "call_" <> short_hash(call_id)
          else
            value
          end
        end)
        |> String.slice(0, 64)

      normalized_item_id =
        sanitized_item_id
        |> String.slice(0, 64)
        |> String.replace(~r/_+$/, "")
        |> then(fn value ->
          cond do
            value == "" ->
              "fc_" <> short_hash(item_id)

            value == "fc" or value == "fc_" ->
              "fc_" <> short_hash(item_id)

            String.starts_with?(value, "fc_") ->
              value

            true ->
              "fc_" <> short_hash(item_id)
          end
        end)
        |> String.slice(0, 64)

      "#{normalized_call_id}|#{normalized_item_id}"
    end
  end

  defp normalize_tool_call_id(id, _provider), do: id

  defp insert_synthetic_tool_results(messages) do
    {result, pending_tool_calls, existing_ids} =
      messages
      |> Enum.filter(& &1)
      |> Enum.reduce({[], [], MapSet.new()}, fn msg, {result, pending_tool_calls, existing_ids} ->
        case msg do
          %AssistantMessage{} = assistant_msg ->
            # Insert synthetic results for pending orphaned tool calls
            result =
              if pending_tool_calls != [] do
                synthetic =
                  pending_tool_calls
                  |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
                  |> Enum.map(&synthetic_tool_result/1)

                result ++ synthetic
              else
                result
              end

            # Extract tool calls from this message
            tool_calls =
              assistant_msg.content
              |> Enum.filter(&match?(%ToolCall{}, &1))

            {result ++ [msg], tool_calls, MapSet.new()}

          %ToolResultMessage{tool_call_id: id} = tool_result ->
            {result ++ [tool_result], pending_tool_calls, MapSet.put(existing_ids, id)}

          %UserMessage{} = user_msg ->
            # User message interrupts tool flow
            result =
              if pending_tool_calls != [] do
                synthetic =
                  pending_tool_calls
                  |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
                  |> Enum.map(&synthetic_tool_result/1)

                result ++ synthetic
              else
                result
              end

            {result ++ [user_msg], [], MapSet.new()}

          other ->
            {result ++ [other], pending_tool_calls, existing_ids}
        end
      end)

    if pending_tool_calls != [] do
      synthetic =
        pending_tool_calls
        |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
        |> Enum.map(&synthetic_tool_result/1)

      result ++ synthetic
    else
      result
    end
  end

  defp synthetic_tool_result(%ToolCall{} = tc) do
    %ToolResultMessage{
      role: :tool_result,
      tool_call_id: tc.id,
      tool_name: tc.name,
      content: [%TextContent{type: :text, text: "No result provided"}],
      is_error: true,
      timestamp: System.system_time(:millisecond)
    }
  end

  # ============================================================================
  # Tool Conversion
  # ============================================================================

  @doc """
  Convert tools to OpenAI Responses API format.

  ## Options
  - `:strict` - Whether to enforce strict mode (default: false, nil means omit)
  """
  @spec convert_tools([Tool.t()], tool_options()) :: [map()]
  def convert_tools(tools, opts \\ %{}) do
    strict = Map.get(opts, :strict, false)

    Enum.map(tools, fn tool ->
      base = %{
        "type" => "function",
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.parameters
      }

      case strict do
        nil -> base
        val -> Map.put(base, "strict", val)
      end
    end)
  end

  # ============================================================================
  # Stream Processing
  # ============================================================================

  @doc """
  Process OpenAI Responses API stream events and emit to EventStream.
  """
  @spec process_stream(
          Enumerable.t(),
          AssistantMessage.t(),
          EventStream.t(),
          Model.t(),
          stream_options()
        ) ::
          {:ok, AssistantMessage.t()} | {:error, term()}
  def process_stream(events, output, stream, model, opts \\ %{}) do
    state = %{
      current_item: nil,
      current_block: nil,
      output: output,
      stream: stream,
      model: model,
      opts: opts
    }

    try do
      Enum.reduce_while(events, state, fn event, state ->
        case process_event(event, state) do
          {:ok, new_state} -> {:cont, new_state}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:error, reason} -> {:error, reason}
        final_state -> {:ok, final_state.output}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :throw, {:stream_error, reason} -> {:error, reason}
      :throw, reason -> {:error, reason}
      :exit, reason -> {:error, reason}
    end
  end

  defp process_event(%{"type" => "response.output_item.added", "item" => item}, state) do
    case item["type"] do
      "reasoning" ->
        block = %ThinkingContent{type: :thinking, thinking: ""}
        output = %{state.output | content: state.output.content ++ [block]}

        EventStream.push_async(
          state.stream,
          {:thinking_start, length(output.content) - 1, output}
        )

        {:ok, %{state | current_item: item, current_block: block, output: output}}

      "message" ->
        block = %TextContent{type: :text, text: ""}
        output = %{state.output | content: state.output.content ++ [block]}
        EventStream.push_async(state.stream, {:text_start, length(output.content) - 1, output})
        {:ok, %{state | current_item: item, current_block: block, output: output}}

      "function_call" ->
        tool_id = "#{item["call_id"]}|#{item["id"]}"

        block = %ToolCall{
          type: :tool_call,
          id: tool_id,
          name: item["name"],
          arguments: %{}
        }

        # Store partial JSON for streaming parsing
        partial_json = item["arguments"] || ""
        block = Map.put(block, :partial_json, partial_json)

        output = %{state.output | content: state.output.content ++ [block]}

        EventStream.push_async(
          state.stream,
          {:tool_call_start, length(output.content) - 1, output}
        )

        {:ok, %{state | current_item: item, current_block: block, output: output}}

      _ ->
        {:ok, state}
    end
  end

  defp process_event(%{"type" => "response.reasoning_summary_part.added", "part" => part}, state) do
    if state.current_item && state.current_item["type"] == "reasoning" do
      item = Map.update(state.current_item, "summary", [part], &(&1 ++ [part]))
      {:ok, %{state | current_item: item}}
    else
      {:ok, state}
    end
  end

  defp process_event(
         %{"type" => "response.reasoning_summary_text.delta", "delta" => delta},
         state
       ) do
    if state.current_item && state.current_item["type"] == "reasoning" &&
         state.current_block && state.current_block.type == :thinking do
      # Update block thinking text
      block = %{state.current_block | thinking: state.current_block.thinking <> delta}

      # Update output
      output = update_content_block(state.output, block)
      idx = length(output.content) - 1

      EventStream.push_async(state.stream, {:thinking_delta, idx, delta, output})
      {:ok, %{state | current_block: block, output: output}}
    else
      {:ok, state}
    end
  end

  defp process_event(%{"type" => "response.reasoning_summary_part.done"}, state) do
    if state.current_item && state.current_item["type"] == "reasoning" &&
         state.current_block && state.current_block.type == :thinking do
      delta = "\n\n"
      block = %{state.current_block | thinking: state.current_block.thinking <> delta}
      output = update_content_block(state.output, block)
      idx = length(output.content) - 1

      EventStream.push_async(state.stream, {:thinking_delta, idx, delta, output})
      {:ok, %{state | current_block: block, output: output}}
    else
      {:ok, state}
    end
  end

  defp process_event(%{"type" => "response.content_part.added", "part" => part}, state) do
    if state.current_item && state.current_item["type"] == "message" do
      if part["type"] in ["output_text", "refusal"] do
        content = Map.get(state.current_item, "content", []) ++ [part]
        item = Map.put(state.current_item, "content", content)
        {:ok, %{state | current_item: item}}
      else
        {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  defp process_event(%{"type" => "response.output_text.delta", "delta" => delta}, state) do
    if state.current_item && state.current_item["type"] == "message" &&
         state.current_block && state.current_block.type == :text do
      block = %{state.current_block | text: state.current_block.text <> delta}
      output = update_content_block(state.output, block)
      idx = length(output.content) - 1

      EventStream.push_async(state.stream, {:text_delta, idx, delta, output})
      {:ok, %{state | current_block: block, output: output}}
    else
      {:ok, state}
    end
  end

  defp process_event(%{"type" => "response.refusal.delta", "delta" => delta}, state) do
    if state.current_item && state.current_item["type"] == "message" &&
         state.current_block && state.current_block.type == :text do
      block = %{state.current_block | text: state.current_block.text <> delta}
      output = update_content_block(state.output, block)
      idx = length(output.content) - 1

      EventStream.push_async(state.stream, {:text_delta, idx, delta, output})
      {:ok, %{state | current_block: block, output: output}}
    else
      {:ok, state}
    end
  end

  defp process_event(
         %{"type" => "response.function_call_arguments.delta", "delta" => delta},
         state
       ) do
    if state.current_item && state.current_item["type"] == "function_call" &&
         state.current_block && state.current_block.type == :tool_call do
      partial_json = Map.get(state.current_block, :partial_json, "") <> delta
      arguments = parse_streaming_json(partial_json)

      block =
        %{state.current_block | arguments: arguments} |> Map.put(:partial_json, partial_json)

      output = update_content_block(state.output, block)
      idx = length(output.content) - 1

      EventStream.push_async(state.stream, {:tool_call_delta, idx, delta, output})
      {:ok, %{state | current_block: block, output: output}}
    else
      {:ok, state}
    end
  end

  defp process_event(
         %{"type" => "response.function_call_arguments.done", "arguments" => arguments},
         state
       ) do
    if state.current_item && state.current_item["type"] == "function_call" &&
         state.current_block && state.current_block.type == :tool_call do
      parsed_args = parse_streaming_json(arguments)
      block = %{state.current_block | arguments: parsed_args} |> Map.put(:partial_json, arguments)
      output = update_content_block(state.output, block)
      {:ok, %{state | current_block: block, output: output}}
    else
      {:ok, state}
    end
  end

  defp process_event(%{"type" => "response.output_item.done", "item" => item}, state) do
    case item["type"] do
      "reasoning" when state.current_block != nil and state.current_block.type == :thinking ->
        # Build full thinking text from summary
        thinking =
          item
          |> Map.get("summary", [])
          |> Enum.map(& &1["text"])
          |> Enum.join("\n\n")

        block = %{
          state.current_block
          | thinking: thinking,
            thinking_signature: Jason.encode!(item)
        }

        output = update_content_block(state.output, block)
        idx = length(output.content) - 1

        EventStream.push_async(state.stream, {:thinking_end, idx, thinking, output})
        {:ok, %{state | current_block: nil, output: output}}

      "message" when state.current_block != nil and state.current_block.type == :text ->
        # Build full text from content parts
        text =
          item
          |> Map.get("content", [])
          |> Enum.map(fn
            %{"type" => "output_text", "text" => t} -> t
            %{"type" => "refusal", "refusal" => r} -> r
            _ -> ""
          end)
          |> Enum.join("")

        block = %{state.current_block | text: text, text_signature: item["id"]}
        output = update_content_block(state.output, block)
        idx = length(output.content) - 1

        EventStream.push_async(state.stream, {:text_end, idx, text, output})
        {:ok, %{state | current_block: nil, output: output}}

      "function_call" ->
        partial_json = Map.get(state.current_block, :partial_json, "")

        args =
          if partial_json && partial_json != "" do
            case Jason.decode(partial_json) do
              {:ok, decoded} -> decoded
              _ -> %{}
            end
          else
            case Jason.decode(item["arguments"] || "{}") do
              {:ok, decoded} -> decoded
              _ -> %{}
            end
          end

        tool_call = %ToolCall{
          type: :tool_call,
          id: "#{item["call_id"]}|#{item["id"]}",
          name: item["name"],
          arguments: args
        }

        # Remove :partial_json from the block stored in output
        clean_block = Map.delete(state.current_block, :partial_json) |> Map.put(:arguments, args)
        output = update_content_block(state.output, clean_block)
        idx = length(output.content) - 1

        EventStream.push_async(state.stream, {:tool_call_end, idx, tool_call, output})
        {:ok, %{state | current_block: nil, output: output}}

      _ ->
        {:ok, state}
    end
  end

  defp process_event(%{"type" => "response.completed", "response" => response}, state) do
    output = state.output

    # Process usage
    output =
      if response && response["usage"] do
        usage = response["usage"]
        cached_tokens = get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0
        raw_input_tokens = usage["input_tokens"] || 0
        input_tokens = max(raw_input_tokens - cached_tokens, 0)
        output_tokens = usage["output_tokens"] || 0
        total_tokens = usage["total_tokens"] || 0

        usage_struct = %Usage{
          input: input_tokens,
          output: output_tokens,
          cache_read: cached_tokens,
          cache_write: 0,
          total_tokens: total_tokens,
          cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
        }

        # Calculate cost based on model pricing
        usage_struct = calculate_cost(state.model, usage_struct)

        # Apply service tier pricing if provided
        usage_struct =
          if state.opts[:apply_service_tier_pricing] do
            service_tier = response["service_tier"] || state.opts[:service_tier]
            state.opts[:apply_service_tier_pricing].(usage_struct, service_tier)
          else
            usage_struct
          end

        %{output | usage: usage_struct}
      else
        output
      end

    # Map status to stop reason
    stop_reason = map_stop_reason(response && response["status"])

    # If there are tool calls and stop_reason is :stop, change to :tool_use
    stop_reason =
      if Enum.any?(output.content, &match?(%ToolCall{}, &1)) && stop_reason == :stop do
        :tool_use
      else
        stop_reason
      end

    output = %{output | stop_reason: stop_reason}
    {:ok, %{state | output: output}}
  end

  defp process_event(%{"type" => "error", "code" => code, "message" => message}, _state) do
    error_msg = "Error Code #{code}: #{message || "Unknown error"}"
    {:error, error_msg}
  end

  defp process_event(%{"type" => "response.failed"}, _state) do
    {:error, "Unknown error"}
  end

  defp process_event(_event, state) do
    {:ok, state}
  end

  defp update_content_block(output, block) do
    content = List.replace_at(output.content, length(output.content) - 1, block)
    %{output | content: content}
  end

  defp map_stop_reason(nil), do: :stop
  defp map_stop_reason("completed"), do: :stop
  defp map_stop_reason("incomplete"), do: :length
  defp map_stop_reason("failed"), do: :error
  defp map_stop_reason("cancelled"), do: :error
  defp map_stop_reason("in_progress"), do: :stop
  defp map_stop_reason("queued"), do: :stop
  defp map_stop_reason(_), do: :stop

  # ============================================================================
  # Cost Calculation
  # ============================================================================

  @doc """
  Calculate cost based on model pricing.
  """
  @spec calculate_cost(Model.t(), Usage.t()) :: Usage.t()
  def calculate_cost(model, usage) do
    cost = model.cost

    input_cost = usage.input / 1_000_000 * cost.input
    output_cost = usage.output / 1_000_000 * cost.output
    cache_read_cost = usage.cache_read / 1_000_000 * cost.cache_read
    cache_write_cost = usage.cache_write / 1_000_000 * cost.cache_write
    total_cost = input_cost + output_cost + cache_read_cost + cache_write_cost

    %{
      usage
      | cost: %Cost{
          input: input_cost,
          output: output_cost,
          cache_read: cache_read_cost,
          cache_write: cache_write_cost,
          total: total_cost
        }
    }
  end

  # ============================================================================
  # JSON Parsing
  # ============================================================================

  @doc """
  Parse potentially incomplete JSON for streaming tool arguments.
  Returns a map with whatever can be parsed.
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

    # Add closing characters
    closing =
      String.duplicate("}", max(open_braces, 0)) <> String.duplicate("]", max(open_brackets, 0))

    json <> closing
  end

  # ============================================================================
  # Service Tier Pricing
  # ============================================================================

  @doc """
  Get cost multiplier for service tier.
  """
  @spec service_tier_cost_multiplier(String.t() | nil) :: float()
  def service_tier_cost_multiplier("flex"), do: 0.5
  def service_tier_cost_multiplier("priority"), do: 2.0
  def service_tier_cost_multiplier(_), do: 1.0

  @doc """
  Apply service tier pricing to usage.
  """
  @spec apply_service_tier_pricing(Usage.t(), String.t() | nil) :: Usage.t()
  def apply_service_tier_pricing(usage, service_tier) do
    multiplier = service_tier_cost_multiplier(service_tier)

    if multiplier == 1.0 do
      usage
    else
      cost = usage.cost

      %{
        usage
        | cost: %Cost{
            input: cost.input * multiplier,
            output: cost.output * multiplier,
            cache_read: cost.cache_read * multiplier,
            cache_write: cost.cache_write * multiplier,
            total: (cost.input + cost.output + cost.cache_read + cost.cache_write) * multiplier
          }
      }
    end
  end
end
