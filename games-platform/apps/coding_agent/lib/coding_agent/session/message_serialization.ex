defmodule CodingAgent.Session.MessageSerialization do
  @moduledoc """
  Pure-function module for serializing and deserializing session messages.

  Handles conversion between Ai.Types structs (UserMessage, AssistantMessage,
  ToolResultMessage, etc.) and their JSON-serializable map representations for
  persistence in the SessionManager.
  """

  # ============================================================================
  # Serialization
  # ============================================================================

  @spec serialize_message(map()) :: map()
  def serialize_message(%Ai.Types.UserMessage{} = msg) do
    %{
      "role" => "user",
      "content" => serialize_content(msg.content),
      "timestamp" => msg.timestamp
    }
  end

  def serialize_message(%Ai.Types.AssistantMessage{} = msg) do
    %{
      "role" => "assistant",
      "content" => Enum.map(msg.content, &serialize_content_block/1),
      "provider" => msg.provider,
      "model" => msg.model,
      "api" => msg.api,
      "usage" => serialize_usage(msg.usage),
      "stop_reason" => msg.stop_reason && Atom.to_string(msg.stop_reason),
      "timestamp" => msg.timestamp
    }
  end

  def serialize_message(%Ai.Types.ToolResultMessage{} = msg) do
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

  def serialize_message(msg) when is_map(msg) do
    msg
  end

  @spec serialize_content(String.t() | list()) :: String.t() | list()
  def serialize_content(content) when is_binary(content), do: content

  def serialize_content(content) when is_list(content) do
    Enum.map(content, &serialize_content_block/1)
  end

  @spec serialize_content_block(map()) :: map()
  def serialize_content_block(%Ai.Types.TextContent{text: text}) do
    %{"type" => "text", "text" => text}
  end

  def serialize_content_block(%Ai.Types.ImageContent{data: data, mime_type: mime_type}) do
    %{"type" => "image", "data" => data, "mime_type" => mime_type}
  end

  def serialize_content_block(%Ai.Types.ThinkingContent{thinking: thinking}) do
    %{"type" => "thinking", "thinking" => thinking}
  end

  def serialize_content_block(%Ai.Types.ToolCall{id: id, name: name, arguments: arguments}) do
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

  def serialize_usage(%Ai.Types.Usage{} = usage) do
    %{
      "input" => usage.input,
      "output" => usage.output,
      "cache_read" => usage.cache_read,
      "cache_write" => usage.cache_write,
      "total_tokens" => usage.total_tokens
    }
  end

  def serialize_usage(usage) when is_map(usage), do: usage

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
    %Ai.Types.UserMessage{
      role: :user,
      content: deserialize_content(msg["content"]),
      timestamp: msg["timestamp"] || 0
    }
  end

  def deserialize_message(%{"role" => "assistant"} = msg) do
    %Ai.Types.AssistantMessage{
      role: :assistant,
      content: deserialize_content_blocks(msg["content"]),
      provider: msg["provider"] || "",
      model: msg["model"] || "",
      api: msg["api"] || "",
      usage: deserialize_usage(msg["usage"]),
      stop_reason: deserialize_stop_reason(msg["stop_reason"]),
      timestamp: msg["timestamp"] || 0
    }
  end

  def deserialize_message(%{"role" => "tool_result"} = msg) do
    %Ai.Types.ToolResultMessage{
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
  def deserialize_content_block(%{"type" => "text", "text" => text}) do
    %Ai.Types.TextContent{type: :text, text: text}
  end

  def deserialize_content_block(%{"type" => "image", "data" => data, "mime_type" => mime_type}) do
    %Ai.Types.ImageContent{type: :image, data: data, mime_type: mime_type}
  end

  def deserialize_content_block(%{"type" => "thinking", "thinking" => thinking}) do
    %Ai.Types.ThinkingContent{type: :thinking, thinking: thinking}
  end

  def deserialize_content_block(%{
        "type" => "tool_call",
        "id" => id,
        "name" => name,
        "arguments" => arguments
      }) do
    %Ai.Types.ToolCall{type: :tool_call, id: id, name: name, arguments: arguments}
  end

  def deserialize_content_block(block), do: block

  @spec deserialize_usage(map() | nil) :: Ai.Types.Usage.t() | nil
  def deserialize_usage(nil), do: nil

  def deserialize_usage(usage) when is_map(usage) do
    %Ai.Types.Usage{
      input: usage["input"] || 0,
      output: usage["output"] || 0,
      cache_read: usage["cache_read"] || 0,
      cache_write: usage["cache_write"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      cost: %Ai.Types.Cost{}
    }
  end

  @spec deserialize_stop_reason(String.t() | nil) :: atom() | nil
  def deserialize_stop_reason(nil), do: nil
  def deserialize_stop_reason("stop"), do: :stop
  def deserialize_stop_reason("length"), do: :length
  def deserialize_stop_reason("tool_use"), do: :tool_use
  def deserialize_stop_reason("error"), do: :error
  def deserialize_stop_reason("aborted"), do: :aborted
  def deserialize_stop_reason(_), do: nil

  @spec deserialize_trust(atom() | String.t()) :: atom()
  def deserialize_trust(:untrusted), do: :untrusted
  def deserialize_trust("untrusted"), do: :untrusted
  def deserialize_trust(:trusted), do: :trusted
  def deserialize_trust("trusted"), do: :trusted
  def deserialize_trust(_), do: :trusted
end
