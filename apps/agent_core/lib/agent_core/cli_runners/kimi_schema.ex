defmodule AgentCore.CliRunners.KimiSchema do
  @moduledoc """
  Kimi CLI JSONL event schema definitions.

  This module defines the event shape emitted by `kimi --print --output-format stream-json`.
  The output is newline-delimited JSON where each line wraps a single message.
  """

  # ============================================================================
  # Tool Call Types
  # ============================================================================

  defmodule ToolFunction do
    @moduledoc "Function payload for a tool call"
    @type t :: %__MODULE__{
            name: String.t() | nil,
            arguments: String.t() | map() | nil
          }
    defstruct name: nil, arguments: nil
  end

  defmodule ToolCall do
    @moduledoc "Tool call entry"
    @type t :: %__MODULE__{
            id: String.t() | nil,
            type: String.t() | nil,
            function: ToolFunction.t() | nil
          }
    defstruct id: nil, type: nil, function: nil
  end

  # ============================================================================
  # Message Types
  # ============================================================================

  defmodule Message do
    @moduledoc "Kimi message payload"
    @type t :: %__MODULE__{
            role: String.t() | nil,
            content: String.t() | list() | nil,
            tool_calls: [ToolCall.t()] | nil,
            tool_call_id: String.t() | nil,
            name: String.t() | nil,
            is_error: boolean() | nil
          }
    defstruct role: nil,
              content: nil,
              tool_calls: nil,
              tool_call_id: nil,
              name: nil,
              is_error: nil
  end

  defmodule StreamMessage do
    @moduledoc "Wrapper for a message line"
    @type t :: %__MODULE__{
            type: :message,
            message: Message.t()
          }
    defstruct type: :message, message: %Message{}
  end

  defmodule ErrorMessage do
    @moduledoc "Error line emitted by the CLI"
    @type t :: %__MODULE__{
            type: :error,
            error: String.t() | map()
          }
    defstruct type: :error, error: nil
  end

  @type stream_event :: StreamMessage.t() | ErrorMessage.t()

  @doc """
  Decode a JSONL line into a Kimi schema event.

  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec decode_event(binary()) :: {:ok, stream_event()} | {:error, term()}
  def decode_event(line) when is_binary(line) do
    with {:ok, data} <- Jason.decode(line) do
      decode_map(data)
    end
  end

  def decode_event(_), do: {:error, :invalid_line}

  # ============================================================================
  # Internal decoding helpers
  # ============================================================================

  defp decode_map(%{"message" => message}) when is_map(message) do
    {:ok, %StreamMessage{type: :message, message: decode_message(message)}}
  end

  defp decode_map(%{"role" => _role} = message) do
    {:ok, %StreamMessage{type: :message, message: decode_message(message)}}
  end

  defp decode_map(%{"error" => error}) do
    {:ok, %ErrorMessage{error: error}}
  end

  defp decode_map(_), do: {:error, :unknown_event}

  defp decode_message(message) do
    %Message{
      role: Map.get(message, "role"),
      content: Map.get(message, "content"),
      tool_calls: decode_tool_calls(Map.get(message, "tool_calls")),
      tool_call_id: Map.get(message, "tool_call_id"),
      name: Map.get(message, "name"),
      is_error: Map.get(message, "is_error")
    }
  end

  defp decode_tool_calls(nil), do: nil
  defp decode_tool_calls(calls) when is_list(calls), do: Enum.map(calls, &decode_tool_call/1)
  defp decode_tool_calls(_), do: nil

  defp decode_tool_call(call) when is_map(call) do
    %ToolCall{
      id: Map.get(call, "id"),
      type: Map.get(call, "type"),
      function: decode_tool_function(Map.get(call, "function"))
    }
  end

  defp decode_tool_call(_), do: %ToolCall{}

  defp decode_tool_function(func) when is_map(func) do
    %ToolFunction{
      name: Map.get(func, "name"),
      arguments: Map.get(func, "arguments")
    }
  end

  defp decode_tool_function(_), do: nil
end
