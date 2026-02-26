defmodule AgentCore.CliRunners.OpencodeSchema do
  @moduledoc """
  OpenCode CLI JSONL event schema definitions.

  OpenCode emits newline-delimited JSON with a `"type"` discriminator when run with:

      opencode run --format json

  Observed event types (mirrors Takopi):
  - `step_start`
  - `tool_use`
  - `text`
  - `step_finish`
  - `error`
  """

  # Keep these structs small and permissive: OpenCode may add fields over time.

  defmodule StepStart do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :step_start,
            timestamp: integer() | nil,
            sessionID: String.t() | nil,
            part: map() | nil
          }
    defstruct type: :step_start, timestamp: nil, sessionID: nil, part: nil
  end

  defmodule StepFinish do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :step_finish,
            timestamp: integer() | nil,
            sessionID: String.t() | nil,
            part: map() | nil
          }
    defstruct type: :step_finish, timestamp: nil, sessionID: nil, part: nil
  end

  defmodule ToolUse do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :tool_use,
            timestamp: integer() | nil,
            sessionID: String.t() | nil,
            part: map() | nil
          }
    defstruct type: :tool_use, timestamp: nil, sessionID: nil, part: nil
  end

  defmodule Text do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :text,
            timestamp: integer() | nil,
            sessionID: String.t() | nil,
            part: map() | nil
          }
    defstruct type: :text, timestamp: nil, sessionID: nil, part: nil
  end

  defmodule Error do
    @moduledoc false
    @type t :: %__MODULE__{
            type: :error,
            timestamp: integer() | nil,
            sessionID: String.t() | nil,
            error: term(),
            message: term()
          }
    defstruct type: :error, timestamp: nil, sessionID: nil, error: nil, message: nil
  end

  defmodule Unknown do
    @moduledoc false
    @type t :: %__MODULE__{type: :unknown, raw: map()}
    defstruct type: :unknown, raw: %{}
  end

  @type opencode_event ::
          StepStart.t()
          | StepFinish.t()
          | ToolUse.t()
          | Text.t()
          | Error.t()
          | Unknown.t()

  @spec decode_event(String.t() | binary()) :: {:ok, opencode_event()} | {:error, term()}
  def decode_event(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> decode_event_map(data)
      {:error, _} = err -> err
    end
  end

  @spec decode_event_map(map()) :: {:ok, opencode_event()} | {:error, term()}
  def decode_event_map(%{"type" => type} = data) when is_binary(type) do
    timestamp = Map.get(data, "timestamp")
    session_id = Map.get(data, "sessionID")

    case type do
      "step_start" ->
        {:ok,
         %StepStart{timestamp: timestamp, sessionID: session_id, part: Map.get(data, "part")}}

      "step_finish" ->
        {:ok,
         %StepFinish{timestamp: timestamp, sessionID: session_id, part: Map.get(data, "part")}}

      "tool_use" ->
        {:ok, %ToolUse{timestamp: timestamp, sessionID: session_id, part: Map.get(data, "part")}}

      "text" ->
        {:ok, %Text{timestamp: timestamp, sessionID: session_id, part: Map.get(data, "part")}}

      "error" ->
        {:ok,
         %Error{
           timestamp: timestamp,
           sessionID: session_id,
           error: Map.get(data, "error"),
           message: Map.get(data, "message")
         }}

      _ ->
        {:ok, %Unknown{raw: data}}
    end
  end

  def decode_event_map(data) when is_map(data), do: {:ok, %Unknown{raw: data}}
  def decode_event_map(_), do: {:error, :invalid_event}
end
