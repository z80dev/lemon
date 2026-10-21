defmodule CodingAgent.Session.MessageSerialization do
  @moduledoc """
  Pure-function module for serializing and deserializing session messages.

  Handles conversion between LemonAi.Types structs (UserMessage, AssistantMessage,
  ToolResultMessage, etc.) and their JSON-serializable map representations for
  persistence in the SessionManager.
  """

  # ============================================================================
  # Serialization
  # ============================================================================

  @spec serialize_message(map()) :: map()
  def serialize_message(%LemonAi.Types.UserMessage{} = msg) do
    %{
      "role" => "user",
      "content" => serialize_content(msg.content),
      "timestamp" => msg.timestamp
    }
  end

  def serialize_message(%LemonAi.Types.AssistantMessage{} = msg) do
    %{
      "role" => "assistant",
      "content" => Enum.map(msg.content, &serialize_content_block/1),
      "provider" => msg.provider,
      "model" => msg.model,
      "api" => msg.api,
      "usage" => serialize_usage(msg.usage),
      "stop_reason" => msg.stop_reason && Atom.to_string(msg.stop_reason),
      "error_message" => msg.error_message,
      "error_details" => msg.error_details,
      "retry_after_ms" => msg.retry_after_ms,
      "timestamp" => msg.timestamp
    }
  end

  def serialize_message(%LemonAi.Types.ToolResultMessage{} = msg) do
    %{
      "role" => "tool_result",
      "tool_call_id" => msg.tool_call_id,
      "tool_name" => msg.tool_name,
      "content" => Enum.map(msg.content, &serialize_content_block/1),
      "details" => msg.details,
      "trust" => serialize_trust(msg.trust),
      "is_error" => msg.is_error,
      "timestamp" => msg.timestamp
    }
  end

  def serialize_message(%CodingAgent.Messages.CustomMessage{} = msg) do
    %{
      "role" => "custom",
      "custom_type" => msg.custom_type,
      "content" => serialize_content(msg.content),
      "display" => msg.display,
      "details" => normalize_map_keys(msg.details),
      "timestamp" => msg.timestamp
    }
  end

  def serialize_message(msg) when is_map(msg) do
    msg
  end

  @spec serialize_content(String.t() | list()) :: String.t() | list()
  def serialize_content(nil), do: ""
  def serialize_content(content) when is_binary(content), do: content

  def serialize_content(content) when is_list(content) do
    Enum.map(content, &serialize_content_block/1)
  end

  # Provider signatures travel with their blocks so a resumed session replays
  # them: Anthropic thinking signatures, OpenAI Responses reasoning items and
  # message ids (stored as signature JSON / ids), and Gemini thought
  # signatures. Without them, a restored transcript degrades signed thinking to
  # plain text and drops encrypted reasoning items.
  @spec serialize_content_block(map()) :: map()
  def serialize_content_block(%LemonAi.Types.TextContent{text: text, text_signature: signature}) do
    put_signature(%{"type" => "text", "text" => text}, "text_signature", signature)
  end

  def serialize_content_block(%LemonAi.Types.ImageContent{data: data, mime_type: mime_type}) do
    %{"type" => "image", "data" => data, "mime_type" => mime_type}
  end

  def serialize_content_block(%LemonAi.Types.ThinkingContent{
        thinking: thinking,
        thinking_signature: signature
      }) do
    put_signature(
      %{"type" => "thinking", "thinking" => thinking},
      "thinking_signature",
      signature
    )
  end

  def serialize_content_block(%LemonAi.Types.ToolCall{
        id: id,
        name: name,
        arguments: arguments,
        thought_signature: signature
      }) do
    put_signature(
      %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments},
      "thought_signature",
      signature
    )
  end

  def serialize_content_block(%CodingAgent.Messages.TextContent{text: text}) do
    %{"type" => "text", "text" => text}
  end

  def serialize_content_block(%CodingAgent.Messages.ImageContent{
        data: data,
        mime_type: mime_type
      }) do
    %{"type" => "image", "data" => data, "mime_type" => mime_type}
  end

  def serialize_content_block(%CodingAgent.Messages.ThinkingContent{thinking: thinking}) do
    %{"type" => "thinking", "thinking" => thinking}
  end

  def serialize_content_block(%CodingAgent.Messages.ToolCall{
        id: id,
        name: name,
        arguments: arguments
      }) do
    %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}
  end

  def serialize_content_block(%{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  def serialize_content_block(block) when is_map(block) do
    block
  end

  @spec serialize_usage(map() | nil) :: map() | nil
  def serialize_usage(nil), do: nil

  def serialize_usage(%LemonAi.Types.Usage{} = usage) do
    %{
      "input" => usage.input,
      "output" => usage.output,
      "cache_read" => usage.cache_read,
      "cache_write" => usage.cache_write,
      "cache_write_long" => usage.cache_write_long,
      "total_tokens" => usage.total_tokens,
      "cost" => serialize_cost(usage.cost)
    }
  end

  def serialize_usage(usage) when is_map(usage), do: usage

  defp serialize_cost(nil), do: nil

  defp serialize_cost(cost) do
    Map.new([:input, :output, :cache_read, :cache_write, :total], fn key ->
      {Atom.to_string(key), usage_value(cost, key, nil)}
    end)
  end

  # ============================================================================
  # Trust Serialization
  # ============================================================================

  @spec serialize_trust(atom() | String.t()) :: String.t()
  def serialize_trust(:untrusted), do: "untrusted"
  def serialize_trust(:trusted), do: "trusted"
  def serialize_trust("untrusted"), do: "untrusted"
  def serialize_trust("trusted"), do: "trusted"
  def serialize_trust(_), do: "trusted"

  # ============================================================================
  # Deserialization
  # ============================================================================

  @spec deserialize_message(map()) :: map() | nil
  def deserialize_message(%{"role" => "user"} = msg) do
    %LemonAi.Types.UserMessage{
      role: :user,
      content: deserialize_content(msg["content"]),
      timestamp: msg["timestamp"] || 0
    }
  end

  def deserialize_message(%{"role" => "assistant"} = msg) do
    %LemonAi.Types.AssistantMessage{
      role: :assistant,
      content: deserialize_content_blocks(msg["content"]),
      provider: msg["provider"] || "",
      model: msg["model"] || "",
      api: msg["api"] || "",
      usage: deserialize_usage(msg["usage"]),
      stop_reason: deserialize_stop_reason(msg["stop_reason"]),
      error_message: msg["error_message"],
      error_details:
        if(is_map(msg["error_details"]), do: LemonAi.Error.to_error_details(msg["error_details"])),
      retry_after_ms: msg["retry_after_ms"],
      timestamp: msg["timestamp"] || 0
    }
  end

  def deserialize_message(%{"role" => "tool_result"} = msg) do
    %LemonAi.Types.ToolResultMessage{
      role: :tool_result,
      tool_call_id: msg["tool_call_id"] || msg["tool_use_id"] || "",
      tool_name: msg["tool_name"] || "",
      content: deserialize_content_blocks(msg["content"]),
      details: msg["details"],
      trust: deserialize_trust(msg["trust"]),
      is_error: msg["is_error"] || false,
      timestamp: msg["timestamp"] || 0
    }
  end

  def deserialize_message(%{"role" => "custom"} = msg) do
    %CodingAgent.Messages.CustomMessage{
      role: :custom,
      custom_type: msg["custom_type"] || "",
      content: deserialize_content(msg["content"]),
      display: if(is_nil(msg["display"]), do: true, else: msg["display"]),
      details: msg["details"],
      timestamp: msg["timestamp"] || 0
    }
  end

  def deserialize_message(%{"role" => "branch_summary"} = msg) do
    %CodingAgent.Messages.BranchSummaryMessage{
      summary: msg["summary"],
      timestamp: msg["timestamp"] || 0
    }
  end

  def deserialize_message(_msg), do: nil

  @spec deserialize_content(String.t() | list() | nil) :: String.t() | list()
  def deserialize_content(nil), do: ""
  def deserialize_content(content) when is_binary(content), do: content
  def deserialize_content(content) when is_list(content), do: deserialize_content_blocks(content)

  @spec deserialize_content_blocks(list() | nil) :: list()
  def deserialize_content_blocks(nil), do: []

  def deserialize_content_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, &deserialize_content_block/1)
  end

  @spec deserialize_content_block(map()) :: map()
  def deserialize_content_block(%{"type" => "text", "text" => text} = block) do
    %LemonAi.Types.TextContent{type: :text, text: text, text_signature: block["text_signature"]}
  end

  def deserialize_content_block(%{"type" => "image", "data" => data, "mime_type" => mime_type}) do
    %LemonAi.Types.ImageContent{type: :image, data: data, mime_type: mime_type}
  end

  def deserialize_content_block(%{"type" => "thinking", "thinking" => thinking} = block) do
    %LemonAi.Types.ThinkingContent{
      type: :thinking,
      thinking: thinking,
      thinking_signature: block["thinking_signature"]
    }
  end

  def deserialize_content_block(
        %{
          "type" => "tool_call",
          "id" => id,
          "name" => name,
          "arguments" => arguments
        } = block
      ) do
    %LemonAi.Types.ToolCall{
      type: :tool_call,
      id: id,
      name: name,
      arguments: arguments,
      thought_signature: block["thought_signature"]
    }
  end

  def deserialize_content_block(block), do: block

  @spec deserialize_usage(map() | nil) :: LemonAi.Types.Usage.t() | nil
  def deserialize_usage(nil), do: nil

  def deserialize_usage(usage) when is_map(usage) do
    %LemonAi.Types.Usage{
      input: usage_value(usage, :input, nil),
      output: usage_value(usage, :output, nil),
      cache_read: usage_value(usage, :cache_read, nil),
      cache_write: usage_value(usage, :cache_write, nil),
      cache_write_long: usage_value(usage, :cache_write_long, nil),
      total_tokens: usage_value(usage, :total_tokens, nil),
      cost: deserialize_cost(usage_value(usage, :cost, nil))
    }
  end

  defp deserialize_cost(nil), do: nil

  defp deserialize_cost(cost) do
    %LemonAi.Types.Cost{
      input: usage_value(cost, :input, nil),
      output: usage_value(cost, :output, nil),
      cache_read: usage_value(cost, :cache_read, nil),
      cache_write: usage_value(cost, :cache_write, nil),
      total: usage_value(cost, :total, nil)
    }
  end

  defp usage_value(map, key, default),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default

  @spec deserialize_stop_reason(String.t() | nil) :: atom() | nil
  def deserialize_stop_reason(nil), do: nil
  def deserialize_stop_reason("stop"), do: :stop
  def deserialize_stop_reason("length"), do: :length
  def deserialize_stop_reason("tool_use"), do: :tool_use
  def deserialize_stop_reason("error"), do: :error
  def deserialize_stop_reason("aborted"), do: :aborted
  def deserialize_stop_reason("redirected"), do: :redirected
  def deserialize_stop_reason(_), do: nil

  @spec deserialize_trust(atom() | String.t()) :: atom()
  def deserialize_trust(:untrusted), do: :untrusted
  def deserialize_trust("untrusted"), do: :untrusted
  def deserialize_trust(:trusted), do: :trusted
  def deserialize_trust("trusted"), do: :trusted
  def deserialize_trust(_), do: :trusted

  # Unsigned blocks keep their historical shape: the key is written only when
  # there is a signature to replay.
  defp put_signature(map, key, signature) when is_binary(signature) and signature != "",
    do: Map.put(map, key, signature)

  defp put_signature(map, _key, _signature), do: map

  defp normalize_map_keys(nil), do: nil

  defp normalize_map_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize_map_keys(value)} end)
  end

  defp normalize_map_keys(list) when is_list(list), do: Enum.map(list, &normalize_map_keys/1)
  defp normalize_map_keys(other), do: other

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
