defmodule Ai.Providers.OpenAICompletions do
  @moduledoc """
  OpenAI Completions API provider.

  This provider implements the OpenAI Chat Completions API format, which is used
  by many OpenAI-compatible services including:
  - OpenAI (api.openai.com)
  - Groq (api.groq.com)
  - Mistral (api.mistral.ai)
  - xAI/Grok (api.x.ai)
  - Cerebras (api.cerebras.ai)
  - OpenRouter (openrouter.ai)
  - Local servers (llama.cpp, etc.)

  ## SSE Format

  The API returns Server-Sent Events (SSE) with `data:` lines containing JSON chunks:

      data: {"id":"chatcmpl-...","choices":[{"delta":{"content":"Hello"}}]}
      data: {"id":"chatcmpl-...","choices":[{"delta":{"content":" world"}}]}
      data: [DONE]

  ## Compatibility Settings

  Different providers have varying support for OpenAI features. The `model.compat`
  field can override auto-detection:

  - `supports_store` - Whether to send `store: false`
  - `supports_developer_role` - Use "developer" vs "system" role for reasoning models
  - `supports_reasoning_effort` - Whether `reasoning_effort` parameter works
  - `max_tokens_field` - "max_completion_tokens" (default) or "max_tokens"
  - `requires_tool_result_name` - Include `name` in tool results (Mistral)
  - `requires_assistant_after_tool_result` - Add synthetic assistant message after tool results
  - `requires_thinking_as_text` - Convert thinking blocks to plain text
  - `requires_mistral_tool_ids` - Normalize tool IDs to 9 alphanumeric chars
  """

  @behaviour Ai.Provider

  alias Ai.Types.{
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

  alias Ai.EventStream

  require Logger

  # ============================================================================
  # Provider Behaviour Implementation
  # ============================================================================

  @impl Ai.Provider
  def api_id, do: :openai_completions

  @impl Ai.Provider
  def provider_id, do: :openai

  @impl Ai.Provider
  def get_env_api_key do
    System.get_env("OPENAI_API_KEY")
  end

  @impl Ai.Provider
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
  # Private Implementation
  # ============================================================================

  defp do_stream(stream, model, context, opts) do
    output = build_initial_output(model)

    try do
      api_key = get_api_key(model, opts)
      url = build_url(model)
      headers = build_headers(model, context, api_key, opts)
      params = build_params(model, context, opts)

      EventStream.push_async(stream, {:start, output})

      output = stream_request(stream, output, url, headers, params)

      if output.stop_reason in [:error, :aborted] do
        EventStream.error(stream, output)
      else
        EventStream.complete(stream, output)
      end
    rescue
      error ->
        output = %{
          output
          | stop_reason: :error,
            error_message: Exception.message(error)
        }

        EventStream.error(stream, output)
    end
  end

  defp build_initial_output(model) do
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

  defp get_api_key(model, opts) do
    cond do
      opts.api_key && opts.api_key != "" ->
        opts.api_key

      api_key = get_provider_env_key(model.provider) ->
        api_key

      api_key = get_env_api_key() ->
        api_key

      true ->
        raise "OpenAI API key is required. Set OPENAI_API_KEY environment variable or pass api_key option."
    end
  end

  defp get_provider_env_key(provider) do
    env_var =
      case provider do
        :groq -> "GROQ_API_KEY"
        :mistral -> "MISTRAL_API_KEY"
        :xai -> "XAI_API_KEY"
        :cerebras -> "CEREBRAS_API_KEY"
        :openrouter -> "OPENROUTER_API_KEY"
        "groq" -> "GROQ_API_KEY"
        "mistral" -> "MISTRAL_API_KEY"
        "xai" -> "XAI_API_KEY"
        "cerebras" -> "CEREBRAS_API_KEY"
        "openrouter" -> "OPENROUTER_API_KEY"
        _ -> nil
      end

    if env_var, do: System.get_env(env_var), else: nil
  end

  defp build_url(model) do
    base_url = String.trim_trailing(model.base_url, "/")
    "#{base_url}/chat/completions"
  end

  defp build_headers(model, context, api_key, opts) do
    base_headers = %{
      "authorization" => "Bearer #{api_key}",
      "content-type" => "application/json",
      "accept" => "text/event-stream"
    }

    # Add model-specific headers
    model_headers =
      (model.headers || %{})
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), v} end)
      |> Map.new()

    # Add Copilot-specific headers
    copilot_headers =
      if model.provider in [:github_copilot, "github-copilot"] do
        build_copilot_headers(context) |> Map.new()
      else
        %{}
      end

    # Add user-provided headers last (highest priority)
    opts_headers =
      (opts.headers || %{})
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), v} end)
      |> Map.new()

    # Merge headers - later entries override earlier ones
    base_headers
    |> Map.merge(model_headers)
    |> Map.merge(copilot_headers)
    |> Map.merge(opts_headers)
    |> Map.to_list()
  end

  defp build_copilot_headers(context) do
    messages = context.messages || []
    last_message = List.last(messages)

    is_agent_call =
      case last_message do
        %{role: :user} -> false
        nil -> false
        _ -> true
      end

    has_images =
      Enum.any?(messages, fn msg ->
        case msg do
          %UserMessage{content: content} when is_list(content) ->
            Enum.any?(content, &match?(%ImageContent{}, &1))

          %ToolResultMessage{content: content} ->
            Enum.any?(content, &match?(%ImageContent{}, &1))

          _ ->
            false
        end
      end)

    headers = [
      {"x-initiator", if(is_agent_call, do: "agent", else: "user")},
      {"openai-intent", "conversation-edits"}
    ]

    if has_images do
      [{"copilot-vision-request", "true"} | headers]
    else
      headers
    end
  end

  defp build_params(model, context, opts) do
    compat = get_compat(model)

    %{"model" => model.id, "messages" => convert_messages(model, context, compat), "stream" => true}
    |> maybe_add_stream_options(compat)
    |> maybe_add_store(compat)
    |> maybe_add_max_tokens(opts, compat)
    |> maybe_add_temperature(opts)
    |> maybe_add_tools(context, compat)
    |> maybe_add_reasoning(model, opts, compat)
    |> maybe_add_openrouter_routing(model, compat)
  end

  defp maybe_add_stream_options(params, %{supports_usage_in_streaming: true}) do
    Map.put(params, "stream_options", %{"include_usage" => true})
  end

  defp maybe_add_stream_options(params, _compat), do: params

  defp maybe_add_store(params, %{supports_store: true}) do
    Map.put(params, "store", false)
  end

  defp maybe_add_store(params, _compat), do: params

  defp maybe_add_max_tokens(params, %{max_tokens: max_tokens}, _compat) when is_nil(max_tokens) or max_tokens <= 0, do: params

  defp maybe_add_max_tokens(params, %{max_tokens: max_tokens}, %{max_tokens_field: field}) do
    Map.put(params, field, max_tokens)
  end

  defp maybe_add_temperature(params, %{temperature: nil}), do: params
  defp maybe_add_temperature(params, %{temperature: temp}), do: Map.put(params, "temperature", temp)

  defp maybe_add_tools(params, %{tools: tools}, _compat) when is_list(tools) and length(tools) > 0 do
    Map.put(params, "tools", convert_tools(tools))
  end

  defp maybe_add_tools(params, %{messages: messages}, _compat) do
    if has_tool_history?(messages) do
      Map.put(params, "tools", [])
    else
      params
    end
  end

  defp maybe_add_reasoning(params, %{reasoning: false}, _opts, _compat), do: params
  defp maybe_add_reasoning(params, _model, %{reasoning: nil}, _compat), do: params

  defp maybe_add_reasoning(params, model, %{reasoning: _reasoning}, %{thinking_format: "zai"}) do
    if model.reasoning do
      Map.put(params, "thinking", %{"type" => "enabled"})
    else
      params
    end
  end

  defp maybe_add_reasoning(params, model, %{reasoning: reasoning}, %{supports_reasoning_effort: true}) do
    if model.reasoning do
      Map.put(params, "reasoning_effort", to_string(reasoning))
    else
      params
    end
  end

  defp maybe_add_reasoning(params, %{reasoning: true}, _opts, %{thinking_format: "zai"}) do
    Map.put(params, "thinking", %{"type" => "disabled"})
  end

  defp maybe_add_reasoning(params, _model, _opts, _compat), do: params

  defp maybe_add_openrouter_routing(params, %{base_url: base_url}, %{open_router_routing: routing}) do
    if String.contains?(base_url, "openrouter.ai") && routing do
      Map.put(params, "provider", routing)
    else
      params
    end
  end

  defp maybe_add_openrouter_routing(params, _model, _compat), do: params

  defp has_tool_history?(messages) do
    Enum.any?(messages, fn
      %ToolResultMessage{} -> true
      %AssistantMessage{content: content} -> Enum.any?(content, &match?(%ToolCall{}, &1))
      _ -> false
    end)
  end

  defp convert_messages(model, context, compat) do
    messages = []

    # Add system prompt
    messages =
      if context.system_prompt && context.system_prompt != "" do
        role =
          if model.reasoning && compat.supports_developer_role do
            "developer"
          else
            "system"
          end

        [%{"role" => role, "content" => sanitize_surrogates(context.system_prompt)} | messages]
      else
        messages
      end

    # Convert messages
    messages = messages |> Enum.reverse()
    convert_messages_loop(messages, context.messages, model, compat, nil)
  end

  defp convert_messages_loop(acc, [], _model, _compat, _last_role), do: acc

  defp convert_messages_loop(acc, [msg | rest], model, compat, last_role) do
    # Insert synthetic assistant message if needed (after tool result, before user)
    acc =
      if compat.requires_assistant_after_tool_result && last_role == :tool_result &&
           msg.role == :user do
        acc ++ [%{"role" => "assistant", "content" => "I have processed the tool results."}]
      else
        acc
      end

    {converted, new_rest, new_last_role} = convert_single_message(msg, rest, model, compat)

    acc =
      cond do
        converted == nil ->
          acc

        is_list(converted) ->
          acc ++ converted

        true ->
          acc ++ [converted]
      end

    convert_messages_loop(acc, new_rest, model, compat, new_last_role)
  end

  defp convert_single_message(%UserMessage{content: content}, rest, _model, _compat)
       when is_binary(content) do
    msg = %{"role" => "user", "content" => sanitize_surrogates(content)}
    {msg, rest, :user}
  end

  defp convert_single_message(%UserMessage{content: content}, rest, model, _compat)
       when is_list(content) do
    parts =
      content
      |> Enum.filter(fn
        %ImageContent{} -> :image in model.input
        _ -> true
      end)
      |> Enum.map(fn
        %TextContent{text: text} ->
          %{"type" => "text", "text" => sanitize_surrogates(text)}

        %ImageContent{data: data, mime_type: mime_type} ->
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "data:#{mime_type};base64,#{data}"}
          }
      end)

    if Enum.empty?(parts) do
      {nil, rest, :user}
    else
      msg = %{"role" => "user", "content" => parts}
      {msg, rest, :user}
    end
  end

  defp convert_single_message(%AssistantMessage{content: content}, rest, model, compat) do
    assistant_msg = build_assistant_base_message(compat)
    assistant_msg = add_text_blocks_to_message(assistant_msg, content, model)
    assistant_msg = add_thinking_blocks_to_message(assistant_msg, content, compat)
    assistant_msg = add_tool_calls_to_message(assistant_msg, content, model, compat)

    if assistant_message_valid?(assistant_msg) do
      {assistant_msg, rest, :assistant}
    else
      {nil, rest, :assistant}
    end
  end

  defp convert_single_message(%ToolResultMessage{} = msg, rest, model, compat) do
    {tool_results, remaining, image_blocks} =
      collect_tool_results([msg | rest], model, compat, [], [])

    converted = maybe_add_image_messages(tool_results, image_blocks, compat)
    last_role = if length(image_blocks) > 0, do: :user, else: :tool_result

    case converted do
      [] -> {nil, remaining, last_role}
      list -> {list, remaining, last_role}
    end
  end

  defp maybe_add_image_messages(tool_results, [], _compat), do: tool_results

  defp maybe_add_image_messages(tool_results, image_blocks, compat) do
    tool_results = maybe_add_synthetic_assistant_message(tool_results, compat)
    user_msg = build_image_user_message(image_blocks)
    tool_results ++ [user_msg]
  end

  defp maybe_add_synthetic_assistant_message(messages, %{requires_assistant_after_tool_result: true}) do
    messages ++ [%{"role" => "assistant", "content" => "I have processed the tool results."}]
  end

  defp maybe_add_synthetic_assistant_message(messages, _compat), do: messages

  defp build_image_user_message(image_blocks) do
    %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => "Attached image(s) from tool result:"}] ++ image_blocks
    }
  end

  # Helper functions for convert_single_message (AssistantMessage)
  defp build_assistant_base_message(compat) do
    %{
      "role" => "assistant",
      "content" => if(compat.requires_assistant_after_tool_result, do: "", else: nil)
    }
  end

  defp add_text_blocks_to_message(assistant_msg, content, model) do
    text_blocks =
      content
      |> Enum.filter(&match?(%TextContent{}, &1))
      |> Enum.filter(fn %TextContent{text: text} -> String.trim(text) != "" end)

    if length(text_blocks) == 0 do
      assistant_msg
    else
      add_text_content(assistant_msg, text_blocks, model.provider)
    end
  end

  defp add_text_content(assistant_msg, text_blocks, provider) when provider in [:github_copilot, "github-copilot"] do
    text = text_blocks |> Enum.map(& &1.text) |> Enum.join("") |> sanitize_surrogates()
    Map.put(assistant_msg, "content", text)
  end

  defp add_text_content(assistant_msg, text_blocks, _provider) do
    parts =
      Enum.map(text_blocks, fn %TextContent{text: text} ->
        %{"type" => "text", "text" => sanitize_surrogates(text)}
      end)

    Map.put(assistant_msg, "content", parts)
  end

  defp add_thinking_blocks_to_message(assistant_msg, content, compat) do
    thinking_blocks =
      content
      |> Enum.filter(&match?(%ThinkingContent{}, &1))
      |> Enum.filter(fn %ThinkingContent{thinking: t} -> String.trim(t) != "" end)

    if length(thinking_blocks) == 0 do
      assistant_msg
    else
      add_thinking_content(assistant_msg, thinking_blocks, compat)
    end
  end

  defp add_thinking_content(assistant_msg, thinking_blocks, %{requires_thinking_as_text: true}) do
    thinking_text = thinking_blocks |> Enum.map(& &1.thinking) |> Enum.join("\n\n")
    current_content = assistant_msg["content"]
    new_content = merge_thinking_with_content(current_content, thinking_text)
    Map.put(assistant_msg, "content", new_content)
  end

  defp add_thinking_content(assistant_msg, thinking_blocks, _compat) do
    first_thinking = List.first(thinking_blocks)

    if first_thinking.thinking_signature && first_thinking.thinking_signature != "" do
      thinking_text = thinking_blocks |> Enum.map(& &1.thinking) |> Enum.join("\n")
      Map.put(assistant_msg, first_thinking.thinking_signature, thinking_text)
    else
      assistant_msg
    end
  end

  defp merge_thinking_with_content(nil, thinking_text) do
    [%{"type" => "text", "text" => thinking_text}]
  end

  defp merge_thinking_with_content("", thinking_text) do
    [%{"type" => "text", "text" => thinking_text}]
  end

  defp merge_thinking_with_content(text, thinking_text) when is_binary(text) do
    [
      %{"type" => "text", "text" => thinking_text},
      %{"type" => "text", "text" => text}
    ]
  end

  defp merge_thinking_with_content(parts, thinking_text) when is_list(parts) do
    [%{"type" => "text", "text" => thinking_text} | parts]
  end

  defp add_tool_calls_to_message(assistant_msg, content, model, compat) do
    tool_calls = Enum.filter(content, &match?(%ToolCall{}, &1))

    if length(tool_calls) == 0 do
      assistant_msg
    else
      build_tool_call_message(assistant_msg, tool_calls, model, compat)
    end
  end

  defp build_tool_call_message(assistant_msg, tool_calls, model, compat) do
    converted_calls =
      Enum.map(tool_calls, fn tc ->
        %{
          "id" => normalize_tool_call_id(tc.id, model, compat),
          "type" => "function",
          "function" => %{
            "name" => tc.name,
            "arguments" => Jason.encode!(tc.arguments)
          }
        }
      end)

    reasoning_details = extract_reasoning_details(tool_calls)
    assistant_msg = Map.put(assistant_msg, "tool_calls", converted_calls)

    if length(reasoning_details) > 0 do
      Map.put(assistant_msg, "reasoning_details", reasoning_details)
    else
      assistant_msg
    end
  end

  defp extract_reasoning_details(tool_calls) do
    tool_calls
    |> Enum.filter(& &1.thought_signature)
    |> Enum.map(fn tc ->
      case Jason.decode(tc.thought_signature) do
        {:ok, detail} -> detail
        _ -> nil
      end
    end)
    |> Enum.filter(& &1)
  end

  defp assistant_message_valid?(assistant_msg) do
    has_content?(assistant_msg["content"]) or Map.has_key?(assistant_msg, "tool_calls")
  end

  defp has_content?(nil), do: false
  defp has_content?("") , do: false
  defp has_content?(text) when is_binary(text), do: String.length(text) > 0
  defp has_content?(parts) when is_list(parts), do: length(parts) > 0

  defp collect_tool_results([], _model, _compat, acc, images) do
    {Enum.reverse(acc), [], images}
  end

  defp collect_tool_results([%ToolResultMessage{} = msg | rest], model, compat, acc, images) do
    # Extract text content
    text_result =
      msg.content
      |> Enum.filter(&match?(%TextContent{}, &1))
      |> Enum.map(& &1.text)
      |> Enum.join("\n")

    has_images = Enum.any?(msg.content, &match?(%ImageContent{}, &1))

    # Build tool result message
    content =
      if String.length(text_result) > 0 do
        sanitize_surrogates(text_result)
      else
        "(see attached image)"
      end

    tool_msg = %{
      "role" => "tool",
      "content" => content,
      "tool_call_id" => normalize_tool_call_id(msg.tool_call_id, model, compat)
    }

    tool_msg =
      if compat.requires_tool_result_name && msg.tool_name do
        Map.put(tool_msg, "name", msg.tool_name)
      else
        tool_msg
      end

    # Collect images
    new_images =
      if has_images && :image in model.input do
        msg.content
        |> Enum.filter(&match?(%ImageContent{}, &1))
        |> Enum.map(fn %ImageContent{data: data, mime_type: mime_type} ->
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "data:#{mime_type};base64,#{data}"}
          }
        end)
      else
        []
      end

    collect_tool_results(rest, model, compat, [tool_msg | acc], images ++ new_images)
  end

  defp collect_tool_results(rest, _model, _compat, acc, images) do
    {Enum.reverse(acc), rest, images}
  end

  defp normalize_tool_call_id(id, model, compat) do
    cond do
      compat.requires_mistral_tool_ids ->
        normalize_mistral_tool_id(id)

      String.contains?(id, "|") ->
        # Handle pipe-separated IDs from OpenAI Responses API
        [call_id | _] = String.split(id, "|")
        call_id |> String.replace(~r/[^a-zA-Z0-9_-]/, "_") |> String.slice(0, 40)

      model.provider in [:openai, "openai"] && String.length(id) > 40 ->
        String.slice(id, 0, 40)

      model.provider in [:github_copilot, "github-copilot"] &&
          String.downcase(to_string(model.id)) |> String.contains?("claude") ->
        id |> String.replace(~r/[^a-zA-Z0-9_-]/, "_") |> String.slice(0, 64)

      true ->
        id
    end
  end

  defp normalize_mistral_tool_id(id) do
    # Mistral requires exactly 9 alphanumeric characters
    normalized = String.replace(id, ~r/[^a-zA-Z0-9]/, "")

    cond do
      String.length(normalized) < 9 ->
        padding = "ABCDEFGHI"
        pad_needed = 9 - String.length(normalized)
        normalized <> String.slice(padding, 0, pad_needed)

      String.length(normalized) > 9 ->
        String.slice(normalized, 0, 9)

      true ->
        normalized
    end
  end

  defp convert_tools(tools) do
    Enum.map(tools, fn %Tool{name: name, description: description, parameters: parameters} ->
      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => description,
          "parameters" => parameters,
          "strict" => false
        }
      }
    end)
  end

  # ============================================================================
  # Compatibility Detection
  # ============================================================================

  defp get_compat(model) do
    detected = detect_compat(model)

    # Merge with explicit compat settings
    model_compat = model.compat || %{}

    %{
      supports_store: Map.get(model_compat, :supports_store, detected.supports_store),
      supports_developer_role:
        Map.get(model_compat, :supports_developer_role, detected.supports_developer_role),
      supports_reasoning_effort:
        Map.get(model_compat, :supports_reasoning_effort, detected.supports_reasoning_effort),
      supports_usage_in_streaming:
        Map.get(model_compat, :supports_usage_in_streaming, detected.supports_usage_in_streaming),
      max_tokens_field: Map.get(model_compat, :max_tokens_field, detected.max_tokens_field),
      requires_tool_result_name:
        Map.get(model_compat, :requires_tool_result_name, detected.requires_tool_result_name),
      requires_assistant_after_tool_result:
        Map.get(
          model_compat,
          :requires_assistant_after_tool_result,
          detected.requires_assistant_after_tool_result
        ),
      requires_thinking_as_text:
        Map.get(model_compat, :requires_thinking_as_text, detected.requires_thinking_as_text),
      requires_mistral_tool_ids:
        Map.get(model_compat, :requires_mistral_tool_ids, detected.requires_mistral_tool_ids),
      thinking_format: Map.get(model_compat, :thinking_format, detected.thinking_format),
      open_router_routing:
        Map.get(model_compat, :open_router_routing, detected.open_router_routing)
    }
  end

  defp detect_compat(model) do
    provider = model.provider
    base_url = model.base_url || ""

    is_zai = provider in [:zai, "zai"] || String.contains?(base_url, "api.z.ai")

    is_non_standard =
      provider in [:cerebras, "cerebras"] || String.contains?(base_url, "cerebras.ai") ||
        provider in [:xai, "xai"] || String.contains?(base_url, "api.x.ai") ||
        provider in [:mistral, "mistral"] || String.contains?(base_url, "mistral.ai") ||
        String.contains?(base_url, "chutes.ai") ||
        String.contains?(base_url, "deepseek.com") ||
        provider in [:opencode, "opencode"] || String.contains?(base_url, "opencode.ai") ||
        is_zai

    use_max_tokens =
      provider in [:mistral, "mistral"] || String.contains?(base_url, "mistral.ai") ||
        String.contains?(base_url, "chutes.ai")

    is_grok = provider in [:xai, "xai"] || String.contains?(base_url, "api.x.ai")
    is_mistral = provider in [:mistral, "mistral"] || String.contains?(base_url, "mistral.ai")

    %{
      supports_store: !is_non_standard,
      supports_developer_role: !is_non_standard,
      supports_reasoning_effort: !is_grok && !is_zai,
      supports_usage_in_streaming: true,
      max_tokens_field: if(use_max_tokens, do: "max_tokens", else: "max_completion_tokens"),
      requires_tool_result_name: is_mistral,
      requires_assistant_after_tool_result: false,
      requires_thinking_as_text: is_mistral,
      requires_mistral_tool_ids: is_mistral,
      thinking_format: if(is_zai, do: "zai", else: "openai"),
      open_router_routing: %{}
    }
  end

  # ============================================================================
  # HTTP Streaming
  # ============================================================================

  defp stream_request(stream, output, url, headers, params) do
    # Use Req for HTTP with SSE streaming
    request =
      Req.new(
        method: :post,
        url: url,
        headers: headers,
        json: params,
        receive_timeout: 120_000,
        into: :self
      )

    case Req.request(request) do
      {:ok, response} ->
        if response.status in 200..299 do
          process_sse_stream(stream, output, response)
        else
          body = response.body
          error_msg = extract_error_message(body)
          %{output | stop_reason: :error, error_message: "HTTP #{response.status}: #{error_msg}"}
        end

      {:error, %Req.TransportError{reason: reason}} ->
        %{output | stop_reason: :error, error_message: "Transport error: #{inspect(reason)}"}

      {:error, error} ->
        %{output | stop_reason: :error, error_message: "Request error: #{inspect(error)}"}
    end
  end

  defp process_sse_stream(stream, output, response) do
    {pid, ref} = extract_stream_ref(response)

    state = %{
      output: output,
      current_block: nil,
      buffer: "",
      tool_call_blocks: %{}
    }

    state = receive_sse_chunks(stream, state, pid, ref)

    state
    |> finalize_current_block(stream)
    |> finalize_tool_call_blocks(stream)
    |> Map.get(:output)
  end

  defp extract_stream_ref(%Req.Response{} = response) do
    pid = Map.get(response, :pid)
    ref = Map.get(response, :ref)

    cond do
      is_pid(pid) and not is_nil(ref) ->
        {pid, ref}

      match?(%Req.Response.Async{}, response.body) ->
        body = response.body
        body_pid = Map.get(body, :pid)
        body_ref = Map.get(body, :ref)

        if is_pid(body_pid) and not is_nil(body_ref) do
          {body_pid, body_ref}
        else
          raise "Stream response missing pid/ref: #{inspect(response)}"
        end

      true ->
        raise "Stream response missing pid/ref: #{inspect(response)}"
    end
  end

  defp receive_sse_chunks(stream, state, pid, ref) do
    receive do
      {^ref, {:data, chunk}} ->
        state = process_chunk(stream, state, chunk)
        receive_sse_chunks(stream, state, pid, ref)

      {^ref, :done} ->
        state

      {:DOWN, ^ref, :process, ^pid, reason} ->
        if reason != :normal do
          %{
            state
            | output: %{
                state.output
                | stop_reason: :error,
                  error_message: "Stream ended unexpectedly: #{inspect(reason)}"
              }
          }
        else
          state
        end
    after
      120_000 ->
        %{
          state
          | output: %{state.output | stop_reason: :error, error_message: "Stream timeout"}
        }
    end
  end

  defp process_chunk(stream, state, chunk) do
    # Combine with buffer and split on newlines
    data = state.buffer <> chunk
    lines = String.split(data, "\n")

    # Last element might be incomplete
    {complete_lines, incomplete} =
      if String.ends_with?(data, "\n") do
        {lines, [""]}
      else
        Enum.split(lines, -1)
      end

    state = %{state | buffer: List.first(incomplete) || ""}

    # Process complete lines
    Enum.reduce(complete_lines, state, fn line, acc ->
      process_sse_line(stream, acc, line)
    end)
  end

  defp process_sse_line(_stream, state, ""), do: state
  defp process_sse_line(_stream, state, ":" <> _comment), do: state

  defp process_sse_line(stream, state, "data: [DONE]") do
    state
    |> finalize_current_block(stream)
    |> finalize_tool_call_blocks(stream)
  end

  defp process_sse_line(stream, state, "data: " <> json_data) do
    case Jason.decode(json_data) do
      {:ok, data} ->
        process_event_data(stream, state, data)

      {:error, _} ->
        Logger.warning("Failed to parse SSE JSON: #{json_data}")
        state
    end
  end

  defp process_sse_line(_stream, state, _line), do: state

  defp process_event_data(stream, state, data) do
    state = process_usage(state, data)
    state = process_choice(stream, state, data)
    state
  end

  defp process_usage(state, %{"usage" => usage}) when is_map(usage) do
    cached_tokens = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    reasoning_tokens = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0
    prompt_tokens = usage["prompt_tokens"] || 0
    completion_tokens = usage["completion_tokens"] || 0

    # OpenAI includes cached tokens in prompt_tokens, so subtract (clamp to zero)
    input = max(prompt_tokens - cached_tokens, 0)
    output = completion_tokens + reasoning_tokens

    new_usage = %Usage{
      input: input,
      output: output,
      cache_read: cached_tokens,
      cache_write: 0,
      total_tokens: input + output + cached_tokens,
      cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    }

    %{state | output: %{state.output | usage: new_usage}}
  end

  defp process_usage(state, _data), do: state

  defp process_choice(stream, state, %{"choices" => [choice | _]}) do
    state =
      if choice["finish_reason"] do
        stop_reason = map_stop_reason(choice["finish_reason"])
        %{state | output: %{state.output | stop_reason: stop_reason}}
      else
        state
      end

    delta = choice["delta"] || %{}

    state = process_delta_content(stream, state, delta)
    state = process_delta_reasoning(stream, state, delta)
    state = process_delta_tool_calls(stream, state, delta)
    state = process_reasoning_details(state, delta)

    state
  end

  defp process_choice(_stream, state, _data), do: state

  defp process_delta_content(stream, state, delta) do
    content = delta["content"]

    if content && content != "" do
      {state, block_index} = ensure_text_block(stream, state)
      current_block = state.current_block

      # Update block
      new_block = %{current_block | text: current_block.text <> content}
      state = %{state | current_block: new_block}

      # Update output content
      output = state.output
      new_content = List.replace_at(output.content, block_index, new_block)
      state = %{state | output: %{output | content: new_content}}

      # Push delta event
      EventStream.push_async(stream, {:text_delta, block_index, content, state.output})

      state
    else
      state
    end
  end

  defp process_delta_reasoning(stream, state, delta) do
    # Check multiple possible reasoning fields
    reasoning_fields = ["reasoning_content", "reasoning", "reasoning_text"]

    reasoning_text =
      Enum.find_value(reasoning_fields, fn field ->
        value = delta[field]
        if value && value != "", do: {field, value}, else: nil
      end)

    case reasoning_text do
      {field, text} ->
        {state, block_index} = ensure_thinking_block(stream, state, field)
        current_block = state.current_block

        # Update block
        new_block = %{current_block | thinking: current_block.thinking <> text}
        state = %{state | current_block: new_block}

        # Update output content
        output = state.output
        new_content = List.replace_at(output.content, block_index, new_block)
        state = %{state | output: %{output | content: new_content}}

        # Push delta event
        EventStream.push_async(stream, {:thinking_delta, block_index, text, state.output})

        state

      nil ->
        state
    end
  end

  defp process_delta_tool_calls(stream, state, delta) do
    tool_calls = delta["tool_calls"] || []

    Enum.reduce(tool_calls, state, fn tool_call, acc ->
      process_single_tool_call(stream, acc, tool_call)
    end)
  end

  defp process_single_tool_call(stream, state, tool_call) do
    index =
      case tool_call["index"] do
        i when is_integer(i) ->
          i

        i when is_binary(i) ->
          case Integer.parse(i) do
            {parsed, _} -> parsed
            _ -> 0
          end

        _ ->
          0
      end

    tool_id = tool_call["id"]
    function = tool_call["function"] || %{}
    func_name = function["name"]
    func_args = function["arguments"] || ""

    {state, info} = ensure_tool_call_block(stream, state, index, tool_id, func_name)

    block = info.block

    block =
      if tool_id && tool_id != "" do
        %{block | id: tool_id}
      else
        block
      end

    block =
      if func_name && func_name != "" do
        %{block | name: func_name}
      else
        block
      end

    new_partial_args = info.partial_args <> func_args
    block = %{block | arguments: parse_partial_json(new_partial_args)}

    output = state.output
    new_content = List.replace_at(output.content, info.block_index, block)
    output = %{output | content: new_content}

    new_info = %{info | block: block, partial_args: new_partial_args}
    tool_call_blocks = Map.put(state.tool_call_blocks, index, new_info)

    state = %{state | output: output, tool_call_blocks: tool_call_blocks}

    EventStream.push_async(stream, {:tool_call_delta, info.block_index, func_args, state.output})

    state
  end

  defp process_reasoning_details(state, delta) do
    reasoning_details = delta["reasoning_details"]

    if is_list(reasoning_details) do
      Enum.reduce(reasoning_details, state, fn detail, acc ->
        if detail["type"] == "reasoning.encrypted" && detail["id"] && detail["data"] do
          # Find matching tool call by ID and add thought signature
          detail_id = detail["id"]
          output = acc.output

          signature = Jason.encode!(detail)

          new_content =
            Enum.map(output.content, fn
              %ToolCall{id: ^detail_id} = tc ->
                %{tc | thought_signature: signature}

              other ->
                other
            end)

          updated_tool_calls =
            Enum.reduce(acc.tool_call_blocks, %{}, fn {index, info}, tool_acc ->
              if info.block.id == detail_id do
                Map.put(tool_acc, index, %{
                  info
                  | block: %{info.block | thought_signature: signature}
                })
              else
                Map.put(tool_acc, index, info)
              end
            end)

          %{acc | output: %{output | content: new_content}, tool_call_blocks: updated_tool_calls}
        else
          acc
        end
      end)
    else
      state
    end
  end

  defp ensure_text_block(stream, state) do
    case state.current_block do
      %TextContent{} ->
        {state, length(state.output.content) - 1}

      _ ->
        # Finish current block
        state = finalize_current_block(state, stream)

        # Create new text block
        new_block = %TextContent{type: :text, text: ""}
        output = state.output
        new_content = output.content ++ [new_block]
        block_index = length(new_content) - 1
        state = %{state | current_block: new_block, output: %{output | content: new_content}}

        # Push start event
        EventStream.push_async(stream, {:text_start, block_index, state.output})

        {state, block_index}
    end
  end

  defp ensure_thinking_block(stream, state, signature) do
    case state.current_block do
      %ThinkingContent{} ->
        {state, length(state.output.content) - 1}

      _ ->
        # Finish current block
        state = finalize_current_block(state, stream)

        # Create new thinking block
        new_block = %ThinkingContent{type: :thinking, thinking: "", thinking_signature: signature}
        output = state.output
        new_content = output.content ++ [new_block]
        block_index = length(new_content) - 1
        state = %{state | current_block: new_block, output: %{output | content: new_content}}

        # Push start event
        EventStream.push_async(stream, {:thinking_start, block_index, state.output})

        {state, block_index}
    end
  end

  defp finalize_current_block(state, stream) do
    case state.current_block do
      %TextContent{text: text} ->
        block_index = length(state.output.content) - 1
        EventStream.push_async(stream, {:text_end, block_index, text, state.output})
        %{state | current_block: nil}

      %ThinkingContent{thinking: thinking} ->
        block_index = length(state.output.content) - 1
        EventStream.push_async(stream, {:thinking_end, block_index, thinking, state.output})
        %{state | current_block: nil}

      nil ->
        state
    end
  end

  defp ensure_tool_call_block(stream, state, index, tool_id, func_name) do
    case Map.get(state.tool_call_blocks, index) do
      nil ->
        state = finalize_current_block(state, stream)

        new_block = %ToolCall{
          type: :tool_call,
          id: tool_id || "",
          name: func_name || "",
          arguments: %{},
          thought_signature: nil
        }

        output = state.output
        new_content = output.content ++ [new_block]
        block_index = length(new_content) - 1
        output = %{output | content: new_content}

        EventStream.push_async(stream, {:tool_call_start, block_index, output})

        info = %{block_index: block_index, block: new_block, partial_args: ""}
        tool_call_blocks = Map.put(state.tool_call_blocks, index, info)

        {%{state | output: output, tool_call_blocks: tool_call_blocks}, info}

      info ->
        {state, info}
    end
  end

  defp finalize_tool_call_blocks(state, _stream) when map_size(state.tool_call_blocks) == 0 do
    state
  end

  defp finalize_tool_call_blocks(state, stream) do
    sorted =
      state.tool_call_blocks
      |> Enum.sort_by(fn {_index, info} -> info.block_index end)

    final_state =
      Enum.reduce(sorted, state, fn {_index, info}, acc_state ->
        final_args =
          case Jason.decode(info.partial_args) do
            {:ok, args} when is_map(args) -> args
            _ -> %{}
          end

        final_block = %{info.block | arguments: final_args}
        output = acc_state.output
        new_content = List.replace_at(output.content, info.block_index, final_block)
        output = %{output | content: new_content}

        EventStream.push_async(stream, {:tool_call_end, info.block_index, final_block, output})

        %{acc_state | output: output}
      end)

    %{final_state | tool_call_blocks: %{}}
  end

  defp map_stop_reason(reason) do
    case reason do
      "stop" -> :stop
      "length" -> :length
      "function_call" -> :tool_use
      "tool_calls" -> :tool_use
      "content_filter" -> :error
      _ -> :stop
    end
  end

  # ============================================================================
  # Utilities
  # ============================================================================

  defp sanitize_surrogates(text) when is_binary(text) do
    # In Elixir/Erlang, strings are UTF-8 by default and unpaired surrogates
    # are generally not valid. Ensure text is valid UTF-8.
    case :unicode.characters_to_binary(text, :utf8, :utf8) do
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
      result when is_binary(result) -> result
    end
  end

  defp sanitize_surrogates(text), do: text

  defp parse_partial_json(""), do: %{}

  defp parse_partial_json(json) do
    # Try to parse as complete JSON first
    case Jason.decode(json) do
      {:ok, result} when is_map(result) ->
        result

      _ ->
        # Attempt recovery for partial JSON by closing brackets
        attempt_partial_json_recovery(json)
    end
  end

  defp attempt_partial_json_recovery(json) do
    # Simple recovery: try adding closing brackets
    json = String.trim(json)

    attempts = [
      json <> "}",
      json <> "\"}"
    ]

    Enum.find_value(attempts, %{}, fn attempt ->
      case Jason.decode(attempt) do
        {:ok, result} when is_map(result) -> result
        _ -> nil
      end
    end)
  end

  defp extract_error_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      {:ok, %{"error" => error}} when is_binary(error) -> error
      _ -> body
    end
  end

  defp extract_error_message(body) when is_map(body) do
    case body do
      %{"error" => %{"message" => message}} -> message
      %{"error" => error} when is_binary(error) -> error
      _ -> inspect(body)
    end
  end

  defp extract_error_message(body), do: inspect(body)
end
