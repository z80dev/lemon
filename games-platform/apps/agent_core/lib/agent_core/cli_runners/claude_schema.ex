defmodule AgentCore.CliRunners.ClaudeSchema do
  @moduledoc """
  Claude CLI JSONL event schema definitions.

  This module defines all the event types emitted by `claude -p --output-format stream-json`.
  Events are decoded from newline-delimited JSON (JSONL) format.

  ## Event Categories

  ### System Messages
  - `StreamSystemMessage` - Session initialization with metadata

  ### Conversation Messages
  - `StreamAssistantMessage` - Claude's response with content blocks
  - `StreamUserMessage` - Tool results returned to Claude

  ### Result Messages
  - `StreamResultMessage` - Final session result with usage stats

  ### Content Block Types
  - `TextBlock` - Plain text response
  - `ThinkingBlock` - Extended thinking/reasoning
  - `ToolUseBlock` - Tool invocation request
  - `ToolResultBlock` - Tool execution result

  ## Decoding

      case ClaudeSchema.decode_event(json_line) do
        {:ok, %StreamSystemMessage{session_id: id}} -> ...
        {:ok, %StreamAssistantMessage{message: msg}} -> ...
        {:error, reason} -> ...
      end

  """

  # ============================================================================
  # Content Block Types
  # ============================================================================

  defmodule TextBlock do
    @moduledoc "Plain text content block"
    @type t :: %__MODULE__{
            type: :text,
            text: String.t()
          }
    defstruct type: :text, text: ""
  end

  defmodule ThinkingBlock do
    @moduledoc "Extended thinking/reasoning block"
    @type t :: %__MODULE__{
            type: :thinking,
            thinking: String.t(),
            signature: String.t() | nil
          }
    defstruct type: :thinking, thinking: "", signature: nil
  end

  defmodule ToolUseBlock do
    @moduledoc "Tool invocation request block"
    @type t :: %__MODULE__{
            type: :tool_use,
            id: String.t(),
            name: String.t(),
            input: map()
          }
    defstruct type: :tool_use, id: "", name: "", input: %{}
  end

  defmodule ToolResultBlock do
    @moduledoc "Tool execution result block"
    @type t :: %__MODULE__{
            type: :tool_result,
            tool_use_id: String.t(),
            content: String.t() | list() | nil,
            is_error: boolean()
          }
    defstruct type: :tool_result, tool_use_id: "", content: nil, is_error: false
  end

  @typedoc "Union of all content block types"
  @type content_block ::
          TextBlock.t()
          | ThinkingBlock.t()
          | ToolUseBlock.t()
          | ToolResultBlock.t()

  # ============================================================================
  # Message Types
  # ============================================================================

  defmodule AssistantMessageContent do
    @moduledoc "Content of an assistant message"
    @type t :: %__MODULE__{
            role: :assistant,
            model: String.t() | nil,
            error: String.t() | nil,
            content: [AgentCore.CliRunners.ClaudeSchema.content_block()]
          }
    defstruct role: :assistant, model: nil, error: nil, content: []
  end

  defmodule UserMessageContent do
    @moduledoc "Content of a user message (tool results)"
    @type t :: %__MODULE__{
            role: :user,
            content: [AgentCore.CliRunners.ClaudeSchema.content_block()] | String.t()
          }
    defstruct role: :user, content: []
  end

  defmodule Usage do
    @moduledoc "Token usage statistics"
    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            cache_creation_input_tokens: non_neg_integer(),
            cache_read_input_tokens: non_neg_integer()
          }
    defstruct input_tokens: 0,
              output_tokens: 0,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0
  end

  # ============================================================================
  # Stream Event Types
  # ============================================================================

  defmodule StreamSystemMessage do
    @moduledoc "Session initialization message"
    @type t :: %__MODULE__{
            type: :system,
            subtype: String.t(),
            session_id: String.t() | nil,
            uuid: String.t() | nil,
            cwd: String.t() | nil,
            tools: [String.t()] | nil,
            mcp_servers: list() | nil,
            model: String.t() | nil,
            permission_mode: String.t() | nil,
            output_style: String.t() | nil,
            api_key_source: String.t() | nil
          }
    defstruct type: :system,
              subtype: "init",
              session_id: nil,
              uuid: nil,
              cwd: nil,
              tools: nil,
              mcp_servers: nil,
              model: nil,
              permission_mode: nil,
              output_style: nil,
              api_key_source: nil
  end

  defmodule StreamAssistantMessage do
    @moduledoc "Assistant response message"
    @type t :: %__MODULE__{
            type: :assistant,
            uuid: String.t() | nil,
            session_id: String.t() | nil,
            parent_tool_use_id: String.t() | nil,
            message: AssistantMessageContent.t()
          }
    defstruct type: :assistant,
              uuid: nil,
              session_id: nil,
              parent_tool_use_id: nil,
              message: %AssistantMessageContent{}
  end

  defmodule StreamUserMessage do
    @moduledoc "User message (typically tool results)"
    @type t :: %__MODULE__{
            type: :user,
            uuid: String.t() | nil,
            session_id: String.t() | nil,
            parent_tool_use_id: String.t() | nil,
            message: UserMessageContent.t()
          }
    defstruct type: :user,
              uuid: nil,
              session_id: nil,
              parent_tool_use_id: nil,
              message: %UserMessageContent{}
  end

  defmodule StreamResultMessage do
    @moduledoc "Final session result message"
    @type t :: %__MODULE__{
            type: :result,
            subtype: String.t(),
            session_id: String.t() | nil,
            duration_ms: non_neg_integer() | nil,
            duration_api_ms: non_neg_integer() | nil,
            num_turns: non_neg_integer() | nil,
            is_error: boolean(),
            total_cost_usd: float() | nil,
            usage: Usage.t() | nil,
            result: String.t() | nil,
            structured_output: any()
          }
    defstruct type: :result,
              subtype: "success",
              session_id: nil,
              duration_ms: nil,
              duration_api_ms: nil,
              num_turns: nil,
              is_error: false,
              total_cost_usd: nil,
              usage: nil,
              result: nil,
              structured_output: nil
  end

  @typedoc "Union of all stream event types"
  @type stream_event ::
          StreamSystemMessage.t()
          | StreamAssistantMessage.t()
          | StreamUserMessage.t()
          | StreamResultMessage.t()

  # ============================================================================
  # Decoding
  # ============================================================================

  @doc """
  Decode a JSON line into a stream event struct.

  Returns `{:ok, event}` on success or `{:error, reason}` on failure.
  """
  @spec decode_event(String.t() | binary()) :: {:ok, stream_event()} | {:error, term()}
  def decode_event(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> decode_event_map(data)
      {:error, _} = err -> err
    end
  end

  @doc """
  Decode a map (already parsed JSON) into a stream event struct.
  """
  @spec decode_event_map(map()) :: {:ok, stream_event()} | {:error, term()}
  def decode_event_map(%{"type" => type} = data) do
    case type do
      "system" ->
        {:ok, decode_system_message(data)}

      "assistant" ->
        {:ok, decode_assistant_message(data)}

      "user" ->
        {:ok, decode_user_message(data)}

      "result" ->
        {:ok, decode_result_message(data)}

      # Ignore other event types (stream_event, control_*, etc.)
      _ ->
        {:ok, :ignored}
    end
  end

  def decode_event_map(_), do: {:error, :missing_type}

  # ============================================================================
  # Private Decoders
  # ============================================================================

  defp decode_system_message(data) do
    %StreamSystemMessage{
      subtype: data["subtype"] || "init",
      session_id: data["session_id"],
      uuid: data["uuid"],
      cwd: data["cwd"],
      tools: data["tools"],
      mcp_servers: data["mcp_servers"],
      model: data["model"],
      permission_mode: data["permissionMode"],
      output_style: data["output_style"],
      api_key_source: data["apiKeySource"]
    }
  end

  defp decode_assistant_message(data) do
    message = data["message"] || %{}

    %StreamAssistantMessage{
      uuid: data["uuid"],
      session_id: data["session_id"],
      parent_tool_use_id: data["parent_tool_use_id"],
      message: %AssistantMessageContent{
        model: message["model"],
        error: message["error"],
        content: decode_content_blocks(message["content"] || [])
      }
    }
  end

  defp decode_user_message(data) do
    message = data["message"] || %{}
    content = message["content"]

    decoded_content =
      cond do
        is_binary(content) -> content
        is_list(content) -> decode_content_blocks(content)
        true -> []
      end

    %StreamUserMessage{
      uuid: data["uuid"],
      session_id: data["session_id"],
      parent_tool_use_id: data["parent_tool_use_id"],
      message: %UserMessageContent{
        content: decoded_content
      }
    }
  end

  defp decode_result_message(data) do
    %StreamResultMessage{
      subtype: data["subtype"] || "success",
      session_id: data["session_id"],
      duration_ms: data["duration_ms"],
      duration_api_ms: data["duration_api_ms"],
      num_turns: data["num_turns"],
      is_error: data["is_error"] || false,
      total_cost_usd: data["total_cost_usd"],
      usage: decode_usage(data["usage"]),
      result: data["result"],
      structured_output: data["structured_output"]
    }
  end

  defp decode_content_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, &decode_content_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_content_blocks(_), do: []

  defp decode_content_block(%{"type" => "text"} = block) do
    %TextBlock{text: block["text"] || ""}
  end

  defp decode_content_block(%{"type" => "thinking"} = block) do
    %ThinkingBlock{
      thinking: block["thinking"] || "",
      signature: block["signature"]
    }
  end

  defp decode_content_block(%{"type" => "tool_use"} = block) do
    %ToolUseBlock{
      id: block["id"] || "",
      name: block["name"] || "",
      input: block["input"] || %{}
    }
  end

  defp decode_content_block(%{"type" => "tool_result"} = block) do
    %ToolResultBlock{
      tool_use_id: block["tool_use_id"] || "",
      content: block["content"],
      is_error: block["is_error"] || false
    }
  end

  defp decode_content_block(_), do: nil

  defp decode_usage(nil), do: nil

  defp decode_usage(data) when is_map(data) do
    %Usage{
      input_tokens: data["input_tokens"] || 0,
      output_tokens: data["output_tokens"] || 0,
      cache_creation_input_tokens: data["cache_creation_input_tokens"] || 0,
      cache_read_input_tokens: data["cache_read_input_tokens"] || 0
    }
  end
end
