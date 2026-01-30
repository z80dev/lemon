defmodule CodingAgent.Messages do
  @moduledoc """
  Message structs and conversion functions for the coding agent.

  This module defines the internal message types used by the coding agent
  and provides functions to convert them to the format expected by the Ai library.

  ## Message Types

  The coding agent uses several specialized message types beyond the standard
  user/assistant/tool_result:

  - `BashExecutionMessage` - Results from bash command execution
  - `CustomMessage` - Extension-defined custom messages
  - `BranchSummaryMessage` - Summary of git branch context
  - `CompactionSummaryMessage` - Summary after context compaction
  """

  # ============================================================================
  # Content Types
  # ============================================================================

  defmodule TextContent do
    @moduledoc "Plain text content block"
    @type t :: %__MODULE__{
            type: :text,
            text: String.t()
          }
    defstruct type: :text, text: ""
  end

  defmodule ImageContent do
    @moduledoc "Base64-encoded image content block"
    @type t :: %__MODULE__{
            type: :image,
            data: String.t(),
            mime_type: String.t()
          }
    defstruct type: :image, data: "", mime_type: "image/png"
  end

  defmodule ThinkingContent do
    @moduledoc "Model reasoning/thinking content block"
    @type t :: %__MODULE__{
            type: :thinking,
            thinking: String.t()
          }
    defstruct type: :thinking, thinking: ""
  end

  defmodule ToolCall do
    @moduledoc "Tool/function call from the model"
    @type t :: %__MODULE__{
            type: :tool_call,
            id: String.t(),
            name: String.t(),
            arguments: map()
          }
    defstruct type: :tool_call, id: "", name: "", arguments: %{}
  end

  @type content_block :: TextContent.t() | ImageContent.t() | ThinkingContent.t() | ToolCall.t()

  # ============================================================================
  # Usage Tracking
  # ============================================================================

  defmodule Usage do
    @moduledoc "Token usage and cost tracking for a response"
    @type t :: %__MODULE__{
            input: non_neg_integer(),
            output: non_neg_integer(),
            cache_read: non_neg_integer(),
            cache_write: non_neg_integer(),
            total_tokens: non_neg_integer(),
            cost: float() | nil
          }
    defstruct input: 0, output: 0, cache_read: 0, cache_write: 0, total_tokens: 0, cost: nil

    @doc "Calculate total tokens from usage"
    @spec total_tokens(t()) :: non_neg_integer()
    def total_tokens(%__MODULE__{} = usage) do
      usage.input + usage.output + usage.cache_read + usage.cache_write
    end
  end

  # ============================================================================
  # Message Types
  # ============================================================================

  defmodule UserMessage do
    @moduledoc "A message from the user"
    alias CodingAgent.Messages.{TextContent, ImageContent}

    @type content :: String.t() | [TextContent.t() | ImageContent.t()]
    @type t :: %__MODULE__{
            role: :user,
            content: content(),
            timestamp: integer()
          }
    defstruct role: :user, content: "", timestamp: 0
  end

  defmodule AssistantMessage do
    @moduledoc "A message from the assistant/model"
    alias CodingAgent.Messages.{TextContent, ThinkingContent, ToolCall, Usage}

    @type content_block :: TextContent.t() | ThinkingContent.t() | ToolCall.t()
    @type stop_reason :: :stop | :length | :tool_use | :error | :aborted
    @type t :: %__MODULE__{
            role: :assistant,
            content: [content_block()],
            provider: String.t(),
            model: String.t(),
            api: String.t(),
            usage: Usage.t() | nil,
            stop_reason: stop_reason() | nil,
            timestamp: integer()
          }
    defstruct role: :assistant,
              content: [],
              provider: "",
              model: "",
              api: "",
              usage: nil,
              stop_reason: nil,
              timestamp: 0
  end

  defmodule ToolResultMessage do
    @moduledoc "Result of a tool call"
    alias CodingAgent.Messages.TextContent

    @type t :: %__MODULE__{
            role: :tool_result,
            tool_use_id: String.t(),
            content: [TextContent.t()],
            is_error: boolean(),
            timestamp: integer()
          }
    defstruct role: :tool_result,
              tool_use_id: "",
              content: [],
              is_error: false,
              timestamp: 0
  end

  defmodule BashExecutionMessage do
    @moduledoc "Result of a bash command execution"
    @type t :: %__MODULE__{
            role: :bash_execution,
            command: String.t(),
            output: String.t(),
            exit_code: integer() | nil,
            cancelled: boolean(),
            truncated: boolean(),
            full_output_path: String.t() | nil,
            timestamp: integer(),
            exclude_from_context: boolean()
          }
    defstruct role: :bash_execution,
              command: "",
              output: "",
              exit_code: nil,
              cancelled: false,
              truncated: false,
              full_output_path: nil,
              timestamp: 0,
              exclude_from_context: false
  end

  defmodule CustomMessage do
    @moduledoc "Extension-defined custom message"
    alias CodingAgent.Messages.{TextContent, ImageContent}

    @type content :: String.t() | [TextContent.t() | ImageContent.t()]
    @type t :: %__MODULE__{
            role: :custom,
            custom_type: String.t(),
            content: content(),
            display: boolean(),
            details: any(),
            timestamp: integer()
          }
    defstruct role: :custom,
              custom_type: "",
              content: "",
              display: true,
              details: nil,
              timestamp: 0
  end

  defmodule BranchSummaryMessage do
    @moduledoc "Summary of git branch context"
    @type t :: %__MODULE__{
            role: :branch_summary,
            summary: String.t(),
            timestamp: integer()
          }
    defstruct role: :branch_summary,
              summary: "",
              timestamp: 0
  end

  defmodule CompactionSummaryMessage do
    @moduledoc "Summary after context compaction"
    @type t :: %__MODULE__{
            role: :compaction_summary,
            summary: String.t(),
            timestamp: integer()
          }
    defstruct role: :compaction_summary,
              summary: "",
              timestamp: 0
  end

  @type message ::
          UserMessage.t()
          | AssistantMessage.t()
          | ToolResultMessage.t()
          | BashExecutionMessage.t()
          | CustomMessage.t()
          | BranchSummaryMessage.t()
          | CompactionSummaryMessage.t()

  # ============================================================================
  # Conversion Functions
  # ============================================================================

  @doc """
  Convert a list of agent messages to LLM-compatible format for the Ai library.

  This function transforms CodingAgent message types into the standard
  Ai.Types message format that can be sent to LLM providers.

  ## Conversion Rules

  - Messages with `exclude_from_context: true` are skipped
  - `BashExecutionMessage` becomes a user message with formatted output
  - `CustomMessage` becomes a user message
  - `BranchSummaryMessage` becomes a user message with summary in `<branch_summary>` tags
  - `CompactionSummaryMessage` becomes a user message with summary in `<compaction_summary>` tags
  - Standard user/assistant/tool_result messages are converted to their Ai.Types equivalents
  """
  @spec to_llm([message()]) :: [Ai.Types.message()]
  def to_llm(messages) when is_list(messages) do
    messages
    |> Enum.reject(&exclude_from_context?/1)
    |> Enum.map(&convert_to_llm/1)
  end

  @doc """
  Extract text content from a message.

  Returns the concatenated text from all text content blocks in the message.
  For simple string content, returns the string directly.
  """
  @spec get_text(message()) :: String.t() | nil
  def get_text(%UserMessage{content: content}) when is_binary(content), do: content
  def get_text(%UserMessage{content: nil}), do: nil

  def get_text(%UserMessage{content: content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  def get_text(%AssistantMessage{content: content}) do
    content
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  def get_text(%ToolResultMessage{content: content}) do
    content
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  def get_text(%BashExecutionMessage{output: output}), do: output

  def get_text(%CustomMessage{content: content}) when is_binary(content), do: content

  def get_text(%CustomMessage{content: content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  def get_text(%BranchSummaryMessage{summary: summary}), do: summary
  def get_text(%CompactionSummaryMessage{summary: summary}), do: summary

  # Handle Ai.Types.UserMessage
  def get_text(%Ai.Types.UserMessage{content: content}) when is_binary(content), do: content
  def get_text(%Ai.Types.UserMessage{content: nil}), do: nil

  def get_text(%Ai.Types.UserMessage{content: content}) when is_list(content) do
    content
    |> Enum.map(&extract_text_from_ai_content/1)
    |> Enum.join("\n")
  end

  # Handle Ai.Types.AssistantMessage
  def get_text(%Ai.Types.AssistantMessage{content: content}) when is_list(content) do
    content
    |> Enum.map(&extract_text_from_ai_content/1)
    |> Enum.join("\n")
  end

  # Handle Ai.Types.ToolResultMessage
  def get_text(%Ai.Types.ToolResultMessage{content: content}) when is_list(content) do
    content
    |> Enum.map(&extract_text_from_ai_content/1)
    |> Enum.join("\n")
  end

  # Helper for Ai.Types content blocks
  defp extract_text_from_ai_content(%Ai.Types.TextContent{text: text}), do: text
  defp extract_text_from_ai_content(%Ai.Types.ThinkingContent{thinking: text}), do: text
  defp extract_text_from_ai_content(%Ai.Types.ImageContent{}), do: "[image]"
  defp extract_text_from_ai_content(%Ai.Types.ToolCall{name: name}), do: "[tool_call: #{name}]"
  defp extract_text_from_ai_content(_), do: ""

  @doc """
  Extract tool calls from an assistant message.

  Returns a list of ToolCall structs from the message content.
  Returns an empty list for non-assistant messages.
  """
  @spec get_tool_calls(message()) :: [ToolCall.t()]
  def get_tool_calls(%AssistantMessage{content: content}) do
    Enum.filter(content, &match?(%ToolCall{}, &1))
  end

  def get_tool_calls(_message), do: []

  @doc """
  Calculate total tokens from a Usage struct.

  This is a convenience function that delegates to `Usage.total_tokens/1`.
  """
  @spec total_tokens(Usage.t()) :: non_neg_integer()
  def total_tokens(%Usage{} = usage), do: Usage.total_tokens(usage)

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp exclude_from_context?(%BashExecutionMessage{exclude_from_context: true}), do: true
  defp exclude_from_context?(_), do: false

  # Pass through Ai.Types messages unchanged - they're already in LLM format
  defp convert_to_llm(%Ai.Types.UserMessage{} = msg), do: msg
  defp convert_to_llm(%Ai.Types.AssistantMessage{} = msg), do: msg
  defp convert_to_llm(%Ai.Types.ToolResultMessage{} = msg), do: msg

  # Convert CodingAgent.Messages types to Ai.Types
  defp convert_to_llm(%UserMessage{} = msg) do
    %Ai.Types.UserMessage{
      role: :user,
      content: convert_content(msg.content),
      timestamp: msg.timestamp
    }
  end

  defp convert_to_llm(%AssistantMessage{} = msg) do
    %Ai.Types.AssistantMessage{
      role: :assistant,
      content: Enum.map(msg.content, &convert_content_block/1),
      api: msg.api,
      provider: msg.provider,
      model: msg.model,
      usage: convert_usage(msg.usage),
      stop_reason: msg.stop_reason,
      timestamp: msg.timestamp
    }
  end

  defp convert_to_llm(%ToolResultMessage{} = msg) do
    %Ai.Types.ToolResultMessage{
      role: :tool_result,
      tool_call_id: msg.tool_use_id,
      tool_name: "",
      content: Enum.map(msg.content, &convert_content_block/1),
      is_error: msg.is_error,
      timestamp: msg.timestamp
    }
  end

  defp convert_to_llm(%BashExecutionMessage{} = msg) do
    formatted_output = format_bash_output(msg)

    %Ai.Types.UserMessage{
      role: :user,
      content: formatted_output,
      timestamp: msg.timestamp
    }
  end

  defp convert_to_llm(%CustomMessage{} = msg) do
    content =
      case msg.content do
        c when is_binary(c) -> c
        c when is_list(c) -> convert_content(c)
      end

    %Ai.Types.UserMessage{
      role: :user,
      content: content,
      timestamp: msg.timestamp
    }
  end

  defp convert_to_llm(%BranchSummaryMessage{} = msg) do
    content = "<branch_summary>\n#{msg.summary}\n</branch_summary>"

    %Ai.Types.UserMessage{
      role: :user,
      content: content,
      timestamp: msg.timestamp
    }
  end

  defp convert_to_llm(%CompactionSummaryMessage{} = msg) do
    content = "<compaction_summary>\n#{msg.summary}\n</compaction_summary>"

    %Ai.Types.UserMessage{
      role: :user,
      content: content,
      timestamp: msg.timestamp
    }
  end

  # Handle plain maps with "role" key for backward compatibility
  defp convert_to_llm(%{role: :user, content: content} = msg) do
    %Ai.Types.UserMessage{
      role: :user,
      content: content,
      timestamp: Map.get(msg, :timestamp, 0)
    }
  end

  defp convert_to_llm(%{role: :assistant, content: content} = msg) do
    %Ai.Types.AssistantMessage{
      role: :assistant,
      content: content,
      api: Map.get(msg, :api),
      provider: Map.get(msg, :provider),
      model: Map.get(msg, :model, ""),
      usage: Map.get(msg, :usage),
      stop_reason: Map.get(msg, :stop_reason),
      timestamp: Map.get(msg, :timestamp, 0)
    }
  end

  defp convert_to_llm(%{role: :tool_result, content: content} = msg) do
    %Ai.Types.ToolResultMessage{
      role: :tool_result,
      tool_call_id: Map.get(msg, :tool_call_id) || Map.get(msg, :tool_use_id, ""),
      tool_name: Map.get(msg, :tool_name, ""),
      content: content,
      is_error: Map.get(msg, :is_error, false),
      timestamp: Map.get(msg, :timestamp, 0)
    }
  end

  defp convert_content(content) when is_binary(content), do: content

  defp convert_content(content) when is_list(content) do
    Enum.map(content, &convert_content_block/1)
  end

  defp convert_content_block(%TextContent{text: text}) do
    %Ai.Types.TextContent{type: :text, text: text}
  end

  defp convert_content_block(%ImageContent{data: data, mime_type: mime_type}) do
    %Ai.Types.ImageContent{type: :image, data: data, mime_type: mime_type}
  end

  defp convert_content_block(%ThinkingContent{thinking: thinking}) do
    %Ai.Types.ThinkingContent{type: :thinking, thinking: thinking}
  end

  defp convert_content_block(%ToolCall{id: id, name: name, arguments: arguments}) do
    %Ai.Types.ToolCall{type: :tool_call, id: id, name: name, arguments: arguments}
  end

  defp convert_usage(nil), do: nil

  defp convert_usage(%Usage{} = usage) do
    %Ai.Types.Usage{
      input: usage.input,
      output: usage.output,
      cache_read: usage.cache_read,
      cache_write: usage.cache_write,
      total_tokens: usage.total_tokens,
      cost: convert_cost(usage.cost)
    }
  end

  defp convert_cost(nil), do: %Ai.Types.Cost{}
  defp convert_cost(cost) when is_float(cost), do: %Ai.Types.Cost{total: cost}

  defp format_bash_output(%BashExecutionMessage{} = msg) do
    parts = ["$ #{msg.command}"]

    parts =
      if msg.output != "" do
        parts ++ [msg.output]
      else
        parts
      end

    parts =
      cond do
        msg.cancelled -> parts ++ ["[cancelled]"]
        msg.truncated -> parts ++ ["[truncated]"]
        true -> parts
      end

    parts =
      if msg.exit_code && msg.exit_code != 0 do
        parts ++ ["[exit code: #{msg.exit_code}]"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end
end
