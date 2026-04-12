defmodule AgentCore.CliRunners.DroidSchema do
  @moduledoc """
  Factory Droid CLI stream-json event schema definitions.

  Droid emits newline-delimited JSON with a `"type"` discriminator when run with:

      droid exec -o stream-json --skip-permissions-unsafe ...
  """

  defmodule DroidSystemEvent do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :system,
            subtype: String.t() | nil,
            cwd: String.t() | nil,
            session_id: String.t() | nil,
            tools: list() | nil,
            model: String.t() | nil
          }

    defstruct type: :system,
              subtype: nil,
              cwd: nil,
              session_id: nil,
              tools: nil,
              model: nil
  end

  defmodule DroidMessageEvent do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :message,
            role: String.t() | nil,
            id: String.t() | nil,
            text: String.t() | nil,
            timestamp: integer() | nil,
            session_id: String.t() | nil
          }

    defstruct type: :message,
              role: nil,
              id: nil,
              text: nil,
              timestamp: nil,
              session_id: nil
  end

  defmodule DroidReasoningEvent do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :reasoning,
            id: String.t() | nil,
            text: String.t() | nil,
            timestamp: integer() | nil,
            session_id: String.t() | nil
          }

    defstruct type: :reasoning,
              id: nil,
              text: nil,
              timestamp: nil,
              session_id: nil
  end

  defmodule DroidToolCallEvent do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :tool_call,
            id: String.t() | nil,
            messageId: String.t() | nil,
            toolId: String.t() | nil,
            toolName: String.t() | nil,
            parameters: map() | nil,
            timestamp: integer() | nil,
            session_id: String.t() | nil
          }

    defstruct type: :tool_call,
              id: nil,
              messageId: nil,
              toolId: nil,
              toolName: nil,
              parameters: nil,
              timestamp: nil,
              session_id: nil
  end

  defmodule DroidToolResultEvent do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :tool_result,
            id: String.t() | nil,
            messageId: String.t() | nil,
            toolId: String.t() | nil,
            isError: boolean() | nil,
            value: term(),
            timestamp: integer() | nil,
            session_id: String.t() | nil
          }

    defstruct type: :tool_result,
              id: nil,
              messageId: nil,
              toolId: nil,
              isError: nil,
              value: nil,
              timestamp: nil,
              session_id: nil
  end

  defmodule DroidCompletionEvent do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :completion,
            finalText: String.t() | nil,
            numTurns: integer() | nil,
            durationMs: integer() | nil,
            session_id: String.t() | nil,
            timestamp: integer() | nil
          }

    defstruct type: :completion,
              finalText: nil,
              numTurns: nil,
              durationMs: nil,
              session_id: nil,
              timestamp: nil
  end

  @type droid_event ::
          DroidSystemEvent.t()
          | DroidMessageEvent.t()
          | DroidReasoningEvent.t()
          | DroidToolCallEvent.t()
          | DroidToolResultEvent.t()
          | DroidCompletionEvent.t()

  @spec decode_line(String.t() | binary()) :: {:ok, droid_event()} | {:error, term()}
  def decode_line(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> decode_event_map(data)
      {:error, _} = err -> err
    end
  end

  @spec decode_event_map(map()) :: {:ok, droid_event()} | {:error, term()}
  def decode_event_map(%{"type" => type} = data) when is_binary(type) do
    case type do
      "system" ->
        {:ok,
         %DroidSystemEvent{
           subtype: Map.get(data, "subtype"),
           cwd: Map.get(data, "cwd"),
           session_id: Map.get(data, "session_id"),
           tools: Map.get(data, "tools"),
           model: Map.get(data, "model")
         }}

      "message" ->
        {:ok,
         %DroidMessageEvent{
           role: Map.get(data, "role"),
           id: Map.get(data, "id"),
           text: Map.get(data, "text"),
           timestamp: Map.get(data, "timestamp"),
           session_id: Map.get(data, "session_id")
         }}

      "reasoning" ->
        {:ok,
         %DroidReasoningEvent{
           id: Map.get(data, "id"),
           text: Map.get(data, "text"),
           timestamp: Map.get(data, "timestamp"),
           session_id: Map.get(data, "session_id")
         }}

      "tool_call" ->
        {:ok,
         %DroidToolCallEvent{
           id: Map.get(data, "id"),
           messageId: Map.get(data, "messageId"),
           toolId: Map.get(data, "toolId"),
           toolName: Map.get(data, "toolName"),
           parameters: Map.get(data, "parameters"),
           timestamp: Map.get(data, "timestamp"),
           session_id: Map.get(data, "session_id")
         }}

      "tool_result" ->
        {:ok,
         %DroidToolResultEvent{
           id: Map.get(data, "id"),
           messageId: Map.get(data, "messageId"),
           toolId: Map.get(data, "toolId"),
           isError: Map.get(data, "isError"),
           value: Map.get(data, "value"),
           timestamp: Map.get(data, "timestamp"),
           session_id: Map.get(data, "session_id")
         }}

      "completion" ->
        {:ok,
         %DroidCompletionEvent{
           finalText: Map.get(data, "finalText"),
           numTurns: Map.get(data, "numTurns"),
           durationMs: Map.get(data, "durationMs"),
           session_id: Map.get(data, "session_id"),
           timestamp: Map.get(data, "timestamp")
         }}

      _ ->
        {:error, {:unknown_event_type, type}}
    end
  end

  def decode_event_map(_), do: {:error, :invalid_event}
end
