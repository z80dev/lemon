defmodule LemonGateway.Types do
  @moduledoc """
  Core type definitions for the LemonGateway domain.

  Defines the foundational structs and types used throughout the gateway:
  `Job`, `ChatScope`, and `ResumeToken`.
  """

  @type engine_id :: String.t()

  defmodule ResumeToken do
    @moduledoc """
    Token for resuming a conversation session with an engine.

    Contains the engine identifier and an opaque value that the engine
    uses to restore conversation context.
    """
    @enforce_keys [:engine, :value]
    defstruct [:engine, :value]

    @type t :: %__MODULE__{engine: LemonGateway.Types.engine_id(), value: String.t()}
  end

  defmodule ChatScope do
    @moduledoc """
    Transport-specific chat identification.
    """
    @enforce_keys [:transport, :chat_id]
    defstruct [:transport, :chat_id, :topic_id]

    @type t :: %__MODULE__{transport: atom(), chat_id: integer(), topic_id: integer() | nil}
  end

  @type queue_mode :: :collect | :followup | :steer | :steer_backlog | :interrupt
  @type lane :: :main | :subagent | :background_exec

  defmodule Job do
    @moduledoc """
    Transport-agnostic job definition for run orchestration.

    ## Fields

    - `:run_id` - Unique run identifier (UUID)
    - `:session_key` - Stable session key for routing and state
    - `:prompt` - User prompt text (or synthesized prompt)
    - `:engine_id` - Resolved engine identifier
    - `:cwd` - Working directory (optional)
    - `:resume` - Resume token for session continuation
    - `:queue_mode` - How to handle queuing (:collect, :followup, :steer, :steer_backlog, :interrupt)
    - `:lane` - Execution lane (:main, :subagent, :background_exec)
    - `:tool_policy` - Tool execution policy map
    - `:meta` - Additional metadata (origin, channel info, etc.)
    """

    defstruct [
      :run_id,
      :session_key,
      :prompt,
      :engine_id,
      :cwd,
      :resume,
      :lane,
      :tool_policy,
      :meta,
      queue_mode: :collect
    ]

    @type t :: %__MODULE__{
            run_id: String.t() | nil,
            session_key: String.t() | nil,
            prompt: String.t() | nil,
            engine_id: LemonGateway.Types.engine_id() | nil,
            cwd: String.t() | nil,
            resume: LemonGateway.Types.ResumeToken.t() | nil,
            queue_mode: LemonGateway.Types.queue_mode(),
            lane: LemonGateway.Types.lane() | nil,
            tool_policy: map() | nil,
            meta: map() | nil
          }
  end
end
