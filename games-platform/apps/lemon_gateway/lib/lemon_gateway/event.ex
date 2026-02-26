defmodule LemonGateway.Event do
  @moduledoc """
  Event types for LemonGateway run lifecycle.

  Events are plain tagged maps (not structs) identified by an `__event__` key.
  Constructor functions normalise the shape; defguards let callers pattern-match.

  These events are emitted during run execution and can be subscribed to
  via the LemonCore.Bus on the "run:<run_id>" topic.
  """

  @type phase :: :started | :updated | :completed

  # ---------------------------------------------------------------------------
  # Guards
  # ---------------------------------------------------------------------------

  defguard is_started(ev) when is_map(ev) and :erlang.map_get(:__event__, ev) == :started
  defguard is_action_event(ev) when is_map(ev) and :erlang.map_get(:__event__, ev) == :action_event
  defguard is_completed(ev) when is_map(ev) and :erlang.map_get(:__event__, ev) == :completed

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc """
  Build a `:started` event map.

  Required keys: `:engine`, `:resume`.
  Optional: `:title`, `:meta`, `:run_id`, `:session_key`.
  """
  @spec started(map()) :: map()
  def started(fields) when is_map(fields) do
    %{
      __event__: :started,
      engine: Map.fetch!(fields, :engine),
      resume: Map.fetch!(fields, :resume),
      title: Map.get(fields, :title),
      meta: Map.get(fields, :meta),
      run_id: Map.get(fields, :run_id),
      session_key: Map.get(fields, :session_key)
    }
  end

  @doc """
  Build an `:action` map (embedded inside action_event).

  Required keys: `:id`, `:kind`, `:title`.
  Optional: `:detail`.
  """
  @spec action(map()) :: map()
  def action(fields) when is_map(fields) do
    %{
      __event__: :action,
      id: Map.fetch!(fields, :id),
      kind: Map.fetch!(fields, :kind),
      title: Map.fetch!(fields, :title),
      detail: Map.get(fields, :detail)
    }
  end

  @doc """
  Build an `:action_event` map.

  Required keys: `:engine`, `:action`, `:phase`.
  Optional: `:ok`, `:message`, `:level`.
  """
  @spec action_event(map()) :: map()
  def action_event(fields) when is_map(fields) do
    %{
      __event__: :action_event,
      engine: Map.fetch!(fields, :engine),
      action: Map.fetch!(fields, :action),
      phase: Map.fetch!(fields, :phase),
      ok: Map.get(fields, :ok),
      message: Map.get(fields, :message),
      level: Map.get(fields, :level)
    }
  end

  @doc """
  Build a `:completed` event map.

  Required keys: `:engine`, `:ok`.
  Optional: `:resume`, `:answer`, `:error`, `:usage`, `:meta`, `:run_id`, `:session_key`.
  """
  @spec completed(map()) :: map()
  def completed(fields) when is_map(fields) do
    %{
      __event__: :completed,
      engine: Map.fetch!(fields, :engine),
      ok: Map.fetch!(fields, :ok),
      resume: Map.get(fields, :resume),
      answer: Map.get(fields, :answer),
      error: Map.get(fields, :error),
      usage: Map.get(fields, :usage),
      meta: Map.get(fields, :meta),
      run_id: Map.get(fields, :run_id),
      session_key: Map.get(fields, :session_key)
    }
  end

  # ---------------------------------------------------------------------------
  # Delta (kept as a struct – has ordering semantics)
  # ---------------------------------------------------------------------------

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
    @spec new(run_id :: String.t(), seq :: pos_integer(), text :: String.t(), meta :: map() | nil) ::
            t()
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
end
