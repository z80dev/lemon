defmodule LemonGateway.Event do
  @moduledoc """
  Event types for LemonGateway run lifecycle.

  These events are emitted during run execution and can be subscribed to
  via the LemonCore.Bus on the "run:<run_id>" topic.
  """

  @type phase :: :started | :updated | :completed

  defmodule Started do
    @moduledoc """
    Emitted when a run starts.
    """
    @enforce_keys [:engine, :resume]
    defstruct [:engine, :resume, :title, :meta, :run_id, :session_key]

    @type t :: %__MODULE__{
            engine: String.t(),
            resume: LemonGateway.Types.ResumeToken.t() | nil,
            title: String.t() | nil,
            meta: map() | nil,
            run_id: String.t() | nil,
            session_key: String.t() | nil
          }
  end

  defmodule Action do
    @moduledoc false
    @enforce_keys [:id, :kind, :title]
    defstruct [:id, :kind, :title, :detail]
  end

  defmodule ActionEvent do
    @moduledoc false
    @enforce_keys [:engine, :action, :phase]
    defstruct [:engine, :action, :phase, :ok, :message, :level]
  end

  defmodule Delta do
    @moduledoc """
    Streaming delta event for incremental text output.

    Emitted during run execution to provide real-time text updates.

    ## Fields

    - `:run_id` - The run this delta belongs to
    - `:ts_ms` - Timestamp in milliseconds
    - `:seq` - Monotonic sequence number (starts at 1, per run)
    - `:text` - The delta text content
    - `:meta` - Optional metadata

    ## Ordering Contract

    - `seq` is monotonic per run (starts at 1)
    - Router/coalescer can reorder/drop duplicates safely using seq
    """
    @enforce_keys [:run_id, :ts_ms, :seq, :text]
    defstruct [:run_id, :ts_ms, :seq, :text, :meta]

    @type t :: %__MODULE__{
            run_id: String.t(),
            ts_ms: non_neg_integer(),
            seq: pos_integer(),
            text: String.t(),
            meta: map() | nil
          }

    @doc """
    Create a new delta event.
    """
    @spec new(run_id :: String.t(), seq :: pos_integer(), text :: String.t(), meta :: map() | nil) :: t()
    def new(run_id, seq, text, meta \\ nil) do
      %__MODULE__{
        run_id: run_id,
        ts_ms: System.system_time(:millisecond),
        seq: seq,
        text: text,
        meta: meta
      }
    end
  end

  defmodule Completed do
    @moduledoc """
    Emitted when a run completes (success or failure).

    ## Completion Payload Contract (minimum)

    - `:ok` - boolean indicating success
    - `:answer` - final answer text
    - `:error` - error term if not ok
    - `:engine` - engine identifier
    - `:resume` - resume token for continuing the session
    - `:usage` - usage statistics map
    """
    @enforce_keys [:engine, :ok]
    defstruct [:engine, :resume, :ok, :answer, :error, :usage, :meta, :run_id, :session_key]

    @type t :: %__MODULE__{
            engine: String.t(),
            resume: LemonGateway.Types.ResumeToken.t() | nil,
            ok: boolean(),
            answer: String.t() | nil,
            error: term() | nil,
            usage: map() | nil,
            meta: map() | nil,
            run_id: String.t() | nil,
            session_key: String.t() | nil
          }
  end
end
