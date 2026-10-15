defmodule LemonAi.Providers.GoogleShared do
  @moduledoc """
  Shared utilities for Google Generative AI, Vertex AI, and Gemini CLI providers.

  This module handles:
  - Content conversion to Gemini format
  - Tool declaration formatting
  - Stop reason mapping
  - Thought signature validation
  - Unicode sanitization
  """

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    ImageContent,
    Model,
    TextContent,
    ThinkingContent,
    Tool,
    ToolCall,
    ToolResultMessage,
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
  # SSE Helpers
  # ============================================================================

  @doc false
  @spec normalize_sse_message(term()) :: {:data, binary()} | :done | :down | :ignore
  def normalize_sse_message(message) do
    case message do
      {:data, data} when is_binary(data) ->
        {:data, data}

      {_, {:data, data}} when is_binary(data) ->
        {:data, data}

      {:done, _} ->
        :done

      {_, :done} ->
        :done

      {_, {:done, _}} ->
        :done

      {:DOWN, _ref, :process, _pid, _reason} ->
        :down

      _ ->
        :ignore
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
  # Retry Helpers
  # ============================================================================

  @doc """
  Extract retry delay from error response (in milliseconds).
  Parses patterns like:
  - "Your quota will reset after 39s"
  - "Your quota will reset after 18h31m10s"
  - "Please retry in Xs" or "Please retry in Xms"
  - "retryDelay": "34.074824224s" (JSON field)
  """
  @spec extract_retry_delay(String.t(), map()) :: non_neg_integer() | nil
  def extract_retry_delay(error_text, headers \\ %{}) do
    LemonAi.Providers.RetryHelper.extract_retry_delay_ms(error_text, headers)
  end

  @doc """
  Check if an error is retryable (rate limit, server error, network error, etc.)
  """
  @spec retryable_error?(non_neg_integer(), String.t()) :: boolean()
  def retryable_error?(status, error_text) do
    LemonAi.Providers.RetryHelper.retryable_http_error?(status, error_text)
  end

  @doc """
  Extract a clean, user-friendly error message from Google API error response.
  """
  @spec extract_error_message(String.t()) :: String.t()
  def extract_error_message(error_text) do
    case Jason.decode(error_text) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      _ -> error_text
    end
  end

  @max_http_error_body_bytes 16_384

  @doc """
  Collect a bounded HTTP error body for classification, not public display.

  Async bodies are limited to 16 KiB and a total elapsed deadline (one second by
  default). The transport is canceled and its queued messages cleaned up before
  returning, including on completion, timeout or transport failure. Unknown body
  terms are never inspected.
  """
  @spec normalize_http_error_body(term()) :: String.t()
  def normalize_http_error_body(body), do: normalize_http_error_body(body, 1_000)

  @spec normalize_http_error_body(term(), non_neg_integer()) :: String.t()
  def normalize_http_error_body(body, _timeout_ms) when is_binary(body) do
    body
    |> binary_part(0, min(byte_size(body), @max_http_error_body_bytes))
    |> :binary.copy()
    |> error_body_utf8()
  end

  def normalize_http_error_body(%Req.Response.Async{} = async, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    response = %Req.Response{body: async}
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect_async_error_body(response, [], 0, deadline)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> error_body_utf8()
    after
      Req.cancel_async_response(response)
    end
  end

  def normalize_http_error_body(%_{} = _body, _timeout_ms), do: ""

  def normalize_http_error_body(body, timeout_ms) when is_map(body) do
    case Jason.encode(body) do
      {:ok, text} -> normalize_http_error_body(text, timeout_ms)
      {:error, _} -> ""
    end
  end

  def normalize_http_error_body(_body, _timeout_ms), do: ""

  # Discard incomplete/invalid suffixes rather than growing the byte-limited
  # body with replacement characters, or passing invalid UTF-8 to classifiers.
  defp error_body_utf8(text) do
    case :unicode.characters_to_binary(text, :utf8, :utf8) do
      {:error, valid, _} -> valid
      {:incomplete, valid, _} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  defp collect_async_error_body(_response, chunks, size, _deadline)
       when size >= @max_http_error_body_bytes,
       do: chunks

  defp collect_async_error_body(
         %Req.Response{body: %Req.Response.Async{ref: ref, pid: pid}} = response,
         chunks,
         size,
         deadline
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      chunks
    else
      receive do
        {^ref, _} = message ->
          case Req.parse_message(response, message) do
            {:ok, [data: chunk]} when is_binary(chunk) ->
              length = min(byte_size(chunk), @max_http_error_body_bytes - size)
              chunk = binary_part(chunk, 0, length)
              collect_async_error_body(response, [chunk | chunks], size + length, deadline)

            {:ok, [:done]} ->
              chunks

            {:error, _} ->
              chunks

            _ ->
              collect_async_error_body(response, chunks, size, deadline)
          end

        {:DOWN, ^ref, :process, ^pid, _reason} ->
          chunks
      after
        remaining -> chunks
      end
    end
  end

  @doc """
  Classify a collected HTTP error without exposing untrusted upstream text.

  Keeps typed status, category, retryability and retry metadata. Public errors
  contain only bounded actionable summaries, never response bodies, credentials
  or transport structs. Pass a normalized body from `normalize_http_error_body/1`.
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
          "Account quota exhausted; check billing or credentials."

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
