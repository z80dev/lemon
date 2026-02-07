defmodule AgentCore.CliRunners.PiSchema do
  @moduledoc """
  Pi Coding Agent JSONL event schema.

  Pi emits newline-delimited JSON when run with:

      pi --print --mode json --session <token> <prompt>

  Events use a `"type"` discriminator (mirrors Takopi).
  This schema decodes known event types and treats unknown ones as `Unknown`.
  """

  defmodule SessionHeader do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :session,
            id: String.t() | nil,
            version: integer() | nil,
            timestamp: String.t() | nil,
            cwd: String.t() | nil,
            parentSession: String.t() | nil
          }
    defstruct type: :session,
              id: nil,
              version: nil,
              timestamp: nil,
              cwd: nil,
              parentSession: nil
  end

  defmodule AgentStart do
    @moduledoc false
    @type t :: %__MODULE__{type: :agent_start}
    defstruct type: :agent_start
  end

  defmodule AgentEnd do
    @moduledoc false
    @type t :: %__MODULE__{type: :agent_end, messages: list()}
    defstruct type: :agent_end, messages: []
  end

  defmodule MessageEnd do
    @moduledoc false
    @type t :: %__MODULE__{type: :message_end, message: map()}
    defstruct type: :message_end, message: %{}
  end

  defmodule ToolExecutionStart do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :tool_execution_start,
            toolCallId: String.t(),
            toolName: String.t() | nil,
            args: map()
          }
    defstruct type: :tool_execution_start, toolCallId: "", toolName: nil, args: %{}
  end

  defmodule ToolExecutionEnd do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :tool_execution_end,
            toolCallId: String.t(),
            toolName: String.t() | nil,
            result: term(),
            isError: boolean()
          }
    defstruct type: :tool_execution_end,
              toolCallId: "",
              toolName: nil,
              result: nil,
              isError: false
  end

  defmodule Unknown do
    @moduledoc false
    @type t :: %__MODULE__{type: :unknown, raw: map()}
    defstruct type: :unknown, raw: %{}
  end

  @type pi_event ::
          SessionHeader.t()
          | AgentStart.t()
          | AgentEnd.t()
          | MessageEnd.t()
          | ToolExecutionStart.t()
          | ToolExecutionEnd.t()
          | Unknown.t()

  @spec decode_event(String.t() | binary()) :: {:ok, pi_event()} | {:error, term()}
  def decode_event(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> decode_event_map(data)
      {:error, _} = err -> err
    end
  end

  @spec decode_event_map(map()) :: {:ok, pi_event()} | {:error, term()}
  def decode_event_map(%{"type" => type} = data) when is_binary(type) do
    case type do
      "session" ->
        {:ok,
         %SessionHeader{
           id: Map.get(data, "id"),
           version: Map.get(data, "version"),
           timestamp: Map.get(data, "timestamp"),
           cwd: Map.get(data, "cwd"),
           parentSession: Map.get(data, "parentSession")
         }}

      "agent_start" ->
        {:ok, %AgentStart{}}

      "agent_end" ->
        {:ok, %AgentEnd{messages: Map.get(data, "messages") || []}}

      "message_end" ->
        {:ok, %MessageEnd{message: Map.get(data, "message") || %{}}}

      "tool_execution_start" ->
        {:ok,
         %ToolExecutionStart{
           toolCallId: Map.get(data, "toolCallId") || "",
           toolName: Map.get(data, "toolName"),
           args: Map.get(data, "args") || %{}
         }}

      "tool_execution_end" ->
        {:ok,
         %ToolExecutionEnd{
           toolCallId: Map.get(data, "toolCallId") || "",
           toolName: Map.get(data, "toolName"),
           result: Map.get(data, "result"),
           isError: Map.get(data, "isError") || false
         }}

      _ ->
        {:ok, %Unknown{raw: data}}
    end
  end

  def decode_event_map(data) when is_map(data), do: {:ok, %Unknown{raw: data}}
  def decode_event_map(_), do: {:error, :invalid_event}
end
